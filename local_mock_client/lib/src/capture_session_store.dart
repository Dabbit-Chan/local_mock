import 'dart:convert';

import 'package:local_mock_core/local_mock_core.dart';

import 'capture_session_store_stub.dart'
    if (dart.library.js_interop) 'capture_session_store_web.dart'
    as platform;
import 'rule_file_transfer_stub.dart'
    if (dart.library.js_interop) 'rule_file_transfer_web.dart'
    as files;

class CaptureSessionStore {
  const CaptureSessionStore();

  Future<List<TrafficSession>> load() async {
    final text = platform.readSessions();
    if (text == null) return [];
    final value = jsonDecode(text);
    if (value is! List) throw const FormatException('本地录制列表无效');
    final sessions = value.map(TrafficSession.fromJson).toList();
    if (sessions.map((session) => session.id).toSet().length !=
        sessions.length) {
      throw const FormatException('本地录制 ID 重复');
    }
    return sessions;
  }

  Future<void> save(List<TrafficSession> sessions) async =>
      platform.writeSessions(
        jsonEncode([for (final session in sessions) session.toJson()]),
      );

  Future<TrafficSession?> importSession() async {
    final text = await files.pickRules();
    if (text == null) return null;
    return TrafficSession.fromJson(
      jsonDecode(text.startsWith('\uFEFF') ? text.substring(1) : text),
    );
  }

  Future<void> exportSession(TrafficSession session) => files.saveRules(
    'mock-capture-${session.id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')}.json',
    const JsonEncoder.withIndent('  ').convert(session.toJson()),
  );
}
