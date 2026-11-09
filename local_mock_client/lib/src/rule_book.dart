import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:local_mock_core/local_mock_core.dart';

import 'format.dart';
import 'mock_connection.dart';
import 'rule_store.dart';

typedef Rule = Map<String, dynamic>;

/// Browser-owned rule lists, isolated by device. A new app session needs one
/// explicit push before edits are automatically sent for that session.
class RuleBook extends ChangeNotifier {
  RuleBook(this.connection, {this.store = const RuleStore()}) {
    connection.addListener(_connectionChanged);
    _connectionChanged();
  }

  final MockConnection connection;
  final RuleStore store;
  final _devices = <String, SavedRules>{};
  String? _deviceId;
  String? _session;
  SavedRules? _current;
  String? _syncError;
  String? _storageError;
  bool _pushing = false;
  Future<void>? _pushTask;
  bool _disposed = false;
  bool _wasOnline = false;

  List<Rule> get _rules => _current?.rules ?? const [];
  List<Rule> get rules => _rules;
  String? get deviceId => _deviceId;
  String? get syncError => _syncError;
  String? get storageError => _storageError;
  bool get autoSyncEnabled =>
      _session != null && _current?.syncedSession == _session;
  bool get canAutoSync => autoSyncEnabled && connection.selectedId == _deviceId;

  Set<String> get ids => {for (final rule in _rules) rule['id'] as String};

  List<Rule> get recordingGroups =>
      _rules.where((rule) => rule['type'] == 'recording').toList();

  static List<Rule> _copy(List<Map<String, dynamic>> rules) =>
      rules.map((rule) => Map<String, dynamic>.of(rule)).toList();

  void _connectionChanged() {
    final id = connection.selectedId;
    if (id == null) {
      _wasOnline = false;
      return; // Keep the browser's list while disconnected.
    }
    if (id != _deviceId) {
      _wasOnline = false;
      _deviceId = id;
      _session = null;
      _syncError = null;
      _storageError = null;
      _current = _devices[id];
    }
    if (_current == null) {
      try {
        _current = store.load(id);
      } catch (error) {
        _storageError = '读取浏览器规则失败：${describeError(error)}';
        _current = SavedRules(rules: []);
      }
      // Migrate rules already on the app only when this browser has no copy.
      if (_current == null && connection.ready) {
        _current = SavedRules(rules: _copy(connection.rules));
        _persist();
      }
      if (_current != null) _devices[id] = _current!;
    }
    final online =
        connection.connected &&
        connection.targets.any((target) => target.id == id && target.online);
    if (online && !_wasOnline) _syncError = null;
    _wasOnline = online;
    final session = connection.appSession;
    if (_session != session) {
      _session = session;
      _syncError = null;
    }
    notifyListeners();
    if (!_pushing &&
        connection.ready &&
        canAutoSync &&
        _current?.pending == true &&
        _syncError == null) {
      unawaited(push().catchError((_) {}));
    }
  }

  void _persist() {
    final current = _current;
    final id = _deviceId;
    if (current == null || id == null) return;
    try {
      store.save(id, current);
      _storageError = null;
    } catch (error) {
      _storageError = describeError(error);
    }
  }

  int indexOfId(String id) => _rules.indexWhere((rule) => rule['id'] == id);

  Rule? byId(String id) {
    final index = indexOfId(id);
    return index < 0 ? null : _rules[index];
  }

  String nextRuleId() {
    var index = _rules.length + 1;
    while (ids.contains('rule-$index')) {
      index++;
    }
    return 'rule-$index';
  }

  /// Save locally first; only an approved session receives automatic edits.
  Future<void> _commit(List<Rule> next) {
    final current = _current;
    if (current == null) throw StateError('请先选择设备');
    current.rules = next;
    current.pending = true;
    current.version++;
    _syncError = null;
    _persist();
    notifyListeners();
    if (_pushing) return _pushTask ?? Future.value();
    if (!canAutoSync || !connection.ready) return Future.value();
    return push();
  }

  /// Explicitly enables automatic synchronization after the app acknowledges
  /// the browser's rules. Failure never approves a new session.
  Future<void> push() {
    if (_pushing) return _pushTask ?? Future.value();
    if (!connection.ready ||
        connection.selectedId != _deviceId ||
        _session == null ||
        _current == null) {
      return Future.error(StateError('设备未就绪'));
    }
    _pushing = true;
    _syncError = null;
    final current = _current!;
    final id = _deviceId!;
    final session = _session!;
    return _pushTask = _flush(current, id, session).whenComplete(() {
      _pushing = false;
      _pushTask = null;
    });
  }

  Future<void> _flush(SavedRules current, String id, String session) async {
    try {
      int version;
      do {
        if (connection.selectedId != id || connection.appSession != session) {
          throw StateError('App 会话已变化，请重新同步到设备');
        }
        version = current.version;
        await connection.updateRules(jsonEncode(current.rules));
        if (connection.selectedId != id || connection.appSession != session) {
          throw StateError('App 会话已变化，请重新同步到设备');
        }
      } while (version != current.version);
      current.syncedSession = session;
      current.pending = false;
      _persist();
      _syncError = null;
    } catch (error) {
      _syncError = describeError(error);
      rethrow;
    } finally {
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> add(Rule rule) => _commit([..._rules, rule]);

  Future<void> insert(int index, Rule rule) =>
      _commit(List.of(_rules)..insert(index.clamp(0, _rules.length), rule));

  /// Replaces [original] with [updated]. Fails if [original] is no longer in
  /// the list, i.e. another browser edit replaced it meanwhile.
  Future<void> replace(Rule original, Rule updated) {
    final index = _rules.indexWhere((rule) => identical(rule, original));
    if (index < 0) {
      throw StateError('这条规则已被其他操作更新，请重新打开后再保存');
    }
    return _commit(List.of(_rules)..[index] = updated);
  }

  Future<void> setEnabled(Rule rule, bool enabled) =>
      replace(rule, {...rule, 'enabled': enabled});

  /// Removes [rule] and returns its former index for undo.
  int remove(Rule rule) {
    final index = _rules.indexWhere((current) => identical(current, rule));
    if (index < 0) return -1;
    unawaited(_commit(List.of(_rules)..removeAt(index)).catchError((_) {}));
    return index;
  }

  Future<void> move(int from, int to) {
    final next = List.of(_rules);
    final rule = next.removeAt(from);
    next.insert(to.clamp(0, next.length), rule);
    return _commit(next);
  }

  /// Adds a recording group, or replaces the group created from the same
  /// recording so a recording never yields two groups.
  Future<void> upsertGroup(Rule group) {
    final index = _rules.indexWhere(
      (rule) =>
          rule['type'] == 'recording' &&
          rule['recordingId'] == group['recordingId'],
    );
    if (index < 0) return add(group);
    return _commit(List.of(_rules)..[index] = group);
  }

  Future<void> replaceAll(List<Rule> rules) => _commit(rules);

  /// Validates an exported rules file without applying it.
  static List<Rule> parseFile(String text) => MockRule.parseList(
    jsonDecode(stripBom(text)),
  ).map((rule) => rule.toJson()).toList();

  String exportText() => prettyJson(_rules);

  Future<void> clearDevice() => replaceAll([]);

  @override
  void dispose() {
    _disposed = true;
    connection.removeListener(_connectionChanged);
    super.dispose();
  }
}
