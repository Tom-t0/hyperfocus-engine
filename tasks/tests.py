"""
逆算エンジンとトリアージロジックの挙動テスト（MVPの主目的 §2）
＋ 認証・ユーザー分離のAPIテスト（本番公開向け）
"""
import json
from datetime import date, datetime, time, timedelta, timezone as dt_tz

from django.contrib.auth.models import User
from django.test import Client, TestCase
from django.utils import timezone

from .models import AuthToken, Level, Task, TaskStatus, UserProfile
from .progress import ProgressLog
from . import services

TZ = dt_tz(timedelta(hours=9))  # Asia/Tokyo
TODAY = date(2026, 7, 18)


def make_task(user, **kw):
    defaults = dict(
        user=user,
        title="テスト",
        level=Level.B,
        unit="問",
        total_amount=100,
        actual_deadline=TODAY + timedelta(days=13),  # 今日含め14日
        margin_days=4,
        work_days_per_week=7,
    )
    defaults.update(kw)
    task = Task(**defaults)
    task.initialize_pace(TODAY)
    task.save()
    return task


class QuotaEngineTests(TestCase):
    def setUp(self):
        self.user = User.objects.create(username="u")

    def test_quota_is_remaining_over_working_days(self):
        # 目標期日 = 実期日-4日 → 今日含め10日、週7稼働 → 100/10 = 10問
        task = make_task(self.user)
        self.assertEqual(task.today_quota(TODAY), 10)
        self.assertEqual(task.initial_daily_quota, 10.0)

    def test_target_deadline_prioritized_over_actual(self):
        task = make_task(self.user)
        self.assertEqual(task.target_deadline, task.actual_deadline - timedelta(days=4))

    def test_flexible_holidays_reduce_working_days(self):
        # 週5稼働: 暦10日 → 休日権利 int(10*2/7)=2 → 稼働8日 → ceil(100/8)=13
        task = make_task(self.user, work_days_per_week=5)
        self.assertEqual(task.rest_days_remaining, 2)
        self.assertEqual(task.today_quota(TODAY), 13)

    def test_partial_progress_recalculates_next_day(self):
        task = make_task(self.user)
        services.record_progress(task, 30, TODAY)
        # 翌日: 残70 ÷ 稼働9日 → ceil = 8
        self.assertEqual(task.today_quota(TODAY + timedelta(days=1)), 8)

    def test_level_c_quota_never_inflates(self):
        task = make_task(self.user, level=Level.C, margin_days=0)
        base = task.today_quota(TODAY)
        # 大幅にサボって日数が足りなくなってもノルマは据え置き
        late = TODAY + timedelta(days=8)
        self.assertEqual(task.today_quota(late), base)

    def test_level_d_fixed_amount(self):
        task = make_task(
            self.user, level=Level.D, actual_deadline=None, fixed_daily_amount=5
        )
        self.assertEqual(task.today_quota(TODAY), 5)
        self.assertEqual(task.today_quota(TODAY + timedelta(days=30)), 5)


class TriageTests(TestCase):
    def setUp(self):
        self.user = User.objects.create(username="u")

    def test_triage_fires_over_1_5x(self):
        task = make_task(self.user)  # 標準10問/日
        # 6日サボる → 残100 ÷ 稼働4日 = 25問 > 15問
        late = TODAY + timedelta(days=6)
        task.rest_days_remaining = 0
        state = services.evaluate_triage(task, late)
        self.assertTrue(state.active)
        self.assertEqual(state.quota, 25)

    def test_triage_not_fired_within_pace(self):
        task = make_task(self.user)
        self.assertFalse(services.evaluate_triage(task, TODAY).active)

    def test_exhausted_options_greyed_out_not_hidden(self):
        task = make_task(self.user, margin_days=0)
        task.rest_days_remaining = 0
        task.save()
        state = services.evaluate_triage(task, TODAY + timedelta(days=8))
        self.assertTrue(state.active)
        keys = {o.key: o.enabled for o in state.options}
        # 非表示ではなくグレーアウト（enabled=False で存在し続ける）
        self.assertFalse(keys["consume_margin"])
        self.assertFalse(keys["forfeit_rest"])
        self.assertTrue(keys["force_through"])

    def test_consume_margin_lowers_quota(self):
        task = make_task(self.user)
        late = TODAY + timedelta(days=6)
        before = task.today_quota(late)
        services.apply_triage_choice(task, "consume_margin", late)
        self.assertLess(task.today_quota(late), before + 1)
        self.assertEqual(task.margin_days, 3)

    def test_forfeit_rest_thins_quota(self):
        task = make_task(self.user, work_days_per_week=5)
        services.apply_triage_choice(task, "forfeit_rest", TODAY)
        self.assertEqual(task.rest_days_remaining, 0)

    def test_level_a_archive_forbidden(self):
        task = make_task(self.user, level=Level.A)
        with self.assertRaises(ValueError):
            services.apply_triage_choice(task, "archive", TODAY)

    def test_level_a_reset_requires_friction_text(self):
        task = make_task(self.user, level=Level.A, margin_days=0)
        with self.assertRaises(ValueError):
            services.apply_triage_choice(
                task,
                "reset_deadline_with_friction",
                TODAY,
                new_deadline=TODAY + timedelta(days=30),
                friction_text="はい",
            )
        services.apply_triage_choice(
            task,
            "reset_deadline_with_friction",
            TODAY,
            new_deadline=TODAY + timedelta(days=30),
            friction_text="関係者と合意済み",
        )
        self.assertEqual(task.actual_deadline, TODAY + timedelta(days=30))

    def test_level_b_final_stage_offers_reset_and_archive(self):
        task = make_task(self.user, level=Level.B, margin_days=0)
        task.rest_days_remaining = 0
        task.save()
        state = services.evaluate_triage(task, TODAY + timedelta(days=8))
        keys = [o.key for o in state.options]
        self.assertIn("reset_deadline", keys)
        self.assertIn("archive", keys)
        self.assertTrue(state.final_stage)


class DailyResetTests(TestCase):
    def setUp(self):
        self.user = User.objects.create(username="u")
        self.profile = UserProfile.objects.create(
            user=self.user,
            next_reset_at=datetime.combine(TODAY + timedelta(days=1), time(4, 0), tzinfo=TZ),
        )

    def _run(self, now):
        return services.run_daily_reset(self.profile, now=now)

    def test_no_progress_consumes_one_rest_day(self):
        task = make_task(self.user, work_days_per_week=5)  # 休日権利2
        self._run(datetime.combine(TODAY + timedelta(days=1), time(4, 1), tzinfo=TZ))
        task.refresh_from_db()
        self.assertEqual(task.rest_days_remaining, 1)

    def test_any_progress_preserves_rest_day(self):
        task = make_task(self.user, work_days_per_week=5)
        services.record_progress(task, 1, TODAY)  # 1問でも進めれば消費されない
        self._run(datetime.combine(TODAY + timedelta(days=1), time(4, 1), tzinfo=TZ))
        task.refresh_from_db()
        self.assertEqual(task.rest_days_remaining, 2)

    def test_level_a_overdue_goes_zombie(self):
        task = make_task(
            self.user, level=Level.A, actual_deadline=TODAY, margin_days=0
        )
        self.profile.next_reset_at = datetime.combine(
            TODAY + timedelta(days=1), time(4, 0), tzinfo=TZ
        )
        notices = self._run(
            datetime.combine(TODAY + timedelta(days=1), time(4, 1), tzinfo=TZ)
        )
        task.refresh_from_db()
        self.assertEqual(task.status, TaskStatus.ZOMBIE)
        # ゾンビモード: 逆算停止、残量のみ提示
        self.assertEqual(task.today_quota(TODAY + timedelta(days=1)), 100)
        self.assertTrue(any("逆算停止" in n for n in notices))

    def test_level_c_projection_pushed_quietly(self):
        task = make_task(self.user, level=Level.C, margin_days=0)
        notices = self._run(
            datetime.combine(TODAY + timedelta(days=1), time(4, 1), tzinfo=TZ)
        )
        task.refresh_from_db()
        self.assertGreater(task.projected_completion, task.target_deadline)
        self.assertTrue(any("完了予定日" in n for n in notices))


class NightOwlTests(TestCase):
    def setUp(self):
        self.user = User.objects.create(username="u")
        self.profile = UserProfile.objects.create(
            user=self.user,
            next_reset_at=datetime.combine(TODAY, time(4, 0), tzinfo=TZ),
        )

    def test_popup_only_between_0_and_4(self):
        night = datetime.combine(TODAY, time(2, 30), tzinfo=TZ)
        day = datetime.combine(TODAY, time(15, 0), tzinfo=TZ)
        self.assertTrue(self.profile.should_offer_extension(night))
        self.assertFalse(self.profile.should_offer_extension(day))

    def test_extension_capped_at_noon(self):
        now = datetime.combine(TODAY, time(2, 0), tzinfo=TZ)
        new_dt = self.profile.extend_reset(time(18, 0), now)  # 18時を要求
        self.assertEqual(new_dt.time(), time(12, 0))  # 正午で強制打ち切り
        self.assertEqual(new_dt.date(), TODAY)

    def test_logical_today_is_yesterday_before_reset(self):
        now = datetime.combine(TODAY, time(2, 0), tzinfo=TZ)
        self.assertEqual(self.profile.logical_today(now), TODAY - timedelta(days=1))


class AuthApiTests(TestCase):
    """トークン認証・ユーザー分離（本番公開の前提）"""

    def setUp(self):
        self.client = Client()

    def _register(self, username, password="Str0ng-Pass-99"):
        return self.client.post(
            "/api/auth/register/",
            data=json.dumps({"username": username, "password": password}),
            content_type="application/json",
        )

    def _auth(self, token):
        return {"HTTP_AUTHORIZATION": f"Token {token}"}

    def test_api_requires_authentication(self):
        r = self.client.get("/api/tasks/")
        self.assertEqual(r.status_code, 401)

    def test_register_returns_token(self):
        r = self._register("alice")
        self.assertEqual(r.status_code, 201)
        self.assertIn("token", r.json())
        self.assertTrue(AuthToken.objects.filter(user__username="alice").exists())

    def test_register_rejects_weak_password(self):
        r = self.client.post(
            "/api/auth/register/",
            data=json.dumps({"username": "bob", "password": "123"}),
            content_type="application/json",
        )
        self.assertEqual(r.status_code, 400)
        self.assertFalse(User.objects.filter(username="bob").exists())

    def test_register_rejects_duplicate_username(self):
        self._register("carol")
        r = self._register("carol")
        self.assertEqual(r.status_code, 409)

    def test_login_returns_token(self):
        self._register("dave", "Str0ng-Pass-99")
        r = self.client.post(
            "/api/auth/login/",
            data=json.dumps({"username": "dave", "password": "Str0ng-Pass-99"}),
            content_type="application/json",
        )
        self.assertEqual(r.status_code, 200)
        self.assertIn("token", r.json())

    def test_login_wrong_password_rejected(self):
        self._register("erin", "Str0ng-Pass-99")
        r = self.client.post(
            "/api/auth/login/",
            data=json.dumps({"username": "erin", "password": "wrong"}),
            content_type="application/json",
        )
        self.assertEqual(r.status_code, 401)

    def test_invalid_token_rejected(self):
        r = self.client.get("/api/tasks/", **self._auth("deadbeef"))
        self.assertEqual(r.status_code, 401)

    def test_users_only_see_their_own_tasks(self):
        token_a = self._register("userA").json()["token"]
        token_b = self._register("userB").json()["token"]

        create = self.client.post(
            "/api/tasks/",
            data=json.dumps(
                {
                    "title": "Aのタスク",
                    "level": "B",
                    "total_amount": 100,
                    "actual_deadline": "2026-08-31",
                }
            ),
            content_type="application/json",
            **self._auth(token_a),
        )
        self.assertEqual(create.status_code, 201)

        # Bの一覧にはAのタスクが出ない
        list_b = self.client.get("/api/tasks/", **self._auth(token_b))
        self.assertEqual(list_b.status_code, 200)
        self.assertEqual(len(list_b.json()["tasks"]), 0)

        # Bは他人のタスクIDを操作できない（404）
        task_id = create.json()["id"]
        forbidden = self.client.post(
            f"/api/tasks/{task_id}/complete/", **self._auth(token_b)
        )
        self.assertEqual(forbidden.status_code, 404)

    def test_logout_invalidates_token(self):
        token = self._register("frank").json()["token"]
        ok = self.client.get("/api/tasks/", **self._auth(token))
        self.assertEqual(ok.status_code, 200)

        self.client.post("/api/auth/logout/", **self._auth(token))
        after = self.client.get("/api/tasks/", **self._auth(token))
        self.assertEqual(after.status_code, 401)

    def test_missing_task_returns_404_not_500(self):
        token = self._register("grace").json()["token"]
        r = self.client.post("/api/tasks/999/complete/", **self._auth(token))
        self.assertEqual(r.status_code, 404)


class UncompleteTests(TestCase):
    """完了の取り消し（タイル再タップ → 未完了へ戻す）"""

    def setUp(self):
        self.user = User.objects.create(username="u")

    def test_uncomplete_reverts_one_tap_complete(self):
        task = make_task(self.user)  # ノルマ10問
        services.complete_today(task, TODAY)
        self.assertEqual(task.completed_amount, 10)

        services.uncomplete_today(task, TODAY)
        self.assertEqual(task.completed_amount, 0)
        self.assertEqual(task.today_quota(TODAY), 10)
        self.assertFalse(
            ProgressLog.objects.filter(task=task, logical_date=TODAY).exists()
        )

    def test_uncomplete_reverts_partial_then_complete(self):
        task = make_task(self.user)
        services.record_progress(task, 4, TODAY)
        services.complete_today(task, TODAY)  # 残り6問を消化扱い
        self.assertEqual(task.completed_amount, 10)

        # 今日の実績はすべて取り消される（部分完了ぶんも含む）
        services.uncomplete_today(task, TODAY)
        self.assertEqual(task.completed_amount, 0)

    def test_uncomplete_only_affects_today(self):
        task = make_task(self.user)
        services.record_progress(task, 10, TODAY - timedelta(days=1))  # 昨日の実績
        services.complete_today(task, TODAY)
        services.uncomplete_today(task, TODAY)
        # 昨日の実績は残る
        self.assertEqual(task.completed_amount, 10)
        self.assertTrue(
            ProgressLog.objects.filter(
                task=task, logical_date=TODAY - timedelta(days=1)
            ).exists()
        )

    def test_uncomplete_revives_done_task(self):
        # 期日=今日・マージン0 → 今日のノルマ=全量10問で、完了すると完遂になる
        task = make_task(
            self.user, total_amount=10, actual_deadline=TODAY, margin_days=0
        )
        services.complete_today(task, TODAY)
        self.assertEqual(task.status, TaskStatus.DONE)

        services.uncomplete_today(task, TODAY)
        self.assertEqual(task.status, TaskStatus.ACTIVE)
        self.assertEqual(task.remaining_amount, 10)
