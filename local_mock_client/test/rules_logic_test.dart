import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_client/src/format.dart';
import 'package:local_mock_client/src/rule_book.dart';
import 'package:local_mock_client/src/rule_store.dart';
import 'package:local_mock_client/src/rule_drafts.dart';
import 'package:local_mock_core/local_mock_core.dart';

import 'support/harness.dart';

void main() {
  group('ruleFromTraffic', () {
    test('copies method, path, host, status and JSON body', () {
      final rule = ruleFromTraffic(
        trafficEntry(
          1,
          '/api/orders',
          method: 'post',
          response: '{"ok":true,"list":[1,2]}',
        ),
        existingIds: const {},
      );
      expect(rule['id'], 'api-orders');
      expect(rule['method'], 'POST');
      expect(rule['host'], 'api.test');
      expect(rule['statusCode'], 200);
      expect(rule['body'], {
        'ok': true,
        'list': [1, 2],
      });
      expect(() => MockRule.fromJson(rule), returnsNormally);
    });

    test('suffixes ids that are taken', () {
      final rule = ruleFromTraffic(
        trafficEntry(1, '/api/orders'),
        existingIds: {'api-orders', 'api-orders-2'},
      );
      expect(rule['id'], 'api-orders-3');
    });

    test('keeps non-JSON text and tolerates failed requests', () {
      expect(
        ruleFromTraffic(
          trafficEntry(1, '/api/text', response: 'plain text'),
          existingIds: const {},
        )['body'],
        'plain text',
      );
      final failed = ruleFromTraffic(
        trafficEntry(2, '/api/down', status: null, error: 'reset'),
        existingIds: const {},
      );
      expect(failed['statusCode'], 200);
      expect(failed.containsKey('body'), isFalse);
    });
  });

  group('RuleBook', () {
    late FakeConnection connection;
    late RuleBook book;
    const a = {'id': 'a', 'method': 'GET', 'path': '/a'};
    const b = {'id': 'b', 'method': 'GET', 'path': '/b'};

    setUp(() {
      connection = FakeConnection(rules: [a, b]);
      final store = MemoryRuleStore()
        ..save(
          'phone',
          SavedRules(rules: [a, b], syncedSession: connection.appSession),
        );
      book = RuleBook(connection, store: store);
    });
    tearDown(() {
      book.dispose();
      connection.dispose();
    });

    test('browser rules survive device replacements and empty app state', () {
      expect(book.rules.map((r) => r['id']), ['a', 'b']);
      connection.deviceReplacesRules([b]);
      expect(book.rules.map((r) => r['id']), ['a', 'b']);
      connection.deviceReplacesRules([]);
      expect(book.rules.map((r) => r['id']), ['a', 'b']);
    });

    test('move, insert and remove push the new order', () async {
      await book.move(0, 1);
      expect(connection.applied!.map((r) => r['id']), ['b', 'a']);
      final index = book.remove(book.rules.first);
      await pumpEventQueue();
      expect(connection.applied!.map((r) => r['id']), ['a']);
      await book.insert(index, b);
      expect(connection.applied!.map((r) => r['id']), ['b', 'a']);
    });

    test('replacing a rule that is no longer listed fails', () async {
      final stale = book.rules.first;
      await book.replaceAll([a, b]);
      expect(
        () => book.replace(stale, {...a, 'path': '/z'}),
        throwsA(isA<StateError>()),
      );
      expect(connection.pushes, 1);
    });

    test('a recording yields at most one group', () async {
      final group = recordingMockFromSession(savedSession()).toJson();
      await book.upsertGroup(group);
      await book.upsertGroup({...group, 'name': '改名'});
      expect(book.recordingGroups, hasLength(1));
      expect(book.recordingGroups.single['name'], '改名');
      final reused = groupForSession(savedSession(), book);
      expect(reused.isNew, isFalse);
      expect(reused.group['name'], '改名');
    });

    test(
      'push failures are kept as syncError until the next success',
      () async {
        connection.supportsGroups = false;
        final group = recordingMockFromSession(savedSession()).toJson();
        await expectLater(book.add(group), throwsA(isA<StateError>()));
        expect(book.syncError, contains('不支持录制组'));
        connection.supportsGroups = true;
        await book.push();
        expect(book.syncError, isNull);
      },
    );

    test('parseFile accepts a BOM and rejects invalid rules', () {
      expect(RuleBook.parseFile('\uFEFF${jsonEncode([a])}').single['id'], 'a');
      expect(
        () => RuleBook.parseFile('[{"id":"x","method":"GET","path":"x"}]'),
        throwsFormatException,
      );
    });

    test('nextRuleId skips used ids', () async {
      await book.add({'id': 'rule-3', 'method': 'GET', 'path': '/c'});
      expect(book.nextRuleId(), 'rule-4');
    });
  });

  test('describeError strips Dart prefixes and extra lines', () {
    expect(describeError(StateError('坏了')), '坏了');
    expect(describeError(const FormatException('格式\n  ^')), '格式');
    expect(describeError(Exception('x')), 'x');
  });
}
