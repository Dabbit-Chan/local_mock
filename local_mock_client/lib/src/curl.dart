/// Builds a cURL command from one captured traffic entry.
///
/// The result is POSIX-shell safe: every URL, header and body is wrapped in
/// single quotes. Headers curl computes itself (`Content-Length`) are skipped,
/// because a stale value would break the replayed request.
library;

/// Placeholder bodies produced by the adapters (binary payloads, FormData…)
/// cannot be replayed, so they become a comment instead of `--data-raw`.
final _placeholder = RegExp(r'^<[^<>]*>$');

/// Wraps [value] in single quotes for a POSIX shell, escaping embedded quotes.
String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// Header values may arrive as lists from the app or as plain strings from
/// older recordings. Anything else is ignored.
List<String> _headerValues(dynamic value) => switch (value) {
  List() => [
    for (final item in value)
      if (item != null) '$item',
  ],
  String() => value.isEmpty ? const [] : [value],
  null => const [],
  _ => ['$value'],
};

String curlForEntry(Map<String, dynamic> entry) {
  final method = '${entry['method'] ?? 'GET'}'.toUpperCase();
  final uri = '${entry['uri'] ?? ''}';
  final parts = <String>['curl', '-X $method', shellQuote(uri)];

  final headers = entry['requestHeaders'];
  if (headers is Map) {
    for (final header in headers.entries) {
      final name = '${header.key}';
      if (name.toLowerCase() == 'content-length') continue;
      for (final value in _headerValues(header.value)) {
        parts.add('-H ${shellQuote('$name: $value')}');
      }
    }
  }

  final body = entry['requestBody'];
  final comment = body is String && _placeholder.hasMatch(body.trim())
      ? '# 请求体未能捕获（$body），需要用原始请求参数手动补全'
      : null;
  if (body is String && body.isNotEmpty && comment == null) {
    parts.add('--data-raw ${shellQuote(body)}');
  }

  final command = parts.join(' ');
  return comment == null ? command : '$comment\n$command';
}
