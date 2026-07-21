"""
デッドライン管理アプリ（実績ベース）- Django設定

本番運用は環境変数で制御する（.env.example 参照）。
- DJANGO_SECRET_KEY: 本番では必ず設定（未設定だと開発用の危険な鍵になる）
- DJANGO_DEBUG=1 で開発モード（デフォルトは本番=False）
- DJANGO_ALLOWED_HOSTS: カンマ区切りの許可ホスト
- DJANGO_SECURE=1 でHTTPS強制などのセキュリティ設定を有効化
- POSTGRES_DB 等を設定するとPostgreSQL、未設定ならSQLite（開発用）
"""
import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent


def _env_bool(name: str, default: bool = False) -> bool:
    return os.environ.get(name, "1" if default else "").lower() in ("1", "true", "yes", "on")


# --- コアセキュリティ設定 -------------------------------------------------

SECRET_KEY = os.environ.get(
    "DJANGO_SECRET_KEY",
    "dev-only-insecure-key-set-DJANGO_SECRET_KEY-in-production",
)

DEBUG = _env_bool("DJANGO_DEBUG", False)

ALLOWED_HOSTS = [
    h.strip()
    for h in os.environ.get(
        "DJANGO_ALLOWED_HOSTS", "localhost,127.0.0.1,10.0.2.2"
    ).split(",")
    if h.strip()
]

# Renderは自身のホスト名を環境変数で渡す。自動で許可に加える（設定漏れ防止）。
_render_host = os.environ.get("RENDER_EXTERNAL_HOSTNAME")
if _render_host:
    ALLOWED_HOSTS.append(_render_host)

# --- アプリケーション -----------------------------------------------------

INSTALLED_APPS = [
    "django.contrib.contenttypes",
    "django.contrib.auth",
    "corsheaders",
    "tasks",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    # Flutter Web（ビルド済み）を同一オリジンで配信する（SecurityMiddleware直後）
    "whitenoise.middleware.WhiteNoiseMiddleware",
    # CORSはCommonMiddlewareより前に置く必要がある（別オリジン配信する場合用）
    "corsheaders.middleware.CorsMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
    # トークン認証（/api/ はログイン必須。/api/auth/ は除外）
    "tasks.middleware.TokenAuthMiddleware",
]

# --- Flutter Web の同一オリジン配信 --------------------------------------
# webapp/ にビルド済みFlutter Webを置き、サイトのルート（/）で配信する。
# /api/ はDjangoが処理し、それ以外の静的ファイル（index.html等）はwhitenoiseが返す。
STATIC_URL = "static/"
WHITENOISE_ROOT = BASE_DIR / "webapp"
WHITENOISE_INDEX_FILE = True

X_FRAME_OPTIONS = "DENY"

# CSRF(W003)はサイレンス: Cookieを使わないヘッダートークン認証のため、
# ブラウザが自動付与する資格情報が存在せずCSRFの前提が成立しない。
SILENCED_SYSTEM_CHECKS = ["security.W003"]

# Web版フロントを別オリジンで配信する場合の許可オリジン（カンマ区切り）。
# 未設定なら同一オリジンのみ（モバイルAPKはネイティブ通信なのでCORS不要）。
CORS_ALLOWED_ORIGINS = [
    o.strip()
    for o in os.environ.get("DJANGO_CORS_ORIGINS", "").split(",")
    if o.strip()
]

ROOT_URLCONF = "config.urls"
WSGI_APPLICATION = "config.wsgi.application"

USE_TZ = True
TIME_ZONE = "Asia/Tokyo"

# --- データベース ---------------------------------------------------------
# 優先順位: DATABASE_URL（多くのPaaS/Neon等） > POSTGRES_* > SQLite（開発用）

if os.environ.get("DATABASE_URL"):
    import dj_database_url

    DATABASES = {
        "default": dj_database_url.parse(
            os.environ["DATABASE_URL"], conn_max_age=600
        )
    }
elif os.environ.get("POSTGRES_DB"):
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.postgresql",
            "NAME": os.environ["POSTGRES_DB"],
            "USER": os.environ.get("POSTGRES_USER", "postgres"),
            "PASSWORD": os.environ.get("POSTGRES_PASSWORD", ""),
            "HOST": os.environ.get("POSTGRES_HOST", "localhost"),
            "PORT": os.environ.get("POSTGRES_PORT", "5432"),
            "CONN_MAX_AGE": 600,
        }
    }
else:
    DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.sqlite3",
            "NAME": BASE_DIR / "db.sqlite3",
        }
    }

# --- パスワード強度チェック（登録時に適用）-------------------------------

AUTH_PASSWORD_VALIDATORS = [
    {"NAME": "django.contrib.auth.password_validation.UserAttributeSimilarityValidator"},
    {
        "NAME": "django.contrib.auth.password_validation.MinimumLengthValidator",
        "OPTIONS": {"min_length": 8},
    },
    {"NAME": "django.contrib.auth.password_validation.CommonPasswordValidator"},
    {"NAME": "django.contrib.auth.password_validation.NumericPasswordValidator"},
]

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# --- HTTPS / 本番ハードニング --------------------------------------------
# TLS終端の背後で運用するときに DJANGO_SECURE=1 で有効化する。

if _env_bool("DJANGO_SECURE", False):
    SECURE_SSL_REDIRECT = True
    SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
    SECURE_HSTS_SECONDS = 31536000
    SECURE_HSTS_INCLUDE_SUBDOMAINS = True
    SECURE_HSTS_PRELOAD = True
    SESSION_COOKIE_SECURE = True
    CSRF_COOKIE_SECURE = True
    SECURE_CONTENT_TYPE_NOSNIFF = True

# --- ロギング（本番はコンソールへ、DEBUG時のみ詳細）----------------------

LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "handlers": {"console": {"class": "logging.StreamHandler"}},
    "root": {"handlers": ["console"], "level": "INFO"},
    "loggers": {
        "django.request": {
            "handlers": ["console"],
            "level": "ERROR",
            "propagate": False,
        }
    },
}
