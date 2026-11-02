import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_client/src/mock_connection.dart';
import 'package:local_mock_client/src/panes/rule_editor.dart';
import 'package:local_mock_client/src/ui/primitives.dart';
import 'package:local_mock_core/local_mock_core.dart';

import 'support/harness.dart';

Finder toggleLabelled(String label) => find.byWidgetPredicate(
  (w) => w is SquareToggle && w.semanticLabel == label,
);

void main() {
  group('home', () {
    testWidgets('lists devices; only online ones open the workspace', (
      tester,
    ) async {
      final connection = FakeConnection(
        devices: const [
          MockTarget('phone', '测试设备'),
          MockTarget('old', '旧手机', online: false),
        ],
      );
      addTearDown(connection.dispose);
      await pumpApp(tester, connection: connection);
      expect(find.text('1 台在线 · 1 台离线 · 选择一台设备进入调试'), findsOneWidget);
      expect(find.text('离线'), findsOneWidget);

      await tester.tap(find.text('旧手机'));
      await tester.pumpAndSettle();
      expect(find.text('01'), findsOneWidget, reason: 'still on home');

      await tester.tap(find.text('测试设备'));
      await tester.pumpAndSettle();
      expect(find.text('规则'), findsOneWidget);
      expect(find.text('请求'), findsOneWidget);
      expect(find.text('详情'), findsOneWidget);

      await tester.tap(find.text('设备').first);
      await tester.pumpAndSettle();
      expect(find.text('旧手机'), findsOneWidget);
    });

    testWidgets('explains how to connect when no device is online', (
      tester,
    ) async {
      final connection = FakeConnection(devices: const []);
      addTearDown(connection.dispose);
      await pumpApp(tester, connection: connection);
      expect(find.text('接入一台设备'), findsOneWidget);
      expect(find.textContaining('LocalMock.connect('), findsOneWidget);
    });

    testWidgets('shows the relay state while disconnected', (tester) async {
      final connection = FakeConnection(isConnected: false);
      addTearDown(connection.dispose);
      await pumpApp(tester, connection: connection);
      expect(find.text('正在连接 Relay'), findsOneWidget);
      expect(find.text('Relay 未连接'), findsOneWidget);
    });

    testWidgets('an offline device route explains instead of failing', (
      tester,
    ) async {
      final connection = FakeConnection(devices: const []);
      addTearDown(connection.dispose);
      await pumpApp(tester, connection: connection, location: '/devices/x');
      expect(find.text('设备不在线'), findsOneWidget);
      await tapText(tester, '返回设备列表');
      expect(find.text('接入一台设备'), findsOneWidget);
    });

    testWidgets('unknown routes show a 404 page', (tester) async {
      await pumpApp(tester, location: '/nope');
      expect(find.text('没有这个页面'), findsOneWidget);
    });
  });

  group('recording library', () {
    testWidgets('saved recordings open offline with request details', (
      tester,
    ) async {
      final store = MemoryStore()..sessions = [savedSession()];
      final connection = FakeConnection(isConnected: false);
      addTearDown(connection.dispose);
      await pumpApp(tester, connection: connection, store: store);
      expect(find.text('登录流程'), findsOneWidget);
      await tester.tap(find.text('登录流程'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 条，其中 1 条可生成 Mock'), findsOneWidget);
      await tester.tap(find.textContaining('/login', findRichText: true).last);
      await tester.pumpAndSettle();
      expect(find.text('响应体'), findsOneWidget);
      expect(find.text('https://api.test/login'), findsOneWidget);
    });

    testWidgets('missing recordings explain where recordings live', (
      tester,
    ) async {
      await pumpApp(tester, location: '/recordings/gone');
      expect(find.text('找不到这段录制'), findsOneWidget);
    });

    testWidgets('import adds once; duplicates and cancels write nothing', (
      tester,
    ) async {
      final store = MemoryStore();
      await pumpApp(tester, store: store);
      await tapText(tester, '导入文件');
      expect(store.saves, 0, reason: 'cancelled picker');

      store.imported = savedSession();
      await tapText(tester, '导入文件');
      expect(store.sessions, hasLength(1));
      expect(find.text('登录流程'), findsOneWidget);

      await tapText(tester, '导入文件');
      expect(find.textContaining('已存在同一录制'), findsOneWidget);
      expect(store.sessions, hasLength(1));
    });

    testWidgets('delete needs confirmation; export keeps the original', (
      tester,
    ) async {
      final store = MemoryStore()..sessions = [savedSession()];
      await pumpApp(tester, store: store, location: '/recordings/saved');
      await tapText(tester, '导出文件');
      expect(store.exported!.toJson(), savedSession().toJson());

      await tapText(tester, '删除');
      await tapText(tester, '取消');
      expect(store.sessions, hasLength(1));
      await tapText(tester, '删除');
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(store.sessions, isEmpty);
      expect(find.text('还没有录制'), findsOneWidget);
    });
  });

  group('recording on a device', () {
    testWidgets('start and stop saves exactly once, even after navigating', (
      tester,
    ) async {
      final store = MemoryStore();
      final connection = FakeConnection();
      addTearDown(connection.dispose);
      await pumpApp(
        tester,
        connection: connection,
        store: store,
        location: '/devices/phone',
      );
      await tapKey(tester, const Key('start-recording'));
      await tester.enterText(find.byKey(const Key('recording-name')), '下单场景');
      await tapKey(tester, const Key('confirm-recording'));
      expect(connection.recordingAs, '下单场景');
      expect(find.textContaining('录制中'), findsWidgets);

      // Leave the device page; the recording keeps going app-wide.
      await tester.tap(find.text('设备').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('录制中'), findsWidgets);
      connection.stopRecording();
      await tester.pumpAndSettle();
      expect(store.saves, 1);
      expect(store.sessions.single.name, '登录流程');
      expect(connection.pendingRecording, isNull);
      expect(find.textContaining('已保存，共 1 条请求'), findsOneWidget);
    });

    testWidgets('a storage failure keeps the recording and retries cleanly', (
      tester,
    ) async {
      final store = MemoryStore()..saveFailure = StateError('空间不足');
      final connection = FakeConnection();
      addTearDown(connection.dispose);
      await pumpApp(
        tester,
        connection: connection,
        store: store,
        location: '/devices/phone',
      );
      connection.stopRecording();
      await tester.pumpAndSettle();
      expect(find.textContaining('空间不足'), findsOneWidget);
      expect(connection.pendingRecording, isNotNull);
      expect(store.saves, 1);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('start-recording')))
            .onPressed,
        isNull,
        reason: 'no new recording while one is unsaved',
      );

      store.saveFailure = null;
      await tapText(tester, '重试保存');
      expect(store.sessions, hasLength(1));
      expect(store.saves, 2);
      expect(connection.pendingRecording, isNull);
    });

    testWidgets('an unsaved recording can be exported instead', (tester) async {
      final store = MemoryStore()..saveFailure = StateError('空间不足');
      final connection = FakeConnection();
      addTearDown(connection.dispose);
      await pumpApp(
        tester,
        connection: connection,
        store: store,
        location: '/devices/phone',
      );
      connection.stopRecording();
      await tester.pumpAndSettle();
      await tapText(tester, '导出文件');
      expect(store.exported!.id, 'saved');
      expect(connection.pendingRecording, isNull);
    });
  });

  group('recording groups', () {
    Future<FakeConnection> openWithRecording(
      WidgetTester tester, {
      List<Map<String, dynamic>> rules = const [],
      bool supportsGroups = true,
    }) async {
      final store = MemoryStore()..sessions = [savedSession()];
      final connection = FakeConnection(
        rules: rules,
        supportsGroups: supportsGroups,
      );
      addTearDown(connection.dispose);
      await pumpApp(
        tester,
        connection: connection,
        store: store,
        location: '/devices/phone',
      );
      return connection;
    }

    Future<void> fromRecording(WidgetTester tester) async {
      await tapKey(tester, const Key('rules-menu'));
      await tapText(tester, '从录制生成录制组');
      await tester.tap(find.textContaining('登录流程').last);
      await tester.pumpAndSettle();
    }

    testWidgets('a recording becomes one editable group, synced on save', (
      tester,
    ) async {
      final connection = await openWithRecording(tester);
      await fromRecording(tester);
      expect(find.text('新建录制组'), findsOneWidget);
      expect(connection.applied, isNull);

      await tester.tap(toggleLabelled('只匹配录制时的传参'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('编辑接口'));
      await tester.pumpAndSettle();
      expect(find.text('录制组接口'), findsOneWidget);
      await setCode(tester, RuleEditorKeys.body, '{"ok":"edited"}');
      await tapText(tester, '应用到录制组');
      expect(connection.applied, isNull, reason: 'interface edits are drafts');

      await tapKey(tester, const Key('group-save'));
      final group = connection.applied!.single;
      expect(group['type'], 'recording');
      expect(group['matchParams'], isTrue);
      expect((group['rules'] as List).single['body'], {'ok': 'edited'});
      expect(find.text('登录流程'), findsWidgets);
      expect(find.text('录制组'), findsOneWidget);

      // Generating again reuses the group and its edits.
      await fromRecording(tester);
      expect(find.text('编辑录制组'), findsOneWidget);
      await tapKey(tester, const Key('group-save'));
      expect(connection.applied, hasLength(1));
      expect((connection.applied!.single['rules'] as List).single['body'], {
        'ok': 'edited',
      });
    });

    testWidgets('abandoning an interface edit asks and keeps the draft', (
      tester,
    ) async {
      await openWithRecording(tester);
      await fromRecording(tester);
      await tester.tap(find.byTooltip('编辑接口'));
      await tester.pumpAndSettle();
      await setCode(tester, RuleEditorKeys.body, '{"ok":"draft"}');
      await tapText(tester, '返回');
      expect(find.text('放弃对这个接口的修改？'), findsOneWidget);
      await tapText(tester, '放弃修改');
      expect(find.text('新建录制组'), findsOneWidget);
    });

    testWidgets('a group cannot be emptied or reuse another rule id', (
      tester,
    ) async {
      final connection = await openWithRecording(
        tester,
        rules: [
          {'id': 'taken', 'method': 'GET', 'path': '/x'},
        ],
      );
      await fromRecording(tester);
      await tester.enterText(find.byKey(const Key('group-id')), 'taken');
      await tester.tap(find.byTooltip('从录制组移除'));
      await tester.pumpAndSettle();
      await tapKey(tester, const Key('group-save'));
      expect(find.text('已有规则使用这个 ID'), findsOneWidget);
      expect(find.text('录制组至少要保留一个接口'), findsOneWidget);
      expect(connection.applied, isNull);
    });

    testWidgets('old app versions cannot receive groups', (tester) async {
      final connection = await openWithRecording(tester, supportsGroups: false);
      await tapKey(tester, const Key('rules-menu'));
      await tapText(tester, '从录制生成录制组');
      expect(find.textContaining('版本过旧'), findsOneWidget);
      expect(connection.applied, isNull);
    });

    testWidgets('edited groups survive rule file export and import', (
      tester,
    ) async {
      final group = recordingMockFromSession(
        savedSession(),
        matchParams: true,
      ).toJson();
      final child = (group['rules'] as List).single as Map<String, dynamic>;
      group['rules'] = [
        {
          ...child,
          'responseText': 'edited',
          'body': 'edited',
          'enabled': false,
        },
      ];
      final files = RuleFiles()..imported = jsonEncode([group]);
      final connection = FakeConnection();
      addTearDown(connection.dispose);
      await pumpApp(
        tester,
        connection: connection,
        files: files,
        location: '/devices/phone',
      );
      await tapKey(tester, const Key('rules-menu'));
      await tapText(tester, '导入规则文件…');
      await tapText(tester, '替换');
      expect(connection.applied, hasLength(1));
      expect(find.text('登录流程'), findsOneWidget);

      await tapKey(tester, const Key('rules-menu'));
      await tapText(tester, '导出规则文件');
      expect(jsonDecode(files.exported!), [group]);
    });
  });
}
