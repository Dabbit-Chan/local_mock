import 'dart:convert';

import 'mock_rule.dart';
import 'recorded_request.dart';
import 'traffic.dart';
import 'traffic_session.dart';

MockRule recordingMockFromSession(
  TrafficSession session, {
  String? id,
  bool matchParams = false,
}) {
  final latest = <String, TrafficEntry>{};
  final entries = session.replayableEntries.toList()
    ..sort((first, second) {
      final time = first.startedAt.compareTo(second.startedAt);
      return time == 0 ? first.revision.compareTo(second.revision) : time;
    });
  for (final entry in entries) {
    final uri = Uri.parse(entry.uri);
    final request = RecordedRequest.fromJson({
      'query': uri.queryParametersAll,
      if (entry.requestBody != null) 'body': entry.requestBody,
    });
    final key = jsonEncode([
      entry.method.toUpperCase(),
      uri.host,
      uri.path,
      request.signature,
    ]);
    latest[key] = entry;
  }
  if (latest.isEmpty) throw const FormatException('录制中没有可生成 Mock 的文本响应');
  return MockRule.fromJson({
    'type': 'recording',
    'id': id ?? 'recording-${session.id}',
    'name': session.name,
    'recordingId': session.id,
    'enabled': true,
    'matchParams': matchParams,
    'rules': [
      for (final (index, entry) in latest.values.indexed)
        {
          ...MockRule.fromTraffic(entry, id: 'request-${index + 1}').toJson(),
          'recordedRequest': {
            'query': Uri.parse(entry.uri).queryParametersAll,
            if (entry.requestBody != null) 'body': entry.requestBody,
          },
        },
    ],
  });
}
