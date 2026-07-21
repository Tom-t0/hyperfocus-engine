"""
モデル定義（設計書V7 §3〜§6）

- Task: 定量タスク。各タスクは完全に独立した計算式を持つ（全体合算なし）。
- ProgressLog: 消化実績（ワンタップ完了 / 部分完了）の記録。
- UserProfile: ユーザーごとの「次回更新日時」（動的日次リセット、§4-1）。
"""
import math
import secrets
from datetime import date, datetime, time, timedelta

from django.conf import settings
from django.db import models
from django.utils import timezone


class AuthToken(models.Model):
    """モバイル/Web向けの単純なトークン認証。

    ログイン成功時に発行し、以後 `Authorization: Token <key>` で送る。
    1ユーザーが複数端末からログインでき、端末ごとにトークンを持つ。
    """

    key = models.CharField(max_length=40, primary_key=True)
    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="auth_tokens",
    )
    created_at = models.DateTimeField(auto_now_add=True)

    @classmethod
    def issue(cls, user) -> "AuthToken":
        return cls.objects.create(key=secrets.token_hex(20), user=user)

    def __str__(self):
        return f"{self.user} …{self.key[-6:]}"


class Level(models.TextChoices):
    A = "A", "Must / 絶対不可侵"
    B = "B", "Should / 努力義務"
    C = "C", "Want / 趣味・自己満"
    D = "D", "Routine / 裏メニュー"


class TaskStatus(models.TextChoices):
    ACTIVE = "active", "進行中"
    ZOMBIE = "zombie", "ゾンビモード（逆算停止）"
    ARCHIVED = "archived", "アーカイブ（ギブアップ）"
    DONE = "done", "完了"


class UserProfile(models.Model):
    """日次リセット（日付境界）をユーザー単位で管理する。

    - デフォルト境界: 午前4時（§4-1）
    - 深夜起動時にユーザーが延長可能。上限は「翌日の正午12:00」。
    - Django側は全ユーザー一斉バッチではなく next_reset_at を監視する。
    """

    DEFAULT_BOUNDARY = time(4, 0)
    EXTENSION_LIMIT = time(12, 0)  # 翌日の正午まで

    user = models.OneToOneField(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="profile"
    )
    next_reset_at = models.DateTimeField()

    def __str__(self):
        return f"{self.user} (next reset: {self.next_reset_at})"

    # ---- 日次リセット境界の計算 ----------------------------------------

    @classmethod
    def default_next_reset(cls, now: datetime) -> datetime:
        """now 以降で最初に訪れる「午前4時」を返す。"""
        tz = now.tzinfo
        candidate = datetime.combine(now.date(), cls.DEFAULT_BOUNDARY, tzinfo=tz)
        if candidate <= now:
            candidate += timedelta(days=1)
        return candidate

    def should_offer_extension(self, now: datetime) -> bool:
        """0:00〜4:00 の初回起動時のみ延長ポップアップを出す（§4-1）。"""
        return time(0, 0) <= now.time() < self.DEFAULT_BOUNDARY

    def extend_reset(self, new_time: time, now: datetime) -> datetime:
        """更新時間の延長。上限「翌日の正午」をシステムで強制する。

        深夜0:00〜4:00に起動している場合、「本日」のリセットは同日中に
        訪れるはずのもの。延長後の時刻が正午以下なら同日、それ以外は不正。
        """
        if new_time > self.EXTENSION_LIMIT:
            new_time = self.EXTENSION_LIMIT  # 日付の概念の崩壊を防ぐ（§4-1）
        tz = now.tzinfo
        candidate = datetime.combine(now.date(), new_time, tzinfo=tz)
        if candidate <= now:
            # 既に過ぎた時刻を指定された場合はデフォルトに戻す
            candidate = self.default_next_reset(now)
        self.next_reset_at = candidate
        self.save(update_fields=["next_reset_at"])
        return candidate

    def logical_today(self, now: datetime) -> date:
        """「アプリ上の今日」。次回リセットが翌日にまたがっている間は前日扱い。

        例: 深夜2時（リセットは当日4時）→ 論理日付は前日。
        """
        boundary = self.next_reset_at
        if now < boundary:
            return (boundary - timedelta(days=1)).date()
        return now.date()


class Task(models.Model):
    """定量タスク（MVP）。ページ数・回数などの数値を全体量として持つ。"""

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="tasks"
    )
    title = models.CharField(max_length=200)
    level = models.CharField(max_length=1, choices=Level.choices)
    status = models.CharField(
        max_length=10, choices=TaskStatus.choices, default=TaskStatus.ACTIVE
    )

    unit = models.CharField(max_length=20, default="ページ")  # 問 / ページ / 回 など
    total_amount = models.PositiveIntegerField()
    completed_amount = models.PositiveIntegerField(default=0)

    # ---- デッドラインの二重構造（§4）----
    actual_deadline = models.DateField(null=True, blank=True)  # 実際の期日（Dはnull）
    margin_days = models.PositiveIntegerField(default=0)  # バッファ。目標期日=実際-マージン

    # ---- フレキシブル休日制（§4）----
    work_days_per_week = models.PositiveSmallIntegerField(default=7)  # 週◯日稼働
    rest_days_remaining = models.PositiveIntegerField(default=0)  # 休日の権利（タスク単体）

    # 作成時の標準ペース。トリアージ発動判定（1.5倍）の基準（§6-1）
    initial_daily_quota = models.FloatField(default=0.0)

    # レベルD: 固定量を毎日提示（§5）
    fixed_daily_amount = models.PositiveIntegerField(null=True, blank=True)

    # レベルC: システムが勝手に後ろへ延ばす「完了予定日」（§5）
    projected_completion = models.DateField(null=True, blank=True)

    # 「強行突破」で承知した論理日。その日はトリアージを再表示しない（§6）
    triage_ack_date = models.DateField(null=True, blank=True)

    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["level", "-status", "actual_deadline", "id"]

    def __str__(self):
        return f"[{self.level}] {self.title}"

    # ---- 基本量 ---------------------------------------------------------

    @property
    def remaining_amount(self) -> int:
        return max(self.total_amount - self.completed_amount, 0)

    @property
    def target_deadline(self) -> date | None:
        """目標期日 = 実際の期日 - マージン。ノルマ計算の分母に優先使用（§4）。"""
        if self.actual_deadline is None:
            return None
        return self.actual_deadline - timedelta(days=self.margin_days)

    def calendar_days_left(self, today: date) -> int:
        """今日を含む、目標期日までの暦日数。"""
        if self.target_deadline is None:
            return 0
        return max((self.target_deadline - today).days + 1, 0)

    def working_days_left(self, today: date) -> int:
        """残り稼働日数 = 暦日数 - 休日の権利（残日数）。"""
        return max(self.calendar_days_left(today) - self.rest_days_remaining, 0)

    # ---- 初期化ヘルパ ----------------------------------------------------

    def initialize_pace(self, today: date):
        """作成時に休日権利と標準ペースを確定させる。"""
        if self.level == Level.D:
            self.initial_daily_quota = float(self.fixed_daily_amount or 0)
            self.rest_days_remaining = 0
            return
        cal = self.calendar_days_left(today)
        if self.level == Level.C:
            # マージンなし（§5）
            self.margin_days = 0
            cal = self.calendar_days_left(today)
        off_ratio = (7 - self.work_days_per_week) / 7
        self.rest_days_remaining = int(cal * off_ratio)
        wd = self.working_days_left(today)
        self.initial_daily_quota = (
            self.remaining_amount / wd if wd > 0 else float(self.remaining_amount)
        )
        if self.level == Level.C:
            self.projected_completion = self.target_deadline

    # ---- 今日のノルマ（各タスク独立計算・全体合算なし §3）----------------

    def today_quota(self, today: date) -> int:
        if self.status in (TaskStatus.ARCHIVED, TaskStatus.DONE):
            return 0
        if self.status == TaskStatus.ZOMBIE:
            # 逆算完全停止。残タスク量のみ提示（§6-2）
            return self.remaining_amount
        if self.level == Level.D:
            return self.fixed_daily_amount or 0
        if self.level == Level.C:
            # 日数不足でもノルマは増やさない（§5）
            return math.ceil(self.initial_daily_quota) if self.remaining_amount else 0
        wd = self.working_days_left(today)
        if wd <= 0:
            return self.remaining_amount
        return math.ceil(self.remaining_amount / wd)
