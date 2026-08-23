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
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'l10n.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocaleController.load(); // 保存された表示言語を復元してから起動する
  runApp(const QuotaApp());
}

/// 認証切れ（401）を表す。UIはこれを捕捉してログイン画面へ戻す。
class UnauthorizedException implements Exception {}

/// APIエラー。code はサーバーが返す識別子（翻訳に使う）、
/// message はサーバーが返した文言（未知のcodeのときの保険）。
class ApiError {
  final String? code;
  final String message;
  const ApiError(this.code, this.message);
}

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
  final DateTime? actualDeadline; // 実際の期日（レベルDはnull）
  final DateTime? targetDeadline; // 目標期日 ＝ 実際の期日 − マージン
  final int marginDays;
  final TriageState triage;
  // 編集フォームの初期値に使う元データ
  final int totalAmount;
  final int completedAmount;
  final int workDaysPerWeek;
  final int? fixedDailyAmount;

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
        actualDeadline = parseDate(j['actual_deadline']),
        targetDeadline = parseDate(j['target_deadline']),
        marginDays = j['margin_days'] ?? 0,
        triage = TriageState.fromJson(j['triage']),
        totalAmount = j['total_amount'] ?? j['remaining_amount'] ?? 0,
        completedAmount = j['completed_amount'] ?? 0,
        workDaysPerWeek = j['work_days_per_week'] ?? 7,
        fixedDailyAmount = j['fixed_daily_amount'];
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

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
String ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
DateTime? parseDate(dynamic v) =>
    (v == null) ? null : DateTime.parse(v as String);
// モックデモ用: 今日からn日後のISO日付
String isoFromNow(int days) => ymd(DateTime.now().add(Duration(days: days)));

/// タスク一覧の取得結果（タスク群 ＋ アプリ上の「今日」）
class TaskListResult {
  final List<TaskTile> tasks;
  final DateTime today;
  TaskListResult(this.tasks, this.today);
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

  /// サーバー側が返すメッセージ（Djangoのパスワード検証など）の言語。
  /// MaterialApp が解決したロケールで更新される。
  static String langCode = 'ja';

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept-Language': langCode,
        if (_token != null) 'Authorization': 'Token $_token',
      };

  /// 401なら例外を投げ、その他の内容をJSONで返す共通処理。
  Map<String, dynamic> _decode(http.Response r) {
    if (r.statusCode == 401) throw UnauthorizedException();
    if (r.body.isEmpty) return {};
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  // ---- 認証 ----------------------------------------------------------

  /// ログイン。成功でnull、失敗でエラーを返す。
  Future<ApiError?> login(String user, String password) =>
      _authRequest('login', user, password);

  /// 新規登録。成功でnull、失敗でエラーを返す。
  Future<ApiError?> register(String user, String password) =>
      _authRequest('register', user, password);

  Future<ApiError?> _authRequest(
      String kind, String user, String password) async {
    if (isMock) {
      await _saveToken('mock-token', user);
      return null;
    }
    final http.Response r;
    try {
      r = await http.post(
        Uri.parse('$baseUrl/api/auth/$kind/'),
        headers: {
          'Content-Type': 'application/json',
          'Accept-Language': langCode,
        },
        body: jsonEncode({'username': user, 'password': password}),
      );
    } catch (_) {
      return const ApiError('connection', '');
    }
    final body = r.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    if (r.statusCode >= 400) {
      return ApiError(body['code'] as String?,
          body['error'] as String? ?? 'HTTP ${r.statusCode}');
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

  Future<TaskListResult> fetchTasks({DateTime? date}) async {
    if (isMock) {
      return TaskListResult(_MockData.tasks(), dateOnly(DateTime.now()));
    }
    final q = date != null ? '?date=${ymd(date)}' : '';
    final r = await http.get(Uri.parse('$baseUrl/api/tasks/$q'), headers: _headers);
    final body = _decode(r);
    final tasks =
        (body['tasks'] as List).map((j) => TaskTile.fromJson(j)).toList();
    final today = DateTime.parse(body['today'] as String);
    return TaskListResult(tasks, today);
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

  /// タスク編集。送ったフィールドだけ更新される（PATCH `/api/tasks/<id>/`）。
  Future<void> updateTask(int id, Map<String, dynamic> body) async {
    if (isMock) return _MockData.update(id, body);
    final r = await http.patch(Uri.parse('$baseUrl/api/tasks/$id/'),
        headers: _headers, body: jsonEncode(body));
    _decode(r);
  }

  /// タスク削除（DELETE `/api/tasks/<id>/`）。
  Future<void> deleteTask(int id) async {
    if (isMock) return _MockData.delete(id);
    final r = await http.delete(Uri.parse('$baseUrl/api/tasks/$id/'),
        headers: _headers);
    _decode(r);
  }

  Future<void> partialProgress(int id, int amount) async {
    if (isMock) return _MockData.partial(id, amount);
    final r = await http.post(Uri.parse('$baseUrl/api/tasks/$id/progress/'),
        headers: _headers, body: jsonEncode({'amount': amount}));
    _decode(r);
  }

  Future<ApiError?> applyTriage(int id, String choice,
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
      final b = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      return ApiError(b['code'] as String?, b['error'] as String? ?? '');
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

/// 表示言語の切り替え（端末の設定に従う / 日本語 / English）。
class LanguageButton extends StatelessWidget {
  const LanguageButton({super.key});

  @override
  Widget build(BuildContext context) {
    final t = tr(context);
    return PopupMenuButton<String>(
      tooltip: t.languageLabel,
      icon: const Icon(Icons.language),
      initialValue: LocaleController.locale.value?.languageCode ?? 'system',
      onSelected: (v) =>
          LocaleController.set(v == 'system' ? null : Locale(v)),
      itemBuilder: (_) => [
        PopupMenuItem(value: 'system', child: Text(t.languageSystem)),
        PopupMenuItem(value: 'ja', child: Text(t.japanese)),
        PopupMenuItem(value: 'en', child: Text(t.english)),
      ],
    );
  }
}

class QuotaApp extends StatelessWidget {
  const QuotaApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Locale?>(
      valueListenable: LocaleController.locale,
      builder: (context, override, _) => MaterialApp(
        onGenerateTitle: (ctx) => tr(ctx).appTitle,
        // override が null なら端末の言語設定に従う。
        // 未対応の言語なら supportedLocales の先頭（英語）にフォールバックする。
        locale: override,
        supportedLocales: const [Locale('en'), Locale('ja')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (ctx, child) {
          // サーバーへ送る Accept-Language を実際の表示言語に合わせる
          ApiClient.langCode = Localizations.localeOf(ctx).languageCode;
          return child!;
        },
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        home: const RootScreen(),
      ),
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
  ApiError? _error;

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
    final t = tr(context);
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
                  const Align(
                    alignment: Alignment.centerRight,
                    child: LanguageButton(),
                  ),
                  Icon(Icons.checklist_rtl,
                      size: 56,
                      color: Theme.of(context).colorScheme.primary),
                  const SizedBox(height: 12),
                  Text(t.appTitle,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _user,
                    decoration: InputDecoration(
                      labelText: t.usernameLabel,
                      prefixIcon: const Icon(Icons.person_outline),
                    ),
                    textInputAction: TextInputAction.next,
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? t.usernameRequired
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _pass,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: t.passwordLabel,
                      prefixIcon: const Icon(Icons.lock_outline),
                    ),
                    onFieldSubmitted: (_) => _submit(),
                    validator: (v) {
                      if (v == null || v.isEmpty) return t.passwordRequired;
                      if (_registerMode && v.length < 8) {
                        return t.passwordMin8;
                      }
                      return null;
                    },
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(t.apiError(_error!.code, _error!.message),
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
                          : Text(_registerMode ? t.createAccount : t.login),
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
                        ? t.switchToLogin
                        : t.switchToRegister),
                  ),
                  const Divider(height: 24),
                  TextButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const GuideScreen()),
                    ),
                    icon: const Icon(Icons.help_outline, size: 18),
                    label: Text(t.openGuide),
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

// ---------------------------------------------------------------------------
// 使い方案内（ログイン前でも見られる）
// ---------------------------------------------------------------------------

class GuideScreen extends StatelessWidget {
  /// ホームから開いたか（戻るボタンの文言だけ変える）。
  final bool fromHome;
  const GuideScreen({super.key, this.fromHome = false});

  @override
  Widget build(BuildContext context) {
    final t = tr(context);
    final theme = Theme.of(context);
    Widget h(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(0, 20, 0, 6),
          child: Text(text,
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: theme.colorScheme.primary)),
        );
    Widget p(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(text, style: theme.textTheme.bodyMedium),
        );
    Widget bullet(String text) => Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.bulletMarker),
              Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
            ],
          ),
        );

    return Scaffold(
      appBar: AppBar(
        title: Text(t.guideTitle),
        actions: const [LanguageButton()],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          h(t.guideWhatIsHeading),
          p(t.guideWhatIsBody),
          h(t.guideStepsHeading),
          bullet(t.guideStep1),
          bullet(t.guideStep2),
          bullet(t.guideStep3),
          bullet(t.guideStep4),
          h(t.guideLevelsHeading),
          bullet(t.guideLevelA),
          bullet(t.guideLevelB),
          bullet(t.guideLevelC),
          bullet(t.guideLevelD),
          h(t.guideFeaturesHeading),
          bullet(t.guideFeature1),
          bullet(t.guideFeature2),
          bullet(t.guideFeature3),
          h(t.guideTipsHeading),
          p(t.guideTipsBody),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(fromHome ? t.guideBackToHome : t.guideBackToLogin),
          ),
        ],
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
class _TileStackScreenState extends State<TileStackScreen> {
  final api = ApiClient();
  List<TaskTile> tiles = [];
  bool loading = true;
  bool loadError = false; // 言語変更に追従させるため文言ではなくフラグで持つ
  DateTime? selectedDate; // 表示中の日付（nullなら今日）
  DateTime? todayDate; // アプリ上の論理的な「今日」（サーバーから取得）
  bool showCompleted = false; // 全完了時に完了済みを表示するか

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool get isToday =>
      selectedDate == null ||
      (todayDate != null && _sameDay(selectedDate!, todayDate!));

  bool get allDone =>
      tiles.isEmpty ||
      tiles.every((t) => t.todayRemaining == 0 && t.status != 'zombie');

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
    final t = tr(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.logoutTitle),
        content: Text(t.logoutBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.logout)),
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
    final TaskListResult res;
    try {
      res = await api.fetchTasks(date: selectedDate);
    } on UnauthorizedException {
      // トークン失効: ログイン画面へ戻す
      await api.logout();
      widget.onLoggedOut?.call();
      return;
    } catch (_) {
      setState(() {
        loading = false;
        loadError = true;
      });
      return;
    }
    setState(() {
      tiles = res.tasks;
      todayDate = res.today;
      selectedDate ??= res.today; // 初回は今日を選択日にする
      showCompleted = false;
      loading = false;
      loadError = false;
    });
    // 今日を見ているときだけ、トリアージ発動中を強制オーバーレイ（§6-1）
    if (isToday) {
      final urgent = res.tasks.where((x) => x.triage.active).toList();
      if (urgent.isNotEmpty && mounted) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _showTriageOverlay(urgent.first));
      }
    }
  }

  // ---- 日付ナビゲーション ----------------------------------------------

  void _shiftDay(int delta) {
    final base = selectedDate ?? todayDate ?? DateTime.now();
    setState(() {
      selectedDate = dateOnly(base).add(Duration(days: delta));
      showCompleted = false;
    });
    _load();
  }

  void _backToToday() {
    setState(() {
      selectedDate = todayDate;
      showCompleted = false;
    });
    _load();
  }

  // ---- §4-1 深夜ポップアップ ------------------------------------------

  void _showNightOwlPopup() {
    final t = tr(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.nightOwlTitle),
        content: Text(t.nightOwlBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.nightOwlKeep),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _pickExtensionTime();
            },
            child: Text(t.nightOwlChange),
          ),
        ],
      ),
    );
  }

  Future<void> _pickExtensionTime() async {
    final t = tr(context);
    final picked = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 6, minute: 0),
      helpText: t.timePickerHelp,
      // アナログ時計を使わずデジタル入力のみにする
      initialEntryMode: TimePickerEntryMode.inputOnly,
    );
    if (picked == null) return;
    // 上限はバックエンドでも強制されるが、UI側でも丸める（§4-1）
    final capped = picked.hour > 12 ? const TimeOfDay(hour: 12, minute: 0) : picked;
    await api.extendReset(
        '${capped.hour.toString().padLeft(2, '0')}:${capped.minute.toString().padLeft(2, '0')}');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(t.extendedTo(capped.format(context)))));
    }
  }

  // ---- §3 消化操作 -----------------------------------------------------

  Future<void> _oneTapComplete(TaskTile t) async {
    await api.completeToday(t.id);
    _load();
  }

  // 完了済みタイルの再タップ → 確認の上で未完了へ戻す
  Future<void> _confirmUncomplete(TaskTile task) async {
    final t = tr(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.uncompleteTitle),
        content: Text(t.uncompleteBody(task.title)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.uncompleteConfirm)),
        ],
      ),
    );
    if (ok == true) {
      await api.uncompleteToday(task.id);
      _load();
    }
  }

  // 長押し → 操作メニュー（部分完了の記録 / 編集 / 削除）
  Future<void> _longPressMenu(TaskTile task) async {
    final t = tr(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(task.title,
                  style: Theme.of(ctx).textTheme.titleMedium,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add_check),
              title: Text(t.menuPartial),
              onTap: () => Navigator.pop(ctx, 'partial'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(t.menuEdit),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(ctx).colorScheme.error),
              title: Text(t.menuDelete,
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    switch (action) {
      case 'partial':
        await _recordPartial(task);
      case 'edit':
        await _editTask(task);
      case 'delete':
        await _deleteTask(task);
    }
  }

  Future<void> _recordPartial(TaskTile task) async {
    final t = tr(context);
    final controller = TextEditingController();
    final amount = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.partialTitle(task.title)),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: t.partialLabel(task.unit),
            hintText: t.partialHint,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: Text(t.cancel)),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, int.tryParse(controller.text) ?? 0),
            child: Text(t.partialRecord),
          ),
        ],
      ),
    );
    if (amount != null && amount > 0) {
      await api.partialProgress(task.id, amount);
      _load(); // タイルは残り続け「今日の残りノルマ」で再描画される（§3）
    }
  }

  // 編集画面へ遷移。保存されたら一覧を再取得する。
  Future<void> _editTask(TaskTile t) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => TaskFormScreen(task: t)),
    );
    if (saved == true) _load();
  }

  // 削除。取り消せない操作なので確認を挟む。
  Future<void> _deleteTask(TaskTile task) async {
    final t = tr(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.deleteTitle),
        content: Text(t.deleteBody(task.title)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.deleteConfirm),
          ),
        ],
      ),
    );
    if (ok == true) {
      await api.deleteTask(task.id);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.deletedSnack(task.title))));
      }
      _load();
    }
  }

  // ---- §6 トリアージ強制オーバーレイ -----------------------------------

  void _showTriageOverlay(TaskTile task) {
    final t = tr(context);
    showDialog(
      context: context,
      barrierDismissible: false, // 強制表示
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.warning_amber_rounded, size: 40),
        title: Text(t.triageTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.triageBody(task.title, task.triage.quota, task.unit,
                task.triage.standard)),
            const SizedBox(height: 12),
            // グレーアウトでも表示し続け、切迫感を突きつける（§6-1）
            ...task.triage.options.map((o) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: o.enabled
                          ? () async {
                              Navigator.pop(ctx);
                              await _applyTriage(task, o);
                            }
                          : null, // null = グレーアウト
                      child: Text(t.triageOption(o.key, o.label)),
                    ),
                  ),
                )),
          ],
        ),
      ),
    );
  }

  Future<void> _applyTriage(TaskTile task, TriageOption o) async {
    final t = tr(context);
    String? frictionText;
    String? newDeadline;
    if (o.key == 'reset_deadline_with_friction') {
      // レベルA: 意図的な決断コスト（§6-2）
      final c = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.triageResetATitle),
          content: TextField(
            controller: c,
            decoration: InputDecoration(labelText: t.frictionLabel),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(t.frictionCancel)),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t.frictionConfirm)),
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
    final err = await api.applyTriage(task.id, o.key,
        newDeadline: newDeadline, frictionText: frictionText);
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t.apiError(err.code, err.message))));
    }
    _load();
  }

  // ---- 画面 ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = tr(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.appTitle),
        actions: [
          const LanguageButton(),
          IconButton(
            tooltip: t.guideTooltip,
            icon: const Icon(Icons.help_outline),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const GuideScreen(fromHome: true)),
            ),
          ),
          if (!ApiClient.isMock)
            IconButton(
              tooltip: t.logoutTooltip(ApiClient.username),
              icon: const Icon(Icons.logout),
              onPressed: _confirmLogout,
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final created = await Navigator.push<bool>(
            context,
            MaterialPageRoute(builder: (_) => const TaskFormScreen()),
          );
          if (created == true) _load();
        },
        icon: const Icon(Icons.add),
        label: Text(t.addTask),
      ),
      // §4-1 常時バナー: 作業途中の延長に対応
      bottomNavigationBar: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: InkWell(
          onTap: _pickExtensionTime,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.nightlight_round, size: 16),
                const SizedBox(width: 8),
                Text(t.changeResetTime),
              ],
            ),
          ),
        ),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : loadError
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off, size: 40),
                      const SizedBox(height: 12),
                      Text(t.connectionError),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () {
                          setState(() => loading = true);
                          _load();
                        },
                        child: Text(t.retry),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    _dateBar(),
                    Expanded(
                      // 「今日のタスクはありません」の空表示は今日だけ。
                      // 今日以外は完了済みも含めて全タスクを表示する。
                      child: (tiles.isEmpty ||
                              (isToday && allDone && !showCompleted))
                          ? _emptyState()
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
                    ),
                  ],
                ),
    );
  }

  // 画面上部の日付バー（矢印で前後の日へ移動）
  Widget _dateBar() {
    final t = tr(context);
    final d = selectedDate ?? todayDate ?? DateTime.now();
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: t.prevDay,
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _shiftDay(-1),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    tr(context).dateLabel(d, todayDate),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              IconButton(
                tooltip: t.nextDay,
                icon: const Icon(Icons.chevron_right),
                onPressed: () => _shiftDay(1),
              ),
            ],
          ),
          if (!isToday)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: TextButton.icon(
                onPressed: _backToToday,
                icon: const Icon(Icons.today, size: 16),
                label: Text(t.backToToday),
              ),
            ),
        ],
      ),
    );
  }

  // 全タスク完了時／タスクが無いときの表示
  Widget _emptyState() {
    final t = tr(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline, size: 56, color: Colors.green),
          const SizedBox(height: 12),
          Text(
            isToday ? t.emptyToday : t.emptyOtherDay,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (isToday) ...[
            const SizedBox(height: 4),
            Text(t.goodWork,
                style: Theme.of(context).textTheme.bodySmall),
          ],
          if (tiles.isNotEmpty) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => setState(() => showCompleted = true),
              child: Text(t.showCompleted),
            ),
          ],
        ],
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
            child: Text(tr(context).levelSection(level),
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge),
          ),
        ]),
      ),
      ...group.map((t) => _tile(t, isToday)),
    ];
  }

  // タイル右端の「期日まであと何日」バッジ。
  // 目標期日があればそこまで、無ければ実際の期日まで。レベルD等は表示しない。
  Widget? _deadlineBadge(TaskTile task) {
    final t = tr(context);
    final target = task.targetDeadline;
    final actual = task.actualDeadline;
    if (target == null && actual == null) return null;
    // 残り日数は「表示中の日付」を基準にする（未来を見れば連動して短くなる）
    final ref = dateOnly(selectedDate ?? todayDate ?? DateTime.now());
    int daysTo(DateTime d) => dateOnly(d).difference(ref).inDays;

    final hasMargin = target != null && actual != null && task.marginDays > 0;
    final scheme = Theme.of(context).colorScheme;
    final String label;
    final String daysText;
    final Color color;

    if (hasMargin) {
      final dTarget = daysTo(target);
      final dActual = daysTo(actual);
      if (dTarget > 0) {
        label = t.badgeTargetIn;
        daysText = t.badgeDays(dTarget);
        color = scheme.onSurfaceVariant;
      } else if (dActual > 0) {
        // 目標期日は過ぎたが、実際の期日まではまだ猶予がある（マージン期間）
        // → 実際の期日を基準に表示する
        label = t.badgeTargetOverdue;
        daysText = t.badgeActualIn(dActual);
        color = Colors.orange.shade800;
      } else if (dActual == 0) {
        label = t.badgeTargetOverdue;
        daysText = t.badgeActualToday;
        color = scheme.error;
      } else {
        label = t.badgeOverdue;
        daysText = t.badgeOverdueBy(-dActual);
        color = scheme.error;
      }
    } else {
      final d = daysTo((actual ?? target)!);
      if (d > 0) {
        label = t.badgeDeadlineIn;
        daysText = t.badgeDays(d);
        color = scheme.onSurfaceVariant;
      } else if (d == 0) {
        label = t.badgeDeadline;
        daysText = t.badgeUntilToday;
        color = Colors.orange.shade800;
      } else {
        label = t.badgeDeadline;
        daysText = t.badgeOverdueBy(-d);
        color = scheme.error;
      }
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(label,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.outline)),
        Text(daysText,
            style: Theme.of(context)
                .textTheme
                .labelLarge
                ?.copyWith(color: color)),
      ],
    );
  }

  Widget _tile(TaskTile task, bool interactive) {
    final t = tr(context);
    final isZombie = task.status == 'zombie';
    final done = task.todayRemaining == 0 && !isZombie;
    final badge = _deadlineBadge(task);
    return Card(
      child: ListTile(
        enabled: interactive, // 今日以外は閲覧のみ（グレー表示）
        onTap: !interactive
            ? null
            : (done
                ? () => _confirmUncomplete(task)
                : () => _oneTapComplete(task)),
        onLongPress: interactive ? () => _longPressMenu(task) : null,
        leading: Icon(
          done ? Icons.check_circle : Icons.radio_button_unchecked,
          color: done ? Colors.green : levelColors[task.level],
        ),
        title: Text(task.title),
        subtitle: Text(
          isZombie
              // 罪悪感を煽らない無機質な事実表示（§6-2）
              ? t.zombieSubtitle(task.remainingAmount, task.unit)
              : task.inProgressToday
                  ? t.quotaRemaining(task.todayRemaining, task.unit)
                  : t.quotaLabel(task.todayQuota, task.unit),
        ),
        trailing: (badge != null || task.triage.active)
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ?badge,
                  if (task.triage.active)
                    IconButton(
                      icon: const Icon(Icons.warning_amber_rounded,
                          color: Colors.orange),
                      onPressed:
                          interactive ? () => _showTriageOverlay(task) : null,
                    ),
                ],
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
  const TaskFormScreen({super.key, this.task});

  /// null なら新規作成。渡されるとそのタスクの編集モードになる。
  final TaskTile? task;

  @override
  State<TaskFormScreen> createState() => _TaskFormScreenState();
}

class _TaskFormScreenState extends State<TaskFormScreen> {
  final api = ApiClient();
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _unit = TextEditingController(); // 既定値は言語に応じて後で入れる
  final _total = TextEditingController();
  final _margin = TextEditingController(text: '2');
  final _fixed = TextEditingController();
  String _level = 'B';
  int _workDays = 7;
  DateTime? _deadline;
  bool _saving = false;

  static const _defaultMargin = {'A': '3', 'B': '2'};
  bool _unitFilled = false;

  bool get _isRoutine => _level == 'D';
  bool get _isEdit => widget.task != null;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    if (task == null) return;
    // 編集モード: 既存の値をフォームに反映する。
    _title.text = task.title;
    _unit.text = task.unit;
    _level = task.level;
    _workDays = task.workDaysPerWeek;
    _deadline = task.actualDeadline;
    _margin.text = task.marginDays.toString();
    if (task.level == 'D') {
      _fixed.text = (task.fixedDailyAmount ?? 0).toString();
    } else {
      _total.text = task.totalAmount.toString();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 新規作成時の単位の既定値は表示言語に合わせる（ページ / pages）
    if (!_unitFilled && _unit.text.isEmpty) {
      _unitFilled = true;
      _unit.text = tr(context).defaultUnit;
    }
  }

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
      helpText: tr(context).formDeadlineHelp,
    );
    if (d != null) setState(() => _deadline = d);
  }

  Future<void> _save() async {
    final t = tr(context);
    if (!_formKey.currentState!.validate()) return;
    if (!_isRoutine && _deadline == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t.formNeedDeadline)));
      return;
    }
    setState(() => _saving = true);
    final unit =
        _unit.text.trim().isEmpty ? t.defaultUnit : _unit.text.trim();
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
      if (_isEdit) {
        await api.updateTask(widget.task!.id, body);
      } else {
        await api.createTask(body);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.formSaveFailed)));
      }
      return;
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final t = tr(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? t.formEditTitle : t.formAddTitle),
        actions: const [LanguageButton()],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _title,
              autofocus: true,
              decoration: InputDecoration(
                labelText: t.formTitleLabel,
                hintText: t.formTitleHint,
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? t.formTitleRequired : null,
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
              '${t.levelSection(_level)}\n${t.levelHint(_level)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            if (_isRoutine)
              TextFormField(
                controller: _fixed,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t.formFixedLabel,
                  suffixText: _unit.text,
                  hintText: t.formFixedHint,
                ),
                validator: (v) =>
                    (int.tryParse(v ?? '') ?? 0) <= 0 ? t.formMin1 : null,
              )
            else ...[
              TextFormField(
                controller: _total,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t.formTotalLabel,
                  suffixText: _unit.text,
                  hintText: t.formTotalHint,
                ),
                validator: (v) =>
                    (int.tryParse(v ?? '') ?? 0) <= 0 ? t.formMin1 : null,
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event),
                title: Text(
                  _deadline == null
                      ? t.formPickDeadline
                      : t.formDeadlineSet(_deadline!),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: _pickDeadline,
              ),
              if (_level != 'C') ...[
                TextFormField(
                  controller: _margin,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: t.formMarginLabel,
                    helperText: t.formMarginHelper,
                  ),
                  validator: (v) =>
                      (int.tryParse(v ?? '') ?? -1) < 0 ? t.formMargin0 : null,
                ),
                const SizedBox(height: 12),
              ],
              DropdownButtonFormField<int>(
                initialValue: _workDays,
                decoration: InputDecoration(
                  labelText: t.formWorkDaysLabel,
                  helperText: t.formWorkDaysHelper,
                ),
                items: [
                  for (var d = 1; d <= 7; d++)
                    DropdownMenuItem(value: d, child: Text(t.formWeekDays(d))),
                ],
                onChanged: (v) => setState(() => _workDays = v ?? 7),
              ),
            ],
            const SizedBox(height: 12),
            TextFormField(
              controller: _unit,
              decoration: InputDecoration(
                labelText: t.formUnitLabel,
                hintText: t.formUnitHint,
              ),
              onChanged: (_) => setState(() {}), // suffixText更新
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              key: const Key('save_task'),
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.check),
              label: Text(_isEdit ? t.formSave : t.formAdd),
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
      // 目標期日は過ぎたが実際の期日まではまだ猶予がある状態のデモ
      'actual_deadline': isoFromNow(5),
      'target_deadline': isoFromNow(-2),
      'margin_days': 7,
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
      'actual_deadline': isoFromNow(30),
      'target_deadline': isoFromNow(28),
      'margin_days': 2,
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
      'actual_deadline': isoFromNow(160),
      'target_deadline': isoFromNow(160),
      'margin_days': 0,
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
    String? actualIso;
    String? targetIso;
    int marginDays = 0;
    if (level == 'D') {
      quota = body['fixed_daily_amount'] as int;
    } else {
      final deadline = DateTime.parse(body['actual_deadline'] as String);
      marginDays = body['margin_days'] as int;
      final workDays = body['work_days_per_week'] as int;
      final target = deadline.subtract(Duration(days: marginDays));
      actualIso = body['actual_deadline'] as String;
      targetIso = ymd(target);
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
      'actual_deadline': actualIso,
      'target_deadline': targetIso,
      'margin_days': marginDays,
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

  static void delete(int id) => _raw.removeWhere((x) => x['id'] == id);

  // 編集の簡易再現。渡されたフィールドを反映し、ノルマを create と同様に引き直す。
  static void update(int id, Map<String, dynamic> body) {
    final t = _raw.firstWhere((x) => x['id'] == id);
    for (final k in ['title', 'level', 'unit']) {
      if (body.containsKey(k)) t[k] = body[k];
    }
    final level = t['level'] as String;
    if (level == 'D') {
      final q = body['fixed_daily_amount'] as int? ?? t['today_quota'] as int;
      t['today_quota'] = q;
      t['today_remaining'] = q;
      t['remaining_amount'] = q;
      t['actual_deadline'] = null;
      t['target_deadline'] = null;
    } else {
      final total =
          body['total_amount'] as int? ?? t['remaining_amount'] as int;
      final marginDays =
          body['margin_days'] as int? ?? t['margin_days'] as int? ?? 0;
      final workDays = body['work_days_per_week'] as int? ?? 7;
      final iso = body['actual_deadline'] as String? ??
          t['actual_deadline'] as String?;
      if (iso != null) {
        final deadline = DateTime.parse(iso);
        final target = deadline.subtract(Duration(days: marginDays));
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final cal = target.difference(today).inDays + 1;
        final rest = (cal * (7 - workDays)) ~/ 7;
        final wd = cal - rest;
        t['actual_deadline'] = iso;
        t['target_deadline'] = ymd(target);
        t['margin_days'] = marginDays;
        t['today_quota'] = wd > 0 ? (total + wd - 1) ~/ wd : total;
        t['today_remaining'] = t['today_quota'];
      }
      t['remaining_amount'] = total;
    }
  }

  // トリアージ選択の適用。実バックエンドでは選択に応じて再計算されるが、
  // モックでは「解決済み＝トリアージ解除」の状態遷移だけを再現する。
  static ApiError? applyTriage(int id, String choice) {
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
