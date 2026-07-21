# 無料デプロイ手順（Render + GitHub）

バックエンドを**無料**でインターネット公開し、スマホアプリから使えるようにする
手順です。かかるお金は **0円**（Renderの無料枠）。所要時間はだいたい30〜60分。

> ⚠️ 無料枠の制約
> - しばらくアクセスが無いとサーバーが眠り、次の起動に30〜60秒かかる。
> - Render付属の無料PostgreSQLは**約30日で期限切れ**になる。長く使うなら
>   後述の「Neonで永続無料DB」に切り替えるか、有料DB（月7ドル程度）に上げる。

以下、コマンドを打つ場所は **PowerShell**（プロジェクト直下 `deadline_app`）です。

---

## ステップ0：必要なアカウント（すべて無料・カード不要で作れる）

1. **GitHub** … コード置き場: https://github.com/signup
2. **Render** … サーバー: https://render.com （GitHubアカウントでログイン可）

この2つを作れば十分です。作成は本人確認が要るのでご自身で行ってください。
（私が代わりに登録・支払いすることはできません）

---

## ステップ1：コードをGitHubへ上げる

git初期化とコミットは**こちらで済ませてあります**。あとはあなたのGitHub上に
空のリポジトリを作って、それに向けてpushするだけです。

1. GitHubで新規リポジトリを作成（例: `deadline-app`）。READMEやgitignoreは
   追加しない（空のまま）でOK。**Private推奨**。
2. 作成後に表示される `https://github.com/あなた/deadline-app.git` をコピー。
3. PowerShellで以下を実行（URLは自分のものに置き換え）:

```powershell
git remote add origin https://github.com/あなた/deadline-app.git
git branch -M main
git push -u origin main
```

初回pushでGitHubのログイン（ブラウザ認証）を求められたら従ってください。

---

## ステップ2：Renderにデプロイする

このリポジトリには `render.yaml`（設定の設計図）が入っているので、
Renderが自動で「Webサーバー＋無料DB」を作ってくれます。

1. Renderにログイン → 右上 **「New +」→「Blueprint」**。
2. さっき上げたGitHubリポジトリを選ぶ。
3. Renderが `render.yaml` を読み取り、作成内容（`deadline-api` と
   `deadline-db`）を表示するので **「Apply」**。
4. ビルドとデプロイが走る（数分）。完了すると
   `https://deadline-api-xxxx.onrender.com` のようなURLが割り当てられる。
   → **このURLをメモ**（次で使う）。

`SECRET_KEY` はRenderが自動生成、`DATABASE_URL` も自動接続、マイグレーションも
ビルド時に自動実行されるので、手作業の設定はありません。

### 動作確認

ブラウザで `https://あなたのURL/api/tasks/` を開いて
`{"error": "認証が必要です"}` と **401** が返ればサーバーは正常です
（未ログインなので401が正解）。

---

## ステップ3：スマホアプリを本番URL向けにビルド

割り当てられたURLを埋め込んでAPKを作ります（`https://` に注意）:

```powershell
cd flutter_app
flutter build apk --release --dart-define=API_BASE_URL=https://あなたのURL.onrender.com
```

生成物: `flutter_app/build/app/outputs/flutter-apk/app-release.apk`

このAPKをスマホに入れて起動 → **新規登録** → ログインすると、クラウド上の
サーバーに自分のデータが保存されます。別のスマホからも同じアカウントで
ログインできます。

---

## ステップ4（任意）：日次リセットの定期実行

休日の自動消費（§4-1）をアプリを開かない日にも効かせたい場合、Renderの
**Cron Job**（無料枠あり）で1時間おきに実行します。

- Render → New + → Cron Job → 同じリポジトリ
- Command: `python manage.py run_resets`
- Schedule: `5 * * * *`（毎時5分）
- 環境変数 `DATABASE_URL` を Webサービスと同じDBに接続

※アプリは起動時にも自動でリセット判定を叩くので、これは無くても普段使いは可能。

---

## 補足：DBを永続無料にする（Neon）

Render無料DBの30日期限を避けたい場合、Neon（無料Postgres・期限なし）に
切り替えられます。

1. https://neon.tech でDBを作成し、接続文字列（`postgres://...`）を取得。
2. Render → `deadline-api` → Environment → `DATABASE_URL` の値を
   Neonの接続文字列に差し替え → 保存（自動再デプロイ）。
3. `render.yaml` の `databases:` は使わなくなるので、Render上の
   `deadline-db` は削除してよい。

---

## つまずいたら

- **500エラーが出る** → Renderの「Logs」を確認。多くは環境変数の設定漏れ。
- **アプリがサーバーに繋がらない** → APKビルド時の `API_BASE_URL` のスペルミス、
  または `https://` になっているか確認。
- **起動が遅い** → 無料枠のスリープ（初回のみ30〜60秒）。仕様です。

ログの読み方や詰まった箇所は、内容を貼ってもらえれば一緒に解決できます。
