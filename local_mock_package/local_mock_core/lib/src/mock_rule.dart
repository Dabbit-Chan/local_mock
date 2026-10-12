import 'dart:convert';

/// A JSON response matched by method, URI path, and optional hostname.
/// Query parameters are deliberately ignored. The first enabled match wins.
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

  /// Response headers for adapters: lowercase names, JSON Content-Type by
  /// default (overridable by [headers]).
  Map<String, String> get responseHeaders => {
    'content-type': 'application/json; charset=utf-8',
    for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
  };

  /// Fresh deep copy of [body] so callers can mutate it safely.
  dynamic get bodyCopy => jsonDecode(jsonEncode(body));

  bool matches(String requestMethod, Uri uri) =>
      enabled &&
      method == requestMethod.toUpperCase() &&
      path == uri.path &&
      (host == null || host == uri.host.toLowerCase());

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
