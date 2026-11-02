import 'dart:convert';

import 'traffic.dart';
import 'recorded_request.dart';

/// A JSON response or response patch matched by endpoint and optional params.
/// The first enabled match wins.
final class MockRule {
  MockRule._({
    required this.id,
    required this.enabled,
    required this.method,
    required this.path,
    required this.host,
    required this.statusCode,
    required this.delayMs,
    required this.headers,
    required this.body,
    required this.params,
    required this.patchBody,
    String? responseText,
    this.name,
    this.recordingId,
    this.matchParams = false,
    this.rules = const [],
    this.recordedRequest,
    bool matchRecordedParams = true,
  }) : _responseText = responseText,
       _matchRecordedParams = matchRecordedParams;

  factory MockRule.fromTraffic(TrafficEntry entry, {required String id}) {
    dynamic body = entry.responseBody;
    try {
      body = jsonDecode(entry.responseBody ?? 'null');
    } on FormatException {
      body = entry.responseBody;
    }
    return MockRule._(
      id: id,
      enabled: true,
      method: entry.method.toUpperCase(),
      path: entry.path,
      host: Uri.parse(entry.uri).host,
      statusCode: entry.statusCode!,
      delayMs: entry.durationMs.clamp(0, 60000),
      headers: {
        'content-type': entry.contentType ?? 'application/json; charset=utf-8',
      },
      body: body,
      params: const {},
      patchBody: const {},
      responseText: entry.responseBody ?? '',
    );
  }

  factory MockRule.fromJson(
    Map<String, dynamic> json, {
    bool matchRecordedParams = true,
  }) {
    String text(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('$key must be a non-empty string');
      }
      return value;
    }

    int number(String key, int fallback, int min, int max) {
      final value = json[key] ?? fallback;
      if (value is! int || value < min || value > max) {
        throw FormatException('$key must be an integer in $min..$max');
      }
      return value;
    }

    final id = text('id');
    final enabled = json['enabled'] ?? true;
    if (enabled is! bool) {
      throw const FormatException('enabled must be a boolean');
    }
    if (json['type'] == 'recording') {
      final matchParams = json['matchParams'] ?? false;
      final rawRules = json['rules'];
      if (matchParams is! bool || rawRules is! List || rawRules.isEmpty) {
        throw const FormatException(
          'recording Mock needs rules and a boolean matchParams',
        );
      }
      if (rawRules.any(
        (rule) => rule is! Map<String, dynamic> || rule['type'] != null,
      )) {
        throw const FormatException(
          'recording Mock can only contain response rules',
        );
      }
      final children = parseList(rawRules, matchRecordedParams: matchParams);
      return MockRule._(
        id: id,
        enabled: enabled,
        name: text('name'),
        recordingId: text('recordingId'),
        matchParams: matchParams,
        rules: List.unmodifiable(children),
        method: '',
        path: '/',
        host: null,
        statusCode: 200,
        delayMs: 0,
        headers: const {},
        body: null,
        params: const {},
        patchBody: const {},
      );
    }
    if (json['type'] != null) throw const FormatException('unknown rule type');
    final method = text('method').toUpperCase();
    if (!RegExp(r'^[A-Z]+$').hasMatch(method)) {
      throw const FormatException('method must contain only ASCII letters');
    }
    final path = text('path');
    if (!path.startsWith('/') || path.contains('?') || path.contains('#')) {
      throw const FormatException(
        'path must start with /, without query or fragment',
      );
    }
    final host = json['host'];
    if (host != null && (host is! String || host.trim().isEmpty)) {
      throw const FormatException('host must be a non-empty string or null');
    }
    final rawHeaders = json['headers'] ?? <String, dynamic>{};
    if (rawHeaders is! Map<String, dynamic> ||
        rawHeaders.values.any((value) => value is! String)) {
      throw const FormatException(
        'headers must be an object with string values',
      );
    }
    final rawParams = json['params'] ?? <String, dynamic>{};
    if (rawParams is! Map<String, dynamic> ||
        rawParams.entries.any(
          (entry) =>
              entry.key.trim().isEmpty ||
              (entry.value != null &&
                  entry.value is! String &&
                  entry.value is! num &&
                  entry.value is! bool),
        )) {
      throw const FormatException(
        'params must be an object with non-empty keys and primitive values',
      );
    }
    final rawPatch = json['patchBody'] ?? <String, dynamic>{};
    if (rawPatch is! Map<String, dynamic>) {
      throw const FormatException('patchBody must be an object');
    }
    for (final path in rawPatch.keys) {
      _fieldPath(path, allowWildcard: true);
    }
    final responseText = json['responseText'];
    if (responseText != null && responseText is! String) {
      throw const FormatException('responseText must be a string');
    }
    return MockRule._(
      id: id,
      enabled: enabled,
      method: method,
      path: path,
      host: (host as String?)?.toLowerCase(),
      statusCode: number('statusCode', 200, 100, 599),
      delayMs: number('delayMs', 0, 0, 60000),
      headers: Map.unmodifiable(rawHeaders.cast<String, String>()),
      body: jsonDecode(jsonEncode(json['body'])),
      params: Map.unmodifiable({
        for (final entry in rawParams.entries) entry.key: '${entry.value}',
      }),
      patchBody: Map.unmodifiable(
        jsonDecode(jsonEncode(rawPatch)) as Map<String, dynamic>,
      ),
      responseText: responseText as String?,
      recordedRequest: json['recordedRequest'] == null
          ? null
          : RecordedRequest.fromJson(json['recordedRequest']),
      matchRecordedParams: matchRecordedParams,
    );
  }

  final String id;
  final bool enabled;
  final String method;
  final String path;
  final String? host;
  final int statusCode;
  final int delayMs;
  final Map<String, String> headers;
  final dynamic body;
  final Map<String, String> params;
  final Map<String, dynamic> patchBody;
  final String? _responseText;
  final String? name;
  final String? recordingId;
  final bool matchParams;
  final List<MockRule> rules;
  final RecordedRequest? recordedRequest;
  final bool _matchRecordedParams;

  bool get isRecording => recordingId != null;

  Iterable<MockRule> candidates(String method, Uri uri) => !enabled
      ? const []
      : isRecording
      ? rules.where((rule) => rule.matchesEndpoint(method, uri))
      : matchesEndpoint(method, uri)
      ? [this]
      : const [];

  String get responseText => _responseText ?? jsonEncode(body);

  bool get isPatch => patchBody.isNotEmpty;

  /// Response headers for adapters: lowercase names, JSON Content-Type by
  /// default (overridable by [headers]).
  Map<String, String> get responseHeaders => {
    'content-type': 'application/json; charset=utf-8',
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };

  /// Fresh deep copy of [body] so callers can mutate it safely.
  dynamic get bodyCopy => jsonDecode(jsonEncode(body));

  bool matchesEndpoint(String requestMethod, Uri uri) =>
      enabled &&
      method == requestMethod.toUpperCase() &&
      path == uri.path &&
      (host == null || host == uri.host.toLowerCase());

  bool matches(String requestMethod, Uri uri, {dynamic requestBody}) {
    if (!matchesEndpoint(requestMethod, uri)) return false;
    if (_matchRecordedParams &&
        recordedRequest != null &&
        !recordedRequest!.matches(uri, requestBody)) {
      return false;
    }
    if (params.isEmpty) return true;
    final body = _decodeRequestBody(requestBody);
    Map<String, List<String>> query;
    try {
      query = uri.queryParametersAll;
    } on FormatException {
      return false;
    } on ArgumentError {
      return false;
    }
    for (final entry in params.entries) {
      final queryValues = query[entry.key];
      if (queryValues != null) {
        if (!queryValues.contains(entry.value)) return false;
        continue;
      }
      dynamic value = body;
      if (body is Map && body.containsKey(entry.key)) {
        value = body[entry.key];
      } else {
        List<String> segments;
        try {
          segments = _fieldPath(entry.key);
        } on FormatException {
          return false;
        }
        for (final segment in segments) {
          if (value is Map && value.containsKey(segment)) {
            value = value[segment];
          } else if (value is List) {
            final index = int.tryParse(segment);
            if (index == null || index < 0 || index >= value.length) {
              return false;
            }
            value = value[index];
          } else {
            return false;
          }
        }
      }
      if (value is Map || value is List || '$value' != entry.value) {
        return false;
      }
    }
    return true;
  }

  dynamic applyPatch(dynamic responseBody) {
    final result = jsonDecode(jsonEncode(responseBody));
    for (final entry in patchBody.entries) {
      final segments = _fieldPath(entry.key, allowWildcard: true);

      dynamic applyTo(dynamic current, int offset) {
        if (offset == segments.length) {
          return jsonDecode(jsonEncode(entry.value));
        }
        final segment = segments[offset];
        if (segment == '[*]') {
          if (current is! List) {
            throw FormatException(
              'patchBody wildcard target is not an array: ${entry.key}',
            );
          }
          for (var index = 0; index < current.length; index++) {
            current[index] = applyTo(current[index], offset + 1);
          }
        } else if (current is Map &&
            (offset == segments.length - 1 || current.containsKey(segment))) {
          current[segment] = applyTo(current[segment], offset + 1);
        } else if (current is List && RegExp(r'^-?[0-9]+$').hasMatch(segment)) {
          final index = int.tryParse(segment);
          if (index != null && index >= 0 && index < current.length) {
            current[index] = applyTo(current[index], offset + 1);
          }
        } else {
          throw FormatException(
            'patchBody target is not a container or parent is missing: ${entry.key}',
          );
        }
        return current;
      }

      applyTo(result, 0);
    }
    return result;
  }

  static List<String> _fieldPath(String path, {bool allowWildcard = false}) {
    if ((!allowWildcard && path.contains('[*]')) ||
        !RegExp(
          r'^(?:[^.\[\]]+|\[(?:\*|0|[1-9][0-9]*)\])(?:\[(?:\*|0|[1-9][0-9]*)\]|\.[^.\[\]]+)*$',
        ).hasMatch(path)) {
      throw FormatException('invalid field path: $path');
    }
    var normalized = path.replaceAllMapped(
      RegExp(r'\[(\*|0|[1-9][0-9]*)\]'),
      (match) => match[1] == '*' ? '.[*]' : '.${match[1]}',
    );
    if (path.startsWith('[') && normalized.startsWith('.')) {
      normalized = normalized.substring(1);
    }
    final segments = normalized.split('.');
    if (segments.any((segment) => segment.trim().isEmpty)) {
      throw FormatException('invalid field path: $path');
    }
    return segments;
  }

  static dynamic _decodeRequestBody(dynamic body) {
    if (body is! String) return body;
    try {
      return jsonDecode(body);
    } on FormatException {
      if (!body.contains('=')) return null;
      try {
        return Uri.splitQueryString(body);
      } on FormatException {
        return null;
      } on ArgumentError {
        return null;
      }
    }
  }

  Map<String, dynamic> toJson() => isRecording
      ? {
          'type': 'recording',
          'id': id,
          'name': name,
          'recordingId': recordingId,
          'enabled': enabled,
          'matchParams': matchParams,
          'rules': [for (final rule in rules) rule.toJson()],
        }
      : {
          'id': id,
          'enabled': enabled,
          'method': method,
          'path': path,
          if (host != null) 'host': host,
          'statusCode': statusCode,
          'delayMs': delayMs,
          'headers': headers,
          'body': body,
          if (params.isNotEmpty) 'params': params,
          if (patchBody.isNotEmpty) 'patchBody': patchBody,
          if (_responseText != null) 'responseText': _responseText,
          if (recordedRequest != null)
            'recordedRequest': recordedRequest!.toJson(),
        };

  /// Parses the entire list before use, rejecting duplicate IDs.
  static List<MockRule> parseList(
    dynamic value, {
    bool matchRecordedParams = true,
  }) {
    if (value is! List) {
      throw const FormatException('rules must be a JSON array');
    }
    final ids = <String>{};
    final rules = <MockRule>[];
    for (final item in value) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('each rule must be an object');
      }
      final rule = MockRule.fromJson(
        item,
        matchRecordedParams: matchRecordedParams,
      );
      if (!ids.add(rule.id)) {
        throw FormatException('duplicate rule ID: ${rule.id}');
      }
      rules.add(rule);
    }
    return List.unmodifiable(rules);
  }
}
