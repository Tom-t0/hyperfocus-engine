from django.apps import AppConfig


class TasksConfig(AppConfig):
    name = "tasks"

    def ready(self):
        from . import progress  # noqa: F401  モデル登録
