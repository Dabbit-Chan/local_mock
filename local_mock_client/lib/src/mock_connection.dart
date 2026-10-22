import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:local_mock_core/local_mock_core.dart';
import 'package:local_mock_transport/local_mock_transport.dart';

class MockTarget {
  const MockTarget(
    this.id,
    this.name, {
    this.supportsCapture = true,
    this.online = true,
  });
  final String id;
  final String name;
  final bool supportsCapture;
  final bool online;
}

/// The browser connects to the same local endpoint as the app.
class MockConnection extends ChangeNotifier {
  RelayPeer? _peer;
  bool _working = false;
  bool _disposed = false;
  int _generation = 0;
  String _status = '未连接服务';
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
  Future<void>? _draining;
  bool _autoReconnect = false;
  Timer? _retry;

  static const _reconnectDelay = Duration(seconds: 2);

  bool get connected => _peer != null;
  bool get working => _working;
  bool get ready =>
      connected &&
      _selectedId != null &&
      _targets.any((t) => t.id == _selectedId && t.online) &&
      !_working;
  String get status => _status;
  List<MockTarget> get targets => _targets;
  String? get selectedId => _selectedId;
  int? get remoteRuleCount => _remoteRuleCount;
  bool get captureAvailable => _selectedId != null;
  bool get captureLive => _captureLive;
  List<Map<String, dynamic>> get traffic => _traffic;
  List<Map<String, dynamic>> get rules => _rules;
  int get rulesRevision => _rulesRevision;

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
    _status = '正在连接服务…';
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
      _status = '已连接服务，请选择在线设备';
      _notify();
      unawaited(
        peer.done.then((_) {
          if (_peer != peer) return;
          final retry = _autoReconnect;
          disconnect();
          _status = retry ? '服务连接已断开，自动重连中…' : '服务连接已断开，请重新连接';
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
        _status = retry ? '连接失败：$error，自动重连中…' : '连接失败：$error';
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
        return MockTarget(
          d['id'] as String,
          d['name'] as String,
          online: d['online'] == true,
        );
      }).toList();
      if (_selectedId != null &&
          !_targets.any((t) => t.id == _selectedId && t.online)) {
        _status = '设备已离线，保留规则与抓包记录';
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
    _session = data['sessionId'] as String;
    _epoch = data['epoch'] as int;
    final incoming = (data['entries'] as List).cast<Map<String, dynamic>>();
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
    _rules = (state['rules'] as List).cast<Map<String, dynamic>>();
    _remoteRuleCount = _rules.length;
    _rulesRevision++;
  }

  Future<Map<String, dynamic>> _command(
    String method, [
    Map<String, dynamic> args = const {},
  ]) {
    final peer = _peer;
    if (peer == null || _selectedId == null) throw StateError('请先连接并选择在线设备');
    return peer.request('command', {
      'deviceId': _selectedId,
      'method': method,
      'args': args,
    });
  }

  Future<void> selectTarget(String id) async {
    if (!connected || _working) return;
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
        _status = '读取设备失败：$error';
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
    _rules = MockRule.parseList(
      jsonDecode(text),
    ).map((r) => r.toJson()).toList();
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
    _working = true;
    _notify();
    try {
      int version;
      do {
        version = _editVersion;
        final state = await _command('replaceRules', {'rules': _rules});
        if (generation != _generation) return;
        _remoteRuleCount = (state['rules'] as List).length;
        _status = '已确认应用 $_remoteRuleCount 条规则，下一次请求生效';
      } while (version != _editVersion);
    } catch (error) {
      if (generation == _generation) _status = '同步失败：$error';
      rethrow;
    } finally {
      if (generation == _generation) {
        _working = false;
        _notify();
      }
    }
  }

  Future<void> apply(String text) async {
    if (!ready) throw StateError('请先选择就绪设备');
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

  Future<void> clearTraffic() async {
    if (!ready) throw StateError('请先选择就绪设备');
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
    _generation++;
    _retry?.cancel();
    _retry = null;
    _peer?.close();
    _peer = null;
    _working = false;
    _targets = [];
    _selectedId = null;
    _remoteRuleCount = null;
    _status = '未连接服务';
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    disconnect();
    super.dispose();
  }
}
