import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:local_mock_client/src/panes/rule_editor.dart';
import 'package:local_mock_client/src/rule_store.dart';
import 'package:local_mock_client/src/panes/traffic_list.dart';
import 'package:local_mock_client/src/ui/primitives.dart';

import 'support/harness.dart';

const _profile = {
  'id': 'profile',
  'enabled': true,
  'method': 'GET',
  'path': '/api/profile',
  'statusCode': 200,
  'delayMs': 0,
  'headers': {'x-mock': '1'},
  'body': {'name': 'real'},
};

const _order = {
  'id': 'order',
  'enabled': true,
  'method': 'POST',
  'path': '/api/order',
  'body': {'ok': true},
};

Future<FakeConnection> openDevice(
  WidgetTester tester, {
  List<Map<String, dynamic>> rules = const [],
  List<Map<String, dynamic>>? traffic,
  RuleFiles? files,
}) async {
  final connection = FakeConnection(rules: rules, traffic: traffic);
  addTearDown(connection.dispose);
  await pumpApp(
    tester,
    connection: connection,
    files: files,
    location: '/devices/phone',
  );
  return connection;
}

Finder field(String key) => find.byKey(ValueKey('rule-field-$key'));

/// A request row whose address contains [path].
Finder request(String path) => find.descendant(
  of: find.byType(TrafficRow),
  matching: find.textContaining(path, findRichText: true),
);

Future<void> openRequest(WidgetTester tester, String path) async {
  await tester.tap(request(path));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('cold start keeps browser rules and requires one manual sync', (
    tester,
  ) async {
    final connection = FakeConnection();
    addTearDown(connection.dispose);
    final store = MemoryRuleStore()
      ..save(
        'phone',
        SavedRules(rules: [_profile], syncedSession: 'previous-session'),
      );
    await pumpApp(
      tester,
      connection: connection,
      ruleStore: store,
      location: '/devices/phone',
    );
    expect(find.text('App 已重启、规则未下发'), findsOneWidget);
    expect(find.text('/api/profile'), findsOneWidget);
    expect(connection.pushes, 0);
    await tester.tap(find.byType(SquareToggle).first);
    await tester.pumpAndSettle();
    expect(connection.pushes, 0);
    expect(store.load('phone')!.rules.single['enabled'], isFalse);
    await tapKey(tester, const Key('sync-rules-to-device'));
    expect(connection.pushes, 1);
    expect(find.text('App 已重启、规则未下发'), findsNothing);
    await tester.tap(find.byType(SquareToggle).first);
    await tester.pumpAndSettle();
    expect(connection.pushes, 2);
    connection.session = 'next-cold-start';
    connection.deviceReplacesRules([]);
    await tester.pumpAndSettle();
    expect(find.text('App 已重启、规则未下发'), findsOneWidget);
    expect(find.text('/api/profile'), findsOneWidget);
    expect(connection.pushes, 2);
  });

  testWidgets('lists the device rules in order with their summaries', (
    tester,
  ) async {
    await openDevice(tester, rules: [_profile, _order]);
    expect(find.text('测试设备'), findsWidgets);
    expect(find.text('/api/profile'), findsOneWidget);
    expect(find.text('/api/order'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('/api/profile')).dy,
      lessThan(tester.getTopLeft(find.text('/api/order')).dy),
    );
    expect(find.textContaining('已同步'), findsOneWidget);
  });

  testWidgets('toggling a rule pushes the whole list with the new state', (
    tester,
  ) async {
    final connection = await openDevice(tester, rules: [_profile, _order]);
    await tester.tap(find.byType(SquareToggle).first);
    await tester.pumpAndSettle();
    expect(connection.applied!.map((r) => r['enabled']), [false, true]);
  });

  testWidgets('creates a rule in the inline editor and syncs it', (
    tester,
  ) async {
    final connection = await openDevice(tester);
    expect(find.text('还没有规则'), findsOneWidget);
    await tapKey(tester, const Key('new-rule'));
    expect(find.byKey(RuleEditorKeys.save), findsOneWidget);
    await tester.enterText(field('path'), '/api/new');
    await setCode(tester, RuleEditorKeys.body, '{"hello": "world"}');
    await tapKey(tester, RuleEditorKeys.save);
    expect(connection.applied, hasLength(1));
    expect(connection.applied!.single, containsPair('path', '/api/new'));
    expect(connection.applied!.single['body'], {'hello': 'world'});
    expect(connection.applied!.single['id'], 'rule-1');
    // The editor stays open on the saved rule.
    expect(find.text('编辑规则'), findsOneWidget);
    expect(find.text('/api/new'), findsWidgets);
  });

  testWidgets('invalid fields are reported inline and nothing is pushed', (
    tester,
  ) async {
    final connection = await openDevice(tester, rules: [_profile]);
    await tapKey(tester, const Key('new-rule'));
    await tester.enterText(field('path'), 'no-slash?x=1');
    await tester.enterText(field('id'), 'profile');
    await setCode(tester, RuleEditorKeys.body, '{broken');
    await tapKey(tester, RuleEditorKeys.save);
    expect(find.textContaining('以 / 开头'), findsOneWidget);
    expect(find.text('已有规则使用这个 ID'), findsOneWidget);
    expect(find.text('响应体不是合法的 JSON'), findsOneWidget);
    expect(find.text('有 3 处需要修改'), findsOneWidget);
    expect(connection.applied, isNull);
  });

  testWidgets('params and a field patch round-trip through the editor', (
    tester,
  ) async {
    final connection = await openDevice(tester, rules: [_profile]);
    await tapText(tester, '/api/profile');
    await tapKey(tester, const Key('expand-params'));
    await setCode(tester, RuleEditorKeys.params, '{"id": 123}');
    await tapText(tester, '字段补丁');
    await setCode(tester, RuleEditorKeys.patch, '{"data.items[*].name": "长"}');
    await tapKey(tester, RuleEditorKeys.save);
    final saved = connection.applied!.single;
    expect(saved['params'], {'id': '123'});
    expect(saved['patchBody'], {'data.items[*].name': '长'});
    // The stored full response survives so switching back restores it.
    expect(saved['statusCode'], 200);
    expect(saved['headers'], {'x-mock': '1'});
    expect(saved['body'], {'name': 'real'});

    await tapText(tester, '整包替换');
    expect(codeAt(tester, RuleEditorKeys.body).text, contains('"real"'));
    await tapKey(tester, RuleEditorKeys.save);
    expect(connection.applied!.single.containsKey('patchBody'), isFalse);
    expect(connection.applied!.single['params'], {'id': '123'});
  });

  testWidgets('nested params are flattened into field paths on save', (
    tester,
  ) async {
    final connection = await openDevice(tester, rules: [_profile]);
    await tapText(tester, '/api/profile');
    await tapKey(tester, const Key('expand-params'));
    await setCode(
      tester,
      RuleEditorKeys.params,
      '{"modules": [1, 2], "filter": {"city": "杭州"}, "page": 1}',
    );
    await tapKey(tester, RuleEditorKeys.save);
    expect(connection.applied!.single['params'], {
      'modules[0]': '1',
      'modules[1]': '2',
      'filter.city': '杭州',
      'page': '1',
    });
  });

  testWidgets('patch mode rejects empty patches, bad paths and bad params', (
    tester,
  ) async {
    final connection = await openDevice(tester, rules: [_profile]);
    await tapText(tester, '/api/profile');
    await tapText(tester, '字段补丁');
    await tapKey(tester, RuleEditorKeys.save);
    expect(find.text('至少填写一个“字段路径: 新值”'), findsOneWidget);

    await setCode(tester, RuleEditorKeys.patch, '{"data..name": 1}');
    await tapKey(tester, RuleEditorKeys.save);
    expect(find.textContaining('字段路径无效'), findsOneWidget);

    await setCode(tester, RuleEditorKeys.patch, '{"data.name": 1}');
    await tapKey(tester, const Key('expand-params'));
    await setCode(tester, RuleEditorKeys.params, '{"modules": []}');
    await tapKey(tester, RuleEditorKeys.save);
    expect(find.text('"modules" 是空数组，无法匹配'), findsOneWidget);
    expect(connection.applied, isNull);
  });

  testWidgets('deleting a rule can be undone', (tester) async {
    final connection = await openDevice(tester, rules: [_profile, _order]);
    await tapText(tester, '/api/order');
    await tapText(tester, '删除');
    expect(connection.applied!.map((r) => r['id']), ['profile']);
    expect(find.text('选中一条规则来编辑，或选中一个请求查看详情。'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(connection.applied!.map((r) => r['id']), ['profile', 'order']);
  });

  testWidgets('switching away from unsaved edits asks first', (tester) async {
    await openDevice(tester, rules: [_profile, _order]);
    await tapText(tester, '/api/profile');
    await tester.enterText(field('path'), '/api/changed');
    await tester.pumpAndSettle();
    expect(find.text('未保存'), findsOneWidget);

    await tester.tap(find.text('/api/order'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tapText(tester, '取消');
    expect(
      tester.widget<TextField>(field('path')).controller!.text,
      '/api/changed',
    );

    await tester.tap(find.text('/api/order'));
    await tester.pumpAndSettle();
    await tapText(tester, '放弃修改');
    expect(
      tester.widget<TextField>(field('path')).controller!.text,
      '/api/order',
    );
  });

  testWidgets('device updates do not replace browser edits', (tester) async {
    final connection = await openDevice(tester, rules: [_profile]);
    await tapText(tester, '/api/profile');
    await tester.enterText(field('path'), '/api/mine');
    await tester.pumpAndSettle();
    connection.deviceReplacesRules([
      {..._profile, 'path': '/api/theirs'},
    ]);
    await tester.pumpAndSettle();
    await tapKey(tester, RuleEditorKeys.save);
    expect(connection.applied!.single['path'], '/api/mine');
  });

  testWidgets('an untouched editor keeps the browser rule list', (
    tester,
  ) async {
    final connection = await openDevice(tester, rules: [_profile]);
    await tapText(tester, '/api/profile');
    connection.deviceReplacesRules([
      {..._profile, 'path': '/api/theirs'},
    ]);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(field('path')).controller!.text,
      '/api/profile',
    );
  });

  group('rule files', () {
    testWidgets('export writes the current list as JSON', (tester) async {
      final files = RuleFiles();
      await openDevice(tester, rules: [_profile, _order], files: files);
      await tapKey(tester, const Key('rules-menu'));
      await tapText(tester, '导出规则文件');
      final exported = jsonDecode(files.exported!) as List;
      expect(exported.map((r) => r['id']), ['profile', 'order']);
    });

    testWidgets('import validates, asks, then replaces and syncs', (
      tester,
    ) async {
      final files = RuleFiles()..imported = '\uFEFF${jsonEncode([_order])}';
      final connection = await openDevice(
        tester,
        rules: [_profile],
        files: files,
      );
      await tapKey(tester, const Key('rules-menu'));
      await tapText(tester, '导入规则文件…');
      expect(find.textContaining('文件中有 1 条规则，将替换当前全部 1 条规则'), findsOneWidget);
      await tapText(tester, '取消');
      expect(connection.applied, isNull);

      await tapKey(tester, const Key('rules-menu'));
      await tapText(tester, '导入规则文件…');
      await tapText(tester, '替换');
      expect(connection.applied!.map((r) => r['id']), ['order']);
      expect(find.text('/api/order'), findsOneWidget);
      expect(find.text('/api/profile'), findsNothing);
    });

    for (final invalid in [
      '{"id": "not-a-list"}',
      '[{"id": "x", "method": "GET", "path": "no-slash"}]',
      'not json',
    ]) {
      testWidgets('import rejects $invalid without changes', (tester) async {
        final files = RuleFiles()..imported = invalid;
        final connection = await openDevice(
          tester,
          rules: [_profile],
          files: files,
        );
        await tapKey(tester, const Key('rules-menu'));
        await tapText(tester, '导入规则文件…');
        expect(find.textContaining('导入失败'), findsOneWidget);
        expect(connection.applied, isNull);
        expect(find.text('/api/profile'), findsOneWidget);
      });
    }

    testWidgets('clearing device rules needs confirmation', (tester) async {
      final connection = await openDevice(tester, rules: [_profile]);
      await tapKey(tester, const Key('rules-menu'));
      await tapText(tester, '清空设备上的规则');
      await tapText(tester, '取消');
      expect(connection.applied, isNull);
      await tapKey(tester, const Key('rules-menu'));
      await tapText(tester, '清空设备上的规则');
      await tapText(tester, '清空');
      expect(connection.applied, isEmpty);
      expect(find.text('还没有规则'), findsOneWidget);
    });
  });

  group('requests', () {
    final traffic = [
      trafficEntry(1, '/api/profile', response: '{"name":"real"}'),
      trafficEntry(
        2,
        '/api/order',
        method: 'POST',
        status: 500,
        request: '{"sku":"A1"}',
        response: '{"code":5001}',
      ),
      trafficEntry(3, '/api/feed', query: 'Page=2', mocked: true),
    ];

    testWidgets('newest first, with text, mock and error filters', (
      tester,
    ) async {
      await openDevice(tester, traffic: traffic);
      double y(String path) => tester.getTopLeft(request(path)).dy;
      expect(y('/api/feed'), lessThan(y('/api/order')));
      expect(y('/api/order'), lessThan(y('/api/profile')));
      expect(find.text('MOCK'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'post');
      await tester.pumpAndSettle();
      expect(request('/api/order'), findsOneWidget);
      expect(request('/api/profile'), findsNothing);

      await tester.enterText(find.byType(TextField).first, '');
      await tapText(tester, '异常');
      expect(request('/api/order'), findsOneWidget);
      expect(request('/api/feed'), findsNothing);
      await tapText(tester, '异常');
      await tapText(tester, 'Mock');
      expect(request('/api/feed'), findsOneWidget);
      expect(request('/api/order'), findsNothing);
    });

    testWidgets('detail shows bodies and keeps query keys verbatim', (
      tester,
    ) async {
      await openDevice(tester, traffic: traffic);
      await openRequest(tester, '/api/order');
      expect(find.text('请求详情'), findsOneWidget);
      expect(find.text('请求体'), findsOneWidget);
      expect(find.text('https://api.test/api/order'), findsOneWidget);

      await openRequest(tester, '/api/feed');
      expect(find.text('Page'), findsOneWidget);
      expect(find.text('2'), findsWidgets);
    });

    testWidgets('a request becomes a pre-filled rule draft', (tester) async {
      final connection = await openDevice(
        tester,
        rules: [
          {..._profile, 'id': 'api-profile'},
        ],
        traffic: traffic,
      );
      await openRequest(tester, '/api/profile');
      await tapText(tester, '用此请求新建规则');
      expect(find.text('新建规则'), findsWidgets);
      expect(
        tester.widget<TextField>(field('id')).controller!.text,
        'api-profile-2',
      );
      expect(
        tester.widget<TextField>(field('host')).controller!.text,
        'api.test',
      );
      expect(codeAt(tester, RuleEditorKeys.body).text, contains('"real"'));
      await tapKey(tester, RuleEditorKeys.save);
      expect(connection.applied!.last['path'], '/api/profile');
      expect(connection.applied!.last['body'], {'name': 'real'});
    });

    testWidgets('clearing requests empties the list', (tester) async {
      final connection = await openDevice(tester, traffic: traffic);
      await tester.tap(find.byTooltip('清空设备上的请求记录'));
      await tester.pumpAndSettle();
      expect(connection.entries, isEmpty);
      expect(find.text('等待请求'), findsOneWidget);
    });
  });

  group('fixes from review', () {
    testWidgets('searching keeps the editor visible under the find bar', (
      tester,
    ) async {
      await openDevice(
        tester,
        traffic: [trafficEntry(1, '/api/a', response: '{"name":"real"}')],
      );
      await openRequest(tester, '/api/a');
      await tester.tap(find.byTooltip('查找（⌘/Ctrl F）').first);
      await tester.pumpAndSettle();
      final bar = tester.getSize(find.byKey(const Key('code-find-bar')));
      final editor = tester.getSize(find.byType(CodeEditor).first);
      expect(bar.height, 41);
      expect(editor.height, greaterThan(bar.height * 3));
    });

    testWidgets(
      'parameter conditions prefill from the request, toggle and remove',
      (tester) async {
        final connection = await openDevice(
          tester,
          traffic: [
            trafficEntry(
              1,
              '/api/order',
              method: 'POST',
              query: 'id=123',
              request: '{"sku":"A1","filter":{"city":"杭州"}}',
              response: '{"ok":true}',
            ),
          ],
        );
        await openRequest(tester, '/api/order');
        await tapText(tester, '用此请求新建规则');
        await tapKey(tester, const Key('expand-params'));
        Map<String, dynamic> params() =>
            jsonDecode(codeAt(tester, RuleEditorKeys.params).text)
                as Map<String, dynamic>;
        expect(params(), {'id': '123', 'sku': 'A1'});

        await tapKey(tester, const ValueKey('param-filter.city'));
        await tapKey(tester, const ValueKey('param-sku'));
        expect(params(), {'id': '123', 'filter.city': '杭州'});
        await tapKey(tester, RuleEditorKeys.save);
        expect(connection.applied!.single['params'], {
          'id': '123',
          'filter.city': '杭州',
        });

        await tapKey(tester, const Key('remove-params'));
        expect(find.byKey(const Key('expand-params')), findsOneWidget);
        await tapKey(tester, RuleEditorKeys.save);
        expect(connection.applied!.single.containsKey('params'), isFalse);
      },
    );

    testWidgets('clicking a field in the reference response writes patches', (
      tester,
    ) async {
      final connection = await openDevice(
        tester,
        traffic: [
          trafficEntry(
            1,
            '/api/site',
            response: '{"data":{"items":[{"name":"a"},{"name":"b"}]}}',
          ),
        ],
      );
      await openRequest(tester, '/api/site');
      await tapText(tester, '用此请求新建规则');
      await tapText(tester, '字段补丁');
      expect(find.textContaining('参照响应 · 抓包响应'), findsOneWidget);

      final reference = codeAt(tester, const Key('rule-reference-editor'));
      final lines = reference.text.split('\n');
      final line = lines.indexWhere((l) => l.contains('"b"'));
      reference.selection = CodeLineSelection.collapsed(
        index: line,
        offset: lines[line].indexOf('"b"') + 1,
      );
      await tester.pumpAndSettle();
      expect(find.text('data.items[1].name'), findsOneWidget);

      await tapKey(tester, const Key('patch-wildcard'));
      await tapKey(tester, const Key('patch-exact'));
      expect(jsonDecode(codeAt(tester, RuleEditorKeys.patch).text), {
        'data.items[*].name': 'b',
        'data.items[1].name': 'b',
      });
      expect(find.text('补丁此字段（已添加）'), findsOneWidget);

      await tapKey(tester, RuleEditorKeys.save);
      expect((connection.applied!.single['patchBody'] as Map).keys, [
        'data.items[*].name',
        'data.items[1].name',
      ]);
    });

    testWidgets(
      'existing rules use the latest captured response as reference',
      (tester) async {
        await openDevice(
          tester,
          rules: [_profile],
          traffic: [
            trafficEntry(1, '/api/profile', response: '{"name":"real"}'),
          ],
        );
        await tapText(tester, '/api/profile');
        await tapText(tester, '字段补丁');
        expect(find.textContaining('参照响应 · 抓包响应'), findsOneWidget);
      },
    );
  });
}
