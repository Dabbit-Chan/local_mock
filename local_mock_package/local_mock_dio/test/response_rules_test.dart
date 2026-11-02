// ignore_for_file: deprecated_member_use

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_dio/local_mock_dio.dart';

class _OrderAdapter implements HttpClientAdapter {
  int calls = 0;
  int statusCode = 201;
  String? rawBody;
  String contentType = 'application/json';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    calls++;
    final id = options.uri.queryParameters['id'] ?? 'unknown';
    final body =
        rawBody ??
        jsonEncode({
          'code': 0,
          'data': {
            'id': id,
            'status': id == '1' ? 'PAID' : 'SHIPPED',
            'product': {'sku': 'backend-$id'},
          },
        });
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: [contentType],
        'content-length': ['${utf8.encode(body).length}'],
        'etag': ['original'],
        'x-backend': ['true'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Dio dio;
  late _OrderAdapter adapter;

  void replace({
    String method = 'GET',
    Map<String, dynamic>? params,
    Map<String, dynamic>? patchBody,
    int delayMs = 0,
  }) => LocalMock.debugReplaceRules([
    {
      'id': 'order',
      'method': method,
      'path': '/api/order',
      'statusCode': 202,
      'delayMs': delayMs,
      'body': {'source': 'mock'},
      if (params != null) 'params': params,
      if (patchBody != null) 'patchBody': patchBody,
    },
  ]);

  setUp(() {
    adapter = _OrderAdapter();
    dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
      ..httpClientAdapter = adapter;
    LocalMockDio.attach(dio);
  });

  tearDown(() {
    LocalMock.debugClear();
    LocalMock.debugClearTraffic();
    dio.close(force: true);
  });

  test(
    'a recording Mock group returns stable edited responses through Dio alongside manual rules',
    () async {
      final group = recordingMockFromSession(
        TrafficSession(
          id: 'dio-replay',
          name: 'Dio 流程',
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
                uri: 'https://api.test/api/order?id=1',
                path: '/api/order',
                requestBody: '{"id":1}',
                statusCode: 201,
                contentType: 'application/json; charset=utf-8',
                responseBody: '{"step":$revision}',
              ),
          ],
        ),
        matchParams: true,
      );
      LocalMock.debugReplaceRules([
        group.toJson(),
        {
          'id': 'manual',
          'method': 'GET',
          'path': '/api/order',
          'body': {'source': 'mock'},
        },
      ]);
      for (final step in [2, 2, 2]) {
        final response = await dio.post<dynamic>(
          '/api/order?id=1',
          data: {'id': 1},
        );
        expect(response.statusCode, 201);
        expect(response.data, {'step': step});
        expect(response.extra['local_mock'], isTrue);
      }
      expect(adapter.calls, 0);
      final unmatched = await dio.post<dynamic>(
        '/api/order?id=2',
        data: {'id': 2},
      );
      expect(unmatched.data['data']['id'], '2');
      expect(adapter.calls, 1);
      final manual = await dio.get<dynamic>('/api/order');
      expect(manual.data, {'source': 'mock'});
      expect(LocalMock.debugTrafficEntries().first.responseBody, '{"step":2}');
    },
  );

  test(
    'only the chosen query id is replaced; others reach the backend',
    () async {
      replace(params: {'id': 2});
      final first = await dio.get<dynamic>(
        '/api/order',
        queryParameters: {'id': 1},
      );
      final selected = await dio.get<dynamic>(
        '/api/order',
        queryParameters: {'id': 2, 'page': 10},
      );
      final missing = await dio.get<dynamic>('/api/order');
      expect(first.data['data']['product'], {'sku': 'backend-1'});
      expect(selected.data, {'source': 'mock'});
      expect(selected.statusCode, 202);
      expect(missing.data['data']['id'], 'unknown');
      expect(adapter.calls, 2);
      expect(LocalMock.debugTrafficEntries().map((entry) => entry.mocked), [
        false,
        true,
        false,
      ]);
    },
  );

  test(
    'body matching supports JSON, form maps, form strings and FormData',
    () async {
      replace(method: 'POST', params: {'id': 2});
      for (final body in <dynamic>[
        {'id': 2, 'other': 'value'},
        '{"id":2}',
        'id=2&other=value',
        FormData.fromMap({'id': 2}),
      ]) {
        final response = await dio.post<dynamic>('/api/order', data: body);
        expect(response.data, {'source': 'mock'});
      }
      await dio.post<dynamic>('/api/order', data: {'id': 1});
      expect(adapter.calls, 1);
      expect(
        LocalMock.debugTrafficEntries().first.requestBody,
        contains('"id":2'),
      );
    },
  );

  test(
    'patch fixes products but preserves each order status and HTTP metadata',
    () async {
      replace(
        patchBody: {
          'data.product': {'sku': 'fixed'},
        },
      );
      final observed = <dynamic>[];
      dio.interceptors.add(
        InterceptorsWrapper(
          onResponse: (response, handler) {
            observed.add(response.data['data']['product']);
            handler.next(response);
          },
        ),
      );
      for (final id in [1, 2]) {
        final response = await dio.get<dynamic>(
          '/api/order',
          queryParameters: {'id': id},
        );
        expect(response.data['data'], {
          'id': '$id',
          'status': id == 1 ? 'PAID' : 'SHIPPED',
          'product': {'sku': 'fixed'},
        });
        expect(response.statusCode, 201);
        expect(response.headers.value('x-backend'), 'true');
        expect(response.headers.value('content-length'), isNull);
        expect(response.headers.value('etag'), isNull);
        expect(response.extra['local_mock_rule_id'], 'order');
      }
      expect(adapter.calls, 2);
      expect(observed, [
        {'sku': 'fixed'},
        {'sku': 'fixed'},
      ]);
      for (final entry in LocalMock.debugTrafficEntries()) {
        expect(entry.mocked, isTrue);
        expect(entry.statusCode, 201);
        expect(jsonDecode(entry.responseBody!)['data']['product'], {
          'sku': 'fixed',
        });
      }
    },
  );

  test(
    'wildcard patches every album name only for the matched request',
    () async {
      adapter.rawBody = jsonEncode({
        'data': {
          'sitePhotoAlbumList': [
            {'id': 2334, 'name': '全部'},
            {'id': 2335, 'name': '天然虾青素'},
          ],
        },
      });
      replace(
        params: {'id': 2},
        patchBody: {'data.sitePhotoAlbumList[*].name': '很长很长的相册名'},
      );
      final original = await dio.get<dynamic>('/api/order?id=1');
      final patched = await dio.get<dynamic>('/api/order?id=2');
      expect(original.data['data']['sitePhotoAlbumList'], [
        {'id': 2334, 'name': '全部'},
        {'id': 2335, 'name': '天然虾青素'},
      ]);
      expect(patched.data['data']['sitePhotoAlbumList'], [
        {'id': 2334, 'name': '很长很长的相册名'},
        {'id': 2335, 'name': '很长很长的相册名'},
      ]);
      expect(patched.statusCode, 201);
      expect(patched.extra['local_mock_rule_id'], 'order');
      expect(LocalMock.debugTrafficEntries().map((entry) => entry.mocked), [
        false,
        true,
      ]);
      expect(
        jsonDecode(LocalMock.debugTrafficEntries().last.responseBody!),
        patched.data,
      );
    },
  );

  test(
    'out-of-range patches do not cancel valid indexed or wildcard patches',
    () async {
      adapter.rawBody = jsonEncode({
        'data': {
          'title': 'original',
          'items': [
            {'name': 'first'},
            {'name': 'second'},
          ],
        },
      });
      replace(
        patchBody: {
          'data.title': 'changed',
          'data.items[9].name': 'ignored',
          'data.items[*].name': 'all',
          'data.items[0].name': 'first only',
          'data.items[5]': null,
        },
      );
      final response = await dio.get<dynamic>('/api/order');
      expect(response.data, {
        'data': {
          'title': 'changed',
          'items': [
            {'name': 'first only'},
            {'name': 'all'},
          ],
        },
      });
      expect(response.statusCode, 201);
      expect(response.headers.value('x-backend'), 'true');
      expect(response.headers.value('content-length'), isNull);
      expect(LocalMock.debugTrafficEntries().single.mocked, isTrue);
    },
  );

  test('params and patch combine without changing other ids', () async {
    replace(params: {'id': 2}, patchBody: {'data.product.sku': 'fixed'});
    final first = await dio.get<dynamic>('/api/order?id=1');
    final selected = await dio.get<dynamic>('/api/order?id=2');
    expect(first.data['data']['product']['sku'], 'backend-1');
    expect(selected.data['data']['product']['sku'], 'fixed');
    expect(adapter.calls, 2);
    expect(LocalMock.debugTrafficEntries().map((entry) => entry.mocked), [
      false,
      true,
    ]);
  });

  test(
    'patch preserves HTTP errors while patching their response body',
    () async {
      adapter.statusCode = 503;
      replace(patchBody: {'data.product.sku': 'fixed'});
      await expectLater(
        dio.get<dynamic>('/api/order?id=1'),
        throwsA(
          isA<DioError>()
              .having((error) => error.response?.statusCode, 'statusCode', 503)
              .having(
                (error) => error.response?.data['data']['product']['sku'],
                'patched product',
                'fixed',
              ),
        ),
      );
      expect(LocalMock.debugTrafficEntries().single.mocked, isTrue);
    },
  );

  test('non-JSON bodies and missing parents are returned unchanged', () async {
    replace(patchBody: {'missing.product': 'fixed'});
    final response = await dio.get<dynamic>('/api/order?id=1');
    expect(response.data['data']['product']['sku'], 'backend-1');
    expect(response.extra['local_mock'], isNull);
    expect(LocalMock.debugTrafficEntries().last.mocked, isFalse);
    adapter
      ..rawBody = 'plain text'
      ..contentType = 'text/plain';
    replace(patchBody: {'data.product': 'fixed'});
    expect((await dio.get<dynamic>('/api/order')).data, 'plain text');
    expect(LocalMock.debugTrafficEntries().last.mocked, isFalse);
  });

  test('byte responses are not treated as JSON arrays to patch', () async {
    replace(patchBody: {'0': 0});
    final response = await dio.get<dynamic>(
      '/api/order',
      options: Options(responseType: ResponseType.bytes),
    );
    expect((response.data as List<int>).first, utf8.encode('{').single);
    expect(LocalMock.debugTrafficEntries().single.mocked, isFalse);
  });

  test('cancellation during patch delay stays cancelled', () async {
    replace(patchBody: {'data.product.sku': 'fixed'}, delayMs: 1000);
    final token = CancelToken();
    final request = dio.get<dynamic>('/api/order', cancelToken: token);
    final expectation = expectLater(
      request,
      throwsA(
        isA<DioError>().having(
          (error) => error.type,
          'type',
          DioErrorType.cancel,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    token.cancel('cancel patch');
    await expectation;
    expect(adapter.calls, 1);
    expect(LocalMock.debugTrafficEntries().single.error, isNotNull);
  });
}
