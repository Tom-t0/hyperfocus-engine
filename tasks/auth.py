"""登録・ログイン・ログアウトのAPI。

トークン方式: 成功すると `{"token": "...", "username": "..."}` を返す。
Flutter側はトークンを保存し、以後のリクエストヘッダに付与する。
"""
import json

from django.contrib.auth import authenticate
from django.contrib.auth.models import User
from django.contrib.auth.password_validation import validate_password
from django.core.exceptions import ValidationError
from django.db import IntegrityError, transaction
from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.views.decorators.http import require_http_methods

from .models import AuthToken

MAX_USERNAME = 150


def _read(request):
    try:
        body = json.loads(request.body or b"{}")
    except json.JSONDecodeError:
        return None, None
    return (body.get("username") or "").strip(), (body.get("password") or "")


@csrf_exempt
@require_http_methods(["POST"])
def register(request):
    username, password = _read(request)
    if not username or not password:
        return JsonResponse({"error": "ユーザー名とパスワードは必須です"}, status=400)
    if len(username) > MAX_USERNAME:
        return JsonResponse({"error": "ユーザー名が長すぎます"}, status=400)
    try:
        validate_password(password)
    except ValidationError as e:
        return JsonResponse({"error": " ".join(e.messages)}, status=400)
    try:
        with transaction.atomic():
            user = User.objects.create_user(username=username, password=password)
    except IntegrityError:
        return JsonResponse({"error": "このユーザー名は既に使われています"}, status=409)
    token = AuthToken.issue(user)
    return JsonResponse({"token": token.key, "username": user.username}, status=201)


@csrf_exempt
@require_http_methods(["POST"])
def login(request):
    username, password = _read(request)
    if not username or not password:
        return JsonResponse({"error": "ユーザー名とパスワードは必須です"}, status=400)
    user = authenticate(username=username, password=password)
    if user is None:
        return JsonResponse(
            {"error": "ユーザー名またはパスワードが違います"}, status=401
        )
    token = AuthToken.issue(user)
    return JsonResponse({"token": token.key, "username": user.username})


@csrf_exempt
@require_http_methods(["POST"])
def logout(request):
    """提示されたトークンだけを失効させる（他端末のトークンは残す）。"""
    parts = request.headers.get("Authorization", "").split()
    if len(parts) == 2 and parts[0] == "Token":
        AuthToken.objects.filter(key=parts[1]).delete()
    return JsonResponse({"ok": True})
