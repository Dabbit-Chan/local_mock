import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_client/src/recording_mock_dialog.dart';
import 'package:local_mock_core/local_mock_core.dart';

Map<String, dynamic> fixture() => recordingMockFromSession(
  TrafficSession(
    id: 'flow',
    name: '录制流程',
    deviceId: 'phone',
    deviceName: '手机',
    startedAt: 1,
    endedAt: 3,
    entries: [
      for (final index in [1, 2])
        TrafficEntry(
          revision: index,
          startedAt: index,
          durationMs: 0,
          mocked: false,
          method: 'POST',
          uri: 'https://api.test/order?id=$index',
          path: '/order',
          requestBody: '{"id":$index}',
          statusCode: 200,
          responseBody: '{"value":$index}',
        ),
    ],
  ),
).toJson();

void main() {
  Future<void> open(
    WidgetTester tester,
    Map<String, dynamic> initial,
    ValueChanged<Map<String, dynamic>?> onSaved,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => onSaved(
                await showDialog<Map<String, dynamic>>(
                  context: context,
                  builder: (_) => RecordingMockDialog(
                    initial: initial,
                    existingIds: const {'duplicate'},
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'nested cancel discards edits and parent cancel leaves original group unchanged',
    (tester) async {
      final initial = fixture();
      Map<String, dynamic>? result;
      await open(tester, initial, (value) => result = value);
      await tester.tap(find.byTooltip('编辑接口').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, '路径'),
        '/changed',
      );
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(find.text('POST api.test/changed'), findsNothing);
      await tester.tap(find.text('只 Mock 录制时的传参'));
      await tester.tap(find.byTooltip('移除接口').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(initial, fixture());
    },
  );

  testWidgets(
    'nested save edits parameters response metadata and payload within the group',
    (tester) async {
      final initial = fixture();
      Map<String, dynamic>? result;
      await open(tester, initial, (value) => result = value);
      await tester.tap(find.text('只 Mock 录制时的传参'));
      await tester.tap(find.byTooltip('编辑接口').first);
      await tester.pumpAndSettle();
      final query = find.widgetWithText(TextFormField, '录制 query 参数 JSON');
      await tester.ensureVisible(query);
      await tester.enterText(query, '{"id":["99"]}');
      final body = find.widgetWithText(TextFormField, '录制请求体（文本 / JSON）');
      await tester.ensureVisible(body);
      await tester.enterText(body, '{"id":99}');
      final status = find.widgetWithText(TextFormField, '状态码');
      await tester.ensureVisible(status);
      await tester.enterText(status, '202');
      final response = find.widgetWithText(TextFormField, '响应体文本（支持 JSON）');
      await tester.ensureVisible(response);
      await tester.enterText(response, 'edited plain text');
      await tester.tap(find.text('保存').last);
      await tester.pumpAndSettle();
      expect(result, isNull);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result!['matchParams'], isTrue);
      final child = (result!['rules'] as List).first as Map<String, dynamic>;
      expect(child['statusCode'], 202);
      expect(child['responseText'], 'edited plain text');
      expect(child['body'], 'edited plain text');
      expect(child['recordedRequest'], {
        'query': {
          'id': ['99'],
        },
        'body': '{"id":99}',
      });
      expect(initial, fixture());
    },
  );

  testWidgets(
    'child toggles deletions and group naming remain draft until save',
    (tester) async {
      Map<String, dynamic>? result;
      await open(tester, fixture(), (value) => result = value);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Mock 组名称'),
        '修改后的录像',
      );
      await tester.tap(find.byType(Switch).at(1));
      await tester.tap(find.byTooltip('移除接口').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result!['name'], '修改后的录像');
      expect((result!['rules'] as List), hasLength(1));
      expect((result!['rules'] as List).single['enabled'], isFalse);
    },
  );

  testWidgets('empty groups and duplicate group IDs cannot be saved', (
    tester,
  ) async {
    Map<String, dynamic>? result;
    await open(tester, fixture(), (value) => result = value);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Mock 组 ID'),
      'duplicate',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('ID 已存在'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Mock 组 ID'),
      'valid',
    );
    await tester.tap(find.byTooltip('移除接口').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('移除接口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('至少保留一条接口规则'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('group interface reorder is preserved when saving', (
    tester,
  ) async {
    Map<String, dynamic>? result;
    await open(tester, fixture(), (value) => result = value);
    final list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    list.onReorderItem!(0, 1);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect((result!['rules'] as List).map((rule) => rule['id']), [
      'request-2',
      'request-1',
    ]);
  });
}
