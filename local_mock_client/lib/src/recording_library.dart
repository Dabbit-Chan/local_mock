import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:local_mock_core/local_mock_core.dart';

import 'capture_session_store.dart';
import 'format.dart';
import 'mock_connection.dart';

/// Recordings saved in this browser, plus the hand-off of a finished
/// recording from [MockConnection] into storage.
///
/// Lives for the whole page so a recording keeps saving while the user moves
/// between routes.
class RecordingLibrary extends ChangeNotifier {
  RecordingLibrary({required this.connection, required this.store}) {
    connection.addListener(_connectionChanged);
  }

  final MockConnection connection;
  final CaptureSessionStore store;

  List<TrafficSession> _sessions = [];
  bool _loaded = false;
  bool _saving = false;
  String? _attemptedSave;
  String? _loadError;
  String? _saveError;
  final _saved = StreamController<TrafficSession>.broadcast();

  List<TrafficSession> get sessions => _sessions;
  bool get loaded => _loaded;
  String? get loadError => _loadError;

  /// Why the last finished recording could not be stored; the recording
  /// stays in [MockConnection.pendingRecording] until saved or exported.
  String? get saveError => _saveError;
  bool get saving => _saving;

  /// Emits every recording that was stored successfully.
  Stream<TrafficSession> get saved => _saved.stream;

  TrafficSession? byId(String id) {
    for (final session in _sessions) {
      if (session.id == id) return session;
    }
    return null;
  }

  Future<void> load() async {
    try {
      _sessions = await store.load();
      _loaded = true;
      _loadError = null;
    } catch (error) {
      _loadError = '读取本地录制失败：${describeError(error)}';
    }
    notifyListeners();
    _connectionChanged();
  }

  Future<void> _persist(List<TrafficSession> sessions) async {
    if (!_loaded) throw StateError('本地录制尚未读取成功');
    await store.save(sessions);
    _sessions = sessions;
    notifyListeners();
  }

  void _connectionChanged() {
    final pending = connection.pendingRecording;
    if (_loaded &&
        !_saving &&
        pending != null &&
        _attemptedSave != pending.id) {
      unawaited(savePending());
    }
  }

  /// Stores the finished recording. Automatic attempts happen once per
  /// recording; afterwards the user retries explicitly.
  Future<void> savePending() async {
    final session = connection.pendingRecording;
    if (session == null || _saving) return;
    _saving = true;
    _attemptedSave = session.id;
    notifyListeners();
    try {
      await _persist([
        session,
        ..._sessions.where((saved) => saved.id != session.id),
      ]);
      _saveError = null;
      connection.acknowledgeRecording(session.id);
      _saved.add(session);
    } catch (error) {
      _saveError = describeError(error);
    } finally {
      _saving = false;
      notifyListeners();
    }
  }

  /// Downloads the unsaved recording as a file and drops it from memory.
  Future<void> exportPending() async {
    final session = connection.pendingRecording;
    if (session == null) return;
    await store.exportSession(session);
    _saveError = null;
    connection.acknowledgeRecording(session.id);
    notifyListeners();
  }

  /// Returns the imported recording, or null when the picker was cancelled.
  Future<TrafficSession?> importFile() async {
    final session = await store.importSession();
    if (session == null) return null;
    if (byId(session.id) != null) {
      throw StateError('已存在同一录制（ID ${session.id}），如需覆盖请先删除旧的');
    }
    await _persist([session, ..._sessions]);
    return session;
  }

  Future<void> export(TrafficSession session) => store.exportSession(session);

  Future<void> delete(TrafficSession session) =>
      _persist(_sessions.where((saved) => saved.id != session.id).toList());

  @override
  void dispose() {
    connection.removeListener(_connectionChanged);
    unawaited(_saved.close());
    super.dispose();
  }
}
