import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_desktop/src/mock_connection.dart';
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
