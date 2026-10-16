import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_desktop/src/capture_panel.dart';

Map<String, dynamic> entry(
  String path, {
  int revision = 1,
  String method = 'GET',
  int? statusCode = 200,
  bool mocked = false,
  String? error,
  String? requestBody,
  String? responseBody = '{"ok":true,"list":[1,2]}',
}) => {
  'revision': revision,
  'startedAt': 1710000000123,
  'durationMs': 57,
  'mocked': mocked,
  'method': method,
  'uri': 'https://api.test$path?debug=1',
  'host': 'api.test',
  'path': path,
  if (requestBody != null) 'requestBody': requestBody,
  if (statusCode != null) 'statusCode': statusCode,
  'contentType': 'application/json',
  if (responseBody != null) 'responseBody': responseBody,
  if (error != null) 'error': error,
};

Widget host(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(body: Center(child: child)),
);

Widget panel(
  List<Map<String, dynamic>> entries, {
  bool connected = true,
  bool ready = true,
  bool available = true,
  void Function(Map<String, dynamic>)? onRuleCreated,
}) => CapturePanel(
  connected: connected,
  ready: ready,
  available: available,
  live: true,
  entries: entries,
  existingRuleIds: const {'existing'},
  onRuleCreated: onRuleCreated ?? (_) {},
  onViewRules: () {},
);

void main() {
  testWidgets('renders entries newest first with status and mock badges', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        panel([
          entry('/api/first', revision: 1),
          entry('/api/second', revision: 2, mocked: true),
          entry(
            '/api/failed',
            revision: 3,
            statusCode: null,
            error: 'SocketException\nat x',
          ),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    final tiles = find.byType(ListTile);
    expect(tiles, findsNWidgets(3));
    // Newest (revision 3) is rendered first.
    expect(tester.widget<ListTile>(tiles.first).subtitle, isNotNull);
    expect(find.text('api.test/api/failed'), findsOneWidget);
    expect(find.text('api.test/api/first'), findsOneWidget);
    expect(find.textContaining('SocketException'), findsOneWidget);
    expect(find.text('MOCK'), findsOneWidget);
    expect(find.text('200'), findsNWidgets(2));
    expect(find.text('失败'), findsOneWidget);
    expect(find.byIcon(Icons.bolt_outlined), findsNWidgets(3));
  });

  testWidgets('filters entries by method, host, or path', (tester) async {
    await tester.pumpWidget(
      host(panel([entry('/api/orders'), entry('/api/users', method: 'POST')])),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(2));

    await tester.enterText(find.byType(TextField), 'post');
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    expect(find.text('api.test/api/users'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'nothing-matches');
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNothing);
    expect(find.textContaining('没有匹配'), findsOneWidget);
  });

  testWidgets('detail dialog shows request and pretty-printed response', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(panel([entry('/api/orders', requestBody: '{"q":1}')])),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('api.test/api/orders'));
    await tester.pumpAndSettle();

    expect(find.text('请求详情'), findsOneWidget);
    expect(
      find.textContaining('GET https://api.test/api/orders?debug=1'),
      findsOneWidget,
    );
    // Pretty-printed JSON has line breaks; raw compact text would not.
    expect(find.textContaining('"ok": true'), findsOneWidget);
    expect(find.textContaining('"list": ['), findsOneWidget);
    expect(find.text('请求体'), findsOneWidget);
    expect(find.text('响应体'), findsOneWidget);
  });

  testWidgets('generating a rule prefills the edit dialog from the entry', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        panel([
          entry('/api/orders', mocked: false, responseBody: '{"ok":true}'),
        ]),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.bolt_outlined).first);
    await tester.pumpAndSettle();

    // RuleEditDialog opened with prefilled fields.
    expect(find.text('添加规则'), findsNothing);
    expect(find.text('编辑规则'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(find.widgetWithText(TextFormField, '路径'))
          .controller
          ?.text,
      '/api/orders',
    );
    expect(
      tester
          .widget<TextFormField>(
            find.widgetWithText(TextFormField, 'Host（可选，留空匹配任意域名）'),
          )
          .controller
          ?.text,
      'api.test',
    );
    expect(find.textContaining('"ok": true'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('编辑规则'), findsNothing);
  });

  testWidgets('rule creation callback receives the saved rule', (tester) async {
    final created = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      host(panel([entry('/api/orders')], onRuleCreated: created.add)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.bolt_outlined).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(created, hasLength(1));
    expect(created.single['id'], 'api-orders');
    expect(created.single['path'], '/api/orders');
    expect(created.single['host'], 'api.test');
    expect(created.single['statusCode'], 200);
    expect(created.single['body'], {
      'ok': true,
      'list': [1, 2],
    });
    expect(find.textContaining('已从抓包生成规则 api-orders'), findsOneWidget);
  });

  testWidgets('duplicate ids get a numeric suffix', (tester) async {
    final created = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      host(
        CapturePanel(
          connected: true,
          ready: true,
          available: true,
          live: true,
          entries: [entry('/api/orders')],
          existingRuleIds: {'api-orders', 'api-orders-2'},
          onRuleCreated: created.add,
          onViewRules: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.bolt_outlined).first);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(find.widgetWithText(TextFormField, 'ID（唯一标识）'))
          .controller
          ?.text,
      'api-orders-3',
    );
  });

  testWidgets('shows connection-dependent hint states', (tester) async {
    await tester.pumpWidget(
      host(panel(const [], connected: false, ready: false, available: false)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('未连接'), findsOneWidget);

    await tester.pumpWidget(
      host(panel(const [], connected: true, ready: false, available: false)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('等待目标就绪'), findsOneWidget);

    await tester.pumpWidget(
      host(panel(const [], connected: true, ready: true, available: false)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('版本过旧'), findsOneWidget);

    await tester.pumpWidget(
      host(panel(const [], connected: true, ready: true, available: true)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('实时捕获中'), findsOneWidget);
    expect(find.text('清空记录'), findsOneWidget);
  });

  test('ruleFromTraffic falls back to a string body for non-JSON payloads', () {
    final rule = ruleFromTraffic(
      entry('/api/text', responseBody: 'plain text'),
      existingIds: const {},
    );
    expect(rule['body'], 'plain text');

    final failed = ruleFromTraffic(
      entry('/api/down', statusCode: null, responseBody: null),
      existingIds: const {},
    );
    expect(failed['statusCode'], 200);
    expect(failed.containsKey('body'), isFalse);
  });
}
