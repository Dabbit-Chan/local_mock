import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_client/src/rule_edit_dialog.dart';

Widget host(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(body: Center(child: child)),
);

Future<Map<String, dynamic>?> openAndSave(
  WidgetTester tester,
  Map<String, dynamic> initial,
) async {
  Map<String, dynamic>? result;
  await tester.pumpWidget(
    host(
      Builder(
        builder: (context) => FilledButton(
          onPressed: () async {
            result = await showDialog<Map<String, dynamic>>(
              context: context,
              builder: (_) => RuleEditDialog(
                initial: initial,
                existingIds: const {'other'},
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('保存'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('params and patchBody fields round trip through the dialog', (
    tester,
  ) async {
    final result = await openAndSave(
      tester,
      const {
        'id': 'item',
        'enabled': true,
        'method': 'GET',
        'path': '/api/item',
        'params': {'id': '123'},
        'patchBody': {
          'data.product': {'sku': 'A1'},
        },
      },
    );
    expect(result, isNotNull);
    expect(result!['params'], {'id': '123'});
    expect(result['patchBody'], {
      'data.product': {'sku': 'A1'},
    });
  });

  testWidgets('entering params and patchBody includes them in the saved rule', (
    tester,
  ) async {
    Map<String, dynamic>? result;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await showDialog<Map<String, dynamic>>(
                context: context,
                builder: (_) => const RuleEditDialog(
                  isNewRule: true,
                  initial: {
                    'id': 'rule-1',
                    'enabled': true,
                    'method': 'GET',
                    'path': '/',
                    'statusCode': 200,
                    'delayMs': 0,
                  },
                  existingIds: {},
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, '参数匹配（可选）'),
      '{"id": 123}',
    );
    await tester.pump();
    await tester.enterText(
      find.widgetWithText(TextFormField, '字段补丁（可选）'),
      '{"data.status": "PAID"}',
    );
    await tester.pump();

    // The patch hint appears once a patch body is being typed.
    expect(find.textContaining('已启用字段补丁'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // The saved rule carries both fields; params values are stringified.
    expect(result, isNotNull);
    expect(result!['params'], {'id': '123'});
    expect(result!['patchBody'], {'data.status': 'PAID'});
  });

  testWidgets('non-primitive params values are rejected before saving', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () => showDialog<Map<String, dynamic>>(
              context: context,
              builder: (_) => const RuleEditDialog(
                isNewRule: true,
                initial: {
                  'id': 'rule-1',
                  'enabled': true,
                  'method': 'GET',
                  'path': '/',
                  'statusCode': 200,
                  'delayMs': 0,
                },
                existingIds: {},
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, '参数匹配（可选）'),
      '{"id": [1]}',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('参数的值只能是'), findsOneWidget);
    expect(find.text('添加规则'), findsOneWidget);
  });
}
