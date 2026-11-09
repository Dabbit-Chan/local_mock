import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_client/src/mock_connection.dart';
import 'package:local_mock_client/src/rule_book.dart';

import 'support/harness.dart';

void main() {
  const a = {'id': 'a', 'method': 'GET', 'path': '/a'};
  const b = {'id': 'b', 'method': 'GET', 'path': '/b'};
  late FakeConnection connection;
  late MemoryRuleStore store;
  late RuleBook book;

  setUp(() {
    connection = FakeConnection();
    store = MemoryRuleStore();
    book = RuleBook(connection, store: store);
  });
  tearDown(() {
    book.dispose();
    connection.dispose();
  });

  test(
    'new sessions save all mutations locally until a successful push',
    () async {
      await book.add(a);
      await book.add(b);
      await book.move(0, 1);
      await book.setEnabled(book.byId('a')!, false);
      book.remove(book.byId('b')!);
      await pumpEventQueue();
      expect(connection.pushes, 0);
      expect(store.load('phone')!.rules.single['enabled'], isFalse);
      await book.push();
      expect(connection.pushes, 1);
      expect(book.autoSyncEnabled, isTrue);
      await book.setEnabled(book.rules.single, true);
      expect(connection.pushes, 2);
      expect(connection.applied!.single['enabled'], isTrue);
    },
  );

  test(
    'browser reload remembers rules and approval for only the same session',
    () async {
      await book.add(a);
      await book.push();
      book.dispose();
      book = RuleBook(connection, store: store);
      expect(book.rules.single['id'], 'a');
      expect(book.autoSyncEnabled, isTrue);
      expect(connection.pushes, 1);
      connection.session = 'cold-start';
      connection.deviceReplacesRules([]);
      expect(book.autoSyncEnabled, isFalse);
      expect(book.rules.single['id'], 'a');
      await book.add(b);
      expect(connection.pushes, 1);
      book.dispose();
      book = RuleBook(connection, store: store);
      expect(book.autoSyncEnabled, isFalse);
      expect(book.rules.map((r) => r['id']), ['a', 'b']);
    },
  );

  test('switching devices isolates rules and approved sessions', () async {
    await book.add(a);
    await book.push();
    connection.devices = const [
      MockTarget('phone', 'A'),
      MockTarget('other', 'B'),
    ];
    connection.deviceRules = [];
    connection.session = 'other-session';
    await connection.selectTarget('other');
    expect(book.rules, isEmpty);
    expect(book.autoSyncEnabled, isFalse);
    await book.add(b);
    expect(connection.pushes, 1);
    await book.push();
    connection.session = 'session-1';
    await connection.selectTarget('phone');
    expect(book.rules.single['id'], 'a');
    expect(book.autoSyncEnabled, isTrue);
    await book.add({...b, 'id': 'phone-b'});
    expect(connection.applied!.map((r) => r['id']), ['a', 'phone-b']);
    expect(store.load('other')!.rules.single['id'], 'b');
  });

  test(
    'clearing persists an empty list instead of reimporting device rules',
    () async {
      await book.add(a);
      await book.push();
      await book.clearDevice();
      connection.deviceRules = [a];
      book.dispose();
      book = RuleBook(connection, store: store);
      expect(book.rules, isEmpty);
      expect(store.load('phone')!.rules, isEmpty);
    },
  );

  test(
    'storage failure is visible and keeps edits in memory for export',
    () async {
      store.saveFailure = StateError('空间不足');
      await book.add(a);
      expect(book.storageError, contains('空间不足'));
      expect(book.exportText(), contains('/a'));
      expect(connection.pushes, 0);
      store.saveFailure = null;
      await book.add(b);
      expect(book.storageError, isNull);
      expect(store.load('phone')!.rules, hasLength(2));
    },
  );

  test('offline edits persist pending state across a browser reload', () async {
    await book.add(a);
    await book.push();
    connection.isConnected = false;
    connection.notifyListeners();
    await book.add(b);
    expect(connection.pushes, 1);
    expect(store.load('phone')!.pending, isTrue);
    book.dispose();
    book = RuleBook(connection, store: store);
    connection.isConnected = true;
    connection.notifyListeners();
    await pumpEventQueue();
    expect(connection.pushes, 2);
    expect(connection.applied!.map((r) => r['id']), ['a', 'b']);
    expect(store.load('phone')!.pending, isFalse);
  });

  test(
    'existing app rules migrate once without granting session approval',
    () async {
      book.dispose();
      connection.deviceRules = [a];
      book = RuleBook(connection, store: MemoryRuleStore());
      expect(book.rules.single['id'], 'a');
      expect(book.autoSyncEnabled, isFalse);
      expect(connection.pushes, 0);
    },
  );
}
