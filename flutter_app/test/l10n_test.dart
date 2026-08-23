// 多言語対応のテスト（日本語 / 英語の切り替え）
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deadline_app/l10n.dart';
import 'package:deadline_app/main.dart';

Widget appWith(Locale locale, Widget home) => MaterialApp(
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('ja')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: home,
    );

void main() {
  group('使い方画面', () {
    testWidgets('英語で表示される', (tester) async {
      await tester.pumpWidget(appWith(const Locale('en'), const GuideScreen()));
      await tester.pumpAndSettle();
      expect(find.text('How it works'), findsOneWidget);
      expect(find.text('What is Task Tiles?'), findsOneWidget);
      // 戻るボタンは一覧の最後にあるのでスクロールして確認する
      final back = find.text('Back to login');
      await tester.scrollUntilVisible(back, 200,
          scrollable: find.byType(Scrollable).first);
      expect(back, findsOneWidget);
      // 日本語が混ざっていないこと
      expect(find.text('使い方'), findsNothing);
      expect(find.text('タスクタイルとは'), findsNothing);
    });

    testWidgets('日本語で表示される', (tester) async {
      await tester.pumpWidget(appWith(const Locale('ja'), const GuideScreen()));
      await tester.pumpAndSettle();
      expect(find.text('使い方'), findsOneWidget);
      expect(find.text('タスクタイルとは'), findsOneWidget);
      expect(find.text('How it works'), findsNothing);
    });

    testWidgets('ホームから開くと戻るボタンの文言が変わる（英語）', (tester) async {
      await tester.pumpWidget(
          appWith(const Locale('en'), const GuideScreen(fromHome: true)));
      await tester.pumpAndSettle();
      final back = find.text('Back to home');
      await tester.scrollUntilVisible(back, 200,
          scrollable: find.byType(Scrollable).first);
      expect(back, findsOneWidget);
      expect(find.text('Back to login'), findsNothing);
    });
  });

  group('ログイン画面', () {
    testWidgets('英語で表示され、入力チェックも英語になる', (tester) async {
      await tester
          .pumpWidget(appWith(const Locale('en'), LoginScreen(onSuccess: () {})));
      await tester.pumpAndSettle();

      expect(find.text('Task Tiles'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Log in'), findsOneWidget);
      expect(find.text('Create a new account'), findsOneWidget);

      // 空欄のまま送信 → 英語のバリデーション
      await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
      await tester.pumpAndSettle();
      expect(find.text('Please enter a username'), findsOneWidget);
      expect(find.text('ユーザー名を入力してください'), findsNothing);
    });
  });

  group('タスク追加フォーム', () {
    testWidgets('英語では単位の既定値が pages になる', (tester) async {
      await tester
          .pumpWidget(appWith(const Locale('en'), const TaskFormScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Add task'), findsWidgets);
      expect(find.text('Total amount'), findsOneWidget);
      expect(find.text('pages'), findsWidgets); // 単位フィールドの初期値
      expect(find.text('ページ'), findsNothing);
    });

    testWidgets('日本語では単位の既定値が ページ になる', (tester) async {
      await tester
          .pumpWidget(appWith(const Locale('ja'), const TaskFormScreen()));
      await tester.pumpAndSettle();

      expect(find.text('全体量'), findsOneWidget);
      expect(find.text('ページ'), findsWidgets);
      expect(find.text('Total amount'), findsNothing);
    });
  });

  group('言語切り替えボタン', () {
    testWidgets('メニューから English / 日本語 を選べる', (tester) async {
      await tester.pumpWidget(appWith(const Locale('ja'), const GuideScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.language));
      await tester.pumpAndSettle();

      expect(find.text('端末の設定に合わせる'), findsOneWidget);
      expect(find.text('日本語'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
    });
  });

  group('文字列テーブル', () {
    test('未知のAPIエラーはサーバーの文言をそのまま使う', () {
      const en = EnStrings();
      const ja = JaStrings();
      expect(en.apiError('username_taken', 'x'), 'That username is already taken.');
      expect(ja.apiError('username_taken', 'x'), 'このユーザー名は既に使われています');
      // 未知のコード（Djangoのパスワード検証など）はサーバー文言を通す
      expect(en.apiError('weak_password', 'This password is too short.'),
          'This password is too short.');
      expect(en.apiError(null, 'fallback'), 'fallback');
    });

    test('トリアージ選択肢はキーから翻訳される', () {
      const en = EnStrings();
      const ja = JaStrings();
      expect(en.triageOption('force_through', 'サーバー文言'), 'Push through');
      expect(ja.triageOption('force_through', 'サーバー文言'), '強行突破');
      // 未知のキーはサーバーが返したラベルにフォールバック
      expect(en.triageOption('unknown_key', 'server label'), 'server label');
    });

    test('日付ラベルが言語ごとに整形される', () {
      final day = DateTime(2026, 8, 8);
      expect(const JaStrings().dateLabel(day, day), '2026年8月8日（土）・今日');
      expect(const EnStrings().dateLabel(day, day), 'Sat, Aug 8, 2026 · Today');
    });
  });
}
