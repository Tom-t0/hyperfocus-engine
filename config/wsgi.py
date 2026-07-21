"""WSGIエントリポイント（gunicorn等の本番サーバーが読み込む）。"""
import os

from django.core.wsgi import get_wsgi_application

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "config.settings")

application = get_wsgi_application()
