import 'dart:convert';

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
  });

  factory MockRule.fromJson(Map<String, dynamic> json) {
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
    final enabled = json['enabled'] ?? true;
    if (enabled is! bool) {
      throw const FormatException('enabled must be a boolean');
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
      _fieldPath(path);
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
      final segments = _fieldPath(entry.key);
      dynamic parent = result;
      for (final segment in segments.take(segments.length - 1)) {
        if (parent is Map && parent.containsKey(segment)) {
          parent = parent[segment];
        } else if (parent is List && _listIndex(segment, parent) != null) {
          parent = parent[_listIndex(segment, parent)!];
        } else {
          throw FormatException(
            'patchBody parent does not exist: ${entry.key}',
          );
        }
      }
      final leaf = segments.last;
      final value = jsonDecode(jsonEncode(entry.value));
      if (parent is Map) {
        parent[leaf] = value;
      } else if (parent is List && _listIndex(leaf, parent) != null) {
        parent[_listIndex(leaf, parent)!] = value;
      } else {
        throw FormatException(
          'patchBody target is not a container: ${entry.key}',
        );
      }
    }
    return result;
  }

  static int? _listIndex(String segment, List<dynamic> list) {
    final index = int.tryParse(segment);
    return index != null && index >= 0 && index < list.length ? index : null;
  }

  static List<String> _fieldPath(String path) {
    if (!RegExp(
      r'^(?:[^.\[\]]+|\[(?:0|[1-9][0-9]*)\])(?:\[(?:0|[1-9][0-9]*)\]|\.[^.\[\]]+)*$',
    ).hasMatch(path)) {
      throw FormatException('invalid field path: $path');
    }
    var normalized = path.replaceAllMapped(
      RegExp(r'\[(0|[1-9][0-9]*)\]'),
      (match) => '.${match[1]}',
    );
    if (path.startsWith('[') && normalized.startsWith('.')) {
      normalized = normalized.substring(1);
    }
    final segments = normalized.split('.');
    if (segments.any((segment) => segment.trim().isEmpty) ||
        normalized.contains(RegExp(r'[\[\]]'))) {
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

  Map<String, dynamic> toJson() => {
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
  };

  /// Parses the entire list before use, rejecting duplicate IDs.
  static List<MockRule> parseList(dynamic value) {
    if (value is! List) {
      throw const FormatException('rules must be a JSON array');
    }
    final ids = <String>{};
    final rules = <MockRule>[];
    for (final item in value) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('each rule must be an object');
      }
      final rule = MockRule.fromJson(item);
      if (!ids.add(rule.id)) {
        throw FormatException('duplicate rule ID: ${rule.id}');
      }
      rules.add(rule);
    }
    return List.unmodifiable(rules);
  }
}
