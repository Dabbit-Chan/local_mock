import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_client/main.dart';
import 'package:local_mock_client/src/rule_edit_dialog.dart';
import 'package:local_mock_client/src/rule_file_transfer.dart';

const _initial = <String, dynamic>{
  'id': 'order',
  'enabled': true,
  'method': 'GET',
  'path': '/api/order',
  'statusCode': 200,
  'delayMs': 0,
  'body': {'source': 'mock'},
};

Future<void> _openEditor(
  WidgetTester tester, {
  Map<String, dynamic> initial = _initial,
  void Function(Map<String, dynamic>?)? onSaved,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            return FilledButton(
              onPressed: () async {
                final result = await showDialog<Map<String, dynamic>>(
                  context: context,
                  builder: (_) =>
                      RuleEditDialog(initial: initial, existingIds: const {}),
                );
                onSaved?.call(result);
              },
              child: const Text('open'),
            );
          },
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

class _MemoryFiles extends RuleFileTransfer {
  String? contents;
  String? saved;

  @override
  Future<String?> pickRules() async => contents;

  @override
  Future<void> saveRules(String filename, String contents) async =>
      saved = contents;
}

void main() {
  testWidgets(
    'patch mode disables ignored response options without losing them',
    (tester) async {
      Map<String, dynamic>? saved;
      await _openEditor(
        tester,
        initial: {
          ..._initial,
          'params': {'id': '123'},
          'patchBody': {'data.product.sku': 'fixed'},
        },
        onSaved: (result) => saved = result,
      );
      for (final label in ['状态码', '响应头 JSON（可选）', '响应体 JSON（留空视为 null）']) {
        expect(
          tester
              .widget<TextFormField>(find.widgetWithText(TextFormField, label))
              .enabled,
          isFalse,
        );
      }
      expect(find.textContaining('已启用字段补丁'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(saved!['body'], _initial['body']);
      expect(saved!['patchBody'], {'data.product.sku': 'fixed'});
    },
  );

  testWidgets('clearing params and patch restores a normal response rule', (
    tester,
  ) async {
    Map<String, dynamic>? saved;
    await _openEditor(
      tester,
      initial: {
        ..._initial,
        'params': {'id': '123'},
        'patchBody': {'data.product.sku': 'fixed'},
      },
      onSaved: (result) => saved = result,
    );
    await tester.enterText(find.widgetWithText(TextFormField, '参数匹配（可选）'), '');
    await tester.enterText(find.widgetWithText(TextFormField, '字段补丁（可选）'), '');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(find.widgetWithText(TextFormField, '状态码'))
          .enabled,
      isTrue,
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved, isNot(contains('params')));
    expect(saved, isNot(contains('patchBody')));
    expect(saved!['body'], _initial['body']);
  });

  testWidgets('ignored invalid response fields do not block patch saving', (
    tester,
  ) async {
    Map<String, dynamic>? saved;
    await _openEditor(tester, onSaved: (result) => saved = result);
    await tester.enterText(
      find.widgetWithText(TextFormField, '响应体 JSON（留空视为 null）'),
      'not JSON',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, '字段补丁（可选）'),
      '{"data.product.sku":"fixed"}',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved, isNotNull);
    expect(saved!['patchBody'], {'data.product.sku': 'fixed'});
  });

  testWidgets('invalid patch paths are rejected before saving', (tester) async {
    await _openEditor(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, '字段补丁（可选）'),
      '{"data..product":"fixed"}',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('invalid field path'), findsOneWidget);
    expect(find.text('编辑规则'), findsOneWidget);
  });

  testWidgets('rule cards distinguish patches and display parameter scope', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 320,
            child: RuleCard(
              rule: {
                ..._initial,
                'params': {'id': '123'},
                'patchBody': {'data.product.sku': 'fixed'},
              },
              onToggle: (_) {},
              onEdit: () {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('字段补丁'), findsOneWidget);
    expect(find.text('1 个参数条件'), findsOneWidget);
    expect(find.textContaining('参数匹配: {"id":"123"}'), findsOneWidget);
    expect(
      find.textContaining('字段补丁: {"data.product.sku":"fixed"}'),
      findsOneWidget,
    );
    expect(find.text('200'), findsNothing);
  });

  testWidgets('import and export preserve params and field patches', (
    tester,
  ) async {
    final files = _MemoryFiles()
      ..contents = jsonEncode([
        {
          ..._initial,
          'params': {'id': 123},
          'patchBody': {'data.product.sku': 'fixed'},
        },
      ]);
    await tester.pumpWidget(
      MaterialApp(
        home: MockPage(initialRules: const [], ruleFileTransfer: files),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入规则'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出规则'));
    await tester.pumpAndSettle();
    final exported = (jsonDecode(files.saved!) as List).single;
    expect(exported['params'], {'id': '123'});
    expect(exported['patchBody'], {'data.product.sku': 'fixed'});
  });
}
