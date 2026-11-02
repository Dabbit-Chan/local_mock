import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_http/local_mock_http.dart';
import 'package:local_mock_http/src/http_overrides.dart';

void main() {
  late HttpServer server;
  late HttpClient client;
  late Uri uri;
  var networkCalls = 0;

  setUp(() async {
    LocalMock.ensureInitialized();
    networkCalls = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    uri = Uri.parse('http://127.0.0.1:${server.port}/value?id=1');
    server.listen((request) async {
      networkCalls++;
      await request.drain<void>();
      request.response.write('network');
      await request.response.close();
    });
    client = HttpOverrides.runWithHttpOverrides(
      HttpClient.new,
      LocalMockHttpOverrides(),
    );
    LocalMock.debugReplaceRules([
      recordingMockFromSession(
        TrafficSession(
          id: 'http-replay',
          name: '文本回放',
          deviceId: 'device',
          deviceName: '设备',
          startedAt: 1,
          endedAt: 3,
          entries: [
            for (final revision in [1, 2])
              TrafficEntry(
                revision: revision,
                startedAt: revision,
                durationMs: 0,
                mocked: false,
                method: 'POST',
                uri: uri.toString(),
                path: uri.path,
                requestBody: '{"id":1,"name":"你好"}',
                statusCode: 202,
                contentType: 'text/plain; charset=utf-8',
                responseBody: '响应 $revision\n你好',
              ),
          ],
        ),
        matchParams: true,
      ).toJson(),
    ]);
  });

  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    LocalMock.debugClear();
    LocalMock.debugClearTraffic();
  });

  Future<(int, String, String?)> send(String body, {Uri? target}) async {
    final request = await client.postUrl(target ?? uri);
    request.add(utf8.encode(body));
    final response = await request.close();
    return (
      response.statusCode,
      await utf8.decodeStream(response),
      response.headers.contentType?.mimeType,
    );
  }

  test(
    'HTTP replay matches body on close and preserves text bytes, status and content type',
    () async {
      expect(await send('{"name":"你好","id":1}'), (
        202,
        '响应 2\n你好',
        'text/plain',
      ));
      expect(await send('{"id":1,"name":"你好"}'), (
        202,
        '响应 2\n你好',
        'text/plain',
      ));
      expect(await send('{"id":1,"name":"你好"}'), (
        202,
        '响应 2\n你好',
        'text/plain',
      ));
      expect(networkCalls, 0);
      final traffic = LocalMock.debugTrafficEntries();
      expect(traffic.every((entry) => entry.mocked), isTrue);
      expect(traffic.first.responseBody, '响应 2\n你好');
    },
  );

  test(
    'unmatched request bodies and query values still use the real network',
    () async {
      expect((await send('{"id":2}')).$2, 'network');
      expect(
        (await send(
          '{"id":1,"name":"你好"}',
          target: uri.replace(query: 'id=2'),
        )).$2,
        'network',
      );
      expect(networkCalls, 2);
      expect((await send('{"id":1,"name":"你好"}')).$2, '响应 2\n你好');
    },
  );
}
