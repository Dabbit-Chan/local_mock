import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:local_mock_http/local_mock_http.dart';
import 'package:local_mock_http/src/http_overrides.dart';

void main() {
  late HttpServer server;
  late Uri base;
  var backendCalls = 0;

  void replace({
    String method = 'GET',
    int statusCode = 200,
    int delayMs = 0,
    String name = 'mock',
    Map<String, String> headers = const {},
  }) {
    LocalMock.debugReplaceRules([
      {
        'id': 'profile',
        'method': method,
        'path': '/api/profile',
        'statusCode': statusCode,
        'delayMs': delayMs,
        'headers': headers,
        'body': {'name': name},
      },
    ]);
  }

  /// Creates the client inside the override scope, like an app after install.
  HttpClient createClient([HttpOverrides? previous]) =>
      HttpOverrides.runWithHttpOverrides(
        HttpClient.new,
        LocalMockHttpOverrides(previous),
      );

  Future<(int, String, HttpHeaders)> send(
    HttpClient client,
    String method,
    String path, {
    String? body,
  }) async {
    final request = await client.openUrl(method, base.resolve(path));
    if (body != null) request.write(body);
    final response = await request.close();
    return (
      response.statusCode,
      await utf8.decodeStream(response),
      response.headers,
    );
  }

  setUpAll(() async {
    LocalMock.ensureInitialized();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://${server.address.host}:${server.port}');
    server.listen((request) async {
      backendCalls++;
      await request.drain<void>();
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"source":"backend"}');
      await request.response.close();
    });
  });

  tearDownAll(() => server.close(force: true));

  setUp(() => backendCalls = 0);
  tearDown(LocalMock.debugClear);

  test('matched request is answered locally with status and headers', () async {
    replace(statusCode: 201, headers: {'X-Debug-Mock': 'true'});
    final client = createClient();
    final (status, body, headers) = await send(client, 'GET', '/api/profile');
    expect(status, 201);
    expect(jsonDecode(body), {'name': 'mock'});
    expect(headers.value('x-debug-mock'), 'true');
    expect(headers.contentType?.mimeType, 'application/json');
    expect(headers.contentLength, utf8.encode(body).length);
    expect(backendCalls, 0);
    client.close();
  });

  test('unmatched request and query-only differences', () async {
    replace();
    final client = createClient();
    expect((await send(client, 'GET', '/api/other')).$2, contains('backend'));
    expect(
      (await send(client, 'POST', '/api/profile')).$2,
      contains('backend'),
    );
    expect(backendCalls, 2);
    expect(
      (await send(client, 'GET', '/api/profile?a=1')).$2,
      contains('mock'),
    );
    expect(backendCalls, 2);
    client.close();
  });

  test('rule updates apply to existing clients', () async {
    final client = createClient();
    replace(name: 'first');
    expect((await send(client, 'GET', '/api/profile')).$2, contains('first'));
    replace(name: 'second');
    expect((await send(client, 'GET', '/api/profile')).$2, contains('second'));
    LocalMock.debugClear();
    expect((await send(client, 'GET', '/api/profile')).$2, contains('backend'));
    client.close();
  });

  test('request body is consumed and discarded', () async {
    replace(method: 'POST');
    final client = createClient();
    final (status, body, _) = await send(
      client,
      'POST',
      '/api/profile',
      body: '{"x":1}',
    );
    expect(status, 200);
    expect(body, contains('mock'));
    expect(backendCalls, 0);
    client.close();
  });

  test('HEAD and 204 have empty bodies', () async {
    final client = createClient();
    replace(method: 'HEAD');
    expect((await send(client, 'HEAD', '/api/profile')).$2, isEmpty);
    replace(statusCode: 204);
    final (status, body, headers) = await send(client, 'GET', '/api/profile');
    expect(status, 204);
    expect(body, isEmpty);
    expect(headers.contentLength, 0);
    client.close();
  });

  test('delay starts at close and can be aborted', () async {
    replace(delayMs: 1000);
    final client = createClient();
    final request = await client.getUrl(base.resolve('/api/profile'));
    final response = request.close();
    final expectation = expectLater(response, throwsA(isA<HttpException>()));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    request.abort();
    await expectation;
    expect(backendCalls, 0);
    client.close();
  });

  test('force close aborts pending mock requests', () async {
    replace(delayMs: 1000);
    final client = createClient();
    final request = await client.getUrl(base.resolve('/api/profile'));
    final expectation = expectLater(request.close(), throwsA(anything));
    client.close(force: true);
    await expectation;
  });

  test('receive timeout fires like a slow server', () async {
    replace(delayMs: 1000);
    final client = createClient();
    final request = await client.getUrl(base.resolve('/api/profile'));
    await expectLater(
      request.close().timeout(const Duration(milliseconds: 20)),
      throwsA(isA<TimeoutException>()),
    );
    request.abort();
    client.close();
  });

  test('works through package:http IOClient', () async {
    replace(statusCode: 503);
    final client = IOClient(createClient());
    final response = await client.get(base.resolve('/api/profile'));
    expect(response.statusCode, 503);
    expect(response.reasonPhrase, 'Service Unavailable');
    expect(jsonDecode(response.body), {'name': 'mock'});
    expect(backendCalls, 0);
    final unmatched = await client.get(base.resolve('/api/other'));
    expect(unmatched.body, contains('backend'));
    client.close();
  });

  test('previous overrides keep handling unmatched requests', () async {
    var previousUsed = 0;
    final previous = _CountingOverrides(() => previousUsed++);
    final client = createClient(previous);
    expect(previousUsed, 1);
    replace();
    expect((await send(client, 'GET', '/api/other')).$2, contains('backend'));
    client.close();
  });

  test('install is idempotent and chains the current overrides', () {
    final original = HttpOverrides.current;
    addTearDown(() => HttpOverrides.global = original);
    final previous = _CountingOverrides(() {});
    HttpOverrides.global = previous;
    expect(LocalMockHttp.install(), isTrue);
    final installed = HttpOverrides.current;
    expect(installed, isA<LocalMockHttpOverrides>());
    expect((installed! as LocalMockHttpOverrides).previous, same(previous));
    expect(LocalMockHttp.install(), isTrue);
    expect(HttpOverrides.current, same(installed));
  });

  test('package:http top-level functions use installed overrides', () async {
    final original = HttpOverrides.current;
    addTearDown(() => HttpOverrides.global = original);
    LocalMockHttp.install();
    replace();
    final response = await http.get(base.resolve('/api/profile'));
    expect(jsonDecode(response.body), {'name': 'mock'});
    expect(backendCalls, 0);
  });
}

final class _CountingOverrides extends HttpOverrides {
  _CountingOverrides(this.onCreate);

  final void Function() onCreate;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    onCreate();
    return super.createHttpClient(context);
  }
}
