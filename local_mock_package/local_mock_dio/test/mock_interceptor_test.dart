// Runs against both Dio 4 and Dio 5; see README for switching versions.
// ignore_for_file: deprecated_member_use

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_dio/local_mock_dio.dart';

class CountingAdapter implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromString(
      '{"source":"backend"}',
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Dio dio;
  late CountingAdapter adapter;

  void replace({int statusCode = 200, int delayMs = 0, String name = 'mock'}) {
    LocalMock.debugReplaceRules([
      {
        'id': 'profile',
        'method': 'GET',
        'path': '/api/profile',
        'statusCode': statusCode,
        'delayMs': delayMs,
        'body': {'name': name},
      },
    ]);
  }

  setUp(() {
    adapter = CountingAdapter();
    dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
    dio.httpClientAdapter = adapter;
    dio.interceptors.add(LocalMockInterceptor());
  });

  tearDown(() {
    LocalMock.debugClear();
    dio.close(force: true);
  });

  test(
    'matched request skips transport and runs response interceptors',
    () async {
      replace();
      var responseSeen = false;
      dio.interceptors.add(
        InterceptorsWrapper(
          onResponse: (response, handler) {
            responseSeen = true;
            handler.next(response);
          },
        ),
      );
      final response = await dio.get<dynamic>('/api/profile');
      expect(response.data, {'name': 'mock'});
      expect(response.extra['local_mock_rule_id'], 'profile');
      expect(responseSeen, isTrue);
      expect(adapter.calls, 0);
    },
  );

  test('unmatched request uses the existing transport', () async {
    replace();
    final response = await dio.get<dynamic>('/api/other');
    expect(response.data, {'source': 'backend'});
    expect(adapter.calls, 1);
  });

  test(
    'next request uses replacement without reattaching interceptor',
    () async {
      replace(name: 'first');
      expect((await dio.get<dynamic>('/api/profile')).data, {'name': 'first'});
      replace(name: 'second');
      expect((await dio.get<dynamic>('/api/profile')).data, {'name': 'second'});
      expect(adapter.calls, 0);
    },
  );

  test(
    'mutating a response does not mutate subsequent mock responses',
    () async {
      replace();
      final first = await dio.get<dynamic>('/api/profile');
      (first.data as Map)['name'] = 'mutated';
      expect((await dio.get<dynamic>('/api/profile')).data, {'name': 'mock'});
    },
  );

  test(
    'invalid HTTP status becomes a response error and runs error interceptors',
    () async {
      replace(statusCode: 503);
      var errorSeen = false;
      dio.interceptors.add(
        InterceptorsWrapper(
          onError: (error, handler) {
            errorSeen = true;
            handler.next(error);
          },
        ),
      );
      await expectLater(
        dio.get<dynamic>('/api/profile'),
        throwsA(
          isA<DioError>()
              // Dio 4: response, Dio 5: badResponse.
              .having(
                (error) => error.type.name,
                'type',
                anyOf('response', 'badResponse'),
              )
              .having((error) => error.response?.statusCode, 'status', 503),
        ),
      );
      expect(errorSeen, isTrue);
      expect(adapter.calls, 0);
    },
  );

  test('custom validateStatus can accept error HTTP status', () async {
    replace(statusCode: 503);
    final response = await dio.get<dynamic>(
      '/api/profile',
      options: Options(validateStatus: (_) => true),
    );
    expect(response.statusCode, 503);
  });

  test(
    'receiveDataWhenStatusError=false removes error response body',
    () async {
      replace(statusCode: 500);
      await expectLater(
        dio.get<dynamic>(
          '/api/profile',
          options: Options(receiveDataWhenStatusError: false),
        ),
        throwsA(
          isA<DioError>().having(
            (error) => error.response?.data,
            'data',
            isNull,
          ),
        ),
      );
    },
  );

  test('cancel during mock delay does not hit backend', () async {
    replace(delayMs: 1000);
    final token = CancelToken();
    final request = dio.get<dynamic>('/api/profile', cancelToken: token);
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
    await Future<void>.delayed(const Duration(milliseconds: 10));
    token.cancel('test');
    await expectation;
    expect(adapter.calls, 0);
  });

  test(
    'non-JSON matching request fails explicitly, never goes to backend',
    () async {
      replace();
      await expectLater(
        dio.get<dynamic>(
          '/api/profile',
          options: Options(responseType: ResponseType.bytes),
        ),
        throwsA(isA<DioError>()),
      );
      expect(adapter.calls, 0);
    },
  );

  test('clearing rules restores normal requests', () async {
    replace();
    LocalMock.debugClear();
    await dio.get<dynamic>('/api/profile');
    expect(adapter.calls, 1);
  });

  test('public attachment is idempotent for a Dio instance', () {
    final client = Dio();
    expect(LocalMockDio.attach(client), isTrue);
    expect(LocalMockDio.attach(client), isTrue);
    expect(client.interceptors.whereType<LocalMockInterceptor>().length, 1);
    client.close();
  });
}
