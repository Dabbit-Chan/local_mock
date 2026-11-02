import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_client/main.dart';
import 'package:local_mock_client/src/capture_session_store.dart';
import 'package:local_mock_client/src/mock_connection.dart';
import 'package:local_mock_client/src/rule_file_transfer.dart';
import 'package:local_mock_core/local_mock_core.dart';

TrafficSession savedSession({String id = 'saved'}) => TrafficSession(
  id: id,
  name: '登录流程',
  deviceId: 'phone',
  deviceName: '测试设备',
  startedAt: 100,
  endedAt: 1100,
  entries: [
    TrafficEntry(
      revision: 1,
      startedAt: 100,
      durationMs: 0,
      mocked: false,
      method: 'POST',
      uri: 'https://api.test/login',
      path: '/login',
      statusCode: 200,
      contentType: 'application/json',
      requestBody: '{"name":"test"}',
      responseBody: '{"ok":true}',
    ),
  ],
);

class _MemoryStore extends CaptureSessionStore {
  List<TrafficSession> sessions = [];
  TrafficSession? imported;
  TrafficSession? exported;
  Object? saveFailure;
  int saves = 0;

  @override
  Future<List<TrafficSession>> load() async => List.of(sessions);

  @override
  Future<void> save(List<TrafficSession> value) async {
    saves++;
    if (saveFailure != null) throw saveFailure!;
    sessions = [
      for (final session in value)
        TrafficSession.fromJson(jsonDecode(jsonEncode(session.toJson()))),
    ];
  }

  @override
  Future<TrafficSession?> importSession() async => imported;

  @override
  Future<void> exportSession(TrafficSession session) async =>
      exported = session;
}

class _CaptureConnection extends MockConnection {
  TrafficSession? draft;
  String? name;
  List<Map<String, dynamic>> appliedRules = [];
  bool _isRecording = false;

  @override
  bool get ready => true;
  @override
  bool get connected => true;
  @override
  String? get selectedId => 'phone';
  @override
  bool get supportsRecordingMocks => true;
  @override
  bool get recording => _isRecording;
  @override
  String? get recordingName => name;
  @override
  TrafficSession? get pendingRecording => draft;
  @override
  List<Map<String, dynamic>> get rules => appliedRules;

  @override
  void startRecording(String value) {
    name = value;
    _isRecording = true;
    notifyListeners();
  }

  @override
  TrafficSession stopRecording() {
    _isRecording = false;
    draft = savedSession();
    notifyListeners();
    return draft!;
  }

  @override
  void acknowledgeRecording(String id) {
    if (draft?.id == id) draft = null;
    notifyListeners();
  }

  @override
  Future<void> updateRules(String text) async {
    appliedRules = MockRule.parseList(
      jsonDecode(text),
    ).map((rule) => rule.toJson()).toList();
    notifyListeners();
  }
}

class _RuleFiles extends RuleFileTransfer {
  String? imported;
  String? exported;

  @override
  Future<String?> pickRules() async => imported;

  @override
  Future<void> saveRules(String filename, String contents) async =>
      exported = contents;
}

void main() {
  Future<void> openCapture(
    WidgetTester tester,
    _MemoryStore store, {
    MockConnection? connection,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MockPage(captureSessionStore: store, connection: connection),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('抓包'));
    await tester.pumpAndSettle();
  }

  Future<void> selectSaved(WidgetTester tester) async {
    await tester.tap(find.text('实时抓包'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('登录流程 · 1 条').last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'saved sessions reload, work offline and retain request details',
    (tester) async {
      final store = _MemoryStore()..sessions = [savedSession()];
      await openCapture(tester, store);
      await selectSaved(tester);
      expect(find.text('录制：登录流程（1） · 已保存'), findsOneWidget);
      expect(find.text('/login'), findsOneWidget);
      await tester.tap(find.text('/login'));
      await tester.pumpAndSettle();
      expect(find.text('请求详情'), findsOneWidget);
      expect(find.textContaining('"ok": true'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await openCapture(tester, store);
      await selectSaved(tester);
      expect(find.text('/login'), findsOneWidget);
    },
  );

  testWidgets('start and stop saves once even across navigation', (
    tester,
  ) async {
    final store = _MemoryStore();
    final connection = _CaptureConnection();
    addTearDown(connection.dispose);
    await openCapture(tester, store, connection: connection);
    await tester.tap(find.text('开始录制'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '录制名称'), '下单场景');
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    expect(connection.name, '下单场景');
    await tester.tap(find.text('Mock 规则'));
    await tester.pumpAndSettle();
    connection.stopRecording();
    await tester.pumpAndSettle();
    expect(store.sessions.single.name, '登录流程');
    expect(store.saves, 1);
    expect(connection.pendingRecording, isNull);
    await tester.tap(find.text('抓包'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已保存录制'), findsOneWidget);
  });

  testWidgets(
    'storage failure retains the draft and supports retry without duplicates',
    (tester) async {
      final store = _MemoryStore()..saveFailure = StateError('空间不足');
      final connection = _CaptureConnection();
      addTearDown(connection.dispose);
      await openCapture(tester, store, connection: connection);
      connection.stopRecording();
      await tester.pumpAndSettle();
      expect(find.textContaining('空间不足'), findsOneWidget);
      expect(connection.pendingRecording, isNotNull);
      expect(store.saves, 1);
      store.saveFailure = null;
      await tester.tap(find.text('重试保存录制'));
      await tester.pumpAndSettle();
      expect(store.sessions, hasLength(1));
      expect(connection.pendingRecording, isNull);
      expect(store.saves, 2);
    },
  );

  testWidgets(
    'recording creates one editable Mock group with optional parameter matching',
    (tester) async {
      final store = _MemoryStore()..imported = savedSession();
      final connection = _CaptureConnection();
      addTearDown(connection.dispose);
      await openCapture(tester, store, connection: connection);
      await tester.tap(find.text('导入录制'));
      await tester.pumpAndSettle();
      expect(store.sessions, hasLength(1));
      await tester.tap(find.text('回放 / 配置 Mock'));
      await tester.pumpAndSettle();
      expect(connection.appliedRules, isEmpty);
      expect(find.text('录制 Mock 配置'), findsOneWidget);
      await tester.tap(find.text('只 Mock 录制时的传参'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('编辑接口'));
      await tester.pumpAndSettle();
      expect(find.text('编辑规则'), findsOneWidget);
      final response = find.widgetWithText(TextFormField, '响应体文本（支持 JSON）');
      await tester.ensureVisible(response);
      await tester.enterText(response, '{"ok":"edited"}');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(connection.appliedRules, isEmpty);
      await tester.tap(find.text('保存录制 Mock'));
      await tester.pumpAndSettle();
      expect(connection.appliedRules, hasLength(1));
      expect(connection.appliedRules.single['type'], 'recording');
      expect(connection.appliedRules.single['matchParams'], isTrue);
      expect((connection.appliedRules.single['rules'] as List).single['body'], {
        'ok': 'edited',
      });
      await tester.tap(find.text('导出录制'));
      await tester.pumpAndSettle();
      expect(store.exported!.toJson(), savedSession().toJson());
      await tester.tap(find.text('Mock 规则'));
      await tester.pumpAndSettle();
      expect(find.text('录制 Mock · 登录流程'), findsOneWidget);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(connection.appliedRules.single['enabled'], isFalse);
      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();
      expect(find.text('编辑录制 Mock'), findsOneWidget);
      await tester.tap(find.byTooltip('编辑接口'));
      await tester.pumpAndSettle();
      expect(find.text('编辑规则'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, '响应体文本（支持 JSON）'),
            )
            .controller!
            .text,
        '{"ok":"edited"}',
      );
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('抓包'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('回放 / 配置 Mock'));
      await tester.pumpAndSettle();
      expect(find.text('编辑录制 Mock'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(connection.appliedRules, hasLength(1));
      expect((connection.appliedRules.single['rules'] as List).single['body'], {
        'ok': 'edited',
      });
    },
  );

  testWidgets(
    'deletion requires confirmation and cancelled imports do not write',
    (tester) async {
      final store = _MemoryStore()..sessions = [savedSession()];
      await openCapture(tester, store);
      await tester.tap(find.text('导入录制'));
      await tester.pumpAndSettle();
      expect(store.saves, 0);
      await selectSaved(tester);
      await tester.tap(find.text('删除录制'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.sessions, hasLength(1));
      await tester.tap(find.text('删除录制'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(store.sessions, isEmpty);
      expect(find.text('实时抓包'), findsOneWidget);
    },
  );

  testWidgets(
    'edited recording groups import and export as one rule without losing conditions',
    (tester) async {
      final group = recordingMockFromSession(
        savedSession(),
        matchParams: true,
      ).toJson();
      final child = (group['rules'] as List).single as Map<String, dynamic>;
      group['rules'] = [
        {
          ...child,
          'responseText': 'edited text',
          'body': 'edited text',
          'enabled': false,
        },
      ];
      final files = _RuleFiles()..imported = jsonEncode([group]);
      final connection = _CaptureConnection();
      addTearDown(connection.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: MockPage(ruleFileTransfer: files, connection: connection),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入规则'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认导入'));
      await tester.pumpAndSettle();
      expect(find.text('录制 Mock · 登录流程'), findsOneWidget);
      expect(connection.appliedRules, hasLength(1));
      await tester.tap(find.text('导出规则'));
      await tester.pumpAndSettle();
      expect(jsonDecode(files.exported!), [group]);
    },
  );
}
