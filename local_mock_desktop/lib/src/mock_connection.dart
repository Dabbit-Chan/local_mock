import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:local_mock_core/local_mock_core.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'vm_service_uri.dart';

class MockTarget {
  const MockTarget(this.id, this.name);
  final String id;
  final String name;
}

/// Polling discovers extensions registered after connection / hot restart.
/// Only acknowledged rules are restored into a replacement isolate.
class MockConnection extends ChangeNotifier {
  static const _timeout = Duration(seconds: 8);
  VmService? _service;
  Timer? _poll;
  int _generation = 0;
  bool _disposed = false;
  bool _working = false;
  String _status = '未连接';
  List<MockTarget> _targets = const [];
  String? _selectedId;
  List<Map<String, dynamic>>? _lastApplied;
  int? _remoteRuleCount;

  bool get connected => _service != null;
  bool get working => _working;
  bool get ready => connected && _selectedId != null && !working;
  String get status => _status;
  List<MockTarget> get targets => _targets;
  String? get selectedId => _selectedId;
  int? get remoteRuleCount => _remoteRuleCount;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _current(VmService service) =>
      !_disposed && identical(service, _service);

  Future<void> connect(String address) async {
    final uri = normalizeVmServiceUri(address);
    disconnect();
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
            targets.add(MockTarget(id, isolate.name ?? id));
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
      }
    }
  }

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
    if (json == null || json['protocolVersion'] != LocalMockProtocol.version) {
      throw const FormatException('local_mock 协议版本不兼容');
    }
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
    var state = await _call(service, id, LocalMockProtocol.getState);
    if (!_current(service)) return;
    if (_lastApplied case final rules?) {
      state = await _call(
        service,
        id,
        LocalMockProtocol.replaceRules,
        _replaceArgs(rules),
      );
    }
    if (!_current(service)) return;
    _selectedId = id;
    _remoteRuleCount = (state['rules'] as List).length;
    _status = _lastApplied == null ? '已就绪' : '已就绪，已恢复上次确认的规则';
  }

  Future<void> selectTarget(String id) async {
    final service = _service;
    if (service == null || _working) return;
    _working = true;
    _selectedId = null;
    _remoteRuleCount = null;
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
    _working = true;
    _status = '正在同步…';
    _notify();
    try {
      final state = await _call(
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
      }
    }
  }

  /// Disconnect is not clear: the app retains its in-memory rules.
  void disconnect() {
    _generation++;
    _poll?.cancel();
    _poll = null;
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
