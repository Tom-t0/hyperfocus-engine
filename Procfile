web: gunicorn config.wsgi --bind 0.0.0.0:${PORT:-8000} --workers 3
release: python manage.py migrate --noinput
