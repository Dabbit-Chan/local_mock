import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../format.dart';
import '../pages/home_page.dart' show PendingRecordingNotice;
import '../ui/primitives.dart';
import '../ui/theme.dart';
import 'traffic_list.dart';

/// Column 02: live requests from the device, plus recording controls.
class TrafficPane extends StatefulWidget {
  const TrafficPane({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.onCreateRule,
  });

  final Entry? selected;
  final ValueChanged<Entry> onSelect;
  final ValueChanged<Entry> onCreateRule;

  @override
  State<TrafficPane> createState() => _TrafficPaneState();
}

class _TrafficPaneState extends State<TrafficPane> {
  final _name = TextEditingController();
  bool _naming = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _beginNaming() {
    _name.text = '录制 ${formatDateTime(DateTime.now().millisecondsSinceEpoch)}';
    _name.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _name.text.length,
    );
    setState(() => _naming = true);
  }

  void _start() {
    final connection = AppScope.of(context).connection;
    try {
      connection.startRecording(_name.text);
      setState(() => _naming = false);
    } catch (error) {
      toast(context, '无法开始录制：${describeError(error)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final connection = services.connection;
    final library = services.library;
    return ListenableBuilder(
      listenable: Listenable.merge([connection, library]),
      builder: (context, _) {
        final pending = connection.pendingRecording;
        final canRecord = library.loaded && connection.ready && pending == null;
        final p = context.palette;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeading(
              index: '02',
              title: '请求',
              count: '${connection.traffic.length}',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ToolButton(
                    icon: Icons.delete_sweep_outlined,
                    tooltip: '清空设备上的请求记录',
                    onPressed: connection.ready
                        ? () => unawaited(
                            connection.clearTraffic().catchError((Object e) {
                              if (context.mounted) {
                                toast(context, '清空失败：${describeError(e)}');
                              }
                            }),
                          )
                        : null,
                  ),
                  const SizedBox(width: Space.s),
                  if (connection.recording)
                    FilledButton(
                      key: const Key('stop-recording'),
                      style: FilledButton.styleFrom(
                        backgroundColor: p.signal,
                        foregroundColor: p.onSignal,
                      ),
                      onPressed: connection.stopRecording,
                      child: const Text('■  停止并保存'),
                    )
                  else
                    OutlinedButton(
                      key: const Key('start-recording'),
                      onPressed: canRecord && !_naming ? _beginNaming : null,
                      child: Text(
                        '●  录制',
                        style: TextStyle(
                          color: canRecord && !_naming ? p.signal : null,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Hairline(strong: true),
            if (_naming && !connection.recording) _namingBar(context),
            if (connection.recording)
              Notice(
                leading: const _Blink(),
                message:
                    '正在录制「${connection.recordingName}」· 已记录 ${connection.recordedCount} 条。'
                    '只收录开始之后完成的请求，请保持本页打开、设备在线。',
              ),
            if (pending != null && library.saveError != null)
              PendingRecordingNotice(library: library, session: pending),
            Expanded(
              child: TrafficList(
                entries: connection.traffic,
                selected: widget.selected,
                onSelect: widget.onSelect,
                onCreateRule: widget.onCreateRule,
                empty: EmptyState(
                  title: connection.ready ? '等待请求' : '没有请求记录',
                  body: connection.ready
                      ? '在 App 中操作，经过 local_mock 适配器的请求会实时出现在这里。'
                            '设备最多保留最近 500 条。'
                      : '设备连接后，这里会显示它发出的请求。',
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _namingBar(BuildContext context) => Container(
    color: context.palette.well,
    padding: const EdgeInsets.symmetric(
      horizontal: Space.gutter,
      vertical: Space.m,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('recording-name'),
                controller: _name,
                autofocus: true,
                maxLength: 100,
                decoration: const InputDecoration(
                  hintText: '录制名称',
                  counterText: '',
                ),
                onSubmitted: (_) => _start(),
              ),
            ),
            const SizedBox(width: Space.s),
            OutlinedButton(
              onPressed: () => setState(() => _naming = false),
              child: const Text('取消'),
            ),
            const SizedBox(width: Space.s),
            FilledButton(
              key: const Key('confirm-recording'),
              onPressed: _start,
              child: const Text('开始录制'),
            ),
          ],
        ),
        const SizedBox(height: Space.s),
        Text(
          '停止后自动保存到当前浏览器。请求和响应可能含账号、令牌等敏感信息，导出分享前请检查。',
          style: context.text.bodySmall,
        ),
      ],
    ),
  );
}

class _Blink extends StatelessWidget {
  const _Blink();

  @override
  Widget build(BuildContext context) =>
      Container(width: 10, height: 10, color: context.palette.onSignal);
}
