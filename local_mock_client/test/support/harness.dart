import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_client/main.dart';
import 'package:local_mock_client/src/capture_session_store.dart';
import 'package:local_mock_client/src/mock_connection.dart';
import 'package:local_mock_client/src/rule_file_transfer.dart';
import 'package:local_mock_core/local_mock_core.dart';
import 'package:re_editor/re_editor.dart';

TrafficSession savedSession({String id = 'saved', String name = '登录流程'}) =>
    TrafficSession(
      id: id,
      name: name,
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

Map<String, dynamic> trafficEntry(
  int revision,
  String path, {
  String method = 'GET',
  String host = 'api.test',
  String query = '',
  int? status = 200,
  bool mocked = false,
  String? response,
  String? request,
  String? error,
}) => {
  'revision': revision,
  'startedAt': 1710000000000 + revision * 1000,
  'durationMs': 12,
  'mocked': mocked,
  'method': method,
  'uri': 'https://$host$path${query.isEmpty ? '' : '?$query'}',
  'host': host,
  'path': path,
  'statusCode': ?status,
  'contentType': 'application/json',
  'responseBody': ?response,
  'requestBody': ?request,
  'error': ?error,
};

class MemoryStore extends CaptureSessionStore {
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

class RuleFiles extends RuleFileTransfer {
  String? imported;
  String? exported;
  Object? pickFailure;

  @override
  Future<String?> pickRules() async {
    if (pickFailure != null) throw pickFailure!;
    return imported;
  }

  @override
  Future<void> saveRules(String filename, String contents) async =>
      exported = contents;
}

/// A ready device `phone` whose acknowledged rules are recorded in
/// [applied].
class FakeConnection extends MockConnection {
  FakeConnection({
    List<Map<String, dynamic>> rules = const [],
    List<Map<String, dynamic>>? traffic,
    this.devices = const [MockTarget('phone', '测试设备')],
    this.isConnected = true,
    this.supportsGroups = true,
  }) : deviceRules = [for (final r in rules) Map.of(r)],
       entries = traffic ?? [];

  List<Map<String, dynamic>> deviceRules;
  List<Map<String, dynamic>> entries;
  List<MockTarget> devices;
  bool isConnected;
  bool supportsGroups;
  List<Map<String, dynamic>>? applied;
  int pushes = 0;
  int revision = 0;
  String? recordingAs;
  bool _recording = false;
  TrafficSession? draft;
  TrafficSession Function() finish = savedSession;

  /// Simulates the device reporting a different rule set.
  void deviceReplacesRules(List<Map<String, dynamic>> rules) {
    deviceRules = rules;
    revision++;
    notifyListeners();
  }

  @override
  bool get connected => isConnected;
  @override
  bool get ready => isConnected && selectedId != null;
  @override
  bool get working => false;
  @override
  List<MockTarget> get targets => isConnected ? devices : const [];
  @override
  String? get selectedId =>
      isConnected && devices.any((d) => d.id == 'phone' && d.online)
      ? 'phone'
      : null;
  @override
  String get status => isConnected ? '已就绪' : '正在连接 Relay…';
  @override
  bool get supportsRecordingMocks => supportsGroups;
  @override
  List<Map<String, dynamic>> get rules => deviceRules;
  @override
  int get rulesRevision => revision;
  @override
  List<Map<String, dynamic>> get traffic => entries;
  @override
  int? get remoteRuleCount => applied?.length ?? deviceRules.length;
  @override
  bool get recording => _recording;
  @override
  String? get recordingName => recordingAs;
  @override
  int get recordedCount => 0;
  @override
  TrafficSession? get pendingRecording => draft;

  @override
  Future<void> selectTarget(String id) async {}

  @override
  Future<void> updateRules(String text) async {
    final parsed = MockRule.parseList(jsonDecode(text));
    if (!supportsGroups && parsed.any((r) => r.isRecording)) {
      throw StateError('设备上的 local_mock 版本不支持录制组');
    }
    applied = parsed.map((r) => r.toJson()).toList();
    pushes++;
    notifyListeners();
  }

  @override
  Future<void> clear() async {
    applied = [];
    deviceRules = [];
    revision++;
    notifyListeners();
  }

  @override
  Future<void> clearTraffic() async {
    entries = [];
    notifyListeners();
  }

  @override
  void startRecording(String name) {
    recordingAs = name;
    _recording = true;
    notifyListeners();
  }

  @override
  TrafficSession stopRecording() {
    _recording = false;
    draft = finish();
    notifyListeners();
    return draft!;
  }

  @override
  void acknowledgeRecording(String id) {
    if (draft?.id == id) draft = null;
    notifyListeners();
  }
}

Future<void> pumpApp(
  WidgetTester tester, {
  MockConnection? connection,
  MemoryStore? store,
  RuleFiles? files,
  String location = '/',
  ThemeMode themeMode = ThemeMode.light,
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final conn = connection ?? FakeConnection();
  if (connection == null) addTearDown(conn.dispose);
  await tester.pumpWidget(
    LocalMockApp(
      connection: conn,
      store: store ?? MemoryStore(),
      ruleFiles: files ?? RuleFiles(),
      initialLocation: location,
      themeMode: themeMode,
    ),
  );
  await tester.pumpAndSettle();
}

CodeLineEditingController codeAt(WidgetTester tester, Key key) =>
    tester.widget<CodeEditor>(find.byKey(key)).controller!;

Future<void> setCode(WidgetTester tester, Key key, String text) async {
  codeAt(tester, key).text = text;
  await tester.pumpAndSettle();
}

Future<void> tapText(WidgetTester tester, String text) async {
  final finder = find.text(text).last;
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> tapKey(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}
