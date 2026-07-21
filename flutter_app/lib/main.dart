// デッドライン管理アプリ（実績ベース）MVP - Flutterフロントエンド
//
// 設計書V7の以下を実装:
//  - §3 タイルスタックUI（レベルA→D、進行中は各レベル最上部）
//  - §3 ワンタップ完了 / 長押しで部分完了メニュー
//  - §4-1 深夜起動ポップアップ＋常時バナー（更新時間延長、上限は翌日正午）
//  - §6 トリアージ強制オーバーレイ（グレーアウト選択肢を含む）
//  - §6-2 ゾンビモードの無機質表示
//
// ApiClient のURLを差し替えれば Django バックエンド（/api/...）と接続できる。
// 単体で動かせるよう、デフォルトはインメモリのモック実装を使用。

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const QuotaApp());

/// 認証切れ（401）を表す。UIはこれを捕捉してログイン画面へ戻す。
class UnauthorizedException implements Exception {}

// ---------------------------------------------------------------------------
// モデル
// ---------------------------------------------------------------------------

class TaskTile {
  final int id;
  final String title;
  final String level; // A/B/C/D
  final String status; // active / zombie
  final String unit;
  final int todayQuota;
  final int todayRemaining;
  final int remainingAmount;
  final bool inProgressToday;
  final TriageState triage;

  TaskTile.fromJson(Map<String, dynamic> j)
      : id = j['id'],
        title = j['title'],
        level = j['level'],
        status = j['status'],
        unit = j['unit'],
        todayQuota = j['today_quota'],
        todayRemaining = j['today_remaining'],
        remainingAmount = j['remaining_amount'],
        inProgressToday = j['in_progress_today'] ?? false,
        triage = TriageState.fromJson(j['triage']);
}

class TriageOption {
  final String key;
  final String label;
  final bool enabled; // false = グレーアウト（非表示にしない §6-1）
  TriageOption.fromJson(Map<String, dynamic> j)
      : key = j['key'],
        label = j['label'],
        enabled = j['enabled'];
}

class TriageState {
  final bool active;
  final int quota;
  final double standard;
  final bool finalStage;
  final List<TriageOption> options;
  TriageState.fromJson(Map<String, dynamic> j)
      : active = j['active'] ?? false,
        quota = j['quota'] ?? 0,
        standard = (j['standard'] ?? 0).toDouble(),
        finalStage = j['final_stage'] ?? false,
        options = ((j['options'] ?? []) as List)
            .map((o) => TriageOption.fromJson(o))
            .toList();
}

// ---------------------------------------------------------------------------
// APIクライアント（Django接続。baseUrlを空にするとモックで動作）
// ---------------------------------------------------------------------------

class ApiClient {
  // ビルド時に --dart-define=API_BASE_URL=https://api.example.com で指定。
  // 未指定ならモックデータで単体動作する（オフラインデモ）。
  static const String baseUrl = String.fromEnvironment('API_BASE_URL');
  static bool get isMock => baseUrl.isEmpty;

  static const _tokenKey = 'auth_token';
  static const _userKey = 'auth_username';

  // 端末内で共有する認証トークン（どのApiClientインスタンスからでも使える）
  static String? _token;
  static String? username;

  static bool get hasToken => _token != null;

  /// 起動時に保存済みトークンを読み込む。
  static Future<void> loadToken() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey);
    username = prefs.getString(_userKey);
  }

  static Future<void> _saveToken(String token, String user) async {
    _token = token;
    username = user;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    await prefs.setString(_userKey, user);
  }

  static Future<void> _clearToken() async {
    _token = null;
    username = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userKey);
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Token $_token',
      };

  /// 401なら例外を投げ、その他の内容をJSONで返す共通処理。
  Map<String, dynamic> _decode(http.Response r) {
    if (r.statusCode == 401) throw UnauthorizedException();
    if (r.body.isEmpty) return {};
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  // ---- 認証 ----------------------------------------------------------

  /// ログイン。成功でnull、失敗でエラーメッセージを返す。
  Future<String?> login(String user, String password) =>
      _authRequest('login', user, password);

  /// 新規登録。成功でnull、失敗でエラーメッセージを返す。
  Future<String?> register(String user, String password) =>
      _authRequest('register', user, password);

  Future<String?> _authRequest(String kind, String user, String password) async {
    if (isMock) {
      await _saveToken('mock-token', user);
      return null;
    }
    final http.Response r;
    try {
      r = await http.post(
        Uri.parse('$baseUrl/api/auth/$kind/'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': user, 'password': password}),
      );
    } catch (_) {
      return 'サーバーに接続できません。通信環境を確認してください。';
    }
    final body = r.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    if (r.statusCode >= 400) {
      return body['error'] as String? ?? '失敗しました（${r.statusCode}）';
    }
    await _saveToken(body['token'] as String, body['username'] as String);
    return null;
  }

  Future<void> logout() async {
    if (!isMock && _token != null) {
      try {
        await http.post(Uri.parse('$baseUrl/api/auth/logout/'), headers: _headers);
      } catch (_) {
        // 通信失敗でもローカルのトークンは必ず消す
      }
    }
    await _clearToken();
  }

  // ---- タスク --------------------------------------------------------

  Future<List<TaskTile>> fetchTasks() async {
    if (isMock) return _MockData.tasks();
    final r = await http.get(Uri.parse('$baseUrl/api/tasks/'), headers: _headers);
    final body = _decode(r);
    return (body['tasks'] as List).map((j) => TaskTile.fromJson(j)).toList();
  }

  Future<void> completeToday(int id) async {
    if (isMock) return _MockData.complete(id);
    final r = await http.post(Uri.parse('$baseUrl/api/tasks/$id/complete/'),
        headers: _headers);
    _decode(r);
  }

  Future<void> uncompleteToday(int id) async {
    if (isMock) return _MockData.uncomplete(id);
    final r = await http.post(Uri.parse('$baseUrl/api/tasks/$id/uncomplete/'),
        headers: _headers);
    _decode(r);
  }

  /// タスク作成。bodyのキーはDjango側 task_list POST と同じ。
  Future<void> createTask(Map<String, dynamic> body) async {
    if (isMock) return _MockData.create(body);
    final r = await http.post(Uri.parse('$baseUrl/api/tasks/'),
        headers: _headers, body: jsonEncode(body));
    _decode(r);
  }

  Future<void> partialProgress(int id, int amount) async {
    if (isMock) return _MockData.partial(id, amount);
    final r = await http.post(Uri.parse('$baseUrl/api/tasks/$id/progress/'),
        headers: _headers, body: jsonEncode({'amount': amount}));
    _decode(r);
  }

  Future<String?> applyTriage(int id, String choice,
      {String? newDeadline, String? frictionText}) async {
    if (isMock) return _MockData.applyTriage(id, choice);
    final r = await http.post(Uri.parse('$baseUrl/api/tasks/$id/triage/'),
        headers: _headers,
        body: jsonEncode({
          'choice': choice,
          'new_deadline': ?newDeadline,
          'friction_text': ?frictionText,
        }));
    if (r.statusCode == 401) throw UnauthorizedException();
    if (r.statusCode >= 400) {
      return jsonDecode(utf8.decode(r.bodyBytes))['error'] as String?;
    }
    return null;
  }

  Future<void> extendReset(String hhmm) async {
    if (isMock) return;
    final r = await http.post(Uri.parse('$baseUrl/api/reset/extend/'),
        headers: _headers, body: jsonEncode({'until': hhmm}));
    _decode(r);
  }

  /// cron代替: スマホ単体運用ではアプリ起動時に日次リセット判定を依頼する（§4-1）
  Future<void> runResetCheck() async {
    if (isMock) return;
    try {
      await http.post(Uri.parse('$baseUrl/api/reset/run/'), headers: _headers);
    } catch (_) {
      // オフライン等で失敗しても起動は継続（次回起動時に再判定される）
    }
  }
}

// ---------------------------------------------------------------------------
// アプリ本体
// ---------------------------------------------------------------------------

class QuotaApp extends StatelessWidget {
  const QuotaApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'タスクタイル',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const RootScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// 起動時の認証ゲート
//  - モックモード（API_BASE_URL未指定）: そのままタスク画面（オフラインデモ）
//  - 実サーバー接続: 保存トークンがあればタスク画面、なければログイン画面
// ---------------------------------------------------------------------------

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});
  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  bool _checking = true;
  bool _authed = false;

  @override
  void initState() {
    super.initState();
    if (ApiClient.isMock) {
      _checking = false;
      _authed = true; // デモは認証不要
    } else {
      _check();
    }
  }

  Future<void> _check() async {
    await ApiClient.loadToken();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _authed = ApiClient.hasToken;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_authed) {
      return LoginScreen(onSuccess: () => setState(() => _authed = true));
    }
    return TileStackScreen(
      onLoggedOut: () => setState(() => _authed = false),
    );
  }
}

// ---------------------------------------------------------------------------
// ログイン / 新規登録画面
// ---------------------------------------------------------------------------

class LoginScreen extends StatefulWidget {
  final VoidCallback onSuccess;
  const LoginScreen({super.key, required this.onSuccess});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final api = ApiClient();
  final _formKey = GlobalKey<FormState>();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _registerMode = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = _registerMode
        ? await api.register(_user.text.trim(), _pass.text)
        : await api.login(_user.text.trim(), _pass.text);
    if (!mounted) return;
    if (err == null) {
      widget.onSuccess();
    } else {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.checklist_rtl,
                      size: 56,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 12),
                  Text('タスクタイル',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _user,
                    decoration: const InputDecoration(
                      labelText: 'ユーザー名',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    textInputAction: TextInputAction.next,
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'ユーザー名を入力してください'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _pass,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'パスワード',
                      prefixIcon: Icon(Icons.lock_outline),
                    ),
                    onFieldSubmitted: (_) => _submit(),
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'パスワードを入力してください';
                      if (_registerMode && v.length < 8) {
                        return '8文字以上にしてください';
                      }
                      return null;
                    },
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(_registerMode ? 'アカウント作成' : 'ログイン'),
                    ),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                              _registerMode = !_registerMode;
                              _error = null;
                            }),
                    child: Text(_registerMode
                        ? 'アカウントをお持ちの方はログイン'
                        : '新規登録はこちら'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TileStackScreen extends StatefulWidget {
  final VoidCallback? onLoggedOut;
  const TileStackScreen({super.key, this.onLoggedOut});
  @override
  State<TileStackScreen> createState() => _TileStackScreenState();
}

const levelColors = {
  'A': Color(0xFFE53935), // 赤
  'B': Color(0xFFFDD835), // 黄
  'C': Color(0xFF43A047), // 緑
  'D': Color(0xFFBDBDBD), // 灰
};
const levelNames = {
  'A': 'Must / 絶対不可侵',
  'B': 'Should / 努力義務',
  'C': 'Want / 趣味',
  'D': 'Routine / 裏メニュー',
};

class _TileStackScreenState extends State<TileStackScreen> {
  final api = ApiClient();
  List<TaskTile> tiles = [];
  bool loading = true;
  String? loadError;

  @override
  void initState() {
    super.initState();
    _load();
    // §4-1: 0:00〜4:00の初回起動時のみ延長ポップアップ
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final h = DateTime.now().hour;
      if (h >= 0 && h < 4) _showNightOwlPopup();
    });
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ログアウトしますか？'),
        content: const Text('この端末からログアウトします。データはサーバーに残ります。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('ログアウト')),
        ],
      ),
    );
    if (ok == true) {
      await api.logout();
      widget.onLoggedOut?.call();
    }
  }

  Future<void> _load() async {
    await api.runResetCheck();
    final List<TaskTile> t;
    try {
      t = await api.fetchTasks();
    } on UnauthorizedException {
      // トークン失効: ログイン画面へ戻す
      await api.logout();
      widget.onLoggedOut?.call();
      return;
    } catch (_) {
      setState(() {
        loading = false;
        loadError = 'サーバーに接続できません。通信環境を確認してください。';
      });
      return;
    }
    setState(() {
      tiles = t;
      loading = false;
      loadError = null;
    });
    // トリアージ発動中のタスクがあれば強制オーバーレイ（§6-1）
    final urgent = t.where((x) => x.triage.active).toList();
    if (urgent.isNotEmpty && mounted) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _showTriageOverlay(urgent.first));
    }
  }

  // ---- §4-1 深夜ポップアップ ------------------------------------------

  void _showNightOwlPopup() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('まだ起きていますか？'),
        content: const Text('本日のタスク更新時間を延長しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('いいえ（午前4時のまま）'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _pickExtensionTime();
            },
            child: const Text('変更する'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickExtensionTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 6, minute: 0),
      helpText: '延長できるのは翌日の正午（12:00）まで',
    );
    if (picked == null) return;
    // 上限はバックエンドでも強制されるが、UI側でも丸める（§4-1）
    final capped = picked.hour > 12 ? const TimeOfDay(hour: 12, minute: 0) : picked;
    await api.extendReset(
        '${capped.hour.toString().padLeft(2, '0')}:${capped.minute.toString().padLeft(2, '0')}');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('更新時間を ${capped.format(context)} に延長しました')));
    }
  }

  // ---- §3 消化操作 -----------------------------------------------------

  Future<void> _oneTapComplete(TaskTile t) async {
    await api.completeToday(t.id);
    _load();
  }

  // 完了済みタイルの再タップ → 確認の上で未完了へ戻す
  Future<void> _confirmUncomplete(TaskTile t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未完了にしますか？'),
        content: Text('「${t.title}」の今日の実績を取り消して、'
            '今日のノルマを復活させます。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('キャンセル')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('未完了に戻す')),
        ],
      ),
    );
    if (ok == true) {
      await api.uncompleteToday(t.id);
      _load();
    }
  }

  Future<void> _longPressMenu(TaskTile t) async {
    final controller = TextEditingController();
    final amount = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('部分完了：${t.title}'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '今日やった量（${t.unit}）',
            hintText: '例: 10',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('キャンセル')),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, int.tryParse(controller.text) ?? 0),
            child: const Text('記録する'),
          ),
        ],
      ),
    );
    if (amount != null && amount > 0) {
      await api.partialProgress(t.id, amount);
      _load(); // タイルは残り続け「今日の残りノルマ」で再描画される（§3）
    }
  }

  // ---- §6 トリアージ強制オーバーレイ -----------------------------------

  void _showTriageOverlay(TaskTile t) {
    showDialog(
      context: context,
      barrierDismissible: false, // 強制表示
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, size: 40),
        title: const Text('このままでは破綻します'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('「${t.title}」の今日のノルマ: ${t.triage.quota}${t.unit}'
                '（標準 ${t.triage.standard.toStringAsFixed(1)} の1.5倍超）'),
            const SizedBox(height: 12),
            // グレーアウトでも表示し続け、切迫感を突きつける（§6-1）
            ...t.triage.options.map((o) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: o.enabled
                          ? () async {
                              Navigator.pop(ctx);
                              await _applyTriage(t, o);
                            }
                          : null, // null = グレーアウト
                      child: Text(o.label),
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
  }

  Future<void> _applyTriage(TaskTile t, TriageOption o) async {
    String? frictionText;
    String? newDeadline;
    if (o.key == 'reset_deadline_with_friction') {
      // レベルA: 意図的な決断コスト（§6-2）
      final c = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('期日の再設定（レベルA）'),
          content: TextField(
            controller: c,
            decoration: const InputDecoration(
                labelText: '「関係者と合意済み」と入力してください'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('やめる')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('確定')),
          ],
        ),
      );
      if (ok != true) return;
      frictionText = c.text;
    }
    if (o.key.startsWith('reset_deadline')) {
      if (!mounted) return;
      final d = await showDatePicker(
        context: context,
        firstDate: DateTime.now().add(const Duration(days: 1)),
        lastDate: DateTime.now().add(const Duration(days: 365)),
      );
      if (d == null) return;
      newDeadline =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    }
    final err = await api.applyTriage(t.id, o.key,
        newDeadline: newDeadline, frictionText: frictionText);
    if (err != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
    }
    _load();
  }

  // ---- 画面 ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('今日のタスク'),
        actions: [
          if (!ApiClient.isMock)
            IconButton(
              tooltip: ApiClient.username == null
                  ? 'ログアウト'
                  : '${ApiClient.username} — ログアウト',
              icon: const Icon(Icons.logout),
              onPressed: _confirmLogout,
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'タスクを追加',
        onPressed: () async {
          final created = await Navigator.push<bool>(
            context,
            MaterialPageRoute(builder: (_) => const TaskFormScreen()),
          );
          if (created == true) _load();
        },
        child: const Icon(Icons.add),
      ),
      // §4-1 常時バナー: 作業途中の延長に対応
      bottomNavigationBar: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: InkWell(
          onTap: _pickExtensionTime,
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.nightlight_round, size: 16),
                SizedBox(width: 8),
                Text('更新時間を変更する'),
              ],
            ),
          ),
        ),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : loadError != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off, size: 40),
                      const SizedBox(height: 12),
                      Text(loadError!),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () {
                          setState(() => loading = true);
                          _load();
                        },
                        child: const Text('再試行'),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    children: [
                      for (final level in ['A', 'B', 'C', 'D'])
                        ..._levelSection(level),
                    ],
                  ),
                ),
    );
  }

  List<Widget> _levelSection(String level) {
    final group = tiles.where((t) => t.level == level).toList();
    if (group.isEmpty) return [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
        child: Row(children: [
          Icon(Icons.circle, size: 12, color: levelColors[level]),
          const SizedBox(width: 6),
          Expanded(
            child: Text('レベル$level（${levelNames[level]}）',
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge),
          ),
        ]),
      ),
      ...group.map(_tile),
    ];
  }

  Widget _tile(TaskTile t) {
    final isZombie = t.status == 'zombie';
    final done = t.todayRemaining == 0 && !isZombie;
    return Card(
      child: ListTile(
        onTap: done ? () => _confirmUncomplete(t) : () => _oneTapComplete(t),
        onLongPress: () => _longPressMenu(t),
        leading: Icon(
          done ? Icons.check_circle : Icons.radio_button_unchecked,
          color: done ? Colors.green : levelColors[t.level],
        ),
        title: Text(t.title),
        subtitle: Text(
          isZombie
              // 罪悪感を煽らない無機質な事実表示（§6-2）
              ? 'ℹ️ 逆算停止：期日を超過。残 ${t.remainingAmount}${t.unit} を消化してください'
              : t.inProgressToday
                  ? '今日の残りノルマ：${t.todayRemaining}${t.unit}'
                  : '今日のノルマ：${t.todayQuota}${t.unit}',
        ),
        trailing: t.triage.active
            ? IconButton(
                icon: const Icon(Icons.warning_amber_rounded,
                    color: Colors.orange),
                onPressed: () => _showTriageOverlay(t),
              )
            : null,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// タスク追加画面（§3: 全体量と期日を入力し、あとはシステムが逆算する）
// ---------------------------------------------------------------------------

class TaskFormScreen extends StatefulWidget {
  const TaskFormScreen({super.key});
  @override
  State<TaskFormScreen> createState() => _TaskFormScreenState();
}

class _TaskFormScreenState extends State<TaskFormScreen> {
  final api = ApiClient();
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _unit = TextEditingController(text: 'ページ');
  final _total = TextEditingController();
  final _margin = TextEditingController(text: '2');
  final _fixed = TextEditingController();
  String _level = 'B';
  int _workDays = 7;
  DateTime? _deadline;
  bool _saving = false;

  static const _levelHints = {
    'A': '仕事・提出物など、他者が関わる動かせない期日。ギブアップ不可。',
    'B': '資格勉強など自分で決めた期日。あとから再設定・アーカイブ可能。',
    'C': '趣味・自己満。日数が足りなくてもノルマは増えず、完了予定日が延びる。',
    'D': '終わりのない毎日のルーティン。固定量を毎日提示、翌日に繰り越さない。',
  };
  static const _defaultMargin = {'A': '3', 'B': '2'};

  bool get _isRoutine => _level == 'D';

  @override
  void dispose() {
    for (final c in [_title, _unit, _total, _margin, _fixed]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDeadline() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _deadline ?? now.add(const Duration(days: 7)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365 * 3)),
      helpText: '実際の期日（最終デッドライン）',
    );
    if (d != null) setState(() => _deadline = d);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_isRoutine && _deadline == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('期日を選択してください')));
      return;
    }
    setState(() => _saving = true);
    final unit = _unit.text.trim().isEmpty ? 'ページ' : _unit.text.trim();
    final body = <String, dynamic>{
      'title': _title.text.trim(),
      'level': _level,
      'unit': unit,
      if (_isRoutine) ...{
        'total_amount': 0,
        'fixed_daily_amount': int.parse(_fixed.text),
      } else ...{
        'total_amount': int.parse(_total.text),
        'actual_deadline':
            '${_deadline!.year}-${_deadline!.month.toString().padLeft(2, '0')}-${_deadline!.day.toString().padLeft(2, '0')}',
        // レベルC はマージンなし（§5）。バックエンド側でも強制される。
        'margin_days': _level == 'C' ? 0 : (int.tryParse(_margin.text) ?? 0),
        'work_days_per_week': _workDays,
      },
    };
    try {
      await api.createTask(body);
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('保存に失敗しました。通信環境を確認してください。')));
      }
      return;
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('タスクを追加')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _title,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'タイトル',
                hintText: '例: 提出レポート執筆',
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'タイトルを入力してください' : null,
            ),
            const SizedBox(height: 20),
            SegmentedButton<String>(
              segments: [
                for (final lv in ['A', 'B', 'C', 'D'])
                  ButtonSegment(
                    value: lv,
                    label: Text(lv),
                    icon: Icon(Icons.circle, size: 10, color: levelColors[lv]),
                  ),
              ],
              selected: {_level},
              onSelectionChanged: (s) => setState(() {
                _level = s.first;
                _margin.text = _defaultMargin[_level] ?? '0';
              }),
            ),
            const SizedBox(height: 6),
            Text(
              'レベル$_level（${levelNames[_level]}）\n${_levelHints[_level]}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            if (_isRoutine)
              TextFormField(
                controller: _fixed,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: '毎日の固定量',
                  suffixText: _unit.text,
                  hintText: '例: 20',
                ),
                validator: (v) => (int.tryParse(v ?? '') ?? 0) <= 0
                    ? '1以上の数値を入力してください'
                    : null,
              )
            else ...[
              TextFormField(
                controller: _total,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: '全体量',
                  suffixText: _unit.text,
                  hintText: '例: 100',
                ),
                validator: (v) => (int.tryParse(v ?? '') ?? 0) <= 0
                    ? '1以上の数値を入力してください'
                    : null,
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event),
                title: Text(
                  _deadline == null
                      ? '実際の期日を選択'
                      : '実際の期日: ${_deadline!.year}/${_deadline!.month}/${_deadline!.day}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _pickDeadline,
              ),
              if (_level != 'C') ...[
                TextFormField(
                  controller: _margin,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'マージン（バッファ日数）',
                    helperText: '目標期日 = 実際の期日 − マージン。ノルマはこちらで逆算',
                  ),
                  validator: (v) =>
                      (int.tryParse(v ?? '') ?? -1) < 0 ? '0以上の数値' : null,
                ),
                const SizedBox(height: 12),
              ],
              DropdownButtonFormField<int>(
                initialValue: _workDays,
                decoration: const InputDecoration(
                  labelText: '週の稼働日数',
                  helperText: '7未満にすると差分が「休日の権利」になる（曜日は固定しない）',
                ),
                items: [
                  for (var d = 1; d <= 7; d++)
                    DropdownMenuItem(value: d, child: Text('週$d日')),
                ],
                onChanged: (v) => setState(() => _workDays = v ?? 7),
              ),
            ],
            const SizedBox(height: 12),
            TextFormField(
              controller: _unit,
              decoration: const InputDecoration(
                labelText: '単位',
                hintText: 'ページ / 問 / 回 など',
              ),
              onChanged: (_) => setState(() {}), // suffixText更新
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              key: const Key('save_task'),
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.check),
              label: const Text('タスクを追加'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// スタンドアロン動作用モックデータ（バックエンド未接続時）
// ---------------------------------------------------------------------------

class _MockData {
  static final List<Map<String, dynamic>> _raw = [
    {
      'id': 1,
      'title': '提出レポート執筆',
      'level': 'A',
      'status': 'active',
      'unit': 'ページ',
      'today_quota': 8,
      'today_done': 0,
      'today_remaining': 8,
      'remaining_amount': 40,
      'in_progress_today': false,
      'triage': {'active': false},
    },
    {
      'id': 2,
      'title': '資格試験の問題集',
      'level': 'B',
      'status': 'active',
      'unit': '問',
      'today_quota': 25,
      'today_done': 0,
      'today_remaining': 25,
      'remaining_amount': 100,
      'in_progress_today': false,
      'triage': {
        'active': true,
        'quota': 25,
        'standard': 10.0,
        'final_stage': false,
        'options': [
          {'key': 'consume_margin', 'label': 'マージン消費', 'enabled': true},
          {'key': 'forfeit_rest', 'label': '休日返上', 'enabled': false},
          {'key': 'force_through', 'label': '強行突破', 'enabled': true},
        ],
      },
    },
    {
      'id': 3,
      'title': '積読の技術書',
      'level': 'C',
      'status': 'active',
      'unit': 'ページ',
      'today_quota': 5,
      'today_done': 0,
      'today_remaining': 5,
      'remaining_amount': 120,
      'in_progress_today': false,
      'triage': {'active': false},
    },
    {
      'id': 4,
      'title': '英単語',
      'level': 'D',
      'status': 'active',
      'unit': '語',
      'today_quota': 20,
      'today_done': 0,
      'today_remaining': 20,
      'remaining_amount': 20,
      'in_progress_today': false,
      'triage': {'active': false},
    },
  ];

  static List<TaskTile> tasks() =>
      _raw.map((j) => TaskTile.fromJson(j)).toList();

  static void complete(int id) {
    final t = _raw.firstWhere((x) => x['id'] == id);
    t['today_done'] = t['today_quota'];
    t['today_remaining'] = 0;
    t['in_progress_today'] = false;
  }

  static void uncomplete(int id) {
    final t = _raw.firstWhere((x) => x['id'] == id);
    t['today_done'] = 0;
    t['today_remaining'] = t['today_quota'];
    t['in_progress_today'] = false;
  }

  // タスク作成。バックエンドの逆算（残量÷稼働日）を簡易再現する。
  static void create(Map<String, dynamic> body) {
    final level = body['level'] as String;
    final total = body['total_amount'] as int;
    int quota;
    if (level == 'D') {
      quota = body['fixed_daily_amount'] as int;
    } else {
      final deadline = DateTime.parse(body['actual_deadline'] as String);
      final margin = body['margin_days'] as int;
      final workDays = body['work_days_per_week'] as int;
      final target = deadline.subtract(Duration(days: margin));
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final cal = target.difference(today).inDays + 1;
      final rest = (cal * (7 - workDays)) ~/ 7;
      final wd = cal - rest;
      quota = wd > 0 ? (total + wd - 1) ~/ wd : total;
    }
    final nextId =
        _raw.fold<int>(0, (m, t) => (t['id'] as int) > m ? t['id'] as int : m) +
            1;
    _raw.add({
      'id': nextId,
      'title': body['title'],
      'level': level,
      'status': 'active',
      'unit': body['unit'],
      'today_quota': quota,
      'today_done': 0,
      'today_remaining': quota,
      'remaining_amount': level == 'D' ? quota : total,
      'in_progress_today': false,
      'triage': {'active': false},
    });
  }

  static void partial(int id, int amount) {
    final t = _raw.firstWhere((x) => x['id'] == id);
    t['today_done'] = (t['today_done'] as int) + amount;
    final rem = (t['today_quota'] as int) - (t['today_done'] as int);
    t['today_remaining'] = rem < 0 ? 0 : rem;
    t['in_progress_today'] = rem > 0;
  }

  // トリアージ選択の適用。実バックエンドでは選択に応じて再計算されるが、
  // モックでは「解決済み＝トリアージ解除」の状態遷移だけを再現する。
  static String? applyTriage(int id, String choice) {
    final t = _raw.firstWhere((x) => x['id'] == id);
    switch (choice) {
      case 'consume_margin':
        // マージンを削ってノルマを標準ペースまで下げる（§6-1）
        final standard = ((t['triage'] as Map)['standard'] as double).round();
        t['today_quota'] = standard;
        t['today_remaining'] = standard;
      case 'archive':
        _raw.remove(t);
      default:
        // force_through / forfeit_rest / reset_deadline系: ノルマ据え置き
        break;
    }
    t['triage'] = {'active': false};
    return null;
  }
}
