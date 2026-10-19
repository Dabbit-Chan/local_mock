import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_desktop/main.dart';
import 'package:local_mock_desktop/src/mock_connection.dart';

class _RecordingConnection extends MockConnection {
  final updates = <List<dynamic>>[];

  @override
  Future<void> updateRules(String text) async {
    updates.add(jsonDecode(text) as List<dynamic>);
  }
}

const _fixtureRules = [
  {
    'id': 'user-profile',
    'enabled': true,
    'method': 'GET',
    'path': '/api/user/profile',
  },
];

Widget _app({String? rules}) => MaterialApp(
  home: MockPage(
    initialRules: rules == null
        ? _fixtureRules
        : (jsonDecode(rules) as List).cast<Map<String, dynamic>>(),
  ),
);

void main() {
  testWidgets('starts with no rules and synchronizes an empty list', (
    tester,
  ) async {
    final connection = _RecordingConnection();
    addTearDown(connection.dispose);
    await tester.pumpWidget(
      MaterialApp(home: MockPage(connection: connection)),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无规则，添加一条开始 Mock'), findsOneWidget);
    expect(find.byType(RuleCard), findsNothing);
    expect(connection.updates.single, isEmpty);

    await tester.tap(find.text('添加规则').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '路径'), '/first');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('GET /first'), findsOneWidget);
    expect(connection.updates.last.single['path'], '/first');
  });

  testWidgets('synchronizes initial rules, toggles, edits and additions', (
    tester,
  ) async {
    final connection = _RecordingConnection();
    addTearDown(connection.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MockPage(initialRules: _fixtureRules, connection: connection),
      ),
    );
    await tester.pumpAndSettle();
    expect(connection.updates.single.single['path'], '/api/user/profile');

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(connection.updates.last.single['enabled'], false);

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '路径'), '/edited');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(connection.updates.last.single['path'], '/edited');

    await tester.tap(find.text('添加规则'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '路径'), '/added');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(connection.updates.last, hasLength(2));
    expect(connection.updates.last.last['path'], '/added');
  });

  testWidgets('renders an initial rule as a card and toggles enabled', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('GET /api/user/profile'), findsOneWidget);
    expect(find.text('user-profile'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('renders initial rules as multiple cards', (tester) async {
    await tester.pumpWidget(
      _app(
        rules:
            '[{"id":"a","enabled":false,"method":"GET","path":"/a"},'
            '{"id":"b","enabled":true,"method":"POST","path":"/b","delayMs":120}]',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('GET /a'), findsOneWidget);
    expect(find.text('POST /b'), findsOneWidget);
    expect(find.text('120ms'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
    expect(tester.widget<Switch>(find.byType(Switch).last).value, isTrue);
  });

  testWidgets('adds a rule through the edit dialog', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加规则'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, '路径'),
      '/api/orders',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('GET /api/orders'), findsOneWidget);
    expect(find.text('GET /api/user/profile'), findsOneWidget);
  });

  testWidgets('rejects invalid input inside the dialog', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, '路径'),
      'api/user/profile',
    );
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(find.text('必须以 / 开头，且不含查询参数或 fragment'), findsOneWidget);
    expect(find.text('编辑规则'), findsOneWidget);
  });

  testWidgets('deletes a rule and undo restores it', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.text('GET /api/user/profile'), findsNothing);
    expect(find.text('暂无规则，添加一条开始 Mock'), findsOneWidget);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(find.text('GET /api/user/profile'), findsOneWidget);
  });

  testWidgets('reorders rules by dragging a card onto another', (tester) async {
    await tester.pumpWidget(
      _app(
        rules:
            '[{"id":"a","enabled":true,"method":"GET","path":"/a"},'
            '{"id":"b","enabled":true,"method":"GET","path":"/b"}]',
      ),
    );
    await tester.pumpAndSettle();

    final cardA = find.byKey(const ValueKey('rule-a'));
    final cardB = find.byKey(const ValueKey('rule-b'));
    expect(tester.getTopLeft(cardA).dx, lessThan(tester.getTopLeft(cardB).dx));

    // enableLongPress is off, so a plain drag starts the reorder immediately;
    // moving in steps lets the reorderable listener track the pointer.
    final delta = (tester.getCenter(cardB) - tester.getCenter(cardA)) / 10;
    final gesture = await tester.startGesture(tester.getCenter(cardA));
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(delta);
      await tester.pump(const Duration(milliseconds: 30));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(cardA.first).dx,
      greaterThan(tester.getTopLeft(cardB.first).dx),
    );
  });

  for (final ruleCount in [1, 6]) {
    testWidgets('keeps $ruleCount cards sized and anchored while resizing', (
      tester,
    ) async {
      final rules =
          '[${List.generate(ruleCount, (index) => '{"id":"r$index","enabled":true,"method":"GET","path":"/$index"}').join(',')}]';
      final firstCard = find.byKey(const ValueKey('rule-r0'));

      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(700, 900);
      await tester.pumpWidget(_app(rules: rules));
      await tester.pumpAndSettle();
      final originalSize = tester.getSize(firstCard);
      final originalLeft = tester.getTopLeft(firstCard).dx;
      expect(originalLeft, 24);

      // Resize the same page through column boundaries in both directions.
      for (final width in <double>[
        657,
        658,
        659,
        967,
        968,
        969,
        1200,
        1600,
        969,
        968,
        967,
        659,
        658,
        657,
        700,
        400,
      ]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(firstCard),
          originalSize,
          reason: 'card size at window width $width',
        );
        expect(
          tester.getTopLeft(firstCard).dx,
          originalLeft,
          reason: 'first column at window width $width',
        );

        if (ruleCount > 1) {
          final second = tester.getTopLeft(
            find.byKey(const ValueKey('rule-r1')),
          );
          final first = tester.getTopLeft(firstCard);
          if (width >= 658) {
            expect(second.dx - first.dx, 310);
            expect(second.dy, first.dy);
          } else {
            expect(second.dx, first.dx);
            expect(
              second.dy - first.dy,
              closeTo(originalSize.height + 10, 0.001),
            );
          }
        }
      }
    });
  }

  testWidgets('switches between rules and capture views', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Rules view is the default; its header and empty-capture hint coexist
    // only after switching.
    expect(find.textContaining('Mock 规则（1）'), findsOneWidget);
    expect(find.text('添加规则'), findsOneWidget);

    await tester.tap(find.text('抓包'));
    await tester.pumpAndSettle();
    expect(find.textContaining('经过 local_mock 适配器的请求会显示在这里'), findsOneWidget);
    expect(find.text('添加规则'), findsNothing);
    expect(find.text('清空记录'), findsNothing);

    await tester.tap(find.text('Mock 规则'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Mock 规则（1）'), findsOneWidget);
  });

  testWidgets('rejects invalid input inside the dialog', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, '路径'),
      'api/user/profile',
    );
    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(find.text('必须以 / 开头，且不含查询参数或 fragment'), findsOneWidget);
    expect(find.text('编辑规则'), findsOneWidget);
  });

  testWidgets('deletes a rule and undo restores it', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.text('GET /api/user/profile'), findsNothing);
    expect(find.text('暂无规则，添加一条开始 Mock'), findsOneWidget);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(find.text('GET /api/user/profile'), findsOneWidget);
  });

  testWidgets('reorders rules by dragging a card onto another', (tester) async {
    await tester.pumpWidget(
      _app(
        rules:
            '[{"id":"a","enabled":true,"method":"GET","path":"/a"},'
            '{"id":"b","enabled":true,"method":"GET","path":"/b"}]',
      ),
    );
    await tester.pumpAndSettle();

    final cardA = find.byKey(const ValueKey('rule-a'));
    final cardB = find.byKey(const ValueKey('rule-b'));
    expect(tester.getTopLeft(cardA).dx, lessThan(tester.getTopLeft(cardB).dx));

    // enableLongPress is off, so a plain drag starts the reorder immediately;
    // moving in steps lets the reorderable listener track the pointer.
    final delta = (tester.getCenter(cardB) - tester.getCenter(cardA)) / 10;
    final gesture = await tester.startGesture(tester.getCenter(cardA));
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(delta);
      await tester.pump(const Duration(milliseconds: 30));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(cardA.first).dx,
      greaterThan(tester.getTopLeft(cardB.first).dx),
    );
  });

  for (final ruleCount in [1, 6]) {
    testWidgets('keeps $ruleCount cards sized and anchored while resizing', (
      tester,
    ) async {
      final rules =
          '[${List.generate(ruleCount, (index) => '{"id":"r$index","enabled":true,"method":"GET","path":"/$index"}').join(',')}]';
      final firstCard = find.byKey(const ValueKey('rule-r0'));

      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(700, 900);
      await tester.pumpWidget(_app(rules: rules));
      await tester.pumpAndSettle();
      final originalSize = tester.getSize(firstCard);
      final originalLeft = tester.getTopLeft(firstCard).dx;
      expect(originalLeft, 24);

      // Resize the same page through column boundaries in both directions.
      for (final width in <double>[
        657,
        658,
        659,
        967,
        968,
        969,
        1200,
        1600,
        969,
        968,
        967,
        659,
        658,
        657,
        700,
        400,
      ]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(firstCard),
          originalSize,
          reason: 'card size at window width $width',
        );
        expect(
          tester.getTopLeft(firstCard).dx,
          originalLeft,
          reason: 'first column at window width $width',
        );

        if (ruleCount > 1) {
          final second = tester.getTopLeft(
            find.byKey(const ValueKey('rule-r1')),
          );
          final first = tester.getTopLeft(firstCard);
          if (width >= 658) {
            expect(second.dx - first.dx, 310);
            expect(second.dy, first.dy);
          } else {
            expect(second.dx, first.dx);
            expect(
              second.dy - first.dy,
              closeTo(originalSize.height + 10, 0.001),
            );
          }
        }
      }
    });
  }
}
