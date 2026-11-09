import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_core/local_mock_core.dart';
import 'package:local_mock_client/src/mock_connection.dart';
import 'package:local_mock_client/src/rule_book.dart';
import 'support/harness.dart' show MemoryRuleStore;
import '../tool/relay_host.dart';
import 'package:local_mock_transport/local_mock_transport.dart';

String ruleJson(String name) => jsonEncode([
  {
    'id': 'profile',
    'method': 'GET',
    'path': '/api/profile',
    'body': {'name': name},
  },
]);

Future<void> waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for relay state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

TrafficSession replaySession() => TrafficSession(
  id: 'flow',
  name: '历史流程',
  deviceId: 'other-device',
  deviceName: '另一台手机',
  startedAt: 100,
  endedAt: 200,
  entries: [
    TrafficEntry(
      revision: 1,
      startedAt: 100,
      durationMs: 0,
      mocked: false,
      method: 'GET',
      uri: 'https://api.test/api/profile',
      path: '/api/profile',
      statusCode: 202,
      contentType: 'application/json',
      responseBody: '{"name":"replayed"}',
    ),
  ],
);

class TestApp {
  TestApp(String address, String id) {
    agent = LocalMockAgent(
      serverUrl: address,

      deviceId: id,
      deviceName: id,
      reconnectDelay: const Duration(milliseconds: 40),
      snapshot: () => {'rules': rules, 'entries': traffic},
      onCommand: (method, args) async {
        if (delay != null) await delay!.future;
        if (reject && method == 'replaceRules') {
          throw StateError('Invalid rules');
        }
        switch (method) {
          case 'replaceRules':
            rules = List.of(args['rules'] as List);
          case 'clear':
            rules = [];
          case 'clearTraffic':
            traffic.clear();
        }
        return {'rules': rules};
      },
    );
  }
  late final LocalMockAgent agent;
  List<dynamic> rules = [];
  bool reject = false;
  Completer<void>? delay;
  int revision = 0;
  final traffic = <Map<String, dynamic>>[];
  void emit(String path) {
    final entry = <String, dynamic>{
      'revision': ++revision,
      'method': 'GET',
      'uri': 'https://api.test$path',
      'path': path,
      'startedAt': 1710000000000,
      'durationMs': 1,
      'mocked': false,
    };
    traffic.add(entry);
    agent.report(entry);
  }
}

void main() {
  late LocalMockRelay server;
  late MockConnection connection;
  final apps = <TestApp>[];
  late String address;

  setUp(() async {
    server = LocalMockRelay();
    await server.start(port: 0);
    address = 'http://127.0.0.1:${server.port}';
    connection = MockConnection();
  });
  tearDown(() async {
    LocalMock.disconnect();
    LocalMock.debugClear();
    LocalMock.debugClearTraffic();
    connection.dispose();
    for (final app in apps) {
      app.agent.stop();
    }
    apps.clear();
    await server.close();
  });

  Future<TestApp> startApp(String id) async {
    final app = TestApp(address, id);
    apps.add(app);
    app.agent.start();
    await waitUntil(() => app.agent.connected);
    return app;
  }

  test(
    'recording excludes history and survives the live 500-entry cap and clear',
    () async {
      final app = await startApp('a');
      await connection.connect(address);
      app.emit('/before');
      await waitUntil(() => connection.traffic.length == 1);
      connection.startRecording('完整流程');
      for (var index = 0; index < 520; index++) {
        app.emit('/recorded-$index');
      }
      await waitUntil(() => connection.recordedCount == 520);
      await connection.clearTraffic();
      app.emit('/after-clear');
      await waitUntil(() => connection.recordedCount == 521);
      final saved = connection.stopRecording();
      expect(saved.name, '完整流程');
      expect(saved.deviceId, 'a');
      expect(saved.entries, hasLength(521));
      expect(saved.entries.first.path, '/recorded-0');
      expect(saved.entries.last.path, '/after-clear');
      expect(connection.traffic, hasLength(1));
      app.emit('/after-stop');
      await waitUntil(() => connection.traffic.length == 2);
      expect(saved.entries, hasLength(521));
      expect(() => connection.startRecording('new'), throwsStateError);
      connection.acknowledgeRecording(saved.id);
      connection.startRecording('next');
      expect(connection.recordedCount, 0);
    },
  );

  test(
    'recording cannot mix devices and stops with a recoverable draft offline',
    () async {
      final app = await startApp('a');
      final other = await startApp('b');
      await connection.connect(address);
      await connection.selectTarget('a');
      connection.startRecording('a only');
      await expectLater(connection.selectTarget('b'), throwsStateError);
      app.emit('/recorded');
      other.emit('/not-recorded');
      await waitUntil(() => connection.recordedCount == 1);
      app.agent.stop();
      await waitUntil(() => !connection.recording);
      expect(connection.pendingRecording!.entries.single.path, '/recorded');
      expect(connection.pendingRecording!.deviceId, 'a');
      expect(connection.ready, isFalse);
    },
  );

  test(
    'state refreshes and app reconnects do not duplicate a recording',
    () async {
      final app = await startApp('a');
      await connection.connect(address);
      app.emit('/before');
      await waitUntil(() => connection.traffic.length == 1);
      connection.startRecording('refresh');
      app.emit('/once');
      await waitUntil(() => connection.recordedCount == 1);
      await connection.apply(ruleJson('state refresh'));
      await connection.selectTarget('a');
      expect(connection.recordedCount, 1);
      connection.disconnect();
      expect(connection.recording, isFalse);
      expect(connection.pendingRecording!.entries.single.path, '/once');
    },
  );

  test(
    'recording Mock group is acknowledged, editable and survives console reconnect',
    () async {
      LocalMock.connect(serverUrl: address, deviceId: 'sdk');
      await waitUntil(() => LocalMock.connected);
      await connection.connect(address);
      expect(connection.supportsRecordingMocks, isTrue);
      await connection.apply(ruleJson('manual'));
      final group = recordingMockFromSession(
        replaySession(),
        matchParams: true,
      ).toJson();
      await connection.apply(jsonEncode([group, ...connection.rules]));
      expect(connection.rules.first['recordingId'], 'flow');
      expect(connection.rules.last['body'], {'name': 'manual'});
      final uri = Uri.parse('https://api.test/api/profile');
      expect(LocalMock.match('GET', uri)!.body, {'name': 'replayed'});
      connection.disconnect();
      await connection.connect(address);
      expect(connection.rules.first['name'], '历史流程');
      await connection.apply(
        jsonEncode([
          {...group, 'enabled': false},
          connection.rules.last,
        ]),
      );
      expect(LocalMock.match('GET', uri)!.body, {'name': 'manual'});
    },
  );

  test(
    'older apps cannot falsely acknowledge replay and keep existing rules',
    () async {
      await startApp('old');
      await connection.connect(address);
      await connection.apply(ruleJson('kept'));
      expect(connection.supportsRecordingMocks, isFalse);
      await expectLater(
        connection.apply(
          jsonEncode([recordingMockFromSession(replaySession()).toJson()]),
        ),
        throwsStateError,
      );
      expect(connection.rules.single['body'], {'name': 'kept'});
    },
  );

  test(
    'rapid edits to recording groups converge to the latest acknowledged version',
    () async {
      LocalMock.connect(serverUrl: address, deviceId: 'sdk');
      await waitUntil(() => LocalMock.connected);
      await connection.connect(address);
      final group = recordingMockFromSession(replaySession()).toJson();
      final first = connection.updateRules(jsonEncode([group]));
      final child = (group['rules'] as List).single as Map<String, dynamic>;
      final edited = {
        ...group,
        'rules': [
          {
            ...child,
            'body': {'name': 'edited'},
            'responseText': '{"name":"edited"}',
          },
        ],
      };
      final second = connection.updateRules(jsonEncode([edited]));
      await Future.wait([first, second]);
      expect(connection.rules.single, edited);
      expect(
        LocalMock.match('GET', Uri.parse('https://api.test/api/profile'))!.body,
        {'name': 'edited'},
      );
    },
  );

  test(
    'real SDK reports traffic, receives rules and excludes control traffic',
    () async {
      expect(
        LocalMock.connect(
          serverUrl: address,
          deviceId: 'sdk',
          deviceName: 'QA phone',
        ),
        isTrue,
      );
      await waitUntil(() => LocalMock.connected);
      await connection.connect(address);
      await waitUntil(() => connection.ready);
      await connection.apply(ruleJson('QA'));
      expect(
        LocalMock.match('GET', Uri.parse('https://api.test/api/profile'))?.body,
        {'name': 'QA'},
      );
      LocalMock.beginTraffic(
        'GET',
        Uri.parse('https://api.test/api/profile'),
      )!.finish(statusCode: 200, mocked: true, body: '{"name":"QA"}');
      await waitUntil(() => connection.traffic.length == 1);
      expect(connection.traffic.single['mocked'], isTrue);
      expect(
        LocalMock.beginTraffic('GET', Uri.parse('$address/ws/app')),
        isNull,
      );
      await connection.clearTraffic();
      expect(connection.traffic, isEmpty);
      expect(LocalMock.debugTrafficEntries(), isEmpty);
      await connection.clear();
      expect(
        LocalMock.match('GET', Uri.parse('https://api.test/api/profile')),
        isNull,
      );
    },
  );

  test(
    'a console can connect before an app and discovers it automatically',
    () async {
      await connection.connect(address);
      expect(connection.ready, isFalse);
      await startApp('phone');
      await waitUntil(() => connection.ready);
      expect(connection.selectedId, 'phone');
    },
  );

  test(
    'switching devices loads their rules without overwriting them',
    () async {
      final a = await startApp('a');
      final b = await startApp('b');
      await connection.connect(address);
      await waitUntil(() => connection.targets.length == 2);
      await connection.selectTarget('a');
      await connection.apply(ruleJson('A'));
      a.emit('/a');
      b.emit('/b');
      await waitUntil(() => connection.traffic.length == 1);
      await connection.selectTarget('b');
      expect(connection.rules, isEmpty);
      expect(connection.traffic.single['path'], '/b');
      await connection.apply(ruleJson('B'));
      await connection.selectTarget('a');
      expect(connection.rules.single['body'], {'name': 'A'});
      expect((b.rules.single as Map)['body'], {'name': 'B'});
      expect(connection.traffic.single['path'], '/a');
    },
  );

  test(
    'only rule updates report syncing rules while device commands are busy',
    () async {
      final app = await startApp('a');
      await connection.connect(address);
      app.delay = Completer<void>();
      final reading = connection.selectTarget('a');
      expect(connection.working, isTrue);
      expect(connection.syncingRules, isFalse);
      app.delay!.complete();
      await reading;

      app.delay = Completer<void>();
      final syncing = connection.apply(ruleJson('saved'));
      expect(connection.working, isTrue);
      expect(connection.syncingRules, isTrue);
      app.delay!.complete();
      await syncing;
      expect(connection.syncingRules, isFalse);

      app.delay = Completer<void>();
      final clearingTraffic = connection.clearTraffic();
      expect(connection.working, isTrue);
      expect(connection.syncingRules, isFalse);
      app.delay!.complete();
      await clearingTraffic;
      expect(connection.working, isFalse);
    },
  );

  test('rapid edits converge to the latest acknowledged version', () async {
    final app = await startApp('a');
    await connection.connect(address);
    app.delay = Completer<void>();
    final first = connection.updateRules(ruleJson('first'));
    final latest = connection.updateRules(ruleJson('latest'));
    app.delay!.complete();
    await Future.wait([first, latest]);
    expect((app.rules.single as Map)['body'], {'name': 'latest'});
    expect(connection.remoteRuleCount, 1);
  });

  test(
    'reconnecting an app preserves its in-memory rules and deduplicates traffic',
    () async {
      final app = await startApp('a');
      await connection.connect(address);
      await connection.apply(ruleJson('saved'));
      app.emit('/one');
      await waitUntil(() => connection.traffic.length == 1);
      app.agent.stop();
      await waitUntil(() => !connection.ready);
      app.agent.start();
      await waitUntil(() => connection.ready);
      expect((app.rules.single as Map)['body'], {'name': 'saved'});
      app.emit('/two');
      await waitUntil(() => connection.traffic.length == 2);
      expect(connection.traffic.map((e) => e['path']), ['/one', '/two']);
    },
  );

  test('failed rules never replace the last acknowledged rules', () async {
    final app = await startApp('a');
    await connection.connect(address);
    await connection.apply(ruleJson('saved'));
    app.reject = true;
    await expectLater(connection.apply(ruleJson('rejected')), throwsStateError);
    app.reject = false;
    connection.disconnect();
    await connection.connect(address);
    expect(connection.rules.single['body'], {'name': 'saved'});
  });

  test('cold start leaves rules empty until explicit browser sync', () async {
    final app = await startApp('a');
    await connection.connect(address);
    final store = MemoryRuleStore();
    final book = RuleBook(connection, store: store);
    addTearDown(book.dispose);
    await book.replaceAll(RuleBook.parseFile(ruleJson('saved')));
    expect(app.rules, isEmpty);
    await book.push();
    expect(book.autoSyncEnabled, isTrue);
    app.agent.stop();
    await waitUntil(() => !connection.ready);
    final replacement = await startApp('a');
    await waitUntil(() => connection.ready);
    expect(replacement.rules, isEmpty);
    expect(book.rules.single['body'], {'name': 'saved'});
    expect(book.autoSyncEnabled, isFalse);
    await book.replaceAll(RuleBook.parseFile(ruleJson('edited')));
    expect(replacement.rules, isEmpty);
    await book.push();
    await book.replaceAll(RuleBook.parseFile(ruleJson('automatic')));
    expect((replacement.rules.single as Map)['body'], {'name': 'automatic'});
  });

  test('offline edits resume only for the approved app session', () async {
    final app = await startApp('a');
    await connection.connect(address);
    final book = RuleBook(connection, store: MemoryRuleStore());
    addTearDown(book.dispose);
    await book.replaceAll(RuleBook.parseFile(ruleJson('saved')));
    await book.push();
    app.agent.stop();
    await waitUntil(() => !connection.ready);
    await book.replaceAll(RuleBook.parseFile(ruleJson('offline')));
    app.agent.start();
    await waitUntil(
      () =>
          connection.ready &&
          (app.rules.single as Map)['body']['name'] == 'offline',
    );
    expect(book.autoSyncEnabled, isTrue);
    app.agent.stop();
    await waitUntil(() => !connection.ready);
    await book.replaceAll(RuleBook.parseFile(ruleJson('next-session')));
    final replacement = await startApp('a');
    await waitUntil(() => connection.ready);
    expect(replacement.rules, isEmpty);
    expect(book.autoSyncEnabled, isFalse);
  });

  test(
    'interrupted automatic edits retry on the same session reconnect',
    () async {
      final app = await startApp('a');
      await connection.connect(address);
      final book = RuleBook(connection, store: MemoryRuleStore());
      addTearDown(book.dispose);
      await book.replaceAll(RuleBook.parseFile(ruleJson('saved')));
      await book.push();
      app.delay = Completer<void>();
      final edit = book.replaceAll(RuleBook.parseFile(ruleJson('interrupted')));
      final failed = expectLater(edit, throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      app.agent.stop();
      await failed;
      expect(book.syncError, isNotNull);
      app.delay!.complete();
      app.delay = null;
      app.agent.start();
      await waitUntil(
        () =>
            connection.ready &&
            (app.rules.single as Map)['body']['name'] == 'interrupted',
      );
      expect(book.autoSyncEnabled, isTrue);
      expect(book.syncError, isNull);
    },
  );

  test('a failed initial sync never enables automatic sync', () async {
    final app = await startApp('a');
    await connection.connect(address);
    final book = RuleBook(connection, store: MemoryRuleStore());
    addTearDown(book.dispose);
    await book.replaceAll(RuleBook.parseFile(ruleJson('saved')));
    app.reject = true;
    await expectLater(book.push(), throwsStateError);
    expect(book.autoSyncEnabled, isFalse);
    app.reject = false;
    await book.replaceAll(RuleBook.parseFile(ruleJson('local-only')));
    expect(app.rules, isEmpty);
    await book.push();
    expect(book.autoSyncEnabled, isTrue);
    expect((app.rules.single as Map)['body'], {'name': 'local-only'});
  });

  test('a restarted app resets the traffic revision namespace', () async {
    final app = await startApp('a');
    await connection.connect(address);
    app.emit('/old');
    await waitUntil(() => connection.traffic.length == 1);
    app.agent.stop();
    await waitUntil(() => !connection.ready);
    final replacement = await startApp('a');
    await waitUntil(() => connection.ready);
    replacement.emit('/new');
    await waitUntil(
      () =>
          connection.traffic.length == 1 &&
          connection.traffic.single['path'] == '/new',
    );
  });

  test('console disconnect preserves app rules and server traffic', () async {
    final app = await startApp('a');
    await connection.connect(address);
    await connection.apply(ruleJson('saved'));
    app.emit('/retained');
    await waitUntil(() => connection.traffic.length == 1);
    connection.disconnect();
    expect(app.rules, hasLength(1));
    expect(connection.traffic, hasLength(1));
    await connection.connect(address);
    expect(connection.traffic.single['path'], '/retained');
  });

  test(
    'an unavailable backend is retried without uncaught socket errors',
    () async {
      final port = server.port;
      await server.close();
      final app = TestApp(address, 'retry');
      apps.add(app);
      app.agent.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(app.agent.connected, isFalse);
      server = LocalMockRelay();
      await server.start(port: port);
      await waitUntil(() => app.agent.connected);
      await connection.connect(address);
      expect(connection.selectedId, 'retry');
      expect(connection.ready, isTrue);
    },
  );

  test(
    'two live apps cannot accidentally share the same device identity',
    () async {
      final app = await startApp('unique');
      final duplicate = TestApp(address, 'unique');
      apps.add(duplicate);
      duplicate.agent.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(duplicate.agent.connected, isFalse);
      expect(app.agent.connected, isTrue);
      await connection.connect(address);
      await connection.apply(ruleJson('original'));
      expect((app.rules.single as Map)['body'], {'name': 'original'});
      expect(duplicate.rules, isEmpty);
    },
  );

  test(
    'disconnecting a device fails pending edits and releases busy state',
    () async {
      final app = await startApp('a');
      await connection.connect(address);
      await connection.apply(ruleJson('saved'));
      app.delay = Completer<void>();
      final edit = connection.apply(ruleJson('interrupted'));
      final failed = expectLater(edit, throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      app.agent.stop();
      await failed;
      expect(connection.working, isFalse);
      expect(connection.syncingRules, isFalse);
      app.delay!.complete();
      app.delay = null;
      app.agent.start();
      await waitUntil(() => connection.ready);
      await connection.apply(ruleJson('recovered'));
      expect((app.rules.single as Map)['body'], {'name': 'recovered'});
    },
  );

  test('server and console keep the latest 500 requests', () async {
    final app = await startApp('a');
    await connection.connect(address);
    for (var i = 0; i < 510; i++) {
      app.emit('/$i');
    }
    await waitUntil(
      () =>
          connection.traffic.isNotEmpty &&
          connection.traffic.last['path'] == '/509',
    );
    expect(connection.traffic, hasLength(500));
    expect(connection.traffic.first['path'], '/10');
  });
}
