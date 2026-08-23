"""
Flutterフロント向けのシンプルなJSON API。

- GET  /api/tasks/            : 今日のタイルスタック（レベル順・進行中は各レベル最上部）
- POST /api/tasks/            : タスク作成
- PATCH  /api/tasks/<id>/     : タスク編集（送信フィールドのみ更新しペース再計算）
- DELETE /api/tasks/<id>/     : タスク削除
- POST /api/tasks/<id>/complete/  : ワンタップ完了
- POST /api/tasks/<id>/progress/  : 部分完了（実績数値入力）
- GET  /api/tasks/<id>/triage/    : トリアージ状態
- POST /api/tasks/<id>/triage/    : トリアージ選択の適用
- POST /api/reset/extend/         : 徹夜時の更新時間延長（上限=翌日正午）
- POST /api/reset/run/            : 次回更新日時の超過チェック＆日次処理
"""
import json
from datetime import date, datetime, time

from django.http import JsonResponse
from django.utils import timezone
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_http_methods

from .models import Level, Task, TaskStatus, UserProfile
from .progress import ProgressLog
from . import services


def _profile(request) -> UserProfile:
    profile, _ = UserProfile.objects.get_or_create(
        user=request.user,
        defaults={"next_reset_at": UserProfile.default_next_reset(timezone.now())},
    )
    return profile


def _get_task(request, task_id: int) -> Task | None:
    """本人のタスクを取得。無ければ None（呼び出し側で404を返す）。"""
    return Task.objects.filter(id=task_id, user=request.user).first()


def _not_found() -> JsonResponse:
    return JsonResponse(
        {"error": "タスクが見つかりません", "code": "task_not_found"}, status=404
    )


def _effective_start(task: Task) -> date:
    """タスクの開始日（追加した論理日）。未設定の旧タスクは作成日時から補完。"""
    if task.start_date:
        return task.start_date
    return timezone.localtime(task.created_at).date()


def _task_payload(task: Task, today: date) -> dict:
    triage = services.evaluate_triage(task, today)
    today_done = ProgressLog.objects.filter(
        task=task, logical_date=today
    ).aggregate_total()
    quota = task.today_quota(today)
    return {
        "id": task.id,
        "title": task.title,
        "level": task.level,
        "status": task.status,
        "unit": task.unit,
        "today_quota": quota,
        "today_done": today_done,
        "today_remaining": max(quota - today_done, 0),
        "remaining_amount": task.remaining_amount,
        # 編集フォームの初期値に使う元データ
        "total_amount": task.total_amount,
        "completed_amount": task.completed_amount,
        "work_days_per_week": task.work_days_per_week,
        "fixed_daily_amount": task.fixed_daily_amount,
        "actual_deadline": task.actual_deadline.isoformat() if task.actual_deadline else None,
        "target_deadline": task.target_deadline.isoformat() if task.target_deadline else None,
        "margin_days": task.margin_days,
        "rest_days_remaining": task.rest_days_remaining,
        "projected_completion": (
            task.projected_completion.isoformat() if task.projected_completion else None
        ),
        "in_progress_today": 0 < today_done < quota,
        "triage": {
            "active": triage.active,
            "quota": triage.quota,
            "standard": triage.standard,
            "final_stage": triage.final_stage,
            "options": [
                {"key": o.key, "label": o.label, "enabled": o.enabled}
                for o in triage.options
            ],
        },
    }


@csrf_exempt
@require_http_methods(["GET", "POST"])
def task_list(request):
    profile = _profile(request)
    today = profile.logical_today(timezone.now())

    if request.method == "POST":
        body = json.loads(request.body)
        task = Task(
            user=request.user,
            title=body["title"],
            level=body["level"],
            unit=body.get("unit", "ページ"),
            total_amount=int(body["total_amount"]),
            margin_days=int(body.get("margin_days", 0)),
            work_days_per_week=int(body.get("work_days_per_week", 7)),
            fixed_daily_amount=body.get("fixed_daily_amount"),
        )
        if body.get("actual_deadline"):
            task.actual_deadline = date.fromisoformat(body["actual_deadline"])
        task.initialize_pace(today)
        task.start_date = today  # 追加した論理日。これより前の日付では非表示
        task.save()
        return JsonResponse(_task_payload(task, today), status=201)

    # 表示対象日。?date=YYYY-MM-DD で昨日/明日などを閲覧できる（既定は今日）。
    view_date = today
    date_str = request.GET.get("date")
    if date_str:
        try:
            view_date = date.fromisoformat(date_str)
        except ValueError:
            view_date = today

    # タイルスタック: レベルA→D。進行中（部分完了あり）は各レベルの最上部（§3）
    # 追加した日より前の日付では、そのタスクは表示しない。
    tasks = [
        _task_payload(t, view_date)
        for t in request.user.tasks.exclude(
            status__in=[TaskStatus.ARCHIVED, TaskStatus.DONE]
        )
        if _effective_start(t) <= view_date
    ]
    tasks.sort(key=lambda p: (p["level"], not p["in_progress_today"]))
    return JsonResponse(
        {
            "today": today.isoformat(),
            "view_date": view_date.isoformat(),
            "tasks": tasks,
        }
    )


@csrf_exempt
@require_http_methods(["PATCH", "DELETE"])
def task_detail(request, task_id: int):
    """タスクの編集（PATCH）と削除（DELETE）。"""
    profile = _profile(request)
    today = profile.logical_today(timezone.now())
    task = _get_task(request, task_id)
    if task is None:
        return _not_found()

    if request.method == "DELETE":
        task.delete()
        return JsonResponse({"deleted": True})

    # PATCH: 送られてきたフィールドだけ更新する。
    body = json.loads(request.body)
    if "title" in body:
        task.title = body["title"]
    if "level" in body:
        task.level = body["level"]
    if "unit" in body:
        task.unit = body.get("unit") or "ページ"
    if "total_amount" in body:
        task.total_amount = int(body["total_amount"])
    if "fixed_daily_amount" in body:
        task.fixed_daily_amount = body["fixed_daily_amount"]
    if "margin_days" in body:
        task.margin_days = int(body["margin_days"])
    if "work_days_per_week" in body:
        task.work_days_per_week = int(body["work_days_per_week"])
    if "actual_deadline" in body:
        task.actual_deadline = (
            date.fromisoformat(body["actual_deadline"])
            if body["actual_deadline"]
            else None
        )
    # 全体量・期日・レベル等の変更を「今日」基準で反映する。消化済み分は保持され、
    # 残量ベースで標準ペース（トリアージ判定の基準）と休日権利を引き直す。
    task.initialize_pace(today)
    task.save()
    return JsonResponse(_task_payload(task, today))


@csrf_exempt
@require_http_methods(["POST"])
def complete(request, task_id: int):
    profile = _profile(request)
    today = profile.logical_today(timezone.now())
    task = _get_task(request, task_id)
    if task is None:
        return _not_found()
    services.complete_today(task, today)
    return JsonResponse(_task_payload(task, today))


@csrf_exempt
@require_http_methods(["POST"])
def uncomplete(request, task_id: int):
    profile = _profile(request)
    today = profile.logical_today(timezone.now())
    task = _get_task(request, task_id)
    if task is None:
        return _not_found()
    services.uncomplete_today(task, today)
    return JsonResponse(_task_payload(task, today))


@csrf_exempt
@require_http_methods(["POST"])
def progress(request, task_id: int):
    profile = _profile(request)
    today = profile.logical_today(timezone.now())
    task = _get_task(request, task_id)
    if task is None:
        return _not_found()
    body = json.loads(request.body)
    services.record_progress(task, int(body["amount"]), today)
    return JsonResponse(_task_payload(task, today))


@csrf_exempt
@require_http_methods(["GET", "POST"])
def triage(request, task_id: int):
    profile = _profile(request)
    today = profile.logical_today(timezone.now())
    task = _get_task(request, task_id)
    if task is None:
        return _not_found()

    if request.method == "POST":
        body = json.loads(request.body)
        try:
            services.apply_triage_choice(
                task,
                body["choice"],
                today,
                new_deadline=(
                    date.fromisoformat(body["new_deadline"])
                    if body.get("new_deadline")
                    else None
                ),
                friction_text=body.get("friction_text"),
            )
        except ValueError as e:
            # code はフロント側の翻訳キー（TriageError が持つ）
            return JsonResponse(
                {"error": str(e), "code": getattr(e, "code", None)}, status=400
            )

    return JsonResponse(_task_payload(task, today))


@csrf_exempt
@require_http_methods(["POST"])
def extend_reset(request):
    """徹夜対応: 更新時間を延長する。上限は翌日の正午（§4-1）。"""
    profile = _profile(request)
    body = json.loads(request.body)
    h, m = map(int, body["until"].split(":"))
    new_dt = profile.extend_reset(time(h, m), timezone.now())
    return JsonResponse({"next_reset_at": new_dt.isoformat()})


@csrf_exempt
@require_http_methods(["POST"])
def run_reset(request):
    """次回更新日時を超過していれば、休日の自動消費と翌日分の再計算を行う。"""
    profile = _profile(request)
    notices = services.run_daily_reset(profile)
    return JsonResponse(
        {"next_reset_at": profile.next_reset_at.isoformat(), "notices": notices}
    )
