// One source for Dio 4 and Dio 5. `DioError` / `DioErrorType` exist in both
// (Dio 5.2+ keeps them as deprecated typedefs of DioException(Type)), so the
// deprecation is suppressed instead of splitting into per-version packages.
// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:local_mock_core/local_mock_core.dart';

/// `DioErrorType.response` (Dio 4) was renamed to `badResponse` (Dio 5).
/// Look it up by name so the same code compiles against both.
final DioErrorType _badResponseType = DioErrorType.values.firstWhere(
  (type) => type.name == 'badResponse' || type.name == 'response',
);

/// Default content-type recorded for mocked responses.
const _mockContentType = 'application/json; charset=utf-8';

/// Best-effort body text for the capture view; never throws.
String? _describeBody(Object? data) {
  if (data == null) return null;
  if (data is String) return data;
  if (data is List<int>) return '<${data.length} bytes>';
  if (data is FormData) {
    return '<FormData: ${data.fields.length} fields, ${data.files.length} files>';
  }
  try {
    return jsonEncode(data);
  } on FormatException {
    return data.toString();
  } on JsonUnsupportedObjectError {
    return data.toString();
  }
}

/// Serves matching requests from local_mock rules; others go to the network.
/// Every request that passes through is recorded for the desktop capture
/// view, whether it was mocked or answered by the real backend.
///
/// Add it after interceptors that change the request URL / method. Prefer
/// [LocalMockDio.attach], which also registers the VM Service extensions.
final class LocalMockInterceptor extends Interceptor {
  LocalMockInterceptor() {
    LocalMock.ensureInitialized();
  }

  /// Pass-through recordings, finalized in onResponse / onError. Requests
  /// short-circuited by other interceptors are evicted by cap instead of
  /// waiting for a callback that never comes.
  static const _maxPending = 64;
  final _pendingTraffic = <RequestOptions, TrafficRecording>{};

  void _remember(RequestOptions options, TrafficRecording traffic) {
    while (_pendingTraffic.length >= _maxPending) {
      _pendingTraffic.remove(_pendingTraffic.keys.first);
    }
    _pendingTraffic[options] = traffic;
  }

  TrafficRecording? _forget(RequestOptions options) =>
      _pendingTraffic.remove(options);

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final traffic = LocalMock.beginTraffic(options.method, options.uri);
    final rule = LocalMock.match(options.method, options.uri);
    if (rule == null) {
      if (traffic != null) {
        traffic.requestBody = _describeBody(options.data);
        _remember(options, traffic);
      }
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
      traffic?.finish(
        mocked: true,
        statusCode: rule.statusCode,
        contentType: _mockContentType,
        body: jsonEncode(rule.body),
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
      traffic?.fail(
        error is DioError
            ? (error.error ??
                  error.response?.statusMessage ??
                  '${error.type.name} ${error.message ?? ''}')
            : error,
        mocked: true,
      );
      handler.reject(
        error is DioError
            ? error
            : DioError(requestOptions: options, error: error),
        true,
      );
    }
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    _forget(response.requestOptions)?.finish(
      statusCode: response.statusCode,
      contentType: response.headers.value(Headers.contentTypeHeader),
      body: _describeBody(response.data),
    );
    handler.next(response);
  }

  @override
  void onError(DioError err, ErrorInterceptorHandler handler) {
    final traffic = _forget(err.requestOptions);
    final response = err.response;
    if (traffic != null) {
      if (response != null) {
        traffic.finish(
          statusCode: response.statusCode,
          contentType: response.headers.value(Headers.contentTypeHeader),
          body: _describeBody(response.data),
        );
      } else {
        traffic.fail(
          '${err.type.name}: ${err.message ?? err.error ?? 'failed'}',
        );
      }
    }
    handler.next(err);
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
