import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:local_mock_core/local_mock_core.dart';

/// Wraps every `HttpClient` created through `dart:io` so matching requests
/// are answered locally. Unmatched requests use [previous] (or the default
/// client) unchanged.
final class LocalMockHttpOverrides extends HttpOverrides {
  LocalMockHttpOverrides([this.previous]);

  /// Overrides active before local_mock was installed (proxy, certificates…).
  final HttpOverrides? previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _MockHttpClient(
    previous?.createHttpClient(context) ?? super.createHttpClient(context),
  );

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      previous?.findProxyFromEnvironment(url, environment) ??
      super.findProxyFromEnvironment(url, environment);
}

final class _MockHttpClient implements HttpClient {
  _MockHttpClient(this._inner);

  final HttpClient _inner;
  final _pending = <_MockRequest>{};
  bool _closed = false;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    final rule = LocalMock.match(method, url);
    if (rule == null) return _inner.openUrl(method, url);
    if (_closed) throw StateError('Client is closed');
    final request = _MockRequest(method, url, rule, _pending.remove);
    _pending.add(request);
    return Future.value(request);
  }

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) {
    // Same URI construction as dart:io: `path` may carry a query string.
    final reference = Uri.parse(path);
    final url = Uri(
      scheme: 'http',
      host: host,
      port: port,
      path: reference.path,
      query: reference.hasQuery ? reference.query : null,
    );
    if (LocalMock.match(method, url) == null) {
      return _inner.open(method, host, port, path);
    }
    return openUrl(method, url);
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    // Dio 4 cancels requests by force-closing the client.
    if (force) {
      for (final request in _pending.toList()) {
        request.abort();
      }
    }
    _inner.close(force: force);
  }

  // Convenience methods: dart:io uses lowercase method names here.
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('get', host, port, path);
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('get', url);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('post', host, port, path);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('post', url);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('put', host, port, path);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('put', url);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('delete', host, port, path);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('delete', url);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('patch', host, port, path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('patch', url);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('head', host, port, path);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('head', url);

  // Everything below is forwarded to the real client.
  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;
  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;
  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) => _inner.authenticate = f;
  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addCredentials(url, realm, credentials);
  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )?
    f,
  ) => _inner.connectionFactory = f;
  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;
  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
    f,
  ) => _inner.authenticateProxy = f;
  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addProxyCredentials(host, port, realm, credentials);
  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) => _inner.badCertificateCallback = callback;
  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;
}

/// Request body is accepted and discarded. The rule delay starts at [close],
/// so client receive timeouts behave like a slow server.
final class _MockRequest implements HttpClientRequest {
  _MockRequest(this.method, this.uri, this._rule, this._onFinish) {
    // Abort without a listener must not become an uncaught zone error.
    _done.future.ignore();
  }

  final MockRule _rule;
  final void Function(_MockRequest) _onFinish;
  final _done = Completer<HttpClientResponse>();
  Timer? _timer;

  @override
  final String method;
  @override
  final Uri uri;
  @override
  final HttpHeaders headers = _MockHeaders();
  @override
  final List<Cookie> cookies = [];
  @override
  bool persistentConnection = true;
  @override
  bool followRedirects = true;
  @override
  int maxRedirects = 5;
  @override
  int contentLength = -1;
  @override
  bool bufferOutput = true;
  @override
  Encoding encoding = utf8;

  @override
  HttpConnectionInfo? get connectionInfo => null;

  @override
  Future<HttpClientResponse> get done => _done.future;

  @override
  Future<HttpClientResponse> close() {
    if (!_done.isCompleted) {
      _timer ??= Timer(Duration(milliseconds: _rule.delayMs), () {
        if (_done.isCompleted) return;
        _onFinish(this);
        _done.complete(_MockResponse(method, _rule));
      });
    }
    return done;
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    if (_done.isCompleted) return;
    _timer?.cancel();
    _onFinish(this);
    _done.completeError(
      exception ?? HttpException('Request has been aborted', uri: uri),
      stackTrace,
    );
  }

  @override
  void add(List<int> data) {}
  @override
  void write(Object? object) {}
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {}
  @override
  void writeln([Object? object = '']) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      abort(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();
  @override
  Future<void> flush() => Future.value();
}

final class _MockResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  factory _MockResponse(String method, MockRule rule) {
    final noBody =
        method.toUpperCase() == 'HEAD' ||
        rule.statusCode == 204 ||
        rule.statusCode == 304;
    final bytes = noBody ? <int>[] : utf8.encode(jsonEncode(rule.body));
    final headers = _MockHeaders();
    rule.responseHeaders.forEach(headers.set);
    headers.contentLength = bytes.length;
    return _MockResponse._(rule, bytes, headers);
  }

  _MockResponse._(this._rule, List<int> bytes, this.headers)
    : contentLength = bytes.length,
      super(Stream<List<int>>.fromIterable([if (bytes.isNotEmpty) bytes]));

  final MockRule _rule;

  @override
  final HttpHeaders headers;
  @override
  final int contentLength;

  @override
  int get statusCode => _rule.statusCode;
  @override
  String get reasonPhrase => _reasonPhrases[_rule.statusCode] ?? '';
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  bool get persistentConnection => true;
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => const [];
  @override
  X509Certificate? get certificate => null;
  @override
  HttpConnectionInfo? get connectionInfo => null;
  @override
  List<Cookie> get cookies => [
    for (final value in headers[HttpHeaders.setCookieHeader] ?? const [])
      Cookie.fromSetCookieValue(value),
  ];

  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) => Future.error(StateError('local_mock responses do not redirect'));

  /// There is no socket. Never completes instead of failing, because Dio's
  /// receive-timeout path calls this without handling errors.
  @override
  Future<Socket> detachSocket() => Completer<Socket>().future;
}

/// Minimal case-insensitive header map, enough for Dio and package:http.
final class _MockHeaders implements HttpHeaders {
  final _values = <String, List<String>>{};
  final _names = <String, String>{};

  @override
  String? host;
  @override
  int? port;
  @override
  bool persistentConnection = true;
  @override
  bool chunkedTransferEncoding = false;

  static String _text(Object? value) =>
      value is DateTime ? HttpDate.format(value) : '$value';

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  String? value(String name) {
    final values = this[name];
    if (values == null) return null;
    if (values.length > 1) {
      throw HttpException('More than one value for header $name');
    }
    return values.single;
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    final key = name.toLowerCase();
    if (preserveHeaderCase) _names[key] = name;
    final values = _values.putIfAbsent(key, () => []);
    if (value is Iterable) {
      values.addAll(value.map(_text));
    } else {
      values.add(_text(value));
    }
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    removeAll(name);
    add(name, value, preserveHeaderCase: preserveHeaderCase);
  }

  @override
  void remove(String name, Object value) {
    final key = name.toLowerCase();
    final values = _values[key];
    if (values == null) return;
    values.remove(_text(value));
    if (values.isEmpty) removeAll(name);
  }

  @override
  void removeAll(String name) {
    final key = name.toLowerCase();
    _values.remove(key);
    _names.remove(key);
  }

  @override
  void forEach(void Function(String name, List<String> values) action) =>
      _values.forEach((key, values) => action(_names[key] ?? key, [...values]));

  @override
  void noFolding(String name) {}

  @override
  void clear() {
    _values.clear();
    _names.clear();
  }

  @override
  ContentType? get contentType {
    final value = this.value(HttpHeaders.contentTypeHeader);
    return value == null ? null : ContentType.parse(value);
  }

  @override
  set contentType(ContentType? value) => value == null
      ? removeAll(HttpHeaders.contentTypeHeader)
      : set(HttpHeaders.contentTypeHeader, value.toString());

  @override
  int get contentLength =>
      int.tryParse(value(HttpHeaders.contentLengthHeader) ?? '') ?? -1;

  @override
  set contentLength(int value) => value < 0
      ? removeAll(HttpHeaders.contentLengthHeader)
      : set(HttpHeaders.contentLengthHeader, '$value');

  DateTime? _date(String name) {
    final value = this.value(name);
    if (value == null) return null;
    try {
      return HttpDate.parse(value);
    } on HttpException {
      return null;
    }
  }

  void _setDate(String name, DateTime? value) =>
      value == null ? removeAll(name) : set(name, value);

  @override
  DateTime? get date => _date(HttpHeaders.dateHeader);
  @override
  set date(DateTime? value) => _setDate(HttpHeaders.dateHeader, value);
  @override
  DateTime? get expires => _date(HttpHeaders.expiresHeader);
  @override
  set expires(DateTime? value) => _setDate(HttpHeaders.expiresHeader, value);
  @override
  DateTime? get ifModifiedSince => _date(HttpHeaders.ifModifiedSinceHeader);
  @override
  set ifModifiedSince(DateTime? value) =>
      _setDate(HttpHeaders.ifModifiedSinceHeader, value);
}

const _reasonPhrases = {
  200: 'OK',
  201: 'Created',
  202: 'Accepted',
  204: 'No Content',
  301: 'Moved Permanently',
  302: 'Found',
  304: 'Not Modified',
  400: 'Bad Request',
  401: 'Unauthorized',
  403: 'Forbidden',
  404: 'Not Found',
  405: 'Method Not Allowed',
  409: 'Conflict',
  422: 'Unprocessable Entity',
  429: 'Too Many Requests',
  500: 'Internal Server Error',
  502: 'Bad Gateway',
  503: 'Service Unavailable',
  504: 'Gateway Timeout',
};
