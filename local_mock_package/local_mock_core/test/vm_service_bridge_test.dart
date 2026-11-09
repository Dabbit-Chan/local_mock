import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_core/local_mock_core.dart';
import 'package:local_mock_core/src/vm_service_bridge_io.dart';

// Run with flutter test --enable-vmservice. These are real VM Service RPCs,
// not in-process calls to LocalMock's test-only rule setters.
void main() {
  late VmServiceBridge bridge;
  late List<Map<String, dynamic>> events;

  setUp(() {
    LocalMock.ensureInitialized();
    LocalMock.debugClear();
    LocalMock.debugClearTraffic();
    events = [];
    bridge = VmServiceBridge(onTraffic: events.add, onDisconnected: () {});
  });
  tearDown(() async {
    await bridge.close();
    LocalMock.debugClear();
    LocalMock.debugClearTraffic();
  });

  test(
    'real service extensions acknowledge rules and preserve them after invalid edits',
    () async {
      final state = await bridge.command('getState', {});
      expect(state['supportsRecordingMocks'], isTrue);
      expect(state['rules'], isEmpty);
      await bridge.command('replaceRules', {
        'rules': [
          {
            'id': 'value',
            'method': 'GET',
            'path': '/value',
            'body': {'source': 'vm'},
          },
        ],
      });
      final uri = Uri.parse('https://api.test/value');
      expect(LocalMock.match('GET', uri)!.body, {'source': 'vm'});
      await expectLater(
        bridge.command('replaceRules', {
          'rules': [
            {'id': 'invalid', 'method': 'GET', 'path': 'missing-slash'},
          ],
        }),
        throwsA(isA<Exception>()),
      );
      expect(LocalMock.match('GET', uri)!.body, {'source': 'vm'});
      await bridge.command('clear', {});
      expect(LocalMock.match('GET', uri), isNull);
    },
  );

  test(
    'traffic arrives via Extension events and snapshots backfill without changing cursors',
    () async {
      LocalMock.beginTraffic(
        'GET',
        Uri.parse('https://api.test/before'),
      )!.finish(statusCode: 200, body: 'before');
      final initial = await bridge.command('getState', {});
      expect((initial['entries'] as List).single['path'], '/before');
      final received = Completer<void>();
      final live = VmServiceBridge(
        onTraffic: (entry) {
          events.add(entry);
          if (!received.isCompleted) received.complete();
        },
        onDisconnected: () {},
      );
      addTearDown(live.close);
      await live.command('getState', {});
      developer.postEvent('unrelated.event', {
        'entry': {'path': '/ignore'},
      });
      LocalMock.beginTraffic(
        'POST',
        Uri.parse('https://api.test/live'),
      )!.finish(statusCode: 201, mocked: true, body: '{"ok":true}');
      await received.future.timeout(const Duration(seconds: 3));
      expect(events.every((entry) => entry['path'] == '/live'), isTrue);
      final snapshot = await bridge.command('getState', {});
      expect((snapshot['entries'] as List).map((entry) => entry['path']), [
        '/before',
        '/live',
      ]);
      final cursor = snapshot['trafficRevision'];
      await bridge.command('clearTraffic', {});
      expect(LocalMock.debugTrafficEntries(), isEmpty);
      expect((await bridge.command('getState', {}))['trafficRevision'], cursor);
    },
  );

  test('closing and recreating the bridge preserves the App state', () async {
    await bridge.command('replaceRules', {
      'rules': [
        {'id': 'kept', 'method': 'GET', 'path': '/kept'},
      ],
    });
    await bridge.close();
    await expectLater(bridge.command('getState', {}), throwsStateError);
    bridge = VmServiceBridge(onTraffic: events.add, onDisconnected: () {});
    expect(
      ((await bridge.command('getState', {}))['rules'] as List).single['id'],
      'kept',
    );
  });
}
