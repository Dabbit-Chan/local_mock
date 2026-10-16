import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_core/local_mock_core.dart';
import 'package:local_mock_desktop/src/mock_connection.dart';

/// Exercises the wire client without starting a business app or real Dart VM.
class FakeVm {
  late HttpServer server;
  final sockets = <WebSocket>[];
  bool extensionAvailable = true;
  bool captureAvailable = true;
  bool rejectReplacement = false;
  String isolateId = 'isolates/1';
  int version = LocalMockProtocol.version;
  List<dynamic> rules = [];

  /// Captured entries with monotonic revisions, like TrafficRecorder.
  final traffic = <Map<String, dynamic>>[];
  int trafficRevision = 0;

  String get address => 'http://127.0.0.1:${server.port}/token=/';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path != '/token=/ws') {
        request.response.statusCode = 403;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((message) {
        final request = jsonDecode(message as String) as Map<String, dynamic>;
        final method = request['method'];
        final params = request['params'] as Map<String, dynamic>;
        Map<String, dynamic> result;
        switch (method) {
          case 'getVM':
            result = {
              'type': 'VM',
              'isolates': [
                {
                  'type': '@Isolate',
                  'id': isolateId,
                  'name': 'main',
                  'number': '1',
                },
              ],
            };
          case 'getIsolate':
            result = {
              'type': 'Isolate',
              'id': isolateId,
              'name': 'main',
              'number': '1',
              'extensionRPCs': extensionAvailable
                  ? [
                      LocalMockProtocol.getState,
                      LocalMockProtocol.replaceRules,
                      LocalMockProtocol.clear,
                      if (captureAvailable) ...[
                        LocalMockProtocol.getTraffic,
                        LocalMockProtocol.clearTraffic,
                      ],
                    ]
                  : [],
            };
          case LocalMockProtocol.replaceRules:
            if (rejectReplacement) {
              socket.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'id': request['id'],
                  'error': {'code': -32602, 'message': 'invalid rules'},
                }),
              );
              return;
            }
            expect(params['protocolVersion'], '${LocalMockProtocol.version}');
            rules = jsonDecode(params['rules'] as String) as List;
            result = state;
          case LocalMockProtocol.clear:
            rules = [];
            result = state;
          case LocalMockProtocol.getState:
            result = state;
          case LocalMockProtocol.getTraffic:
            final since = int.parse(params['sinceRevision'] as String? ?? '0');
            result = {
              'protocolVersion': version,
              'trafficRevision': trafficRevision,
              'entries': [
                for (final entry in traffic)
                  if (entry['revision'] as int > since) entry,
              ],
            };
          case LocalMockProtocol.clearTraffic:
            traffic.clear();
            result = {
              'protocolVersion': version,
              'trafficRevision': trafficRevision,
              'entries': [],
            };
          default:
            throw StateError('Unexpected RPC: $method');
        }
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
        );
      });
    });
  }

  Map<String, dynamic> get state => {
    'protocolVersion': version,
    'revision': 1,
    'rules': rules,
  };

  /// Appends one captured request, like an adapter would.
  void emitTraffic(String path, {int? statusCode, bool mocked = false}) {
    trafficRevision++;
    traffic.add({
      'revision': trafficRevision,
      'startedAt': 1710000000000 + trafficRevision * 1000,
      'durationMs': 42,
      'mocked': mocked,
      'method': 'GET',
      'uri': 'https://api.test$path?token=1',
      'host': 'api.test',
      'path': path,
      'statusCode': statusCode,
      'responseBody': '{"source":"backend"}',
    });
  }

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}

String ruleJson(String name) => jsonEncode([
  {
    'id': 'profile',
    'method': 'GET',
    'path': '/api/profile',
    'body': {'name': name},
  },
]);

Future<void> waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 6));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for VM client state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late FakeVm vm;
  late MockConnection connection;

  setUp(() async {
    vm = FakeVm();
    await vm.start();
    connection = MockConnection();
  });

  tearDown(() async {
    connection.dispose();
    await vm.close();
  });

  test('connect, apply, acknowledge and clear rules', () async {
    await connection.connect(vm.address);
    expect(connection.ready, isTrue);
    expect(connection.selectedId, 'isolates/1');
    await connection.apply(ruleJson('first'));
    expect(connection.remoteRuleCount, 1);
    expect((vm.rules.single as Map)['body'], {'name': 'first'});
    await connection.clear();
    expect(vm.rules, isEmpty);
    expect(connection.remoteRuleCount, 0);
  });

  test(
    'discovers extensions registered after the initial connection',
    () async {
      vm.extensionAvailable = false;
      await connection.connect(vm.address);
      expect(connection.ready, isFalse);
      vm.extensionAvailable = true;
      await waitUntil(() => connection.ready);
    },
  );

  test(
    'hot restart restores acknowledged rules into replacement isolate',
    () async {
      await connection.connect(vm.address);
      await connection.apply(ruleJson('first'));
      vm.rules = [];
      vm.isolateId = 'isolates/2';
      await waitUntil(() => connection.selectedId == 'isolates/2');
      expect((vm.rules.single as Map)['body'], {'name': 'first'});
    },
  );

  test(
    'failed application does not overwrite last acknowledged rules',
    () async {
      await connection.connect(vm.address);
      await connection.apply(ruleJson('first'));
      vm.rejectReplacement = true;
      await expectLater(
        connection.apply(ruleJson('rejected')),
        throwsException,
      );
      vm.rejectReplacement = false;
      vm.rules = [];
      vm.isolateId = 'isolates/2';
      await waitUntil(() => connection.selectedId == 'isolates/2');
      expect((vm.rules.single as Map)['body'], {'name': 'first'});
    },
  );

  test('disconnect retains remote rules; reconnect restores them', () async {
    await connection.connect(vm.address);
    await connection.apply(ruleJson('first'));
    connection.disconnect();
    expect(connection.connected, isFalse);
    expect(vm.rules, hasLength(1));
    await connection.connect(vm.address);
    expect(connection.remoteRuleCount, 1);
  });

  test('incompatible protocol is never modified', () async {
    vm.version = 999;
    await connection.connect(vm.address);
    expect(connection.ready, isFalse);
    expect(connection.status, contains('协议版本不兼容'));
    expect(vm.rules, isEmpty);
  });

  test('older app protocol is reported clearly', () async {
    vm.version = 1;
    await connection.connect(vm.address);
    expect(connection.ready, isFalse);
    expect(connection.status, contains('版本过旧'));
    expect(vm.rules, isEmpty);
  });

  test('live capture polls only new traffic entries', () async {
    await connection.connect(vm.address);
    expect(connection.captureAvailable, isTrue);

    connection.setCaptureLive(true);
    vm.emitTraffic('/api/a');
    await waitUntil(() => connection.traffic.length == 1);
    expect(connection.traffic.single['path'], '/api/a');

    vm.emitTraffic('/api/b');
    await waitUntil(() => connection.traffic.length == 2);
    expect(connection.traffic.map((entry) => entry['path']), [
      '/api/a',
      '/api/b',
    ]);
  });

  test('clearTraffic empties the app buffer and the local list', () async {
    await connection.connect(vm.address);
    connection.setCaptureLive(true);
    vm.emitTraffic('/api/a');
    await waitUntil(() => connection.traffic.length == 1);

    await connection.clearTraffic();
    expect(connection.traffic, isEmpty);
    expect(vm.traffic, isEmpty);

    // The cursor survives the clear; later entries are still fetched.
    vm.emitTraffic('/api/c');
    await waitUntil(() => connection.traffic.length == 1);
    expect(connection.traffic.single['path'], '/api/c');
  });

  test('capture is unavailable on apps without traffic extensions', () async {
    vm.captureAvailable = false;
    await connection.connect(vm.address);
    expect(connection.ready, isTrue);
    expect(connection.captureAvailable, isFalse);

    connection.setCaptureLive(true);
    vm.emitTraffic('/api/a');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(connection.traffic, isEmpty);
    expect(vm.traffic, hasLength(1));
  });
}
