import 'dart:convert';

/// Turns any thrown object into one readable line.
///
/// Strips Dart's `Bad state:` / `FormatException:` prefixes and multi-line
/// source excerpts so messages fit in a status line.
String describeError(Object error) {
  var text = switch (error) {
    FormatException(:final message) => message,
    StateError(:final message) => message,
    ArgumentError(:final message) => '$message',
    UnsupportedError(:final message) => message ?? '$error',
    _ => '$error',
  };
  text = text.split('\n').first.trim();
  for (final prefix in ['Exception: ', 'Bad state: ', 'FormatException: ']) {
    if (text.startsWith(prefix)) text = text.substring(prefix.length);
  }
  return text.isEmpty ? '未知错误' : text;
}

String _two(int value) => '$value'.padLeft(2, '0');

/// `14:03:27`
String formatClock(int millis) {
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';
}

/// `2026-11-02 14:03`
String formatDateTime(int millis) {
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${time.year}-${_two(time.month)}-${_two(time.day)} '
      '${_two(time.hour)}:${_two(time.minute)}';
}

String formatDuration(int millis) {
  if (millis < 1000) return '$millis ms';
  if (millis < 60000) return '${(millis / 1000).toStringAsFixed(1)} s';
  final minutes = millis ~/ 60000;
  final seconds = (millis % 60000) ~/ 1000;
  return '$minutes 分 $seconds 秒';
}

const _indent = JsonEncoder.withIndent('  ');

String prettyJson(Object? value) => _indent.convert(value);

/// Indents JSON text; anything that is not JSON is returned unchanged.
String prettyBody(String? text) {
  if (text == null) return '';
  try {
    return _indent.convert(jsonDecode(text));
  } on FormatException {
    return text;
  }
}

bool looksLikeJson(String text) {
  final trimmed = text.trimLeft();
  return trimmed.startsWith('{') || trimmed.startsWith('[');
}

/// Strips the UTF-8 BOM some editors add to saved files.
String stripBom(String text) =>
    text.startsWith('\uFEFF') ? text.substring(1) : text;

/// File-name-safe timestamp: `2026-11-02T14-03-27`.
String fileStamp([DateTime? time]) => (time ?? DateTime.now())
    .toIso8601String()
    .split('.')
    .first
    .replaceAll(':', '-');

/// The address this console was served from, i.e. the relay. Falls back to
/// the default local relay when the page has no http(s) origin.
String pageOrigin() {
  final base = Uri.base;
  return base.isScheme('http') || base.isScheme('https')
      ? base.origin
      : 'http://127.0.0.1:9090';
}
