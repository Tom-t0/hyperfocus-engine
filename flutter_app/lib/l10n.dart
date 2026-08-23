// 多言語対応（日本語 / 英語）
//
// - 文字列は AppStrings の抽象メンバとして定義し、JaStrings / EnStrings で実装する。
//   （実装漏れがあればコンパイルエラーになるので、翻訳の抜けを防げる）
// - 画面からは `final t = tr(context);` で取得する。MaterialApp の locale に追従する。
// - 言語の選択は LocaleController が端末に保存する（null = 端末の設定に従う）。

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 現在のロケールに対応する文字列セットを返す。
AppStrings tr(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'ja'
        ? const JaStrings()
        : const EnStrings();

/// アプリの表示言語。null なら端末の設定に従う。
class LocaleController {
  static const _key = 'app_locale';
  static final ValueNotifier<Locale?> locale = ValueNotifier<Locale?>(null);

  static Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    final code = sp.getString(_key);
    locale.value = (code == null) ? null : Locale(code);
  }

  static Future<void> set(Locale? value) async {
    locale.value = value;
    final sp = await SharedPreferences.getInstance();
    if (value == null) {
      await sp.remove(_key);
    } else {
      await sp.setString(_key, value.languageCode);
    }
  }
}

abstract class AppStrings {
  const AppStrings();

  // ---- アプリ共通 ----
  String get appTitle;
  String get languageLabel;
  String get languageSystem;
  String get japanese;
  String get english;
  String get cancel;
  String get retry;

  // ---- ログイン ----
  String get usernameLabel;
  String get passwordLabel;
  String get usernameRequired;
  String get passwordRequired;
  String get passwordMin8;
  String get createAccount;
  String get login;
  String get switchToLogin;
  String get switchToRegister;
  String get openGuide;

  // ---- 使い方 ----
  String get guideTitle;
  String get guideBackToLogin;
  String get guideBackToHome;
  String get guideWhatIsHeading;
  String get guideWhatIsBody;
  String get guideStepsHeading;
  String get guideStep1;
  String get guideStep2;
  String get guideStep3;
  String get guideStep4;
  String get guideLevelsHeading;
  String get guideLevelA;
  String get guideLevelB;
  String get guideLevelC;
  String get guideLevelD;
  String get guideFeaturesHeading;
  String get guideFeature1;
  String get guideFeature2;
  String get guideFeature3;
  String get guideTipsHeading;
  String get guideTipsBody;
  String get bulletMarker;

  // ---- レベル ----
  String levelName(String level);
  String levelSection(String level);
  String levelHint(String level);

  // ---- ホーム ----
  String get logoutTitle;
  String get logoutBody;
  String get logout;
  String logoutTooltip(String? username);
  String get guideTooltip;
  String get connectionError;
  String get prevDay;
  String get nextDay;
  String get backToToday;
  String get emptyToday;
  String get emptyOtherDay;
  String get goodWork;
  String get showCompleted;
  String get addTask;
  String get changeResetTime;
  String dateLabel(DateTime d, DateTime? today);

  // ---- 深夜の更新時間延長 ----
  String get nightOwlTitle;
  String get nightOwlBody;
  String get nightOwlKeep;
  String get nightOwlChange;
  String get timePickerHelp;
  String extendedTo(String time);

  // ---- 完了 / 取り消し ----
  String get uncompleteTitle;
  String uncompleteBody(String title);
  String get uncompleteConfirm;

  // ---- 長押しメニュー ----
  String get menuPartial;
  String get menuEdit;
  String get menuDelete;

  // ---- 部分完了 ----
  String partialTitle(String title);
  String partialLabel(String unit);
  String get partialHint;
  String get partialRecord;

  // ---- 削除 ----
  String get deleteTitle;
  String deleteBody(String title);
  String get deleteConfirm;
  String deletedSnack(String title);

  // ---- トリアージ ----
  String get triageTitle;
  String triageBody(String title, int quota, String unit, double standard);
  String triageOption(String key, String fallback);
  String get triageResetATitle;
  String get frictionLabel;
  String get frictionPhrase;
  String get frictionCancel;
  String get frictionConfirm;

  // ---- タイル ----
  String zombieSubtitle(int remaining, String unit);
  String quotaRemaining(int n, String unit);
  String quotaLabel(int n, String unit);

  // ---- 期日バッジ ----
  String get badgeTargetIn;
  String get badgeTargetOverdue;
  String get badgeOverdue;
  String get badgeDeadlineIn;
  String get badgeDeadline;
  String badgeDays(int n);
  String badgeActualIn(int n);
  String get badgeActualToday;
  String badgeOverdueBy(int n);
  String get badgeUntilToday;

  // ---- タスク追加・編集フォーム ----
  String get formAddTitle;
  String get formEditTitle;
  String get formTitleLabel;
  String get formTitleHint;
  String get formTitleRequired;
  String get formFixedLabel;
  String get formFixedHint;
  String get formMin1;
  String get formTotalLabel;
  String get formTotalHint;
  String get formPickDeadline;
  String formDeadlineSet(DateTime d);
  String get formDeadlineHelp;
  String get formMarginLabel;
  String get formMarginHelper;
  String get formMargin0;
  String get formWorkDaysLabel;
  String get formWorkDaysHelper;
  String formWeekDays(int n);
  String get formUnitLabel;
  String get formUnitHint;
  String get defaultUnit;
  String get formSave;
  String get formAdd;
  String get formNeedDeadline;
  String get formSaveFailed;

  /// APIエラー。code が既知なら翻訳し、未知ならサーバーの文言をそのまま出す。
  String apiError(String? code, String fallback);
}

// ---------------------------------------------------------------------------
// 日本語
// ---------------------------------------------------------------------------

class JaStrings extends AppStrings {
  const JaStrings();

  @override
  String get appTitle => 'タスクタイル';
  @override
  String get languageLabel => '言語';
  @override
  String get languageSystem => '端末の設定に合わせる';
  @override
  String get japanese => '日本語';
  @override
  String get english => 'English';
  @override
  String get cancel => 'キャンセル';
  @override
  String get retry => '再試行';

  @override
  String get usernameLabel => 'ユーザー名';
  @override
  String get passwordLabel => 'パスワード';
  @override
  String get usernameRequired => 'ユーザー名を入力してください';
  @override
  String get passwordRequired => 'パスワードを入力してください';
  @override
  String get passwordMin8 => '8文字以上にしてください';
  @override
  String get createAccount => 'アカウント作成';
  @override
  String get login => 'ログイン';
  @override
  String get switchToLogin => 'アカウントをお持ちの方はログイン';
  @override
  String get switchToRegister => '新規登録はこちら';
  @override
  String get openGuide => 'はじめての方へ・使い方を見る';

  @override
  String get guideTitle => '使い方';
  @override
  String get guideBackToLogin => 'ログイン画面に戻る';
  @override
  String get guideBackToHome => 'ホーム画面に戻る';
  @override
  String get guideWhatIsHeading => 'タスクタイルとは';
  @override
  String get guideWhatIsBody =>
      '「全体の量」と「期日」を登録すると、今日やるべき量（ノルマ）を'
      'アプリが自動で計算します。「今日どれだけやるか」を考えず、'
      '提示されたタスクを上から順にこなしていくだけ、を目指したアプリです。';
  @override
  String get guideStepsHeading => '使い方（4ステップ）';
  @override
  String get guideStep1 => '① アカウントを作成してログインします。';
  @override
  String get guideStep2 =>
      '② 右下の「＋ タスクを追加」で、やること・全体量・期日・重要度レベルを登録します。';
  @override
  String get guideStep3 => '③ 毎日、各タスクに表示される「今日のノルマ」をこなします。';
  @override
  String get guideStep4 =>
      '④ 終わったらタイルをタップして完了。少しだけ進めた日は、'
      'タイルを長押しして実績（やった量）を入力します。';
  @override
  String get guideLevelsHeading => '重要度レベル（A〜D）';
  @override
  String get guideLevelA => 'A（Must）: 絶対に落とせない期日。仕事や提出物など。';
  @override
  String get guideLevelB => 'B（Should）: 自分で決めた期日。資格勉強など。';
  @override
  String get guideLevelC => 'C（Want）: 趣味・自己満。いつ終わってもよいもの。';
  @override
  String get guideLevelD => 'D（Routine）: 終わりのない毎日の習慣。固定量を毎日提示。';
  @override
  String get guideFeaturesHeading => '便利な機能';
  @override
  String get guideFeature1 => '各タイルの右端に、期日までの残り日数が出ます。';
  @override
  String get guideFeature2 =>
      '画面上部の日付の矢印で、前後の日のノルマを確認できます（今日以外は閲覧のみ）。';
  @override
  String get guideFeature3 =>
      'ペースが乱れて1日のノルマが増えすぎると警告が出て、'
      '立て直し方（マージン消費・強行突破など）を選べます。';
  @override
  String get guideTipsHeading => 'ヒント';
  @override
  String get guideTipsBody =>
      'まずは小さなタスクを1つ登録して、毎日こなす感覚をつかんでみてください。';
  @override
  String get bulletMarker => '・';

  static const _levelNames = {
    'A': 'Must / 絶対不可侵',
    'B': 'Should / 努力義務',
    'C': 'Want / 趣味',
    'D': 'Routine / 裏メニュー',
  };
  static const _levelHints = {
    'A': '仕事・提出物など、他者が関わる動かせない期日。ギブアップ不可。',
    'B': '資格勉強など自分で決めた期日。あとから再設定・アーカイブ可能。',
    'C': '趣味・自己満。日数が足りなくてもノルマは増えず、完了予定日が延びる。',
    'D': '終わりのない毎日のルーティン。固定量を毎日提示、翌日に繰り越さない。',
  };
  @override
  String levelName(String level) => _levelNames[level] ?? level;
  @override
  String levelSection(String level) => 'レベル$level（${levelName(level)}）';
  @override
  String levelHint(String level) => _levelHints[level] ?? '';

  @override
  String get logoutTitle => 'ログアウトしますか？';
  @override
  String get logoutBody => 'この端末からログアウトします。データはサーバーに残ります。';
  @override
  String get logout => 'ログアウト';
  @override
  String logoutTooltip(String? username) =>
      username == null ? 'ログアウト' : '$username — ログアウト';
  @override
  String get guideTooltip => '使い方';
  @override
  String get connectionError => 'サーバーに接続できません。通信環境を確認してください。';
  @override
  String get prevDay => '前の日';
  @override
  String get nextDay => '次の日';
  @override
  String get backToToday => '今日に戻る（他の日は閲覧のみ）';
  @override
  String get emptyToday => '今日のタスクはありません';
  @override
  String get emptyOtherDay => 'この日のタスクはありません';
  @override
  String get goodWork => 'おつかれさまでした';
  @override
  String get showCompleted => '完了したタスクを表示';
  @override
  String get addTask => 'タスクを追加';
  @override
  String get changeResetTime => '更新時間を変更する';

  static const _weekdays = ['月', '火', '水', '木', '金', '土', '日'];
  @override
  String dateLabel(DateTime d, DateTime? today) {
    var rel = '';
    if (today != null) {
      final diff = DateTime(d.year, d.month, d.day)
          .difference(DateTime(today.year, today.month, today.day))
          .inDays;
      if (diff == 0) {
        rel = '・今日';
      } else if (diff == -1) {
        rel = '・昨日';
      } else if (diff == 1) {
        rel = '・明日';
      }
    }
    return '${d.year}年${d.month}月${d.day}日（${_weekdays[d.weekday - 1]}）$rel';
  }

  @override
  String get nightOwlTitle => 'まだ起きていますか？';
  @override
  String get nightOwlBody => '本日のタスク更新時間を延長しますか？';
  @override
  String get nightOwlKeep => 'いいえ（午前4時のまま）';
  @override
  String get nightOwlChange => '変更する';
  @override
  String get timePickerHelp => '延長できるのは翌日の正午（12:00）まで';
  @override
  String extendedTo(String time) => '更新時間を $time に延長しました';

  @override
  String get uncompleteTitle => '未完了にしますか？';
  @override
  String uncompleteBody(String title) =>
      '「$title」の今日の実績を取り消して、今日のノルマを復活させます。';
  @override
  String get uncompleteConfirm => '未完了に戻す';

  @override
  String get menuPartial => '部分完了を記録';
  @override
  String get menuEdit => '編集する';
  @override
  String get menuDelete => '削除する';

  @override
  String partialTitle(String title) => '部分完了：$title';
  @override
  String partialLabel(String unit) => '今日やった量（$unit）';
  @override
  String get partialHint => '例: 10';
  @override
  String get partialRecord => '記録する';

  @override
  String get deleteTitle => '削除しますか？';
  @override
  String deleteBody(String title) =>
      '「$title」を削除します。これまでの進捗も含めて完全に削除され、元に戻せません。';
  @override
  String get deleteConfirm => '削除する';
  @override
  String deletedSnack(String title) => '「$title」を削除しました';

  @override
  String get triageTitle => 'このままでは破綻します';
  @override
  String triageBody(String title, int quota, String unit, double standard) =>
      '「$title」の今日のノルマ: $quota$unit'
      '（標準 ${standard.toStringAsFixed(1)} の1.5倍超）';
  static const _triageOptions = {
    'consume_margin': 'マージン消費',
    'forfeit_rest': '休日返上',
    'force_through': '強行突破',
    'reset_deadline': '期日の再設定',
    'reset_deadline_with_friction': '期日の再設定（要合意入力）',
    'archive': 'アーカイブ（ギブアップ）',
  };
  @override
  String triageOption(String key, String fallback) =>
      _triageOptions[key] ?? fallback;
  @override
  String get triageResetATitle => '期日の再設定（レベルA）';
  @override
  String get frictionLabel => '「関係者と合意済み」と入力してください';
  @override
  String get frictionPhrase => '関係者と合意済み';
  @override
  String get frictionCancel => 'やめる';
  @override
  String get frictionConfirm => '確定';

  @override
  String zombieSubtitle(int remaining, String unit) =>
      'ℹ️ 逆算停止：期日を超過。残 $remaining$unit を消化してください';
  @override
  String quotaRemaining(int n, String unit) => '残りノルマ：$n$unit';
  @override
  String quotaLabel(int n, String unit) => 'ノルマ：$n$unit';

  @override
  String get badgeTargetIn => '目標期日まであと';
  @override
  String get badgeTargetOverdue => '目標期日を超過中';
  @override
  String get badgeOverdue => '期日超過';
  @override
  String get badgeDeadlineIn => '期日まであと';
  @override
  String get badgeDeadline => '期日';
  @override
  String badgeDays(int n) => '$n日';
  @override
  String badgeActualIn(int n) => '実際の期日まで$n日';
  @override
  String get badgeActualToday => '実際の期日は今日';
  @override
  String badgeOverdueBy(int n) => '$n日超過';
  @override
  String get badgeUntilToday => '今日まで';

  @override
  String get formAddTitle => 'タスクを追加';
  @override
  String get formEditTitle => 'タスクを編集';
  @override
  String get formTitleLabel => 'タイトル';
  @override
  String get formTitleHint => '例: 提出レポート執筆';
  @override
  String get formTitleRequired => 'タイトルを入力してください';
  @override
  String get formFixedLabel => '毎日の固定量';
  @override
  String get formFixedHint => '例: 20';
  @override
  String get formMin1 => '1以上の数値を入力してください';
  @override
  String get formTotalLabel => '全体量';
  @override
  String get formTotalHint => '例: 100';
  @override
  String get formPickDeadline => '実際の期日を選択';
  @override
  String formDeadlineSet(DateTime d) => '実際の期日: ${d.year}/${d.month}/${d.day}';
  @override
  String get formDeadlineHelp => '実際の期日（最終デッドライン）';
  @override
  String get formMarginLabel => 'マージン（バッファ日数）';
  @override
  String get formMarginHelper => '目標期日 = 実際の期日 − マージン。ノルマはこちらで逆算';
  @override
  String get formMargin0 => '0以上の数値';
  @override
  String get formWorkDaysLabel => '週の稼働日数';
  @override
  String get formWorkDaysHelper => '7未満にすると差分が「休日の権利」になる（曜日は固定しない）';
  @override
  String formWeekDays(int n) => '週$n日';
  @override
  String get formUnitLabel => '単位';
  @override
  String get formUnitHint => 'ページ / 問 / 回 など';
  @override
  String get defaultUnit => 'ページ';
  @override
  String get formSave => '保存する';
  @override
  String get formAdd => 'タスクを追加';
  @override
  String get formNeedDeadline => '期日を選択してください';
  @override
  String get formSaveFailed => '保存に失敗しました。通信環境を確認してください。';

  static const _errors = {
    'connection': 'サーバーに接続できません。通信環境を確認してください。',
    'auth_required': '認証が必要です',
    'task_not_found': 'タスクが見つかりません',
    'missing_credentials': 'ユーザー名とパスワードは必須です',
    'username_too_long': 'ユーザー名が長すぎます',
    'username_taken': 'このユーザー名は既に使われています',
    'invalid_credentials': 'ユーザー名またはパスワードが違います',
    'margin_zero': 'マージンは既にゼロです',
    'rest_zero': '休日の権利は既にゼロです',
    'level_a_only': 'このオプションはレベルA専用です',
    'level_b_only': 'このオプションはレベルB専用です',
    'level_a_no_archive': 'レベルAタスクはアーカイブできません',
    'friction_mismatch': '「関係者と合意済み」と入力してください',
    'unknown_choice': '不明な選択肢です',
    'deadline_future_required': '新しい期日（明日以降）を指定してください',
  };
  @override
  String apiError(String? code, String fallback) => _errors[code] ?? fallback;
}

// ---------------------------------------------------------------------------
// 英語
// ---------------------------------------------------------------------------

class EnStrings extends AppStrings {
  const EnStrings();

  @override
  String get appTitle => 'Task Tiles';
  @override
  String get languageLabel => 'Language';
  @override
  String get languageSystem => 'Use device setting';
  @override
  String get japanese => '日本語';
  @override
  String get english => 'English';
  @override
  String get cancel => 'Cancel';
  @override
  String get retry => 'Retry';

  @override
  String get usernameLabel => 'Username';
  @override
  String get passwordLabel => 'Password';
  @override
  String get usernameRequired => 'Please enter a username';
  @override
  String get passwordRequired => 'Please enter a password';
  @override
  String get passwordMin8 => 'Use at least 8 characters';
  @override
  String get createAccount => 'Create account';
  @override
  String get login => 'Log in';
  @override
  String get switchToLogin => 'Already have an account? Log in';
  @override
  String get switchToRegister => 'Create a new account';
  @override
  String get openGuide => 'New here? See how it works';

  @override
  String get guideTitle => 'How it works';
  @override
  String get guideBackToLogin => 'Back to login';
  @override
  String get guideBackToHome => 'Back to home';
  @override
  String get guideWhatIsHeading => 'What is Task Tiles?';
  @override
  String get guideWhatIsBody =>
      'Enter the total amount of work and a deadline, and the app works out how '
      'much to do today. Instead of deciding how much to tackle each day, you '
      'just work through the tiles from the top.';
  @override
  String get guideStepsHeading => 'Getting started (4 steps)';
  @override
  String get guideStep1 => '1. Create an account and log in.';
  @override
  String get guideStep2 =>
      '2. Tap "Add task" at the bottom right and enter what to do, the total '
      'amount, the deadline and a priority level.';
  @override
  String get guideStep3 =>
      '3. Each day, work through the daily target shown on every task.';
  @override
  String get guideStep4 =>
      '4. Tap a tile to mark it done. On days you only got partway, long-press '
      'the tile and enter how much you actually did.';
  @override
  String get guideLevelsHeading => 'Priority levels (A–D)';
  @override
  String get guideLevelA =>
      'A (Must): deadlines you cannot miss, such as work and submissions.';
  @override
  String get guideLevelB =>
      'B (Should): deadlines you set yourself, such as studying for an exam.';
  @override
  String get guideLevelC =>
      'C (Want): hobbies and personal projects that can finish whenever.';
  @override
  String get guideLevelD =>
      'D (Routine): daily habits with no end. A fixed amount every day.';
  @override
  String get guideFeaturesHeading => 'Handy features';
  @override
  String get guideFeature1 =>
      'Each tile shows how many days are left until its deadline.';
  @override
  String get guideFeature2 =>
      'Use the arrows next to the date at the top to look at other days '
      '(days other than today are read-only).';
  @override
  String get guideFeature3 =>
      'If you fall behind and a daily target grows too large, a warning appears '
      'and you can choose how to recover (spend margin, push through, and more).';
  @override
  String get guideTipsHeading => 'Tip';
  @override
  String get guideTipsBody =>
      'Start with one small task and get a feel for working through it daily.';
  @override
  String get bulletMarker => '•  ';

  static const _levelNames = {
    'A': 'Must / non-negotiable',
    'B': 'Should / best effort',
    'C': 'Want / for yourself',
    'D': 'Routine / daily habit',
  };
  static const _levelHints = {
    'A': 'Fixed deadlines involving other people, such as work or submissions. '
        'Cannot be given up.',
    'B': 'A deadline you set yourself, such as exam study. Can be rescheduled '
        'or archived later.',
    'C': 'Hobbies and personal projects. The daily target never grows; the '
        'projected finish date moves instead.',
    'D': 'A never-ending daily routine. A fixed amount each day, with nothing '
        'carried over to tomorrow.',
  };
  @override
  String levelName(String level) => _levelNames[level] ?? level;
  @override
  String levelSection(String level) => 'Level $level (${levelName(level)})';
  @override
  String levelHint(String level) => _levelHints[level] ?? '';

  @override
  String get logoutTitle => 'Log out?';
  @override
  String get logoutBody =>
      'You will be logged out on this device. Your data stays on the server.';
  @override
  String get logout => 'Log out';
  @override
  String logoutTooltip(String? username) =>
      username == null ? 'Log out' : '$username — log out';
  @override
  String get guideTooltip => 'How it works';
  @override
  String get connectionError =>
      'Cannot reach the server. Please check your connection.';
  @override
  String get prevDay => 'Previous day';
  @override
  String get nextDay => 'Next day';
  @override
  String get backToToday => 'Back to today (other days are read-only)';
  @override
  String get emptyToday => 'Nothing left for today';
  @override
  String get emptyOtherDay => 'No tasks for this day';
  @override
  String get goodWork => 'Nice work';
  @override
  String get showCompleted => 'Show completed tasks';
  @override
  String get addTask => 'Add task';
  @override
  String get changeResetTime => 'Change the daily reset time';

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  @override
  String dateLabel(DateTime d, DateTime? today) {
    var rel = '';
    if (today != null) {
      final diff = DateTime(d.year, d.month, d.day)
          .difference(DateTime(today.year, today.month, today.day))
          .inDays;
      if (diff == 0) {
        rel = ' · Today';
      } else if (diff == -1) {
        rel = ' · Yesterday';
      } else if (diff == 1) {
        rel = ' · Tomorrow';
      }
    }
    return '${_weekdays[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}, '
        '${d.year}$rel';
  }

  @override
  String get nightOwlTitle => 'Still up?';
  @override
  String get nightOwlBody => "Would you like to extend today's reset time?";
  @override
  String get nightOwlKeep => 'No (keep 4:00 AM)';
  @override
  String get nightOwlChange => 'Change it';
  @override
  String get timePickerHelp =>
      'You can extend until noon (12:00) at the latest';
  @override
  String extendedTo(String time) => 'Reset time extended to $time';

  @override
  String get uncompleteTitle => 'Mark as not done?';
  @override
  String uncompleteBody(String title) =>
      'This clears today\'s progress on "$title" and brings back its daily '
      'target.';
  @override
  String get uncompleteConfirm => 'Mark as not done';

  @override
  String get menuPartial => 'Record partial progress';
  @override
  String get menuEdit => 'Edit';
  @override
  String get menuDelete => 'Delete';

  @override
  String partialTitle(String title) => 'Partial progress: $title';
  @override
  String partialLabel(String unit) => 'Amount done today ($unit)';
  @override
  String get partialHint => 'e.g. 10';
  @override
  String get partialRecord => 'Record';

  @override
  String get deleteTitle => 'Delete this task?';
  @override
  String deleteBody(String title) =>
      '"$title" will be deleted permanently, along with all its progress. '
      'This cannot be undone.';
  @override
  String get deleteConfirm => 'Delete';
  @override
  String deletedSnack(String title) => 'Deleted "$title"';

  @override
  String get triageTitle => 'This pace will not hold';
  @override
  String triageBody(String title, int quota, String unit, double standard) =>
      'Today\'s target for "$title": $quota $unit '
      '(over 1.5x the standard pace of ${standard.toStringAsFixed(1)})';
  static const _triageOptions = {
    'consume_margin': 'Spend margin',
    'forfeit_rest': 'Give up a rest day',
    'force_through': 'Push through',
    'reset_deadline': 'Reschedule the deadline',
    'reset_deadline_with_friction':
        'Reschedule the deadline (confirmation required)',
    'archive': 'Archive (give up)',
  };
  @override
  String triageOption(String key, String fallback) =>
      _triageOptions[key] ?? fallback;
  @override
  String get triageResetATitle => 'Reschedule the deadline (Level A)';
  @override
  String get frictionLabel => 'Type "Agreed with stakeholders" to confirm';
  @override
  String get frictionPhrase => 'Agreed with stakeholders';
  @override
  String get frictionCancel => 'Never mind';
  @override
  String get frictionConfirm => 'Confirm';

  @override
  String zombieSubtitle(int remaining, String unit) =>
      'ℹ️ Scheduling stopped: deadline passed. $remaining $unit left to clear.';
  @override
  String quotaRemaining(int n, String unit) => 'Remaining today: $n $unit';
  @override
  String quotaLabel(int n, String unit) => 'Today: $n $unit';

  @override
  String get badgeTargetIn => 'Target deadline in';
  @override
  String get badgeTargetOverdue => 'Past target deadline';
  @override
  String get badgeOverdue => 'Overdue';
  @override
  String get badgeDeadlineIn => 'Deadline in';
  @override
  String get badgeDeadline => 'Deadline';
  @override
  String badgeDays(int n) => n == 1 ? '1 day' : '$n days';
  @override
  String badgeActualIn(int n) =>
      n == 1 ? 'real deadline in 1 day' : 'real deadline in $n days';
  @override
  String get badgeActualToday => 'real deadline is today';
  @override
  String badgeOverdueBy(int n) => n == 1 ? '1 day over' : '$n days over';
  @override
  String get badgeUntilToday => 'today';

  @override
  String get formAddTitle => 'Add task';
  @override
  String get formEditTitle => 'Edit task';
  @override
  String get formTitleLabel => 'Title';
  @override
  String get formTitleHint => 'e.g. Write the report';
  @override
  String get formTitleRequired => 'Please enter a title';
  @override
  String get formFixedLabel => 'Fixed amount per day';
  @override
  String get formFixedHint => 'e.g. 20';
  @override
  String get formMin1 => 'Enter a number of 1 or more';
  @override
  String get formTotalLabel => 'Total amount';
  @override
  String get formTotalHint => 'e.g. 100';
  @override
  String get formPickDeadline => 'Choose the real deadline';
  @override
  String formDeadlineSet(DateTime d) =>
      'Real deadline: ${d.year}/${d.month}/${d.day}';
  @override
  String get formDeadlineHelp => 'Real deadline (the final one)';
  @override
  String get formMarginLabel => 'Margin (buffer days)';
  @override
  String get formMarginHelper =>
      'Target deadline = real deadline − margin. Daily targets are worked out '
      'from the target deadline.';
  @override
  String get formMargin0 => 'Enter 0 or more';
  @override
  String get formWorkDaysLabel => 'Working days per week';
  @override
  String get formWorkDaysHelper =>
      'Below 7, the difference becomes rest days you may take on any day.';
  @override
  String formWeekDays(int n) => n == 1 ? '1 day/week' : '$n days/week';
  @override
  String get formUnitLabel => 'Unit';
  @override
  String get formUnitHint => 'pages / questions / reps, etc.';
  @override
  String get defaultUnit => 'pages';
  @override
  String get formSave => 'Save';
  @override
  String get formAdd => 'Add task';
  @override
  String get formNeedDeadline => 'Please choose a deadline';
  @override
  String get formSaveFailed => 'Could not save. Please check your connection.';

  static const _errors = {
    'connection': 'Cannot reach the server. Please check your connection.',
    'auth_required': 'Please log in.',
    'task_not_found': 'Task not found.',
    'missing_credentials': 'Username and password are required.',
    'username_too_long': 'That username is too long.',
    'username_taken': 'That username is already taken.',
    'invalid_credentials': 'Incorrect username or password.',
    'margin_zero': 'There is no margin left to spend.',
    'rest_zero': 'There are no rest days left to give up.',
    'level_a_only': 'That option is only for Level A tasks.',
    'level_b_only': 'That option is only for Level B tasks.',
    'level_a_no_archive': 'Level A tasks cannot be archived.',
    'friction_mismatch': 'Type "Agreed with stakeholders" to confirm.',
    'unknown_choice': 'Unknown option.',
    'deadline_future_required': 'Choose a new deadline of tomorrow or later.',
  };
  @override
  String apiError(String? code, String fallback) => _errors[code] ?? fallback;
}
