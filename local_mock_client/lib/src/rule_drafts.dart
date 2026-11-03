import 'dart:convert';

import 'package:local_mock_core/local_mock_core.dart';

import 'format.dart';
import 'json_paths.dart';
import 'rule_book.dart';

String _uniqueId(String base, Set<String> taken) {
  if (!taken.contains(base)) return base;
  var suffix = 2;
  while (taken.contains('$base-$suffix')) {
    suffix++;
  }
  return '$base-$suffix';
}

/// A blank response rule.
Rule blankRule(String id) => {
  'id': id,
  'enabled': true,
  'method': 'GET',
  'path': '/',
  'statusCode': 200,
  'delayMs': 0,
  'body': <String, dynamic>{},
};

/// A response rule pre-filled from one captured request.
///
/// JSON responses become the rule body as-is; other text is kept as a string
/// body. The id is derived from the path and made unique.
Rule ruleFromTraffic(
  Map<String, dynamic> entry, {
  required Set<String> existingIds,
}) {
  dynamic body;
  final text = entry['responseBody'] as String?;
  if (text != null && text.isNotEmpty) {
    try {
      body = jsonDecode(text);
    } on FormatException {
      body = text;
    }
  }
  final path = '${entry['path'] ?? '/'}';
  final host = entry['host'] as String?;
  return {
    'id': _uniqueId(_idFromPath(path), existingIds),
    'enabled': true,
    'method': '${entry['method'] ?? 'GET'}'.toUpperCase(),
    'path': path,
    if (host != null && host.isNotEmpty) 'host': host,
    'statusCode': entry['statusCode'] as int? ?? 200,
    'delayMs': 0,
    if (body != null) 'body': body,
  };
}

String _idFromPath(String path) {
  final segments = path
      .split(RegExp(r'[^a-zA-Z0-9]+'))
      .where((segment) => segment.isNotEmpty);
  if (segments.isEmpty) return 'capture';
  final joined = segments.take(4).join('-').toLowerCase();
  return joined.length > 40 ? joined.substring(0, 40) : joined;
}

/// The recording group for [session]: the existing group created from the
/// same recording (so earlier edits are kept), otherwise a fresh one.
({Rule group, bool isNew}) groupForSession(
  TrafficSession session,
  RuleBook book,
) {
  for (final rule in book.recordingGroups) {
    if (rule['recordingId'] == session.id) return (group: rule, isNew: false);
  }
  final id = _uniqueId('recording-${session.id}', book.ids);
  return (
    group: recordingMockFromSession(session, id: id).toJson(),
    isNew: true,
  );
}

bool isPatchRule(Rule rule) =>
    rule['patchBody'] is Map && (rule['patchBody'] as Map).isNotEmpty;

bool isGroup(Rule rule) => rule['type'] == 'recording';

List<Rule> groupChildren(Rule group) =>
    (group['rules'] as List?)?.cast<Map<String, dynamic>>() ?? const [];

/// One parameter a captured request carried, offered as a `params` condition.
typedef ParamCandidate = ({
  String key,
  Object? value,
  bool fromQuery,
  bool topLevel,
});

/// Parameters of [entry]: URL query first, then JSON (flattened to field
/// paths) or URL-encoded form body. Keys present in the query are not
/// repeated from the body, matching how `params` looks them up.
List<ParamCandidate> requestParams(Map<String, dynamic> entry) {
  final result = <ParamCandidate>[];
  final seen = <String>{};
  try {
    final query = Uri.parse('${entry['uri'] ?? ''}').queryParametersAll;
    for (final MapEntry(:key, :value) in query.entries) {
      if (key.isEmpty || value.isEmpty || !seen.add(key)) continue;
      result.add((
        key: key,
        value: value.first,
        fromQuery: true,
        topLevel: true,
      ));
    }
  } on FormatException {
    // Malformed query escapes: offer body parameters only.
  }
  final body = entry['requestBody'];
  if (body is! String || body.isEmpty) return result;
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    if (body.contains('=')) {
      try {
        decoded = Uri.splitQueryString(body);
      } on FormatException {
        return result;
      } on ArgumentError {
        return result;
      }
    }
  }
  if (decoded is! Map) return result;
  for (final (path, value) in leaves(decoded)) {
    if (!isAddressable(path)) continue;
    final key = formatPath(path);
    if (!seen.add(key)) continue;
    result.add((
      key: key,
      value: value,
      fromQuery: false,
      topLevel: path.length == 1,
    ));
  }
  return result;
}

/// The response to write patches against: the sample request's response
/// when it is JSON, otherwise the JSON stored in [rule].
({Object? json, String label})? referenceResponse(
  Rule rule,
  Map<String, dynamic>? sample,
) {
  final captured = sample?['responseBody'];
  if (captured is String) {
    try {
      final json = jsonDecode(captured);
      if (json is Map || json is List) {
        return (
          json: json,
          label: '抓包响应 · ${formatClock(sample!['startedAt'] as int? ?? 0)}',
        );
      }
    } on FormatException {
      // Not JSON; fall back to the stored body.
    }
  }
  Object? stored = rule['body'];
  if (stored is String) {
    try {
      stored = jsonDecode(stored);
    } on FormatException {
      stored = null;
    }
  }
  if (stored is Map || stored is List) {
    return (json: stored, label: '规则中保存的响应');
  }
  return null;
}
