import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:local_mock_core/local_mock_core.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'vm_service_uri.dart';

class MockTarget {
  const MockTarget(this.id, this.name, {this.supportsCapture = false});

  final String id;
  final String name;
  final bool supportsCapture;
}

/// Polling discovers extensions registered after connection / hot restart.
/// The latest desktop rules are synchronized when a target becomes ready.
///
/// Traffic capture polls the app-side ring buffer with a revision cursor
/// while [setCaptureLive] is enabled and a target is selected.
class MockConnection extends ChangeNotifier {
  static const _timeout = Duration(seconds: 8);
  static const _trafficInterval = Duration(seconds: 1);

  /// Local display cap; the app-side buffer keeps fewer entries itself.
  static const _maxTrafficEntries = 500;

  VmService? _service;
  Timer? _poll;
  int _generation = 0;
  bool _disposed = false;
  bool _working = false;
  String _status = '未连接';
  List<MockTarget> _targets = const [];
  String? _selectedId;
  List<Map<String, dynamic>>? _lastApplied;
  List<Map<String, dynamic>>? _desiredRules;
  int _rulesVersion = 0;
  int? _remoteRuleCount;

  Timer? _trafficPoll;
  bool _captureLive = false;
  bool _trafficBusy = false;
  List<Map<String, dynamic>> _traffic = const [];
  int _trafficCursor = 0;
  bool _clearTrafficOnConnect = false;

  bool get connected => _service != null;
  bool get working => _working;
  bool get ready => connected && _selectedId != null && !working;
  String get status => _status;
  List<MockTarget> get targets => _targets;
  String? get selectedId => _selectedId;
  int? get remoteRuleCount => _remoteRuleCount;

  /// Whether the selected target implements the traffic extensions.
  bool get captureAvailable {
    final id = _selectedId;
    return id != null &&
        _targets.any((target) => target.id == id && target.supportsCapture);
  }

  /// Whether the UI wants live traffic (only polls while a capture-capable
  /// target is selected).
  bool get captureLive => _captureLive;

  /// Captured entries, oldest first.
  List<Map<String, dynamic>> get traffic => _traffic;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _current(VmService service) =>
      !_disposed && identical(service, _service);

  Future<void> connect(String address) async {
    final uri = normalizeVmServiceUri(address);
    disconnect();
    _resetTraffic();
    _clearTrafficOnConnect = true;
    final generation = _generation;
    _working = true;
    _status = '正在连接…';
    _notify();
    var abandoned = false;
    final opening = vmServiceConnectUri(uri.toString());
    // Future.timeout does not cancel the socket handshake; close late results.
    unawaited(
      opening.then<void>((service) {
        if (abandoned) unawaited(service.dispose());
      }, onError: (Object _, StackTrace __) {}),
    );
    try {
      final service = await opening.timeout(_timeout);
      if (_disposed || generation != _generation) {
        await service.dispose();
        return;
      }
      _service = service;
      unawaited(
        service.onDone.then((_) {
          if (!_current(service)) return;
          disconnect();
          _status = '连接已断开，请重新连接；手机上的规则不会因此清空';
          _notify();
        }),
      );
      _working = false;
      await _discover();
      if (_current(service)) {
        _poll = Timer.periodic(const Duration(seconds: 2), (_) {
          unawaited(_discover());
        });
      }
    } catch (error) {
      abandoned = true;
      if (!_disposed && generation == _generation) {
        disconnect();
        _status = '连接失败：$error';
        _notify();
      }
      rethrow;
    }
  }

  Future<void> _discover() async {
    final service = _service;
    if (service == null || _working) return;
    final version = _rulesVersion;
    _working = true;
    try {
      final vm = await service.getVM().timeout(_timeout);
      final targets = <MockTarget>[];
      for (final ref in vm.isolates ?? <IsolateRef>[]) {
        final id = ref.id;
        if (id == null) continue;
        try {
          final isolate = await service.getIsolate(id).timeout(_timeout);
          final extensions = isolate.extensionRPCs ?? <String>[];
          if ([
            LocalMockProtocol.getState,
            LocalMockProtocol.replaceRules,
            LocalMockProtocol.clear,
          ].every(extensions.contains)) {
            targets.add(
              MockTarget(
                id,
                isolate.name ?? id,
                supportsCapture: extensions.contains(
                  LocalMockProtocol.getTraffic,
                ),
              ),
            );
          }
        } on RPCError {
          // An isolate may exit between getVM and getIsolate.
        }
      }
      if (!_current(service)) return;
      _targets = List.unmodifiable(targets);
      if (!targets.any((target) => target.id == _selectedId)) {
        _selectedId = null;
        _remoteRuleCount = null;
        _resetTraffic();
        if (targets.length == 1) {
          final target = targets.single;
          await _syncTarget(service, target.id);
        } else {
          _status = targets.isEmpty
              ? '已连接，等待 App 注册 local_mock（需 Debug 模式并接入 local_mock_dio / local_mock_http）'
              : '发现多个 isolate，请选择目标';
        }
      }
    } catch (error) {
      if (_current(service)) _status = '发现 / 同步失败，将重试：$error';
    } finally {
      if (_current(service)) {
        _working = false;
        _notify();
        if (ready && version != _rulesVersion) {
          try {
            await _update(LocalMockProtocol.replaceRules, _desiredRules!);
          } catch (_) {
            // The synchronization status already contains the failure.
          }
        }
      }
    }
  }

  /// Calls an extension and validates the wire protocol version, accepting
  /// answers of any shape (rules state vs. traffic snapshot).
  Future<Map<String, dynamic>> _call(
    VmService service,
    String isolateId,
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    final response = await service
        .callServiceExtension(method, isolateId: isolateId, args: args)
        .timeout(_timeout);
    final json = response.json;
    final remote = json?['protocolVersion'];
    if (json == null || remote is! int || remote <= 0) {
      throw const FormatException('local_mock 返回了无效响应');
    }
    if (remote > LocalMockProtocol.version) {
      throw FormatException('协议版本不兼容（App 端 v$remote）');
    }
    if (remote < LocalMockProtocol.version) {
      throw const FormatException(
        'App 端 local_mock 版本过旧，请升级 local_mock_dio / local_mock_http 至 0.2.0+',
      );
    }
    return json;
  }

  Future<Map<String, dynamic>> _callState(
    VmService service,
    String isolateId,
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    final json = await _call(service, isolateId, method, args);
    if (json['rules'] is! List) {
      throw const FormatException('local_mock 返回了无效的规则状态');
    }
    return json;
  }

  Map<String, dynamic> _replaceArgs(List<Map<String, dynamic>> rules) => {
    'protocolVersion': '${LocalMockProtocol.version}',
    'rules': jsonEncode(rules),
  };

  Future<void> _syncTarget(VmService service, String id) async {
    // Check compatibility before modifying a newly discovered target.
    var state = await _callState(service, id, LocalMockProtocol.getState);
    if (!_current(service)) return;
    if (_clearTrafficOnConnect &&
        _targets.any((target) => target.id == id && target.supportsCapture)) {
      await _call(service, id, LocalMockProtocol.clearTraffic);
      if (!_current(service)) return;
    }
    _clearTrafficOnConnect = false;
    var version = _rulesVersion;
    do {
      version = _rulesVersion;
      if (_desiredRules ?? _lastApplied case final rules?) {
        state = await _callState(
          service,
          id,
          LocalMockProtocol.replaceRules,
          _replaceArgs(rules),
        );
      }
      if (!_current(service)) return;
    } while (version != _rulesVersion);
    _selectedId = id;
    _remoteRuleCount = (state['rules'] as List).length;
    _status = _desiredRules == null && _lastApplied == null
        ? '已就绪'
        : '已就绪，已自动应用全部规则';
    _syncTrafficPolling();
  }

  Future<void> selectTarget(String id) async {
    final service = _service;
    if (service == null || _working) return;
    _working = true;
    _selectedId = null;
    _remoteRuleCount = null;
    _resetTraffic();
    _notify();
    try {
      await _syncTarget(service, id);
    } finally {
      if (_current(service)) {
        _working = false;
        _notify();
      }
    }
  }

  /// Keeps edits made while disconnected or busy for the next ready target.
  Future<void> updateRules(String text) async {
    _desiredRules = MockRule.parseList(
      jsonDecode(text),
    ).map((rule) => rule.toJson()).toList();
    _rulesVersion++;
    if (ready) await _update(LocalMockProtocol.replaceRules, _desiredRules!);
  }

  Future<void> apply(String text) async {
    final rules = MockRule.parseList(jsonDecode(text));
    await _update(
      LocalMockProtocol.replaceRules,
      rules.map((rule) => rule.toJson()).toList(),
    );
  }

  Future<void> clear() => _update(LocalMockProtocol.clear, []);

  Future<void> _update(String method, List<Map<String, dynamic>> rules) async {
    final service = _service;
    final id = _selectedId;
    if (!ready || service == null || id == null) {
      throw StateError('请先连接并选择就绪的 isolate');
    }
    final version = _rulesVersion;
    _working = true;
    _status = '正在同步…';
    _notify();
    try {
      final state = await _callState(
        service,
        id,
        method,
        method == LocalMockProtocol.replaceRules ? _replaceArgs(rules) : null,
      );
      if (!_current(service)) throw StateError('连接已变化，无法确认是否应用');
      _lastApplied = rules;
      _remoteRuleCount = (state['rules'] as List).length;
      _status = '已确认应用 $_remoteRuleCount 条规则，下一次请求生效';
    } catch (error) {
      if (_current(service)) _status = '同步失败：$error';
      rethrow;
    } finally {
      if (_current(service)) {
        _working = false;
        _notify();
        if (version != _rulesVersion) {
          await _update(LocalMockProtocol.replaceRules, _desiredRules!);
        }
      }
    }
  }

  /// Enables / disables live capture polling (kept across reconnects).
  void setCaptureLive(bool value) {
    if (_captureLive == value) return;
    _captureLive = value;
    _syncTrafficPolling();
    _notify();
  }

  void _resetTraffic() {
    _trafficPoll?.cancel();
    _trafficPoll = null;
    _traffic = const [];
    _trafficCursor = 0;
  }

  void _syncTrafficPolling() {
    _trafficPoll?.cancel();
    _trafficPoll = null;
    if (!_captureLive || !captureAvailable || _service == null) return;
    unawaited(_pollTraffic());
    _trafficPoll = Timer.periodic(_trafficInterval, (_) {
      unawaited(_pollTraffic());
    });
  }

  Future<void> _pollTraffic() async {
    final service = _service;
    final id = _selectedId;
    if (service == null || id == null || _trafficBusy) return;
    _trafficBusy = true;
    try {
      final json = await _call(service, id, LocalMockProtocol.getTraffic, {
        'sinceRevision': '$_trafficCursor',
      });
      if (!_current(service) || id != _selectedId) return;
      final revision = json['trafficRevision'];
      final entries = json['entries'];
      if (revision is! int || revision < 0 || entries is! List) {
        throw const FormatException('local_mock 返回了无效的抓包数据');
      }
      final fresh = entries.whereType<Map<String, dynamic>>().toList();
      if (fresh.isNotEmpty) {
        final merged = [..._traffic, ...fresh];
        _traffic = List.unmodifiable(
          merged.length > _maxTrafficEntries
              ? merged.sublist(merged.length - _maxTrafficEntries)
              : merged,
        );
      }
      _trafficCursor = revision;
      if (fresh.isNotEmpty) _notify();
    } catch (_) {
      // Transient polling failures are retried on the next tick; permanent
      // incompatibilities surface through the rules calls.
    } finally {
      _trafficBusy = false;
    }
  }

  /// Clears the app-side buffer and the local list.
  Future<void> clearTraffic() async {
    final service = _service;
    final id = _selectedId;
    if (service == null || id == null) {
      throw StateError('请先连接并选择目标');
    }
    final json = await _call(service, id, LocalMockProtocol.clearTraffic);
    final revision = json['trafficRevision'];
    _trafficCursor = revision is int ? revision : _trafficCursor;
    _traffic = const [];
    _notify();
  }

  /// Disconnect is not clear: the app retains its in-memory rules.
  void disconnect() {
    _generation++;
    _poll?.cancel();
    _poll = null;
    _trafficPoll?.cancel();
    _trafficPoll = null;
    final service = _service;
    _service = null;
    if (service != null) unawaited(service.dispose());
    _targets = const [];
    _selectedId = null;
    _remoteRuleCount = null;
    _working = false;
    _status = '未连接';
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    disconnect();
    super.dispose();
  }
}
