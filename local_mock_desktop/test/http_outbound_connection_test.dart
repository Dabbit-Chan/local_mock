import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_http/local_mock_http.dart';
import '../tool/relay_host.dart';
import 'package:local_mock_transport/local_mock_transport.dart';

Future<void> waitUntil(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('Timed out waiting for outbound SDK');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test(
    'global HttpOverrides allows outbound WebSocket and reports only business traffic',
    () async {
      final previous = HttpOverrides.current;
      final server = LocalMockRelay();
      await server.start(port: 0);
      RelayPeer? console;
      HttpClient? client;
      final events = <Map<String, dynamic>>[];
      addTearDown(() async {
        client?.close(force: true);
        LocalMock.disconnect();
        LocalMock.debugClear();
        LocalMock.debugClearTraffic();
        HttpOverrides.global = previous;
        console?.close();
        await server.close();
      });
      LocalMockHttp.install();
      final address = 'http://127.0.0.1:${server.port}';
      LocalMock.connect(serverUrl: address, deviceId: 'http-app');
      await waitUntil(() => LocalMock.connected);
      console = await RelayPeer.connect(
        relayUri(address, 'console'),
        hello: const {},
        onEvent: events.add,
      );
      await console.request('command', {
        'deviceId': 'http-app',
        'method': 'replaceRules',
        'args': {
          'rules': [
            {
              'id': 'hello',
              'method': 'GET',
              'path': '/hello',
              'body': {'source': 'mock'},
            },
          ],
        },
      });
      // The test console's own handshake is not the SDK control connection.
      LocalMock.debugClearTraffic();
      client = HttpClient();
      final request = await client.getUrl(Uri.parse('https://api.test/hello'));
      final response = await request.close();
      expect(jsonDecode(await utf8.decoder.bind(response).join()), {
        'source': 'mock',
      });
      await waitUntil(
        () => events.any(
          (e) =>
              e['event'] == 'traffic' &&
              (e['entries'] as List).any((entry) => entry['path'] == '/hello'),
        ),
      );
      expect(LocalMock.debugTrafficEntries(), hasLength(1));
      expect(LocalMock.debugTrafficEntries().single.mocked, isTrue);
      expect(LocalMock.debugTrafficEntries().single.path, '/hello');
    },
  );
}
