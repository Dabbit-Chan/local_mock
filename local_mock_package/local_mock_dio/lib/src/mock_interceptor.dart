// One source for Dio 4 and Dio 5. `DioError` / `DioErrorType` exist in both
// (Dio 5.2+ keeps them as deprecated typedefs of DioException(Type)), so the
// deprecation is suppressed instead of splitting into per-version packages.
// ignore_for_file: deprecated_member_use

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:local_mock_core/local_mock_core.dart';

/// `DioErrorType.response` (Dio 4) was renamed to `badResponse` (Dio 5).
/// Look it up by name so the same code compiles against both.
final DioErrorType _badResponseType = DioErrorType.values.firstWhere(
  (type) => type.name == 'badResponse' || type.name == 'response',
);

/// Serves matching requests from local_mock rules; others go to the network.
///
/// Add it after interceptors that change the request URL / method. Prefer
/// [LocalMockDio.attach], which also registers the VM Service extensions.
final class LocalMockInterceptor extends Interceptor {
  LocalMockInterceptor() {
    LocalMock.ensureInitialized();
  }

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final rule = LocalMock.match(options.method, options.uri);
    if (rule == null) {
      handler.next(options);
      return;
    }
    try {
      if (options.responseType != ResponseType.json) {
        throw DioError(
          requestOptions: options,
          error: 'local_mock_dio only supports ResponseType.json',
        );
      }
      final token = options.cancelToken;
      if (token?.isCancelled == true) throw token!.cancelError!;
      if (rule.delayMs > 0) {
        final delay = Future<void>.delayed(
          Duration(milliseconds: rule.delayMs),
        );
        await (token == null
            ? delay
            : Future.any<void>([delay, token.whenCancel.then<void>((_) {})]));
      }
      if (token?.isCancelled == true) throw token!.cancelError!;
      final response = Response<dynamic>(
        requestOptions: options,
        statusCode: rule.statusCode,
        data: rule.bodyCopy,
        headers: Headers.fromMap({
          for (final entry in rule.responseHeaders.entries)
            entry.key: [entry.value],
        }),
        extra: {'local_mock': true, 'local_mock_rule_id': rule.id},
      );
      if (!options.validateStatus(rule.statusCode)) {
        if (!options.receiveDataWhenStatusError) response.data = null;
        // Same shape Dio uses for real HTTP error responses.
        handler.reject(
          DioError(
            requestOptions: options,
            response: response,
            type: _badResponseType,
            error: 'Http status error [${rule.statusCode}]',
          ),
          true,
        );
        return;
      }
      // Keep the app's response interceptors (e.g. business deserialization).
      handler.resolve(response, true);
    } catch (error) {
      handler.reject(
        error is DioError
            ? error
            : DioError(requestOptions: options, error: error),
        true,
      );
    }
  }
}

/// Debug-only attachment for Dio 4.x and 5.x instances.
abstract final class LocalMockDio {
  /// Returns false outside Debug mode, true when attached (or already
  /// attached). Attach after request interceptors that modify URL / method.
  static bool attach(Dio dio) {
    if (!LocalMock.ensureInitialized()) return false;
    if (!dio.interceptors.any((item) => item is LocalMockInterceptor)) {
      dio.interceptors.add(LocalMockInterceptor());
    }
    return true;
  }
}
