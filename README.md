# タスクタイル（実績ベースのデッドライン管理アプリ）

基本設計書V7に基づく実装。定量タスクの逆算エンジンとトリアージロジックを核に、
トークン認証・マルチユーザー対応まで含めた公開可能な構成。

---

# 仕様書 V1（現在の仕様）

> 本セクションは 2026-07-21 時点の実装済み仕様のまとめ。基本設計書V7準拠。
> PDF版: `SPEC_V1.pdf`

## 1. 概要

- **名称**: タスクタイル（実績ベースのデッドライン管理アプリ）
- **コンセプト**: 時間ではなく「実績（量）」でタスクを管理し、1日のノルマを自動逆算する
  成果特化型の生産性ツール。全体進捗ゲージは持たず、重要度順（レベルA→D）に並んだ
  タスクタイルを上から消化させる。「今日何をどれだけやるか」を考えさせず、システムが
  提示したリストをただ潰していく状態を作り、過集中モードへの突入を支援する。
- **対象タスク**: 定量タスク（ページ数・問題数・回数など、数値で量を持つもの）
- **提供形態**: Web（ブラウザ）＋ Android アプリ。アカウント制のマルチユーザー。

## 2. 主な機能

### 2.1 逆算エンジンとタスク管理
- タスクは **レベルA〜D** に分類（後述）。各タスクは完全に独立した計算式を持ち、全体合算はしない。
- 算出されたノルマが優先度順のタイルとしてスタック表示される。
- **今日のノルマ = 残量 ÷ 残り稼働日数**。
- **二重デッドライン**: 実際の期日と、目標期日（＝実際の期日 − マージン日数）。ノルマ計算は目標期日を優先。
- **フレキシブル休日制**: 「週◯日稼働」で裁量を残す。休日の権利はアプリ全体でなくタスク単位で管理。
- **自動休日消費**: 進捗が全く無かった日は休日の権利を1消費。1でも進めれば消費しない。

### 2.2 レベル別のシステム挙動
| レベル | 位置づけ | 挙動 |
|---|---|---|
| 🔴 A (Must) | 他者が関わる動かせない期日 | マージン厳しめ。安易なアーカイブ不可 |
| 🟡 B (Should) | 自分で決めた期日 | 標準マージン。期日再設定・アーカイブ可 |
| 🟢 C (Want) | 趣味・自己満 | マージンなし。ノルマは増やさず完了予定日を後ろ倒し（静かな通知） |
| ⚪ D (Routine) | 終わりのないルーティン | 逆算なし。固定量を毎日提示、翌日繰越なし |

### 2.3 消化操作
- **ワンタップ完了**: タイルをタップで今日のノルマを完了。
- **部分完了**: 長押しで実績数値を入力。タイルは残り「今日の残りノルマ」として各レベル最上部に留置。
- **完了の取り消し**: 完了済みタイルを再タップ → 確認の上で未完了へ戻す（今日の実績を取り消し）。

### 2.4 日次リセットと徹夜対応
- 日付境界はデフォルト **午前4時**。
- 深夜0〜4時の初回起動時のみ「延長しますか？」ポップアップ＋常時バナー表示。
- 延長の上限は **翌日の正午** までシステムで強制。
- サーバーはユーザーごとの「次回更新日時」を監視（全ユーザー一斉バッチではない）。

### 2.5 トリアージ（フェイルセーフ）
- レベルA/Bで、計算上ノルマが標準ペースの **1.5倍** を超えると強制オーバーレイ。
- 選択肢: **マージン消費 / 休日返上 / 強行突破**（マージン・休日が枯渇していても非表示にせずグレーアウトで表示）。
- 最終分岐: レベルAは「関係者と合意済み」入力（フリクション）付きの期日再設定、期日超過で **ゾンビモード**（逆算停止・無機質表示）。レベルBは期日再設定・アーカイブ。

### 2.6 認証・マルチユーザー
- トークン認証（登録・ログイン・ログアウト）。`Authorization: Token <key>`。
- ユーザーごとにデータ完全分離（他人のタスクは参照・操作不可）。
- パスワードはハッシュ保存＋登録時に強度チェック（8文字以上等）。

## 3. 技術構成

- **バックエンド**: Python / Django 5.2（JSON API、プレーンなviews）
- **フロントエンド**: Flutter（Android / Web の同一コード）
- **データベース**: PostgreSQL（本番）/ SQLite（開発）
- **配信構成**: 同一オリジン。DjangoがビルドしたFlutter Web（`webapp/`）をwhitenoiseでルート配信し、`/api/` はAPI。CORS不要。
- **認証方式**: Cookieを使わないヘッダートークン（CSRF非該当）。

## 4. API仕様

認証以外の `/api/` はすべて `Authorization: Token <key>` が必須。

| メソッド | パス | 内容 |
|---|---|---|
| POST | /api/auth/register/ | 新規登録（トークン発行） |
| POST | /api/auth/login/ | ログイン（トークン発行） |
| POST | /api/auth/logout/ | ログアウト（提示トークン失効） |
| GET/POST | /api/tasks/ | タイルスタック取得 / タスク作成 |
| POST | /api/tasks/{id}/complete/ | ワンタップ完了 |
| POST | /api/tasks/{id}/uncomplete/ | 完了の取り消し |
| POST | /api/tasks/{id}/progress/ | 部分完了（実績数値） |
| GET/POST | /api/tasks/{id}/triage/ | トリアージ状態 / 選択適用 |
| POST | /api/reset/extend/ | 更新時間の延長（上限=翌日正午） |
| POST | /api/reset/run/ | 次回更新日時の超過チェック＆日次処理 |

## 5. デプロイ構成

- **ホスティング**: Render（無料枠）、`render.yaml` によるBlueprintデプロイ。
- **設定**: 環境変数駆動（SECRET_KEY / DEBUG / ALLOWED_HOSTS / DATABASE_URL / SECURE / CORS）。
- **セキュリティ**: 本番はHTTPS強制・HSTS・セキュアCookie。gunicornで配信。
- **日次リセット**: `python manage.py run_resets` をcronで定期実行（アプリ起動時にも自動判定）。

## 6. 現時点の制限・今後の課題（V2候補）

- **タスクの編集・一般削除・完了/履歴一覧** が未実装。
- **パスワードリセット**（要メール基盤）・**ログイン試行の回数制限** が未実装。
- **定性タスクのLLM自動分割**（設計書§2の別フェーズ）は未実装。
- **iOS** 未対応（Android / Web のみ）。
- 無料DBは約30日で期限切れのため、永続運用には Neon 等への移行が必要。
- Web版更新時はService Workerキャッシュにより、既存利用者に旧版が一時表示される。

---

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
