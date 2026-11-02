import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_http/local_mock_http.dart';
import 'package:local_mock_client/src/mock_connection.dart';
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
    'records real requests, reloads a session and replays without backend calls',
    () async {
      final previous = HttpOverrides.current;
      final relay = LocalMockRelay();
      await relay.start(port: 0);
      final backend = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var backendCalls = 0;
      backend.listen((request) async {
        backendCalls++;
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'step': backendCalls}));
        await request.response.close();
      });
      final connection = MockConnection();
      HttpClient? client;
      addTearDown(() async {
        client?.close(force: true);
        connection.dispose();
        LocalMock.disconnect();
        LocalMock.debugClear();
        LocalMock.debugClearTraffic();
        HttpOverrides.global = previous;
        await backend.close(force: true);
        await relay.close();
      });
      final address = 'http://127.0.0.1:${relay.port}';
      await connection.connect(address);
      LocalMockHttp.install();
      LocalMock.connect(serverUrl: address, deviceId: 'record-and-replay');
      await waitUntil(() => connection.ready);
      client = HttpClient();
      final uri = Uri.parse('http://127.0.0.1:${backend.port}/workflow?id=1');
      Future<dynamic> send() async {
        final response = await (await client!.getUrl(uri)).close();
        return jsonDecode(await utf8.decodeStream(response));
      }

      connection.startRecording('真实流程');
      expect(await send(), {'step': 1});
      expect(await send(), {'step': 2});
      await waitUntil(() => connection.recordedCount == 2);
      final recorded = connection.stopRecording();
      final restored = TrafficSession.fromJson(
        jsonDecode(jsonEncode(recorded.toJson())),
      );
      final group = recordingMockFromSession(
        restored,
        matchParams: true,
      ).toJson();
      await connection.apply(jsonEncode([group]));
      for (final step in [2, 2, 2]) {
        expect(await send(), {'step': step});
      }
      expect(backendCalls, 2);
      expect(LocalMock.debugTrafficEntries().last.mocked, isTrue);
      final child = (group['rules'] as List).single as Map<String, dynamic>;
      final edited = {
        ...group,
        'rules': [
          {
            ...child,
            'body': {'step': 'edited'},
            'responseText': '{"step":"edited"}',
          },
        ],
      };
      await connection.apply(jsonEncode([edited]));
      expect(await send(), {'step': 'edited'});
      await connection.apply(
        jsonEncode([
          {...edited, 'enabled': false},
        ]),
      );
      expect(await send(), {'step': 3});
      expect(backendCalls, 3);
    },
  );

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
