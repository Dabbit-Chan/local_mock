import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_core/local_mock_core.dart';
import 'package:local_mock_client/src/mock_connection.dart';
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
    'reconnecting an app restores acknowledged rules and deduplicates traffic',
    () async {
      final app = await startApp('a');
      await connection.connect(address);
      await connection.apply(ruleJson('saved'));
      app.emit('/one');
      await waitUntil(() => connection.traffic.length == 1);
      app.agent.stop();
      await waitUntil(() => !connection.ready);
      app.rules = [];
      app.agent.start();
      await waitUntil(() => connection.ready && app.rules.isNotEmpty);
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
