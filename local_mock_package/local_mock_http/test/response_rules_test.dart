import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:local_mock_http/local_mock_http.dart';
import 'package:local_mock_http/src/http_overrides.dart';

void main() {
  late HttpServer server;
  late Uri base;
  late HttpClient client;
  final requests = <Map<String, dynamic>>[];

  void replace({
    String method = 'GET',
    String path = '/api/order',
    Map<String, dynamic>? params,
    Map<String, dynamic>? patchBody,
    int delayMs = 0,
  }) => LocalMock.debugReplaceRules([
    {
      'id': 'order',
      'method': method,
      'path': path,
      'statusCode': 202,
      'delayMs': delayMs,
      'body': {'source': 'mock'},
      if (params != null) 'params': params,
      if (patchBody != null) 'patchBody': patchBody,
    },
  ]);

  Future<(HttpClientResponse, String)> send(
    String path, {
    String method = 'GET',
    String? body,
  }) async {
    final request = await client.openUrl(method, base.resolve(path));
    if (body != null) request.write(body);
    final response = await request.close();
    return (response, await utf8.decodeStream(response));
  }

  setUpAll(() async {
    LocalMock.ensureInitialized();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://${server.address.host}:${server.port}');
    server.listen((request) async {
      final body = await utf8.decodeStream(request);
      requests.add({
        'uri': request.uri.toString(),
        'body': body,
        'method': request.method,
        'debug': request.headers.value('x-debug'),
        'cookie': request.headers.value(HttpHeaders.cookieHeader),
      });
      final id = request.uri.queryParameters['id'] ?? 'unknown';
      final text = jsonEncode({
        'code': 0,
        'data': {
          'id': id,
          'status': id == '1' ? 'PAID' : 'SHIPPED',
          'product': {'sku': 'backend-$id'},
        },
      });
      request.response
        ..statusCode = request.uri.path == '/api/error' ? 503 : 201
        ..headers.contentType = ContentType.json
        ..headers.set('x-backend', 'true')
        ..headers.set(HttpHeaders.etagHeader, 'original')
        ..headers.set('content-md5', 'original');
      if (request.uri.path == '/api/plain') {
        request.response
          ..headers.contentType = ContentType.text
          ..write('plain text');
      } else if (request.uri.path == '/api/malformed') {
        request.response.write('{"invalid":');
      } else if (request.uri.path == '/api/compressed') {
        request.response
          ..headers.set(HttpHeaders.contentEncodingHeader, 'gzip')
          ..add(gzip.encode(utf8.encode(text)));
      } else {
        request.response.write(text);
      }
      await request.response.close();
    });
  });

  tearDownAll(() => server.close(force: true));

  setUp(() {
    requests.clear();
    client = HttpOverrides.runWithHttpOverrides(
      HttpClient.new,
      LocalMockHttpOverrides(),
    );
  });

  tearDown(() {
    client.close(force: true);
    LocalMock.debugClear();
    LocalMock.debugClearTraffic();
  });

  test(
    'query params isolate one id, including open(host, port, path)',
    () async {
      replace(params: {'id': 2});
      final (_, first) = await send('/api/order?id=1');
      final request = await client.get(base.host, base.port, '/api/order?id=2');
      final selected = await request.close();
      expect(jsonDecode(first)['data']['product']['sku'], 'backend-1');
      expect(jsonDecode(await utf8.decodeStream(selected)), {'source': 'mock'});
      expect(selected.statusCode, 202);
      await send('/api/order');
      expect(requests, hasLength(2));
      expect(LocalMock.debugTrafficEntries().map((entry) => entry.mocked), [
        false,
        true,
        false,
      ]);
    },
  );

  test(
    'body params select JSON and encoded forms before any network call',
    () async {
      replace(method: 'POST', params: {'id': 2});
      for (final body in ['{"id":2}', 'id=2&other=value']) {
        final (response, text) = await send(
          '/api/order',
          method: 'POST',
          body: body,
        );
        expect(response.statusCode, 202);
        expect(jsonDecode(text), {'source': 'mock'});
      }
      expect(requests, isEmpty);
      final body = '{"id":1,"name":"测试"}';
      final bytes = utf8.encode(body);
      final request = await client.postUrl(base.resolve('/api/order'));
      request
        ..headers.contentType = ContentType.json
        ..headers.set('x-debug', 'kept')
        ..cookies.add(Cookie('session', 'test'))
        ..contentLength = bytes.length;
      await request.addStream(
        Stream.fromIterable([bytes.sublist(0, 10), bytes.sublist(10)]),
      );
      await (await request.close()).drain<void>();
      expect(requests.single['body'], body);
      expect(requests.single['debug'], 'kept');
      expect(requests.single['cookie'], contains('session=test'));
      expect(LocalMock.debugTrafficEntries().last.mocked, isFalse);
      expect(LocalMock.debugTrafficEntries().last.requestBody, body);
    },
  );

  test(
    'patch preserves per-order fields, status, headers and actual byte length',
    () async {
      replace(
        patchBody: {
          'data.product': {'sku': '固定商品'},
        },
      );
      for (final id in [1, 2]) {
        final (response, body) = await send('/api/order?id=$id');
        expect(jsonDecode(body)['data'], {
          'id': '$id',
          'status': id == 1 ? 'PAID' : 'SHIPPED',
          'product': {'sku': '固定商品'},
        });
        expect(response.statusCode, 201);
        expect(response.headers.value('x-backend'), 'true');
        expect(response.headers.value(HttpHeaders.etagHeader), isNull);
        expect(response.headers.value('content-md5'), isNull);
        expect(response.contentLength, utf8.encode(body).length);
        expect(response.headers.contentLength, response.contentLength);
      }
      expect(requests, hasLength(2));
      for (final entry in LocalMock.debugTrafficEntries()) {
        expect(entry.mocked, isTrue);
        expect(entry.statusCode, 201);
        expect(jsonDecode(entry.responseBody!)['data']['product'], {
          'sku': '固定商品',
        });
      }
    },
  );

  test('params and patch combine through package:http IOClient', () async {
    replace(params: {'id': 2}, patchBody: {'data.product.sku': 'fixed'});
    final http = IOClient(client);
    final first = await http.get(base.resolve('/api/order?id=1'));
    final selected = await http.get(base.resolve('/api/order?id=2'));
    expect(jsonDecode(first.body)['data']['product']['sku'], 'backend-1');
    expect(jsonDecode(selected.body)['data']['product']['sku'], 'fixed');
    expect(selected.statusCode, 201);
    expect(requests, hasLength(2));
    expect(LocalMock.debugTrafficEntries().map((entry) => entry.mocked), [
      false,
      true,
    ]);
  });

  test('body params and patch forward the unchanged request body', () async {
    replace(
      method: 'POST',
      params: {'id': 2},
      patchBody: {'data.product.sku': 'fixed'},
    );
    final (_, body) = await send(
      '/api/order',
      method: 'POST',
      body: '{"id":2}',
    );
    expect(jsonDecode(body)['data']['product']['sku'], 'fixed');
    expect(requests.single['body'], '{"id":2}');
    expect(LocalMock.debugTrafficEntries().single.mocked, isTrue);
  });

  test(
    'patches retain backend error status instead of the rule status',
    () async {
      replace(path: '/api/error', patchBody: {'data.product.sku': 'fixed'});
      final (response, body) = await send('/api/error');
      expect(response.statusCode, 503);
      expect(jsonDecode(body)['data']['product']['sku'], 'fixed');
    },
  );

  test(
    'non-JSON, invalid JSON and unavailable parents pass through unchanged',
    () async {
      for (final path in ['/api/plain', '/api/malformed', '/api/order']) {
        replace(path: path, patchBody: {'missing.product': 'fixed'});
        final (response, body) = await send(path);
        expect(response.statusCode, 201);
        expect(response.headers.value(HttpHeaders.etagHeader), 'original');
        if (path == '/api/plain') expect(body, 'plain text');
        if (path == '/api/malformed') expect(body, '{"invalid":');
        if (path == '/api/order') {
          expect(jsonDecode(body)['data']['product']['sku'], 'backend-unknown');
        }
        expect(LocalMock.debugTrafficEntries().last.mocked, isFalse);
      }
    },
  );

  test(
    'decompressed responses receive consistent uncompressed headers',
    () async {
      replace(
        path: '/api/compressed',
        patchBody: {'data.product.sku': 'fixed'},
      );
      final (response, body) = await send('/api/compressed');
      expect(jsonDecode(body)['data']['product']['sku'], 'fixed');
      expect(response.headers.value(HttpHeaders.contentEncodingHeader), isNull);
      expect(
        response.compressionState,
        HttpClientResponseCompressionState.notCompressed,
      );
      expect(response.contentLength, utf8.encode(body).length);
    },
  );

  test(
    'abort during patch delay fails once and does not synthesize a response',
    () async {
      replace(patchBody: {'data.product.sku': 'fixed'}, delayMs: 1000);
      final request = await client.getUrl(base.resolve('/api/order'));
      final expectation = expectLater(
        request.close(),
        throwsA(isA<HttpException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      request.abort();
      await expectation;
      expect(requests, hasLength(1));
      expect(LocalMock.debugTrafficEntries(), hasLength(1));
      expect(LocalMock.debugTrafficEntries().single.error, contains('aborted'));
    },
  );
}
