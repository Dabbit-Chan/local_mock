import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:local_mock_core/local_mock_core.dart';

/// Wraps every `HttpClient` created through `dart:io` so matching requests
/// are answered locally. Unmatched requests use [previous] (or the default
/// client) unchanged. Both mocked and pass-through requests are recorded
/// for the desktop capture view.
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
    final traffic = LocalMock.beginTraffic(method, url);
    final rule = LocalMock.match(method, url);
    if (rule == null) {
      final opening = _inner.openUrl(method, url);
      if (traffic == null) return opening;
      return opening.then(
        (request) => _RecordingHttpClientRequest(traffic, request),
        onError: (error, stackTrace) => _failOpen(traffic, error, stackTrace),
      );
    }
    if (_closed) throw StateError('Client is closed');
    final request = _MockRequest(method, url, rule, _pending.remove, traffic);
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
      final traffic = LocalMock.beginTraffic(method, url);
      final opening = _inner.open(method, host, port, path);
      if (traffic == null) return opening;
      return opening.then(
        (request) => _RecordingHttpClientRequest(traffic, request),
        onError: (error, stackTrace) => _failOpen(traffic, error, stackTrace),
      );
    }
    return openUrl(method, url);
  }

  static Never _failOpen(
    TrafficRecording traffic,
    Object error,
    StackTrace stackTrace,
  ) {
    traffic.fail(error);
    Error.throwWithStackTrace(error, stackTrace);
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

/// Request body is collected for the capture view, then discarded. The rule
/// delay starts at [close], so client receive timeouts behave like a slow
/// server.
final class _MockRequest implements HttpClientRequest {
  _MockRequest(
    this.method,
    this.uri,
    this._rule,
    this._onFinish,
    this._traffic,
  ) {
    // Abort without a listener must not become an uncaught zone error.
    _done.future.ignore();
  }

  final MockRule _rule;
  final TrafficRecording? _traffic;
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
        _traffic?.finish(
          mocked: true,
          statusCode: _rule.statusCode,
          contentType: _rule.responseHeaders['content-type'],
          body: jsonEncode(_rule.body),
        );
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
    _traffic?.fail(
      exception ?? const HttpException('Request has been aborted'),
      mocked: true,
    );
    _done.completeError(
      exception ?? HttpException('Request has been aborted', uri: uri),
      stackTrace,
    );
  }

  @override
  void add(List<int> data) => _traffic?.collectRequestBytes(data);
  @override
  void write(Object? object) => _traffic?.collectRequestText('$object');
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _traffic?.collectRequestText(objects.join(separator));
  @override
  void writeln([Object? object = '']) =>
      _traffic?.collectRequestText('$object\n');
  @override
  void writeCharCode(int charCode) =>
      _traffic?.collectRequestText(String.fromCharCode(charCode));
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      abort(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

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

/// Delegating `HttpClientRequest` for pass-through requests that records the
/// request body and wraps the response for capture.
final class _RecordingHttpClientRequest implements HttpClientRequest {
  _RecordingHttpClientRequest(this._traffic, this._inner);

  final TrafficRecording _traffic;
  final HttpClientRequest _inner;

  HttpClientResponse _wrap(HttpClientResponse response) =>
      _RecordingHttpClientResponse(response, _traffic);

  Never _fail(Object error, StackTrace stackTrace) {
    _traffic.fail(error);
    Error.throwWithStackTrace(error, stackTrace);
  }

  @override
  Future<HttpClientResponse> get done =>
      _inner.done.then(_wrap, onError: _fail);
  @override
  Future<HttpClientResponse> close() =>
      _inner.close().then(_wrap, onError: _fail);

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    _traffic.fail(exception ?? 'request aborted');
    _inner.abort(exception, stackTrace);
  }

  @override
  void add(List<int> data) {
    _traffic.collectRequestBytes(data);
    _inner.add(data);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(
    stream.map((chunk) {
      _traffic.collectRequestBytes(chunk);
      return chunk;
    }),
  );

  @override
  void write(Object? object) {
    _traffic.collectRequestText('$object');
    _inner.write(object);
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    _traffic.collectRequestText(objects.join(separator));
    _inner.writeAll(objects, separator);
  }

  @override
  void writeln([Object? object = '']) {
    _traffic.collectRequestText('$object\n');
    _inner.writeln(object);
  }

  @override
  void writeCharCode(int charCode) {
    _traffic.collectRequestText(String.fromCharCode(charCode));
    _inner.writeCharCode(charCode);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future<void> flush() => _inner.flush();

  @override
  String get method => _inner.method;
  @override
  Uri get uri => _inner.uri;
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;
  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool value) => _inner.followRedirects = value;
  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;
  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;
  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;
  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;
}

/// Delegating `HttpClientResponse` that tees the body into the capture entry
/// while forwarding every byte to the app unchanged.
final class _RecordingHttpClientResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  _RecordingHttpClientResponse(this._inner, TrafficRecording traffic)
    : super(_tee(_inner, traffic));

  final HttpClientResponse _inner;

  /// Content types worth keeping as text; anything else becomes a size
  /// placeholder so binary payloads never reach the capture view.
  static const _textualMimePrefixes = [
    'text/',
    'application/json',
    'application/xml',
    'application/javascript',
    'application/x-www-form-urlencoded',
  ];

  static bool _isTextual(String? mime) {
    if (mime == null) return true;
    return _textualMimePrefixes.any(mime.startsWith) ||
        mime.contains('+json') ||
        mime.contains('+xml');
  }

  static String _describeBody(ContentType? contentType, List<int> bytes) {
    final mime = contentType?.mimeType.toLowerCase();
    if (!_isTextual(mime)) return '<binary ${bytes.length} bytes>';
    return utf8.decode(bytes, allowMalformed: true);
  }

  static Stream<List<int>> _tee(
    HttpClientResponse inner,
    TrafficRecording traffic,
  ) {
    late final StreamSubscription<List<int>> subscription;
    final controller = StreamController<List<int>>(sync: true);
    final received = BytesBuilder(copy: false);
    var settled = false;

    controller.onListen = () {
      subscription = inner.listen(
        (chunk) {
          received.add(chunk);
          controller.add(chunk);
        },
        onError: (Object error, StackTrace stackTrace) {
          settled = true;
          traffic.fail(error);
          controller.addError(error, stackTrace);
        },
        onDone: () {
          settled = true;
          traffic.finish(
            statusCode: inner.statusCode,
            contentType: inner.headers.value(HttpHeaders.contentTypeHeader),
            body: _describeBody(inner.headers.contentType, received.toBytes()),
          );
          controller.close();
        },
        cancelOnError: false,
      );
    };
    controller.onPause = () {
      subscription.pause();
    };
    controller.onResume = () {
      subscription.resume();
    };
    controller.onCancel = () {
      if (!settled) {
        settled = true;
        traffic.fail('response stream cancelled');
      }
      return subscription.cancel();
    };
    return controller.stream;
  }

  @override
  int get statusCode => _inner.statusCode;
  @override
  String get reasonPhrase => _inner.reasonPhrase;
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  int get contentLength => _inner.contentLength;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  bool get isRedirect => _inner.isRedirect;
  @override
  List<RedirectInfo> get redirects => _inner.redirects;
  @override
  X509Certificate? get certificate => _inner.certificate;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  HttpClientResponseCompressionState get compressionState =>
      _inner.compressionState;
  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) => _inner.redirect(method, url, followLoops);
  @override
  Future<Socket> detachSocket() => _inner.detachSocket();
}
