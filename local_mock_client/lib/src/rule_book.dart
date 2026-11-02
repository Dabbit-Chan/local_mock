import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:local_mock_core/local_mock_core.dart';

import 'format.dart';
import 'mock_connection.dart';

typedef Rule = Map<String, dynamic>;

/// The ordered rule list of the selected device.
///
/// Every mutation is pushed to the app through [MockConnection.updateRules];
/// when the app reports a different rule set (device switch, another console)
/// the local list is replaced by the device's.
class RuleBook extends ChangeNotifier {
  RuleBook(this.connection) {
    _revision = connection.rulesRevision;
    _rules = _copy(connection.rules);
    connection.addListener(_connectionChanged);
  }

  final MockConnection connection;
  late int _revision;
  late List<Rule> _rules;
  String? _syncError;

  List<Rule> get rules => _rules;

  /// Last failure while pushing rules, cleared by the next successful push.
  String? get syncError => _syncError;

  Set<String> get ids => {for (final rule in _rules) rule['id'] as String};

  List<Rule> get recordingGroups =>
      _rules.where((rule) => rule['type'] == 'recording').toList();

  static List<Rule> _copy(List<Map<String, dynamic>> rules) =>
      rules.map((rule) => Map<String, dynamic>.of(rule)).toList();

  void _connectionChanged() {
    if (_revision == connection.rulesRevision) return;
    _revision = connection.rulesRevision;
    _rules = _copy(connection.rules);
    notifyListeners();
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

  /// Replaces the list and pushes it. Errors are kept in [syncError] and
  /// rethrown so callers that wait can react.
  Future<void> _commit(List<Rule> next) {
    _rules = next;
    notifyListeners();
    return push();
  }

  Future<void> push() async {
    try {
      await connection.updateRules(jsonEncode(_rules));
      if (_syncError != null) {
        _syncError = null;
        notifyListeners();
      }
    } catch (error) {
      _syncError = describeError(error);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> add(Rule rule) => _commit([..._rules, rule]);

  Future<void> insert(int index, Rule rule) =>
      _commit(List.of(_rules)..insert(index.clamp(0, _rules.length), rule));

  /// Replaces [original] with [updated]. Fails if [original] is no longer in
  /// the list, i.e. the device or another edit replaced it meanwhile.
  Future<void> replace(Rule original, Rule updated) {
    final index = _rules.indexWhere((rule) => identical(rule, original));
    if (index < 0) {
      throw StateError('这条规则已被设备或其他操作更新，请重新打开后再保存');
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

  Future<void> clearDevice() async {
    await connection.clear();
  }

  @override
  void dispose() {
    connection.removeListener(_connectionChanged);
    super.dispose();
  }
}
