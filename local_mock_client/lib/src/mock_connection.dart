import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:local_mock_core/local_mock_core.dart';
import 'package:local_mock_transport/local_mock_transport.dart';

import 'format.dart';

class MockTarget {
  const MockTarget(
    this.id,
    this.name, {
    this.supportsCapture = true,
    this.online = true,
    this.sessionId,
  });
  final String id;
  final String name;
  final bool supportsCapture;
  final bool online;
  final String? sessionId;
}

/// The browser connects to the same local endpoint as the app.
class MockConnection extends ChangeNotifier {
  RelayPeer? _peer;
  bool _working = false;
  bool _syncingRules = false;
  bool _disposed = false;
  int _generation = 0;
  String _status = '未连接 Relay';
  List<MockTarget> _targets = [];
  String? _selectedId;
  int? _remoteRuleCount;
  bool _captureLive = false;
  List<Map<String, dynamic>> _traffic = [];
  List<Map<String, dynamic>> _rules = [];
  int _rulesRevision = 0;
  int _editVersion = 0;
  int _epoch = -1;
  String? _session;
  final _appSessions = <String, String>{};
  Future<void>? _draining;
  bool _autoReconnect = false;
  Timer? _retry;
  bool _supportsRecordingMocks = false;
  String? _recordingName;
  MockTarget? _recordingTarget;
  String? _recordingAppSession;
  int _recordingStartedAt = 0;
  int _recordingRevision = 0;
  List<TrafficEntry> _recorded = [];
  TrafficSession? _pendingRecording;

  static const _reconnectDelay = Duration(seconds: 2);

  bool get connected => _peer != null;
  bool get working => _working;
  bool get syncingRules => _syncingRules;
  bool get ready =>
      connected &&
      _selectedId != null &&
      _targets.any((t) => t.id == _selectedId && t.online) &&
      !_working;
  String get status => _status;
  List<MockTarget> get targets => _targets;
  String? get selectedId => _selectedId;
  String? get appSession => _appSessions[_selectedId];
  int? get remoteRuleCount => _remoteRuleCount;
  bool get captureAvailable => _selectedId != null;
  bool get captureLive => _captureLive;
  List<Map<String, dynamic>> get traffic => _traffic;
  List<Map<String, dynamic>> get rules => _rules;
  int get rulesRevision => _rulesRevision;
  bool get supportsRecordingMocks => _supportsRecordingMocks;
  bool get recording => _recordingName != null;
  String? get recordingName => _recordingName;
  int get recordedCount => _recorded.length;
  TrafficSession? get pendingRecording => _pendingRecording;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> connect(String address, {bool autoReconnect = false}) async {
    _autoReconnect = autoReconnect;
    _retry?.cancel();
    _retry = null;
    final uri = relayUri(address, 'console');
    disconnect();
    final generation = _generation;
    _working = true;
    _status = '正在连接 Relay…';
    _notify();
    try {
      final peer = await RelayPeer.connect(
        uri,
        hello: const {},
        onEvent: (event) {
          if (generation == _generation) _event(event);
        },
      );
      if (_disposed || generation != _generation) {
        peer.close();
        return;
      }
      _peer = peer;
      _event({'event': 'devices', ...peer.helloResult});
      _working = false;
      _status = '已连接 Relay';
      _notify();
      unawaited(
        peer.done.then((_) {
          if (_peer != peer) return;
          final retry = _autoReconnect;
          disconnect();
          _status = retry ? 'Relay 连接已断开，正在重连…' : 'Relay 连接已断开';
          _notify();
          if (retry) _scheduleRetry(address);
        }),
      );
      // Device events can arrive during the initial handshake.
      if (_targets.where((t) => t.online).length == 1) {
        await selectTarget(_targets.singleWhere((t) => t.online).id);
      }
    } catch (error) {
      final retry = _autoReconnect && generation == _generation && !_disposed;
      if (generation == _generation && !_disposed) {
        disconnect();
        _status = retry
            ? '无法连接 Relay（${describeError(error)}），2 秒后重试'
            : '无法连接 Relay（${describeError(error)}）';
        _notify();
      }
      if (retry) _scheduleRetry(address);
      rethrow;
    }
  }

  /// Keeps the console attached to its relay: [connect] retries every few
  /// seconds until it succeeds, and a dropped link schedules the next attempt.
  /// A manual [disconnect] (or dispose) cancels the pending timer.
  void _scheduleRetry(String address) {
    if (_disposed) return;
    _retry?.cancel();
    _retry = Timer(_reconnectDelay, () {
      if (_disposed) return;
      unawaited(connect(address, autoReconnect: true).catchError((_) {}));
    });
  }

  void _event(Map<String, dynamic> event) {
    if (_disposed) return;
    if (event['event'] == 'devices') {
      final wasOnline = _targets.any((t) => t.id == _selectedId && t.online);
      _targets = (event['devices'] as List).map((value) {
        final d = value as Map;
        final id = d['id'] as String;
        final session = d['sessionId'] as String?;
        if (session != null) _appSessions[id] = session;
        return MockTarget(
          id,
          d['name'] as String,
          online: d['online'] == true,
          sessionId: session,
        );
      }).toList();
      if (_selectedId != null &&
          !_targets.any((t) => t.id == _selectedId && t.online)) {
        if (recording) stopRecording();
        _status = '设备已离线，显示的是断开前的数据';
      } else if (_selectedId != null && !_working) {
        _status = '设备在线';
      }
      _notify();
      if (connected &&
          !_working &&
          !wasOnline &&
          _selectedId != null &&
          _targets.any((t) => t.id == _selectedId && t.online)) {
        unawaited(selectTarget(_selectedId!).catchError((Object _) {}));
      }
      if (connected &&
          !_working &&
          _selectedId == null &&
          _targets.where((t) => t.online).length == 1) {
        unawaited(
          selectTarget(
            _targets.singleWhere((t) => t.online).id,
          ).catchError((Object _) {}),
        );
      }
    } else if (event['deviceId'] == _selectedId) {
      if (event['event'] == 'traffic') {
        _readTraffic(event, replace: false);
      } else if (event['event'] == 'state') {
        _readTraffic(event, replace: true);
        if (!_working) _adoptRules(event);
      }
      _notify();
    }
  }

  void _readTraffic(Map<String, dynamic> data, {required bool replace}) {
    final changed = _session != data['sessionId'] || _epoch != data['epoch'];
    if (recording && _recordingAppSession != data['sessionId']) {
      stopRecording();
    }
    _session = data['sessionId'] as String;
    if (_selectedId != null) _appSessions[_selectedId!] = _session!;
    _epoch = data['epoch'] as int;
    final incoming = (data['entries'] as List).cast<Map<String, dynamic>>();
    if (recording) {
      for (final entry in incoming) {
        final revision = entry['revision'] as int;
        if (revision <= _recordingRevision) continue;
        _recorded.add(TrafficEntry.fromJson(entry));
        _recordingRevision = revision;
      }
    }
    if (replace || changed) _traffic = [];
    final last = _traffic.isEmpty ? 0 : _traffic.last['revision'] as int;
    _traffic = [
      ..._traffic,
      ...incoming.where((e) => (e['revision'] as int) > last),
    ];
    if (_traffic.length > 500) {
      _traffic = _traffic.sublist(_traffic.length - 500);
    }
  }

  void _adoptRules(Map<String, dynamic> state) {
    _supportsRecordingMocks = state['supportsRecordingMocks'] == true;
    _rules = (state['rules'] as List).cast<Map<String, dynamic>>();
    _remoteRuleCount = _rules.length;
    _rulesRevision++;
  }

  Future<Map<String, dynamic>> _command(
    String method, [
    Map<String, dynamic> args = const {},
  ]) {
    final peer = _peer;
    if (peer == null || _selectedId == null) {
      throw StateError('请先连接 Relay 并选择在线设备');
    }
    return peer.request('command', {
      'deviceId': _selectedId,
      'sessionId': appSession,
      'method': method,
      'args': args,
    });
  }

  Future<void> selectTarget(String id) async {
    if (!connected || _working) return;
    if (recording && id != _selectedId) {
      throw StateError('正在录制另一台设备，请先停止录制');
    }
    if (!_targets.any((t) => t.id == id && t.online)) throw StateError('设备已离线');
    final generation = _generation;
    final previousId = _selectedId;
    _selectedId = id;
    _working = true;
    _status = '正在读取设备状态…';
    _notify();
    try {
      final state = await _command('getState');
      if (generation != _generation) return;
      _adoptRules(state);
      _readTraffic(state, replace: true);
      _status = '已就绪';
    } catch (error) {
      if (generation == _generation) {
        _selectedId = previousId;
        _status = '读取设备失败：${describeError(error)}';
      }
      rethrow;
    } finally {
      if (generation == _generation) {
        _working = false;
        _notify();
      }
    }
  }

  Future<void> updateRules(String text) async {
    final parsed = MockRule.parseList(jsonDecode(text));
    if (ready &&
        !_supportsRecordingMocks &&
        parsed.any((rule) => rule.isRecording)) {
      throw StateError(
        '设备上的 local_mock 版本不支持录制组，请升级 App 中的 local_mock_core 和适配器',
      );
    }
    _rules = parsed.map((rule) => rule.toJson()).toList();
    _editVersion++;
    if (_draining != null) return _draining;
    if (!ready) return;
    final task = _flushRules();
    _draining = task;
    try {
      await task;
    } finally {
      _draining = null;
    }
  }

  Future<void> _flushRules() async {
    final generation = _generation;
    final deviceId = _selectedId;
    final session = appSession;
    _working = true;
    _syncingRules = true;
    _notify();
    try {
      int version;
      do {
        if (_selectedId != deviceId || appSession != session) {
          throw StateError('App 会话已变化，请重新同步到设备');
        }
        version = _editVersion;
        final state = await _command('replaceRules', {'rules': _rules});
        if (generation != _generation ||
            _selectedId != deviceId ||
            appSession != session) {
          throw StateError('App 会话或 Relay 连接已变化，请重新同步到设备');
        }
        _remoteRuleCount = (state['rules'] as List).length;
        _status = '设备已确认 $_remoteRuleCount 条规则，从下一个请求开始生效';
      } while (version != _editVersion);
    } catch (error) {
      if (generation == _generation) _status = '同步失败：${describeError(error)}';
      rethrow;
    } finally {
      if (generation == _generation) {
        _working = false;
        _syncingRules = false;
        _notify();
      }
    }
  }

  Future<void> apply(String text) async {
    if (!ready) throw StateError('设备未就绪');
    await updateRules(text);
  }

  Future<void> clear() async {
    await apply('[]');
    _rulesRevision++;
    _notify();
  }

  void setCaptureLive(bool value) {
    _captureLive = value;
    _notify();
  }

  void startRecording(String name) {
    if (!ready || !captureAvailable) throw StateError('设备未就绪');
    if (recording) throw StateError('已经在录制');
    if (_pendingRecording != null) throw StateError('上一段录制尚未保存，请先保存或导出');
    if (name.trim().isEmpty) throw const FormatException('请输入录制名称');
    _recordingName = name.trim();
    _recordingTarget = _targets.singleWhere(
      (target) => target.id == _selectedId,
    );
    _recordingAppSession = _session;
    _recordingStartedAt = DateTime.now().millisecondsSinceEpoch;
    _recordingRevision = _traffic.isEmpty
        ? 0
        : _traffic.last['revision'] as int;
    _recorded = [];
    _notify();
  }

  TrafficSession stopRecording() {
    if (!recording) {
      final pending = _pendingRecording;
      if (pending != null) return pending;
      throw StateError('没有正在进行的录制');
    }
    final target = _recordingTarget!;
    final stoppedAt = DateTime.now().millisecondsSinceEpoch;
    final session = TrafficSession(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      name: _recordingName!,
      deviceId: target.id,
      deviceName: target.name,
      startedAt: _recordingStartedAt,
      endedAt: stoppedAt < _recordingStartedAt
          ? _recordingStartedAt
          : stoppedAt,
      entries: _recorded,
    );
    _pendingRecording = session;
    _recordingName = null;
    _recordingTarget = null;
    _recordingAppSession = null;
    _notify();
    return session;
  }

  void acknowledgeRecording(String id) {
    if (_pendingRecording?.id != id) return;
    _pendingRecording = null;
    _recorded = [];
    _notify();
  }

  Future<void> clearTraffic() async {
    if (!ready) throw StateError('设备未就绪');
    final generation = _generation;
    _working = true;
    _notify();
    try {
      final state = await _command('clearTraffic');
      if (generation == _generation) _readTraffic(state, replace: true);
    } finally {
      if (generation == _generation) {
        _working = false;
        _notify();
      }
    }
  }

  void disconnect() {
    if (recording) stopRecording();
    _generation++;
    _retry?.cancel();
    _retry = null;
    _peer?.close();
    _peer = null;
    _working = false;
    _syncingRules = false;
    _targets = [];
    _selectedId = null;
    _remoteRuleCount = null;
    _supportsRecordingMocks = false;
    _status = '未连接 Relay';
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    disconnect();
    super.dispose();
  }
}
