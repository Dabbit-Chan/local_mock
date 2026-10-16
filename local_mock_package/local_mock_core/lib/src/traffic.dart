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
    this.requestBody,
    this.statusCode,
    this.contentType,
    this.responseBody,
    this.truncated = false,
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
    requestBody: json['requestBody'] as String?,
    statusCode: json['statusCode'] as int?,
    contentType: json['contentType'] as String?,
    responseBody: json['responseBody'] as String?,
    truncated: json['truncated'] as bool? ?? false,
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

  /// Best-effort request body text (JSON text or raw string).
  final String? requestBody;

  /// Null when the request failed before a status was received.
  final int? statusCode;
  final String? contentType;

  /// Response body as text; binary payloads become a size placeholder.
  final String? responseBody;

  /// Any recorded body was clipped to the size cap.
  final bool truncated;

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
    if (requestBody != null) 'requestBody': requestBody,
    if (statusCode != null) 'statusCode': statusCode,
    if (contentType != null) 'contentType': contentType,
    if (responseBody != null) 'responseBody': responseBody,
    if (truncated) 'truncated': truncated,
    if (error != null) 'error': error,
  };
}

/// Debug-only in-memory capture buffer, one per isolate.
final class TrafficRecorder {
  /// Kept entries; older ones are dropped first.
  static const maxEntries = 100;

  /// Cap for recorded request/response body text (characters).
  static const maxBodyChars = 64 * 1024;

  /// Cap for accumulated request bytes before text conversion.
  static const maxBodyBytes = 64 * 1024;

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
    _entries.add(build(++_counter));
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
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
  bool _truncated = false;
  bool _finalized = false;

  /// Sets the request body text directly (e.g. Dio's decoded options.data).
  set requestBody(String? text) {
    if (text == null || text.isEmpty) return;
    if (text.length > TrafficRecorder.maxBodyChars) {
      _truncated = true;
      text = text.substring(0, TrafficRecorder.maxBodyChars);
    }
    _requestBody = text;
  }

  /// Collects request body text incrementally (dart:io write* methods).
  void collectRequestText(String text) {
    final buffer = _requestText;
    if (buffer.length >= TrafficRecorder.maxBodyChars) {
      _truncated = true;
      return;
    }
    if (text.length + buffer.length > TrafficRecorder.maxBodyChars) {
      _truncated = true;
      text = text.substring(0, TrafficRecorder.maxBodyChars - buffer.length);
    }
    buffer.write(text);
  }

  /// Collects raw request body chunks (dart:io add / addStream).
  void collectRequestBytes(List<int> bytes) {
    if (_requestBytes.length >= TrafficRecorder.maxBodyBytes) {
      _truncated = true;
      return;
    }
    _requestBytes.add(bytes);
    if (_requestBytes.length > TrafficRecorder.maxBodyBytes) {
      _truncated = true;
    }
  }

  /// Records a completed response (mocked or from the network).
  void finish({
    bool mocked = false,
    int? statusCode,
    String? contentType,
    String? body,
    bool truncated = false,
  }) {
    if (body != null && body.length > TrafficRecorder.maxBodyChars) {
      truncated = true;
      body = body.substring(0, TrafficRecorder.maxBodyChars);
    }
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
        requestBody: _resolveRequestBody(),
        statusCode: statusCode,
        contentType: contentType,
        responseBody: _clip(body),
        truncated: truncated || _truncated,
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
        requestBody: _resolveRequestBody(),
        truncated: _truncated,
        error: _clip(error.toString()),
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
    if (text != null) return _clip(text);
    final bytes = _requestBytes.takeBytes();
    if (bytes.isEmpty) return null;
    return _clip(utf8.decode(bytes, allowMalformed: true));
  }

  static String? _clip(String? text) {
    if (text == null || text.length <= TrafficRecorder.maxBodyChars) {
      return text;
    }
    return text.substring(0, TrafficRecorder.maxBodyChars);
  }
}
