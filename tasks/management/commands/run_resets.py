"""全ユーザーの日次リセットを処理する（§4-1）。

cron等から数分おきに実行する想定。各ユーザーの next_reset_at を超過して
いれば、休日の自動消費・ゾンビ移行・レベルCの後ろ倒しを行う。アプリ起動時
の /api/reset/run/ はユーザーが開いた時だけなので、休まず開かないユーザー
にも確実に日次処理を効かせるためにサーバー側でも回す。

例: crontab で毎時5分に実行
    5 * * * * cd /app && python manage.py run_resets
"""
from django.core.management.base import BaseCommand

from tasks import services
from tasks.models import UserProfile


class Command(BaseCommand):
    help = "全ユーザーの日次リセット（休日消費・ゾンビ移行・完了予定日の後ろ倒し）を処理する"

    def handle(self, *args, **options):
        processed = 0
        reset = 0
        for profile in UserProfile.objects.select_related("user").iterator():
            notices = services.run_daily_reset(profile)
            processed += 1
            if notices:
                reset += 1
                for n in notices:
                    self.stdout.write(f"  [{profile.user}] {n}")
        self.stdout.write(
            self.style.SUCCESS(
                f"処理完了: {processed}ユーザーを確認、{reset}ユーザーで通知が発生"
            )
        )
