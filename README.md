# 過集中エンジンのためのデッドライン管理アプリ（実績ベース）

基本設計書V7に基づく実装。定量タスクの逆算エンジンとトリアージロジックを核に、
トークン認証・マルチユーザー対応まで含めた公開可能な構成。

## 構成

```
deadline_app/
├── manage.py
├── requirements.txt    # Django / gunicorn / cors-headers / psycopg2
├── Procfile            # 本番起動（gunicorn）とリリース時マイグレーション
├── .env.example        # 本番用の環境変数サンプル
├── config/
│   ├── settings.py     # 環境変数駆動（DEBUG/SECRET_KEY/DB/HTTPS/CORS）
│   ├── urls.py
│   └── wsgi.py         # gunicornのエントリポイント
├── tasks/
│   ├── models.py       # AuthToken / Task / UserProfile
│   ├── auth.py         # 登録・ログイン・ログアウトAPI
│   ├── middleware.py   # トークン認証ミドルウェア
│   ├── progress.py     # ProgressLog（消化実績）
│   ├── services.py     # 逆算エンジン・トリアージ・日次リセット
│   ├── views.py        # タスクAPI（ユーザー別に分離）
│   ├── management/commands/run_resets.py  # cron用 日次リセット
│   └── tests.py        # 挙動＋認証テスト 35件
└── flutter_app/        # Flutterプロジェクト（Android/Web対応、ログイン画面込み）
    └── lib/main.dart
```

## ローカル開発（バックエンド）

```bash
pip install -r requirements.txt
python manage.py migrate
python manage.py test          # 35 tests OK
# 開発モードで起動（DEBUG有効）
DJANGO_DEBUG=1 python manage.py runserver
```

デフォルト（環境変数なし）では **DEBUG=False・SQLite** で動く。開発中に
Djangoのエラー詳細を見たいときは `DJANGO_DEBUG=1` を付ける。

## API概要

認証以外の `/api/` はすべて `Authorization: Token <key>` が必須。

| メソッド | パス | 内容 |
|---|---|---|
| POST | /api/auth/register/ | 新規登録（トークン発行） |
| POST | /api/auth/login/ | ログイン（トークン発行） |
| POST | /api/auth/logout/ | ログアウト（提示トークンを失効） |
| GET/POST | /api/tasks/ | タイルスタック取得 / タスク作成 |
| POST | /api/tasks/{id}/complete/ | ワンタップ完了 |
| POST | /api/tasks/{id}/uncomplete/ | 完了の取り消し（今日の実績を取り消す） |
| POST | /api/tasks/{id}/progress/ | 部分完了（実績数値） |
| GET/POST | /api/tasks/{id}/triage/ | トリアージ状態 / 選択適用 |
| POST | /api/reset/extend/ | 更新時間の延長（上限=翌日正午） |
| POST | /api/reset/run/ | 次回更新日時の超過チェック＆日次処理 |

## 本番デプロイ

### 1. 環境変数

`.env.example` をコピーして値を設定する（`.env` はコミット禁止）。最低限:

```bash
DJANGO_SECRET_KEY=<ランダムな長い文字列>
DJANGO_DEBUG=0
DJANGO_ALLOWED_HOSTS=api.example.com
DJANGO_SECURE=1                      # HTTPS終端の背後で運用するとき
POSTGRES_DB=deadline                 # 設定するとPostgreSQLを使用
POSTGRES_USER=deadline
POSTGRES_PASSWORD=<秘密>
POSTGRES_HOST=localhost
# Web版フロントを別ドメインで配信する場合のみ:
# DJANGO_CORS_ORIGINS=https://app.example.com
```

シークレットキーの生成例:
`python -c "import secrets; print(secrets.token_urlsafe(50))"`

### 2. 起動

```bash
pip install -r requirements.txt
python manage.py migrate
gunicorn config.wsgi --bind 0.0.0.0:8000 --workers 3   # Procfileと同等
```

**HTTPSは必須**（トークンが平文で流れないように）。gunicornはTLSを終端する
リバースプロキシ（Nginx / Caddy / ロードバランサ）の背後に置き、`DJANGO_SECURE=1`
を設定する。`SECURE_PROXY_SSL_HEADER` を有効にしてあるので、プロキシは
`X-Forwarded-Proto: https` を渡すこと。

### 3. 日次リセットの定期実行（cron）

各ユーザーの更新時間（§4-1）をサーバー側でも確実に処理するため、cron等で
`run_resets` を定期実行する（アプリを開かないユーザーの休日自動消費のため）:

```cron
5 * * * * cd /path/to/deadline_app && python manage.py run_resets
```

## Flutterアプリ

`flutter_app/` は Android/Web 対応の完全なプロジェクト。ログイン／新規登録画面を
持ち、トークンを端末に保存して認証付きでAPIを叩く。

### 本番用ビルド（配布するAPK）

接続先の本番APIを埋め込んでビルドする:

```bash
cd flutter_app
flutter build apk --release --dart-define=API_BASE_URL=https://api.example.com
```

生成物: `flutter_app/build/app/outputs/flutter-apk/app-release.apk`

- 起動するとログイン画面が出る。新規登録またはログイン後にタスク画面へ。
- `API_BASE_URL` を **未指定** でビルドすると、バックエンド不要の
  **オフラインモック（デモ）** として動く（ログイン不要）。UI確認用。
- 本番は**HTTPSのURL**を指定すること。平文HTTPは（`network_security_config.xml`
  により）ローカル開発ホストを除いてブロックされる。

Google Play / App Store に出す場合は、署名鍵の設定（`key.properties` と
`android/app/build.gradle.kts` の signingConfig）と、必要に応じて
`--dart-define` の値やアプリ名・アイコン・パッケージ名（現在
`com.deadlineapp.deadline_app`）の調整を行う。

### Web版

同じコードがWebでも動く。別オリジンで配信する場合はバックエンドの
`DJANGO_CORS_ORIGINS` にそのURLを追加する。

```bash
flutter build web --dart-define=API_BASE_URL=https://api.example.com
```

## 設計書との対応

- **§3** 独立計算・タイルスタック・部分完了の留置 → `views.task_list` のソートと `in_progress_today`
- **§4** 二重デッドライン・フレキシブル休日・自動休日消費 → `Task.target_deadline` / `run_daily_reset`
- **§4-1** 午前4時境界・深夜ポップアップ・翌日正午上限 → `UserProfile.extend_reset` / Flutter側ポップアップ
- **§5** レベルA〜D別挙動（Cのノルマ据え置き＋静かな延伸、Dの固定量） → `Task.today_quota`
- **§6-1** 1.5倍トリアージ・グレーアウト表示 → `services.evaluate_triage`
- **§6-2** レベルAのフリクション・ゾンビモード、レベルBの再設定/アーカイブ → `services.apply_triage_choice`

## 認証・セキュリティ

- **トークン認証**: 登録/ログインで発行、`Authorization: Token <key>` で送信。
  ユーザーごとにデータは完全分離（他人のタスクは参照・操作不可）。
- パスワードはDjango標準のハッシュで保存、登録時に強度チェック（8文字以上等）。
- 本番設定（`DJANGO_SECURE=1`）でHTTPS強制・HSTS・セキュアCookieを有効化。
- Cookieを使わないヘッダートークン方式のためCSRF非該当。

### 未対応（今後の課題）
- パスワードリセット（メール送信基盤が必要）やメール確認は未実装。
- レート制限（ログイン試行回数制限など）は未実装。公開時はリバースプロキシ
  やWAF側での対策を推奨。
- 定性タスクのLLM分割（設計書§2の別フェーズ）は未実装。
