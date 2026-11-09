@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_client/src/mock_connection.dart';
import 'package:local_mock_client/src/rule_book.dart';
import 'package:local_mock_client/src/rule_store.dart';
import 'package:local_mock_transport/local_mock_transport.dart';
import 'package:web/web.dart' as web;

import 'browser_connection_test.dart' show waitUntil;

void main() {
  const address = String.fromEnvironment('LOCAL_MOCK_TEST_SERVER');
  test(
    'browser reload and app cold start preserve rules but gate new sessions',
    () async {
      final id = 'browser-sync-${DateTime.now().microsecondsSinceEpoch}';
      var rules = <dynamic>[];
      var pushes = 0;
      final agents = <LocalMockAgent>[];
      LocalMockAgent newAgent() {
        final agent = LocalMockAgent(
          serverUrl: address,
          deviceId: id,
          deviceName: 'Browser sync test',
          snapshot: () => {'rules': rules, 'entries': <dynamic>[]},
          onCommand: (method, args) {
            if (method == 'replaceRules') {
              rules = List.of(args['rules'] as List);
              pushes++;
            }
            return {'rules': rules};
          },
        );
        agents.add(agent);
        agent.start();
        return agent;
      }

      final connection = MockConnection();
      RuleBook? book;
      addTearDown(() {
        book?.dispose();
        connection.dispose();
        for (final agent in agents) {
          agent.stop();
        }
        web.window.localStorage.removeItem(RuleStore.keyFor(id));
      });
      final first = newAgent();
      await waitUntil(() => first.connected);
      await connection.connect(address);
      if (connection.selectedId != id) await connection.selectTarget(id);
      book = RuleBook(connection);
      await book.add({
        'id': 'browser',
        'method': 'GET',
        'path': '/browser',
        'body': {'value': 'saved'},
      });
      expect(rules, isEmpty);
      await book.push();
      expect(pushes, 1);
      book.dispose();
      book = RuleBook(connection);
      expect(book.rules.single['body'], {'value': 'saved'});
      expect(book.autoSyncEnabled, isTrue);
      expect(pushes, 1);

      first.stop();
      await waitUntil(() => !connection.ready);
      rules = [];
      final replacement = newAgent();
      await waitUntil(() => replacement.connected && connection.ready);
      expect(rules, isEmpty);
      expect(book.autoSyncEnabled, isFalse);
      expect(book.rules.single['body'], {'value': 'saved'});
      await book.setEnabled(book.rules.single, false);
      expect(pushes, 1);
      await book.push();
      await book.setEnabled(book.rules.single, true);
      expect(pushes, 3);
      expect((rules.single as Map)['enabled'], isTrue);
    },
    skip: address.isEmpty,
  );
}
