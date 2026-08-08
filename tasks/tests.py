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

    def test_no_triage_on_creation_with_fractional_quota(self):
        # 生ペース 6/5=1.2/日 → 表示は切り上げ2。旧実装は 2 > 1.2*1.5=1.8 で
        # 作成直後に誤発動していた（バグ）。作成日はノルマ＝標準なので出ないのが正。
        task = make_task(
            self.user,
            level=Level.B,
            total_amount=6,
            actual_deadline=TODAY + timedelta(days=4),
            margin_days=0,
            work_days_per_week=7,
        )
        self.assertEqual(task.today_quota(TODAY), 2)  # 表示は切り上げの2
        self.assertFalse(services.evaluate_triage(task, TODAY).active)

    def test_force_through_suppresses_triage_for_that_day(self):
        task = make_task(self.user)  # 標準10問/日
        late = TODAY + timedelta(days=6)
        task.rest_days_remaining = 0
        task.save()
        # サボって1.5倍超 → 発動
        self.assertTrue(services.evaluate_triage(task, late).active)
        # 強行突破 → 同じ日は再表示されない
        services.apply_triage_choice(task, "force_through", late)
        self.assertEqual(task.triage_ack_date, late)
        self.assertFalse(services.evaluate_triage(task, late).active)
        # 翌日は再び発動（承知は当日限り）
        self.assertTrue(
            services.evaluate_triage(task, late + timedelta(days=1)).active
        )


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


class CatchUpTests(TestCase):
    """数日アプリを開かなかった場合の日次リセット（溜まった日数をまとめて精算）"""

    def setUp(self):
        self.user = User.objects.create(username="u")
        self.profile = UserProfile.objects.create(
            user=self.user,
            next_reset_at=datetime.combine(
                TODAY + timedelta(days=1), time(4, 0), tzinfo=TZ
            ),
        )

    def _run_at(self, days: int, at=time(4, 1)):
        return services.run_daily_reset(
            self.profile,
            now=datetime.combine(TODAY + timedelta(days=days), at, tzinfo=TZ),
        )

    def test_missed_days_each_consume_a_rest_day(self):
        # 3日開かない → 終わった論理日は TODAY / +1 / +2 の3日分
        task = make_task(self.user, work_days_per_week=5)
        task.rest_days_remaining = 5
        task.save()
        self._run_at(3)
        task.refresh_from_db()
        self.assertEqual(task.rest_days_remaining, 2)  # 5 - 3

    def test_days_with_progress_are_not_charged(self):
        task = make_task(self.user, work_days_per_week=5)
        task.rest_days_remaining = 5
        task.save()
        services.record_progress(task, 1, TODAY + timedelta(days=1))  # その日は進めた
        self._run_at(3)
        task.refresh_from_db()
        self.assertEqual(task.rest_days_remaining, 3)  # 5 - 2（進捗ありの日は消費なし）

    def test_next_reset_lands_on_the_upcoming_4am(self):
        self._run_at(3, at=time(9, 0))
        self.profile.refresh_from_db()
        nxt = timezone.localtime(self.profile.next_reset_at)
        self.assertEqual(nxt.date(), TODAY + timedelta(days=4))
        self.assertEqual(nxt.time(), time(4, 0))

    def test_same_notice_is_not_repeated_per_missed_day(self):
        # レベルCは毎日「完了予定日を延ばしました」を出しうるが、まとめて1件にする
        make_task(self.user, level=Level.C, margin_days=0)
        notices = self._run_at(3)
        self.assertEqual(len([n for n in notices if "完了予定日" in n]), 1)

    def test_rest_days_never_go_negative(self):
        task = make_task(self.user, work_days_per_week=5)
        task.rest_days_remaining = 1
        task.save()
        self._run_at(10)  # 10日放置しても0で止まる
        task.refresh_from_db()
        self.assertEqual(task.rest_days_remaining, 0)


class TimezoneBoundaryTests(TestCase):
    """日付境界はローカル時間（Asia/Tokyo）基準。DBはUTCで返るためズレやすい。"""

    def setUp(self):
        self.user = User.objects.create(username="u")

    def test_logical_today_is_local_after_db_roundtrip(self):
        UserProfile.objects.create(
            user=self.user,
            next_reset_at=datetime(2026, 8, 9, 4, 0, tzinfo=TZ),
        )
        p = UserProfile.objects.get(user=self.user)  # DBからはUTCで返る
        # 境界(8/9 4:00)前は、JSTの時刻に関わらず論理日は 8/8
        for hh in (0, 7, 12, 23):
            self.assertEqual(
                p.logical_today(datetime(2026, 8, 8, hh, 0, tzinfo=TZ)),
                date(2026, 8, 8),
                msg=f"JST {hh}時",
            )
        self.assertEqual(
            p.logical_today(datetime(2026, 8, 9, 3, 59, tzinfo=TZ)), date(2026, 8, 8)
        )
        self.assertEqual(
            p.logical_today(datetime(2026, 8, 9, 4, 30, tzinfo=TZ)), date(2026, 8, 9)
        )

    def test_default_next_reset_is_4am_local_not_utc(self):
        # 夕方 → 翌日の4時（JST）
        nxt = timezone.localtime(
            UserProfile.default_next_reset(datetime(2026, 8, 8, 16, 0, tzinfo=TZ))
        )
        self.assertEqual((nxt.date(), nxt.time()), (date(2026, 8, 9), time(4, 0)))
        # 深夜2時 → その日の4時（JST）
        nxt2 = timezone.localtime(
            UserProfile.default_next_reset(datetime(2026, 8, 8, 2, 0, tzinfo=TZ))
        )
        self.assertEqual((nxt2.date(), nxt2.time()), (date(2026, 8, 8), time(4, 0)))


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

    def test_task_hidden_on_dates_before_it_was_added(self):
        auth = self._auth(self._register("henry").json()["token"])
        created = self.client.post(
            "/api/tasks/",
            data=json.dumps(
                {"title": "今日追加", "level": "B", "total_amount": 50,
                 "actual_deadline": "2026-12-31"}
            ),
            content_type="application/json",
            **auth,
        )
        self.assertEqual(created.status_code, 201)

        today = self.client.get("/api/tasks/", **auth).json()["today"]
        yesterday = (
            date.fromisoformat(today) - timedelta(days=1)
        ).isoformat()
        tomorrow = (
            date.fromisoformat(today) + timedelta(days=1)
        ).isoformat()

        # 追加日（今日）と、それ以降（明日）は表示される
        self.assertEqual(len(self.client.get("/api/tasks/", **auth).json()["tasks"]), 1)
        self.assertEqual(
            len(self.client.get(f"/api/tasks/?date={tomorrow}", **auth).json()["tasks"]),
            1,
        )
        # 追加日より前（昨日）は表示されない
        self.assertEqual(
            len(self.client.get(f"/api/tasks/?date={yesterday}", **auth).json()["tasks"]),
            0,
        )


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


class TaskEditDeleteApiTests(TestCase):
    """タスクの編集（PATCH）と削除（DELETE）"""

    def setUp(self):
        self.client = Client()
        reg = self.client.post(
            "/api/auth/register/",
            data=json.dumps({"username": "owner", "password": "Str0ng-Pass-99"}),
            content_type="application/json",
        )
        self.token = reg.json()["token"]
        self.auth = {"HTTP_AUTHORIZATION": f"Token {self.token}"}
        self.user = User.objects.get(username="owner")

    def _create(self, **over):
        body = {
            "title": "原稿",
            "level": "B",
            "unit": "ページ",
            "total_amount": 100,
            "actual_deadline": "2026-12-31",
            "margin_days": 0,
        }
        body.update(over)
        r = self.client.post(
            "/api/tasks/", data=json.dumps(body),
            content_type="application/json", **self.auth,
        )
        self.assertEqual(r.status_code, 201)
        return r.json()["id"]

    def _patch(self, task_id, payload):
        return self.client.patch(
            f"/api/tasks/{task_id}/", data=json.dumps(payload),
            content_type="application/json", **self.auth,
        )

    def test_delete_removes_task(self):
        task_id = self._create()
        r = self.client.delete(f"/api/tasks/{task_id}/", **self.auth)
        self.assertEqual(r.status_code, 200)
        self.assertFalse(Task.objects.filter(id=task_id).exists())
        self.assertEqual(len(self.client.get("/api/tasks/", **self.auth).json()["tasks"]), 0)

    def test_delete_others_task_forbidden(self):
        task_id = self._create()
        other = self.client.post(
            "/api/auth/register/",
            data=json.dumps({"username": "intruder", "password": "Str0ng-Pass-99"}),
            content_type="application/json",
        ).json()["token"]
        r = self.client.delete(
            f"/api/tasks/{task_id}/", HTTP_AUTHORIZATION=f"Token {other}"
        )
        self.assertEqual(r.status_code, 404)
        self.assertTrue(Task.objects.filter(id=task_id).exists())

    def test_edit_title_and_unit(self):
        task_id = self._create()
        r = self._patch(task_id, {"title": "改題", "unit": "問"})
        self.assertEqual(r.status_code, 200)
        task = Task.objects.get(id=task_id)
        self.assertEqual(task.title, "改題")
        self.assertEqual(task.unit, "問")

    def test_edit_total_amount_recomputes_quota(self):
        # 期日を今日基準で10日先に。100→50に減らせばノルマも半減する。
        task_id = self._create(actual_deadline=None)
        today = date.fromisoformat(self.client.get("/api/tasks/", **self.auth).json()["today"])
        deadline = (today + timedelta(days=9)).isoformat()  # 今日含め10日
        self._patch(task_id, {"actual_deadline": deadline, "total_amount": 100})
        before = self.client.get("/api/tasks/", **self.auth).json()["tasks"][0]["today_quota"]
        self.assertEqual(before, 10)
        r = self._patch(task_id, {"total_amount": 50})
        self.assertEqual(r.json()["today_quota"], 5)

    def test_edit_preserves_completed_amount(self):
        task_id = self._create()
        self.client.post(f"/api/tasks/{task_id}/progress/",
                         data=json.dumps({"amount": 20}),
                         content_type="application/json", **self.auth)
        self._patch(task_id, {"total_amount": 80})
        task = Task.objects.get(id=task_id)
        self.assertEqual(task.completed_amount, 20)  # 消化済みは保持
        self.assertEqual(task.remaining_amount, 60)  # 80 - 20

    def test_edit_others_task_forbidden(self):
        task_id = self._create()
        other = self.client.post(
            "/api/auth/register/",
            data=json.dumps({"username": "intruder2", "password": "Str0ng-Pass-99"}),
            content_type="application/json",
        ).json()["token"]
        r = self.client.patch(
            f"/api/tasks/{task_id}/", data=json.dumps({"title": "乗っ取り"}),
            content_type="application/json", HTTP_AUTHORIZATION=f"Token {other}",
        )
        self.assertEqual(r.status_code, 404)
        self.assertEqual(Task.objects.get(id=task_id).title, "原稿")
