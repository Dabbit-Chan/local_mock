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

/// Best-effort header map for the capture view; never throws. Dio stores
/// header values as `dynamic`, sometimes as lists (e.g. `set-cookie`).
Map<String, List<String>>? _describeHeaders(Map<String, dynamic> headers) {
  final described = <String, List<String>>{};
  for (final entry in headers.entries) {
    final value = entry.value;
    if (value == null) continue;
    final values = value is Iterable
        ? [
            for (final item in value)
              if (item != null) '$item',
          ]
        : ['$value'];
    if (values.isNotEmpty) described[entry.key] = values;
  }
  return described.isEmpty ? null : described;
}

/// Serves matching requests from local_mock rules; others go to the network.
/// Every request that passes through is recorded for the desktop capture
/// view, whether it was mocked or answered by the real backend.
///
/// Add it after interceptors that change the request URL / method. Prefer
/// [LocalMockDio.attach], which also initializes local_mock.
final class LocalMockInterceptor extends Interceptor {
  LocalMockInterceptor() {
    LocalMock.ensureInitialized();
  }

  /// Pass-through recordings, finalized in onResponse / onError. Requests
  /// short-circuited by other interceptors are evicted by cap instead of
  /// waiting for a callback that never comes.
  static const _maxPending = 64;
  final _pendingTraffic = <RequestOptions, TrafficRecording>{};
  final _patchRules = Expando<MockRule>();

  void _remember(RequestOptions options, TrafficRecording traffic) {
    while (_pendingTraffic.length >= _maxPending) {
      _pendingTraffic.remove(_pendingTraffic.keys.first);
    }
    _pendingTraffic[options] = traffic;
  }

  TrafficRecording? _forget(RequestOptions options) =>
      _pendingTraffic.remove(options);

  Future<void> _delay(MockRule rule, RequestOptions options) async {
    final token = options.cancelToken;
    if (token?.isCancelled == true) throw token!.cancelError!;
    if (rule.delayMs > 0) {
      final delay = Future<void>.delayed(Duration(milliseconds: rule.delayMs));
      await (token == null
          ? delay
          : Future.any<void>([delay, token.whenCancel.then<void>((_) {})]));
    }
    if (token?.isCancelled == true) throw token!.cancelError!;
  }

  Future<bool> _patchResponse(Response<dynamic> response) async {
    final options = response.requestOptions;
    final rule = _patchRules[options];
    _patchRules[options] = null;
    if (rule == null || options.responseType != ResponseType.json) return false;
    dynamic patched;
    try {
      patched = rule.applyPatch(response.data);
    } on FormatException {
      return false;
    } on JsonUnsupportedObjectError {
      return false;
    }
    await _delay(rule, options);
    response.data = patched;
    for (final name in ['content-length', 'etag', 'content-md5']) {
      response.headers.map.remove(name);
    }
    response.extra.addAll({'local_mock': true, 'local_mock_rule_id': rule.id});
    return true;
  }

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final traffic = LocalMock.beginTraffic(options.method, options.uri);
    traffic?.requestHeaders = _describeHeaders(options.headers);
    traffic?.requestBody = _describeBody(options.data);
    final data = options.data;
    final rule = LocalMock.match(
      options.method,
      options.uri,
      requestBody: data is FormData
          ? Map<String, String>.fromEntries(data.fields)
          : data,
    );
    if (rule == null || rule.isPatch) {
      if (rule != null) _patchRules[options] = rule;
      if (traffic != null) {
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
      await _delay(rule, options);
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
        contentType: rule.responseHeaders['content-type'],
        body: rule.responseText,
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
  ) async {
    final traffic = _forget(response.requestOptions);
    try {
      final patched = await _patchResponse(response);
      traffic?.finish(
        mocked: patched,
        statusCode: response.statusCode,
        contentType: response.headers.value(Headers.contentTypeHeader),
        body: patched
            ? jsonEncode(response.data)
            : _describeBody(response.data),
      );
      handler.next(response);
    } catch (error) {
      traffic?.fail(error, mocked: true);
      handler.reject(
        error is DioError
            ? error
            : DioError(requestOptions: response.requestOptions, error: error),
        true,
      );
    }
  }

  @override
  void onError(DioError err, ErrorInterceptorHandler handler) async {
    final traffic = _forget(err.requestOptions);
    final response = err.response;
    try {
      if (response != null) {
        final patched = await _patchResponse(response);
        traffic?.finish(
          mocked: patched,
          statusCode: response.statusCode,
          contentType: response.headers.value(Headers.contentTypeHeader),
          body: patched
              ? jsonEncode(response.data)
              : _describeBody(response.data),
        );
      } else {
        _patchRules[err.requestOptions] = null;
        traffic?.fail(
          '${err.type.name}: ${err.message ?? err.error ?? 'failed'}',
        );
      }
      handler.next(err);
    } catch (error) {
      traffic?.fail(error, mocked: true);
      handler.next(error is DioError ? error : err);
    }
  }
}

/// Attachment for Debug and Profile builds.
abstract final class LocalMockDio {
  /// Returns false when local_mock is disabled, true when attached (or already
  /// attached). Attach after request interceptors that modify URL / method.
  static bool attach(Dio dio) {
    if (!LocalMock.ensureInitialized()) return false;
    if (!dio.interceptors.any((item) => item is LocalMockInterceptor)) {
      dio.interceptors.add(LocalMockInterceptor());
    }
    return true;
  }
}
