// モックデータでタイルスタックUIが起動することを確認するスモークテスト
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:deadline_app/main.dart';

void main() {
  testWidgets('タイルスタックが表示される', (WidgetTester tester) async {
    await tester.pumpWidget(const QuotaApp());
    await tester.pumpAndSettle();

    // AppBar
    expect(find.text('タスクタイル'), findsOneWidget);

    // モックのレベルBタスクはトリアージ発動中 → 強制オーバーレイが出る（§6-1）
    expect(find.text('このままでは破綻します'), findsOneWidget);
  });

  testWidgets('ログイン画面: 登録モードに切り替えできる', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(onSuccess: () {}),
    ));
    await tester.pumpAndSettle();

    // 初期はログインモード
    expect(find.widgetWithText(FilledButton, 'ログイン'), findsOneWidget);
    expect(find.text('新規登録はこちら'), findsOneWidget);

    // 切り替え → 登録モード
    await tester.tap(find.text('新規登録はこちら'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'アカウント作成'), findsOneWidget);

    // 空欄でバリデーションが働く
    await tester.tap(find.widgetWithText(FilledButton, 'アカウント作成'));
    await tester.pumpAndSettle();
    expect(find.text('ユーザー名を入力してください'), findsOneWidget);
  });

  // トリアージオーバーレイが出ていれば「強行突破」で閉じる
  Future<void> dismissTriage(WidgetTester tester) async {
    final f = find.text('強行突破');
    if (f.evaluate().isNotEmpty) {
      await tester.tap(f);
      await tester.pumpAndSettle();
    }
  }

  testWidgets('完了→再タップで未完了に戻せる', (WidgetTester tester) async {
    await tester.pumpWidget(const QuotaApp());
    await tester.pumpAndSettle();
    await dismissTriage(tester);

    expect(find.byIcon(Icons.check_circle), findsNothing);

    // ワンタップ完了
    await tester.tap(find.text('提出レポート執筆'));
    await tester.pumpAndSettle();
    await dismissTriage(tester);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    // 完了済みタイルを再タップ → 確認ポップアップ → 未完了へ
    await tester.tap(find.text('提出レポート執筆'));
    await tester.pumpAndSettle();
    expect(find.text('未完了にしますか？'), findsOneWidget);
    await tester.tap(find.text('未完了に戻す'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('キャンセルすると完了のまま', (WidgetTester tester) async {
    await tester.pumpWidget(const QuotaApp());
    await tester.pumpAndSettle();
    await dismissTriage(tester);

    await tester.tap(find.text('提出レポート執筆'));
    await tester.pumpAndSettle();
    await dismissTriage(tester);
    await tester.tap(find.text('提出レポート執筆'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    // 後続テストのため未完了へ戻す
    await tester.tap(find.text('提出レポート執筆'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('未完了に戻す'));
    await tester.pumpAndSettle();
  });

  testWidgets('タスク追加画面から作成できる', (WidgetTester tester) async {
    await tester.pumpWidget(const QuotaApp());
    await tester.pumpAndSettle();
    await dismissTriage(tester);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, '積読消化');
    // レベルD（ルーティン）を選択 → 固定量のみ入力
    await tester.tap(find.text('D'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(1), '15');

    final saveBtn = find.byKey(const Key('save_task'));
    await tester.ensureVisible(saveBtn);
    await tester.tap(saveBtn);
    await tester.pumpAndSettle();

    // 一覧に戻り、新タスクがレベルD（最下部）に表示される。
    // 遅延ビルドのListViewなのでスクロールして確認する。
    await tester.scrollUntilVisible(
      find.text('積読消化'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('積読消化'), findsOneWidget);
    expect(find.text('ノルマ：15ページ'), findsOneWidget);
  });

  testWidgets('日付ナビ: 翌日に移動すると閲覧のみ表示', (WidgetTester tester) async {
    await tester.pumpWidget(const QuotaApp());
    await tester.pumpAndSettle();
    await dismissTriage(tester);

    // 次の日へ
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();

    expect(find.textContaining('明日'), findsOneWidget);
    expect(find.text('今日に戻る（他の日は閲覧のみ）'), findsOneWidget);

    // 今日に戻る
    await tester.tap(find.text('今日に戻る（他の日は閲覧のみ）'));
    await tester.pumpAndSettle();
    expect(find.text('今日に戻る（他の日は閲覧のみ）'), findsNothing);
  });

  // スマホ幅でRenderFlexオーバーフローが起きないこと
  // （オーバーフロー例外が発生するとテストは自動的に失敗する）
  for (final width in [375.0, 320.0]) {
    testWidgets('画面幅$width でオーバーフローしない', (WidgetTester tester) async {
      tester.view.physicalSize = Size(width, 812);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const QuotaApp());
      await tester.pumpAndSettle();

      // オーバーレイを閉じてタイル一覧も描画確認
      final forceThrough = find.text('強行突破');
      if (forceThrough.evaluate().isNotEmpty) {
        await tester.tap(forceThrough);
        await tester.pumpAndSettle();
        // 強行突破後はトリアージが解除され、オーバーレイが再表示されないこと
        expect(find.text('このままでは破綻します'), findsNothing);
      }
      expect(find.text('タスクタイル'), findsOneWidget);
    });
  }
}
