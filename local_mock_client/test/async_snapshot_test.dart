import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_transport/local_mock_transport.dart';

import '../tool/relay_host.dart';

Future<void> waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for async snapshot');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late LocalMockRelay relay;
  LocalMockAgent? agent;
  RelayPeer? console;
  late String address;

  setUp(() async {
    relay = LocalMockRelay();
    await relay.start(port: 0);
    address = 'http://127.0.0.1:${relay.port}';
  });
  tearDown(() async {
    agent?.stop();
    console?.close();
    await relay.close();
  });

  test(
    'initial async VM snapshot completes before the device is advertised',
    () async {
      final initial = Completer<Map<String, dynamic>>();
      final events = <Map<String, dynamic>>[];
      console = await RelayPeer.connect(
        relayUri(address, 'console'),
        hello: {},
        onEvent: events.add,
      );
      var snapshots = 0;
      agent = LocalMockAgent(
        serverUrl: address,
        deviceId: 'async',
        deviceName: 'Async',
        snapshot: () async =>
            ++snapshots == 1 ? initial.future : {'rules': [], 'entries': []},
        onCommand: (_, _) => {'rules': []},
      )..start();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(agent!.connected, isFalse);
      expect(
        events.any(
          (e) => e['event'] == 'devices' && (e['devices'] as List).isNotEmpty,
        ),
        isFalse,
      );
      initial.complete({'rules': [], 'entries': []});
      await waitUntil(() => agent!.connected && snapshots == 2);
      await waitUntil(
        () => events.any(
          (e) => e['event'] == 'devices' && (e['devices'] as List).isNotEmpty,
        ),
      );
    },
  );

  test(
    'a failed post-handshake snapshot closes the socket and retries cleanly',
    () async {
      var snapshots = 0;
      final offline = Completer<void>();
      final online = Completer<void>();
      console = await RelayPeer.connect(
        relayUri(address, 'console'),
        hello: {},
        onEvent: (event) {
          for (final device in event['devices'] as List? ?? []) {
            if (device['id'] != 'retry') continue;
            if (device['online'] == true &&
                snapshots >= 3 &&
                !online.isCompleted) {
              online.complete();
            }
            if (device['online'] == false && !offline.isCompleted) {
              offline.complete();
            }
          }
        },
      );
      agent = LocalMockAgent(
        serverUrl: address,
        deviceId: 'retry',
        deviceName: 'Retry',
        reconnectDelay: const Duration(milliseconds: 30),
        snapshot: () async {
          if (++snapshots == 2) {
            throw StateError('VM Service disconnected during backfill');
          }
          return {'rules': [], 'entries': []};
        },
        onCommand: (_, _) => {'rules': []},
      )..start();
      await Future.wait([
        offline.future,
        online.future,
      ]).timeout(const Duration(seconds: 5));
      expect(agent!.connected, isTrue);
      expect(snapshots, greaterThanOrEqualTo(3));
    },
  );

  test(
    'stopping during a VM snapshot never opens a late Relay connection',
    () async {
      final pending = Completer<Map<String, dynamic>>();
      agent = LocalMockAgent(
        serverUrl: address,
        deviceId: 'stopped',
        deviceName: 'Stopped',
        snapshot: () => pending.future,
        onCommand: (_, _) => {'rules': []},
      )..start();
      agent!.stop();
      pending.complete({'rules': [], 'entries': []});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      console = await RelayPeer.connect(
        relayUri(address, 'console'),
        hello: {},
      );
      expect(console!.helloResult['devices'], isEmpty);
      expect(agent!.connected, isFalse);
    },
  );
}
