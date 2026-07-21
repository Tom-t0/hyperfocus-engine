from django.urls import path

from tasks import auth, views

urlpatterns = [
    # 認証（ログイン不要）
    path("api/auth/register/", auth.register),
    path("api/auth/login/", auth.login),
    path("api/auth/logout/", auth.logout),
    # タスク（要ログイン）
    path("api/tasks/", views.task_list),
    path("api/tasks/<int:task_id>/complete/", views.complete),
    path("api/tasks/<int:task_id>/uncomplete/", views.uncomplete),
    path("api/tasks/<int:task_id>/progress/", views.progress),
    path("api/tasks/<int:task_id>/triage/", views.triage),
    path("api/reset/extend/", views.extend_reset),
    path("api/reset/run/", views.run_reset),
]
