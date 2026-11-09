@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_client/src/rule_store.dart';
import 'package:web/web.dart' as web;

void main() {
  const store = RuleStore();
  const device = 'rule-store-browser-test/手机';
  const other = 'rule-store-browser-test/other';
  const rule = {
    'id': 'profile',
    'method': 'GET',
    'path': '/profile',
    'enabled': false,
    'body': {'name': '你好'},
  };

  setUp(() {
    for (final id in [device, other]) {
      final key = RuleStore.keyFor(id);
      final previous = web.window.localStorage.getItem(key);
      web.window.localStorage.removeItem(key);
      addTearDown(() {
        if (previous == null) {
          web.window.localStorage.removeItem(key);
        } else {
          web.window.localStorage.setItem(key, previous);
        }
      });
    }
  });

  test('rules, pending edits and approved session reload per device', () {
    store.save(
      device,
      SavedRules(rules: [rule], syncedSession: 'session-1')..pending = true,
    );
    store.save(other, SavedRules(rules: []));
    final loaded = const RuleStore().load(device)!;
    expect(loaded.rules.single['body'], {'name': '你好'});
    expect(loaded.rules.single['enabled'], isFalse);
    expect(loaded.syncedSession, 'session-1');
    expect(loaded.pending, isTrue);
    expect(store.load(other)!.rules, isEmpty);
    store.save(device, SavedRules(rules: [], syncedSession: 'session-1'));
    expect(const RuleStore().load(device)!.rules, isEmpty);
    expect(const RuleStore().load(device)!.pending, isFalse);
  });

  test('invalid stored rules are reported without erasing browser data', () {
    final key = RuleStore.keyFor(device);
    const invalid = '{"rules":[{"id":"bad","path":"invalid"}]}';
    web.window.localStorage.setItem(key, invalid);
    expect(() => store.load(device), throwsFormatException);
    expect(web.window.localStorage.getItem(key), invalid);
  });
}
