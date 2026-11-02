import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_client/src/mock_connection.dart';
import 'package:local_mock_core/local_mock_core.dart';
import 'package:local_mock_transport/local_mock_transport.dart';

Future<void> waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for browser relay');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  const address = String.fromEnvironment('LOCAL_MOCK_TEST_SERVER');
  test(
    'browser applies edits and disables one recording Mock group through the normal rule protocol',
    () async {
      final connection = MockConnection();
      addTearDown(() {
        connection.dispose();
        LocalMock.disconnect();
        LocalMock.debugClear();
      });
      final id = 'group-${DateTime.now().microsecondsSinceEpoch}';
      LocalMock.connect(serverUrl: address, deviceId: id);
      await waitUntil(() => LocalMock.connected);
      await connection.connect(address);
      if (connection.selectedId != id) await connection.selectTarget(id);
      expect(connection.supportsRecordingMocks, isTrue);
      final group = recordingMockFromSession(
        TrafficSession(
          id: 'browser-flow',
          name: '浏览器录制 Mock',
          deviceId: id,
          deviceName: '设备',
          startedAt: 1,
          endedAt: 2,
          entries: [
            TrafficEntry(
              revision: 1,
              startedAt: 1,
              durationMs: 0,
              mocked: false,
              method: 'GET',
              uri: 'https://api.test/order?id=1',
              path: '/order',
              statusCode: 200,
              responseBody: '{"value":1}',
            ),
          ],
        ),
        matchParams: true,
      ).toJson();
      final uri = Uri.parse('https://api.test/order?id=2');
      await connection.apply(jsonEncode([group]));
      expect(LocalMock.match('GET', uri), isNull);
      final child = (group['rules'] as List).single as Map<String, dynamic>;
      final edited = {
        ...group,
        'matchParams': false,
        'rules': [
          {
            ...child,
            'body': {'value': 'edited'},
            'responseText': '{"value":"edited"}',
          },
        ],
      };
      await connection.apply(jsonEncode([edited]));
      expect(LocalMock.match('GET', uri)!.body, {'value': 'edited'});
      connection.disconnect();
      await connection.connect(address);
      if (connection.selectedId != id) await connection.selectTarget(id);
      expect(connection.rules.single, edited);
      await connection.apply(
        jsonEncode([
          {...edited, 'enabled': false},
        ]),
      );
      expect(LocalMock.match('GET', uri), isNull);
    },
    skip: !kIsWeb || address.isEmpty,
  );

  test(
    'browser App and console exchange rules and live traffic through the relay',
    () async {
      final id = 'browser-${DateTime.now().microsecondsSinceEpoch}';
      var rules = <dynamic>[];
      final entries = <Map<String, dynamic>>[];
      final agent = LocalMockAgent(
        serverUrl: address,
        deviceId: id,
        deviceName: 'Browser QA',
        snapshot: () => {'rules': rules, 'entries': entries},
        onCommand: (method, args) {
          if (method == 'replaceRules') rules = List.of(args['rules'] as List);
          if (method == 'clearTraffic') entries.clear();
          return {'rules': rules};
        },
      );
      final connection = MockConnection();
      addTearDown(() {
        agent.stop();
        connection.dispose();
      });
      agent.start();
      await waitUntil(() => agent.connected);
      await connection.connect(address);
      if (connection.selectedId != id) await connection.selectTarget(id);
      await waitUntil(() => connection.ready);
      await connection.apply(
        jsonEncode([
          {
            'id': 'web',
            'method': 'GET',
            'path': '/web',
            'body': {'ok': true},
          },
        ]),
      );
      expect((rules.single as Map)['body'], {'ok': true});
      final entry = <String, dynamic>{
        'revision': 1,
        'method': 'GET',
        'uri': 'https://api.test/web',
        'path': '/web',
        'mocked': true,
        'statusCode': 200,
      };
      entries.add(entry);
      agent.report(entry);
      await waitUntil(() => connection.traffic.length == 1);
      expect(connection.traffic.single['path'], '/web');
      await connection.clearTraffic();
      expect(connection.traffic, isEmpty);
      expect(entries, isEmpty);
      connection.disconnect();
      await connection.connect(address);
      if (connection.selectedId != id) await connection.selectTarget(id);
      expect(connection.rules.single['id'], 'web');
    },
    skip: !kIsWeb || address.isEmpty,
  );
}
