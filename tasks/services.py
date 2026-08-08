"""
逆算エンジン・トリアージ・日次リセットのサービス層（設計書V7 §4〜§6）
"""
import math
from dataclasses import dataclass, field
from datetime import date, timedelta

from django.db import transaction
from django.utils import timezone

from .models import Level, Task, TaskStatus, UserProfile
from .progress import ProgressLog  # 分離した実績ログ

TRIAGE_THRESHOLD = 1.5  # 標準ペースの1.5倍でトリアージ発動（§6-1）
MAX_CATCHUP_DAYS = 400  # 日次リセットをまとめて精算する上限（暴走防止）


# ---------------------------------------------------------------------------
# 消化操作（§3）
# ---------------------------------------------------------------------------

@transaction.atomic
def record_progress(task: Task, amount: int, logical_date: date) -> Task:
    """部分完了（長押しメニュー）: 実績数値を加算する。"""
    amount = max(int(amount), 0)
    task.completed_amount = min(task.completed_amount + amount, task.total_amount)
    if task.remaining_amount == 0 and task.level != Level.D:
        task.status = TaskStatus.DONE
    task.save()
    if amount > 0:
        ProgressLog.objects.create(task=task, amount=amount, logical_date=logical_date)
    return task


@transaction.atomic
def complete_today(task: Task, logical_date: date) -> Task:
    """ワンタップ完了: 今日のノルマ全量を消化扱いにする。"""
    quota = task.today_quota(logical_date)
    already = ProgressLog.objects.filter(
        task=task, logical_date=logical_date
    ).aggregate_total()
    remaining_today = max(quota - already, 0)
    return record_progress(task, remaining_today, logical_date)


@transaction.atomic
def uncomplete_today(task: Task, logical_date: date) -> Task:
    """完了の取り消し: 今日の実績ログをすべて取り消し、未完了状態へ戻す。"""
    logs = ProgressLog.objects.filter(task=task, logical_date=logical_date)
    total = logs.aggregate_total()
    if total:
        task.completed_amount = max(task.completed_amount - total, 0)
        logs.delete()
    if task.status == TaskStatus.DONE:
        task.status = TaskStatus.ACTIVE
    task.save()
    return task


# ---------------------------------------------------------------------------
# トリアージ（緊急警告）モード（§6-1）
# ---------------------------------------------------------------------------

@dataclass
class TriageOption:
    key: str
    label: str
    enabled: bool  # False = グレーアウト表示（非表示にはしない §6-1）


@dataclass
class TriageState:
    active: bool
    quota: int = 0
    standard: float = 0.0
    options: list[TriageOption] = field(default_factory=list)
    final_stage: bool = False  # §6-2 の最終フェイルセーフ段階か


def evaluate_triage(task: Task, today: date) -> TriageState:
    """レベルA/Bで、計算上ノルマが標準ペースの1.5倍超なら発動。"""
    if task.level not in (Level.A, Level.B) or task.status != TaskStatus.ACTIVE:
        return TriageState(active=False)
    if task.remaining_amount == 0 or task.initial_daily_quota <= 0:
        return TriageState(active=False)

    quota = task.today_quota(today)  # 表示用（切り上げ済み）
    # 判定は切り上げ前の「生のペース」で行う。切り上げによる僅かな増分で
    # 作成直後（ノルマが小数のとき）に誤発動するのを防ぐ（バグ修正）。
    wd = task.working_days_left(today)
    raw_pace = task.remaining_amount / wd if wd > 0 else float(task.remaining_amount)
    if raw_pace <= task.initial_daily_quota * TRIAGE_THRESHOLD:
        return TriageState(active=False)

    # 「強行突破」で当日を承知済みなら、その日は再表示しない（§6）
    if task.triage_ack_date == today:
        return TriageState(active=False)

    options = [
        TriageOption("consume_margin", "マージン消費", task.margin_days > 0),
        TriageOption("forfeit_rest", "休日返上", task.rest_days_remaining > 0),
        TriageOption("force_through", "強行突破", True),
    ]

    # マージンも休日も枯渇 → 最終フェイルセーフ分岐（§6-2）
    final = task.margin_days == 0 and task.rest_days_remaining == 0
    if final:
        if task.level == Level.A:
            # 意図的な決断コスト付きの期日再設定のみ追加
            options.append(TriageOption("reset_deadline_with_friction", "期日の再設定（要合意入力）", True))
        else:  # Level B
            options.append(TriageOption("reset_deadline", "期日の再設定", True))
            options.append(TriageOption("archive", "アーカイブ（ギブアップ）", True))

    return TriageState(
        active=True,
        quota=quota,
        standard=task.initial_daily_quota,
        options=options,
        final_stage=final,
    )


@transaction.atomic
def apply_triage_choice(
    task: Task,
    choice: str,
    today: date,
    *,
    new_deadline: date | None = None,
    friction_text: str | None = None,
) -> Task:
    """トリアージ画面での選択を適用する。"""
    if choice == "consume_margin":
        if task.margin_days <= 0:
            raise ValueError("マージンは既にゼロです")  # グレーアウト項目の防御
        task.margin_days -= 1  # 目標期日を1日後ろ倒し

    elif choice == "forfeit_rest":
        if task.rest_days_remaining <= 0:
            raise ValueError("休日の権利は既にゼロです")
        task.rest_days_remaining = 0  # 休日の権利を消滅させ稼働日を増やす

    elif choice == "force_through":
        # 警告を無視して過集中で捌く。当日はもう再表示しない（§6）
        task.triage_ack_date = today

    elif choice == "reset_deadline_with_friction":
        # レベルA: 「関係者と合意済み」の入力を意図的な決断コストとする（§6-2）
        if task.level != Level.A:
            raise ValueError("このオプションはレベルA専用です")
        if friction_text != "関係者と合意済み":
            raise ValueError("「関係者と合意済み」と入力してください")
        _reset_deadline(task, new_deadline, today)

    elif choice == "reset_deadline":
        if task.level != Level.B:
            raise ValueError("このオプションはレベルB専用です")
        _reset_deadline(task, new_deadline, today)

    elif choice == "archive":
        # レベルAの安易なギブアップは許可しない（§5）
        if task.level == Level.A:
            raise ValueError("レベルAタスクはアーカイブできません")
        task.status = TaskStatus.ARCHIVED

    else:
        raise ValueError(f"不明な選択肢: {choice}")

    task.save()
    return task


def _reset_deadline(task: Task, new_deadline: date | None, today: date):
    if new_deadline is None or new_deadline <= today:
        raise ValueError("新しい期日（明日以降）を指定してください")
    task.actual_deadline = new_deadline
    task.status = TaskStatus.ACTIVE  # ゾンビからの復帰も可能
    task.initialize_pace(today)  # 計算ロジックを再始動


# ---------------------------------------------------------------------------
# 日次リセット（§4, §4-1）: 休日の自動消費・ゾンビ移行・レベルCの後ろ倒し
# ---------------------------------------------------------------------------

@transaction.atomic
def run_daily_reset(profile: UserProfile, now=None) -> list[str]:
    """ユーザーごとの「次回更新日時」を超過していたら日次処理を実行する。

    全ユーザー一斉バッチではなく、per-user監視で呼び出される想定（§4-1）。
    アプリを数日開かなかった場合は、溜まっている日数ぶんをまとめて精算する
    （1日分しか処理しないと休日の権利が減らず逆算の前提が狂うため）。
    戻り値は静かな通知メッセージのリスト。
    """
    now = now or timezone.now()
    if now < profile.next_reset_at:
        return []  # まだリセット時刻に達していない

    # 通知はタスク×種類ごとに最新だけ残す（5日分溜めて同じ通知を5回出さない）
    latest: dict[tuple[int, str], str] = {}
    boundary = timezone.localtime(profile.next_reset_at)
    local_now = timezone.localtime(now)

    for _ in range(MAX_CATCHUP_DAYS):
        if boundary > local_now:
            break
        _close_logical_day(
            profile,
            closed_day=(boundary - timedelta(days=1)).date(),
            new_today=boundary.date(),
            latest=latest,
        )
        # 延長は当日限り。次の境界は通常運用の午前4時に戻る。
        boundary = UserProfile.local_at(
            boundary.date() + timedelta(days=1), UserProfile.DEFAULT_BOUNDARY
        )
    else:
        # 極端に長く放置された場合の保険（休日権利は上限まで消費済み）
        boundary = UserProfile.default_next_reset(now)

    profile.next_reset_at = boundary
    profile.save(update_fields=["next_reset_at"])
    return list(latest.values())


def _close_logical_day(
    profile: UserProfile,
    closed_day: date,
    new_today: date,
    latest: dict[tuple[int, str], str],
) -> None:
    """終わった論理日1日ぶんの締め処理（休日消費・ゾンビ移行・C の後ろ倒し）。"""
    for task in profile.user.tasks.filter(status=TaskStatus.ACTIVE):
        had_progress = ProgressLog.objects.filter(
            task=task, logical_date=closed_day
        ).exists()

        # 自動休日消費: 1問でも進めていれば消費されない（§4）
        if task.level in (Level.A, Level.B, Level.C) and not had_progress:
            if task.rest_days_remaining > 0:
                task.rest_days_remaining -= 1
                task.save(update_fields=["rest_days_remaining"])

        # レベルA: 実際の期日を超過 → ゾンビモードへ強制移行（§6-2）
        if (
            task.level == Level.A
            and task.actual_deadline is not None
            and new_today > task.actual_deadline
            and task.remaining_amount > 0
        ):
            task.status = TaskStatus.ZOMBIE
            task.save(update_fields=["status"])
            latest[(task.id, "zombie")] = (
                f"ℹ️ 逆算停止：期日を超過。「{task.title}」の残タスクを消化してください"
            )

        # レベルC: ノルマは増やさず完了予定日を後ろへ（静かな通知 §5）
        if task.level == Level.C and task.remaining_amount > 0:
            pace = max(task.initial_daily_quota, 1.0)
            days_needed = math.ceil(task.remaining_amount / pace)
            new_projection = new_today + timedelta(days=days_needed - 1)
            if task.projected_completion and new_projection > task.projected_completion:
                task.projected_completion = new_projection
                task.save(update_fields=["projected_completion"])
                latest[(task.id, "projection")] = (
                    f"「{task.title}」の完了予定日を{new_projection:%m/%d}に延ばしました"
                )
