import 'dart:convert';
import 'dart:typed_data';

/// One request/response pair recorded by an adapter, shown in the desktop
/// capture view and convertible into a mock rule.
final class TrafficEntry {
  TrafficEntry({
    required this.revision,
    required this.startedAt,
    required this.durationMs,
    required this.mocked,
    required this.method,
    required this.uri,
    required this.path,
    this.host,
    this.requestHeaders,
    this.requestBody,
    this.statusCode,
    this.contentType,
    this.responseBody,
    this.error,
  });

  factory TrafficEntry.fromJson(Map<String, dynamic> json) => TrafficEntry(
    revision: json['revision'] as int? ?? 0,
    startedAt: json['startedAt'] as int? ?? 0,
    durationMs: json['durationMs'] as int? ?? 0,
    mocked: json['mocked'] as bool? ?? false,
    method: json['method'] as String? ?? '',
    uri: json['uri'] as String? ?? '',
    host: json['host'] as String?,
    path: json['path'] as String? ?? '',
    requestHeaders: _readHeaders(json['requestHeaders']),
    requestBody: json['requestBody'] as String?,
    statusCode: json['statusCode'] as int?,
    contentType: json['contentType'] as String?,
    responseBody: json['responseBody'] as String?,
    error: json['error'] as String?,
  );

  /// Monotonic per-isolate sequence number, assigned when the entry completes.
  final int revision;

  /// Wall clock (ms since epoch) when the request started.
  final int startedAt;
  final int durationMs;

  /// True when the response came from a mock rule instead of the network.
  final bool mocked;

  final String method;

  /// Full request URI including query string, for display only.
  final String uri;
  final String? host;
  final String path;

  /// Request headers as seen by the adapter, keyed by name. Names keep the
  /// case the app sent; each name keeps all its values. Null when the adapter
  /// could not read them (older app builds never send this field).
  final Map<String, List<String>>? requestHeaders;

  /// Best-effort request body text (JSON text or raw string).
  final String? requestBody;

  /// Null when the request failed before a status was received.
  final int? statusCode;
  final String? contentType;

  /// Response body as text; binary payloads become a size placeholder.
  final String? responseBody;

  /// Error description for requests that never produced a response.
  final String? error;

  Map<String, dynamic> toJson() => {
    'revision': revision,
    'startedAt': startedAt,
    'durationMs': durationMs,
    'mocked': mocked,
    'method': method,
    'uri': uri,
    if (host != null) 'host': host,
    'path': path,
    if (requestHeaders != null && requestHeaders!.isNotEmpty)
      'requestHeaders': requestHeaders,
    if (requestBody != null) 'requestBody': requestBody,
    if (statusCode != null) 'statusCode': statusCode,
    if (contentType != null) 'contentType': contentType,
    if (responseBody != null) 'responseBody': responseBody,
    if (error != null) 'error': error,
  };

  /// Tolerates both `name: [values]` (current apps) and `name: value` shapes,
  /// so recordings written by older builds still load.
  static Map<String, List<String>>? _readHeaders(dynamic value) {
    if (value is! Map) return null;
    final headers = <String, List<String>>{};
    for (final entry in value.entries) {
      final raw = entry.value;
      final values = raw is Iterable
          ? [
              for (final item in raw)
                if (item != null) '$item',
            ]
          : [if (raw != null) '$raw'];
      if (values.isNotEmpty) {
        headers['${entry.key}'] = List.unmodifiable(values);
      }
    }
    return headers.isEmpty ? null : Map.unmodifiable(headers);
  }
}

/// In-memory capture buffer with an optional count limit and event callback.
final class TrafficRecorder {
  TrafficRecorder({this.maxEntries, this.onEntry});

  final int? maxEntries;
  final void Function(TrafficEntry)? onEntry;
  final List<TrafficEntry> _entries = [];
  int _counter = 0;

  /// Latest appended revision; 0 when nothing was recorded yet.
  int get revision => _counter;

  /// Entries appended after [sinceRevision], oldest first.
  List<TrafficEntry> since(int sinceRevision) => [
    for (final entry in _entries)
      if (entry.revision > sinceRevision) entry,
  ];

  /// Drops stored entries; the revision counter keeps increasing so desktop
  /// cursors stay valid after a clear.
  void clear() => _entries.clear();

  TrafficRecording begin(String method, Uri uri) =>
      TrafficRecording._(this, method, uri);

  void _finish(TrafficEntry Function(int revision) build) {
    final entry = build(++_counter);
    _entries.add(entry);
    if (maxEntries != null && _entries.length > maxEntries!) {
      _entries.removeRange(0, _entries.length - maxEntries!);
    }
    onEntry?.call(entry);
  }
}

/// Live handle for one in-flight request. Adapters call [finish] or [fail]
/// exactly once; later calls are ignored, so aborted/double-signalled paths
/// never duplicate entries.
final class TrafficRecording {
  TrafficRecording._(this._recorder, this.method, this.uri);

  final TrafficRecorder _recorder;
  final String method;
  final Uri uri;
  final DateTime startedAt = DateTime.now();
  final Stopwatch _watch = Stopwatch()..start();

  final BytesBuilder _requestBytes = BytesBuilder(copy: false);
  final StringBuffer _requestText = StringBuffer();
  String? _requestBody;
  Map<String, List<String>>? _requestHeaders;
  bool _finalized = false;

  /// Sets the request body text directly (e.g. Dio's decoded options.data).
  set requestBody(String? text) {
    if (text == null || text.isEmpty) return;
    _requestBody = text;
  }

  /// Sets the request headers captured by the adapter. Empty names and empty
  /// value lists are dropped; repeated names keep every value.
  set requestHeaders(Map<String, List<String>>? headers) {
    if (headers == null) return;
    final captured = <String, List<String>>{};
    for (final entry in headers.entries) {
      if (entry.key.isEmpty) continue;
      final values = [
        for (final value in entry.value)
          if (value.isNotEmpty) value,
      ];
      if (values.isNotEmpty) captured[entry.key] = List.unmodifiable(values);
    }
    _requestHeaders = captured.isEmpty ? null : Map.unmodifiable(captured);
  }

  /// Collects request body text incrementally (dart:io write* methods).
  void collectRequestText(String text) {
    _requestText.write(text);
  }

  /// Collects raw request body chunks (dart:io add / addStream).
  void collectRequestBytes(List<int> bytes) {
    _requestBytes.add(bytes);
  }

  /// Records a completed response (mocked or from the network).
  void finish({
    bool mocked = false,
    int? statusCode,
    String? contentType,
    String? body,
  }) {
    _complete(
      (revision) => TrafficEntry(
        revision: revision,
        startedAt: startedAt.millisecondsSinceEpoch,
        durationMs: _watch.elapsedMilliseconds,
        mocked: mocked,
        method: method,
        uri: uri.toString(),
        host: uri.host.isEmpty ? null : uri.host,
        path: uri.path,
        requestHeaders: _requestHeaders,
        requestBody: _resolveRequestBody(),
        statusCode: statusCode,
        contentType: contentType,
        responseBody: body,
      ),
    );
  }

  /// Records a request that never produced a response.
  void fail(Object error, {bool mocked = false}) {
    _complete(
      (revision) => TrafficEntry(
        revision: revision,
        startedAt: startedAt.millisecondsSinceEpoch,
        durationMs: _watch.elapsedMilliseconds,
        mocked: mocked,
        method: method,
        uri: uri.toString(),
        host: uri.host.isEmpty ? null : uri.host,
        path: uri.path,
        requestHeaders: _requestHeaders,
        requestBody: _resolveRequestBody(),
        error: error.toString(),
      ),
    );
  }

  void _complete(TrafficEntry Function(int revision) build) {
    if (_finalized) return;
    _finalized = true;
    _watch.stop();
    _recorder._finish(build);
  }

  String? _resolveRequestBody() {
    final text =
        _requestBody ??
        (_requestText.isNotEmpty ? _requestText.toString() : null);
    if (text != null) return text;
    final bytes = _requestBytes.takeBytes();
    if (bytes.isEmpty) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }
}
