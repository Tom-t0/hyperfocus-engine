"""トークン認証ミドルウェア。

`/api/` 配下はログイン必須（`Authorization: Token <key>`）とし、
未認証なら401を返す。ただし `/api/auth/`（登録・ログイン）は除外する。
Cookieを使わないヘッダートークン方式のためCSRFの対象外。
"""
from django.http import JsonResponse


class TokenAuthMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        path = request.path
        needs_auth = path.startswith("/api/") and not path.startswith("/api/auth/")
        if needs_auth:
            user = self._user_from_header(request.headers.get("Authorization", ""))
            if user is None:
                return JsonResponse(
                    {"error": "認証が必要です", "code": "auth_required"},
                    status=401,
                )
            request.user = user
        return self.get_response(request)

    @staticmethod
    def _user_from_header(header: str):
        parts = header.split()
        if len(parts) != 2 or parts[0] != "Token":
            return None
        # 遅延importで循環参照を回避
        from .models import AuthToken

        try:
            token = AuthToken.objects.select_related("user").get(key=parts[1])
        except AuthToken.DoesNotExist:
            return None
        if not token.user.is_active:
            return None
        return token.user
