import 'dart:convert';

final class RecordedRequest {
  RecordedRequest._(this.query, this.body);

  factory RecordedRequest.fromJson(dynamic value) {
    if (value is! Map<String, dynamic> ||
        value['query'] is! Map<String, dynamic> ||
        (value['body'] != null && value['body'] is! String)) {
      throw const FormatException(
        'recordedRequest must contain query and optional body text',
      );
    }
    final query = <String, List<String>>{};
    for (final entry in (value['query'] as Map<String, dynamic>).entries) {
      if (entry.value is! List ||
          (entry.value as List).any((item) => item is! String)) {
        throw const FormatException(
          'recorded query values must be string arrays',
        );
      }
      query[entry.key] = List.unmodifiable(
        (entry.value as List).cast<String>(),
      );
    }
    return RecordedRequest._(Map.unmodifiable(query), value['body'] as String?);
  }

  final Map<String, List<String>> query;
  final String? body;

  String get signature => jsonEncode([_canonical(query), _bodyKey(body)]);

  bool matches(Uri uri, dynamic requestBody) {
    try {
      return jsonEncode(_canonical(uri.queryParametersAll)) ==
              jsonEncode(_canonical(query)) &&
          _bodyKey(requestBody) == _bodyKey(body);
    } on FormatException {
      return false;
    } on ArgumentError {
      return false;
    } on JsonUnsupportedObjectError {
      return false;
    }
  }

  Map<String, dynamic> toJson() => {
    'query': query,
    if (body != null) 'body': body,
  };

  static String _bodyKey(dynamic value) {
    if (value == null || value == '') return '';
    if (value is String) {
      try {
        value = jsonDecode(value);
      } on FormatException {
        if (value.contains('=')) {
          try {
            value = Uri.splitQueryString(value);
          } on FormatException {
            return jsonEncode(value);
          } on ArgumentError {
            return jsonEncode(value);
          }
        }
      }
    }
    return jsonEncode(_canonical(value));
  }

  static dynamic _canonical(dynamic value) {
    if (value is Map) {
      final keys = value.keys.map((key) => '$key').toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }
}
