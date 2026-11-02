import 'traffic.dart';

final class TrafficSession {
  TrafficSession({
    required this.id,
    required this.name,
    required this.deviceId,
    required this.deviceName,
    required this.startedAt,
    required this.endedAt,
    required List<TrafficEntry> entries,
  }) : entries = List.unmodifiable(entries);

  factory TrafficSession.fromJson(dynamic value) {
    if (value is! Map<String, dynamic> ||
        value['format'] != 'local_mock_capture' ||
        value['version'] != 1) {
      throw const FormatException('不是受支持的 local_mock 录制文件');
    }
    String text(String key) {
      final text = value[key];
      if (text is! String || text.trim().isEmpty) {
        throw FormatException('录制的 $key 必须是非空字符串');
      }
      return text;
    }

    final startedAt = value['startedAt'];
    final endedAt = value['endedAt'];
    final rawEntries = value['entries'];
    if (startedAt is! int ||
        endedAt is! int ||
        startedAt < 0 ||
        endedAt < startedAt ||
        rawEntries is! List) {
      throw const FormatException('录制时间或请求列表无效');
    }
    final entries = <TrafficEntry>[];
    for (final raw in rawEntries) {
      if (raw is! Map<String, dynamic> ||
          raw['revision'] is! int ||
          (raw['revision'] as int) < 0 ||
          raw['startedAt'] is! int ||
          (raw['startedAt'] as int) < 0 ||
          raw['durationMs'] is! int ||
          (raw['durationMs'] as int) < 0 ||
          raw['mocked'] is! bool ||
          raw['method'] is! String ||
          !RegExp(r'^[A-Za-z]+$').hasMatch(raw['method'] as String) ||
          raw['uri'] is! String ||
          raw['path'] is! String) {
        throw const FormatException('录制中包含无效的请求');
      }
      for (final key in [
        'host',
        'requestBody',
        'responseBody',
        'contentType',
        'error',
      ]) {
        if (raw[key] != null && raw[key] is! String) {
          throw FormatException('请求的 $key 必须是字符串');
        }
      }
      final status = raw['statusCode'];
      if (status != null && (status is! int || status < 100 || status > 599)) {
        throw const FormatException('请求的状态码无效');
      }
      final uri = Uri.tryParse(raw['uri'] as String);
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.path != raw['path'] ||
          uri.hasFragment ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException('请求的 URL 无效');
      }
      try {
        uri.queryParametersAll;
      } on FormatException {
        throw const FormatException('请求的 query 编码无效');
      } on ArgumentError {
        throw const FormatException('请求的 query 编码无效');
      }
      entries.add(TrafficEntry.fromJson(raw));
    }
    return TrafficSession(
      id: text('id'),
      name: text('name'),
      deviceId: text('deviceId'),
      deviceName: text('deviceName'),
      startedAt: startedAt,
      endedAt: endedAt,
      entries: entries,
    );
  }

  final String id;
  final String name;
  final String deviceId;
  final String deviceName;
  final int startedAt;
  final int endedAt;
  final List<TrafficEntry> entries;

  List<TrafficEntry> get replayableEntries => [
    for (final entry in entries)
      if (entry.error == null &&
          entry.statusCode != null &&
          (entry.responseBody != null ||
              entry.method.toUpperCase() == 'HEAD' ||
              entry.statusCode == 204 ||
              entry.statusCode == 304) &&
          !_placeholder(entry.requestBody) &&
          !_placeholder(entry.responseBody))
        entry,
  ];

  static bool _placeholder(String? text) =>
      text != null &&
      RegExp(r'^<(?:binary \d+ bytes|\d+ bytes|FormData:.*)>$').hasMatch(text);

  Map<String, dynamic> toJson() => {
    'format': 'local_mock_capture',
    'version': 1,
    'id': id,
    'name': name,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'startedAt': startedAt,
    'endedAt': endedAt,
    'entries': [for (final entry in entries) entry.toJson()],
  };
}
