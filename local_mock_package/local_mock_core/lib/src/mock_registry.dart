import 'mock_rule.dart';
import 'protocol.dart';

/// Isolate-local state; invalid replacements never discard the existing rules.
final class MockRegistry {
  List<MockRule> _rules = const [];
  int _revision = 0;

  void replace(dynamic json) {
    final parsed = MockRule.parseList(json);
    _rules = parsed;
    _revision++;
  }

  void clear() => replace(<dynamic>[]);

  MockRule? match(String method, Uri uri) {
    for (final rule in _rules) {
      if (rule.matches(method, uri)) return rule;
    }
    return null;
  }

  Map<String, dynamic> get state => {
    'protocolVersion': LocalMockProtocol.version,
    'revision': _revision,
    'rules': _rules.map((rule) => rule.toJson()).toList(),
  };
}
