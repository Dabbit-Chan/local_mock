import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:local_mock_core/local_mock_core.dart';

import '../app.dart';
import '../format.dart';
import '../panes/traffic_detail.dart';
import '../panes/traffic_list.dart';
import '../ui/primitives.dart';
import '../ui/theme.dart';
import 'home_page.dart' show deleteRecording;

/// `/recordings/:id` — a saved recording, readable without any device.
class RecordingPage extends StatefulWidget {
  const RecordingPage({super.key, required this.recordingId});

  final String recordingId;

  @override
  State<RecordingPage> createState() => _RecordingPageState();
}

class _RecordingPageState extends State<RecordingPage> {
  Entry? _selected;
  late List<Entry> _entries;
  TrafficSession? _session;

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final session = library.byId(widget.recordingId);
        if (!identical(session, _session)) {
          _session = session;
          _entries = [for (final e in session?.entries ?? const []) e.toJson()];
          _selected = null;
        }
        return AppFrame(
          crumbs: [
            const Crumb('录制', location: Routes.home),
            Crumb(session?.name ?? widget.recordingId),
          ],
          body: session == null
              ? EmptyState(
                  mark: '—',
                  title: library.loaded ? '找不到这段录制' : '正在读取本地录制…',
                  body: library.loaded
                      ? '录制只保存在录下它的浏览器里（同一地址和端口）。'
                            '换了浏览器或地址时，请在原处导出文件，再在这里导入。'
                      : null,
                  action: library.loaded
                      ? OutlinedButton(
                          onPressed: () => context.go(Routes.home),
                          child: const Text('返回首页'),
                        )
                      : null,
                )
              : _body(context, session),
        );
      },
    );
  }

  Widget _body(BuildContext context, TrafficSession session) {
    final p = context.palette;
    final library = AppScope.of(context).library;
    final replayable = session.replayableEntries.length;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.gutter,
                  Space.xl,
                  Space.gutter,
                  Space.l,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(session.name, style: context.text.headlineMedium),
                    const SizedBox(height: Space.m),
                    Fact('设备', '${session.deviceName}（${session.deviceId}）'),
                    Fact(
                      '时间',
                      '${formatDateTime(session.startedAt)} · '
                          '时长 ${formatDuration(session.endedAt - session.startedAt)}',
                    ),
                    Fact(
                      '请求',
                      '${session.entries.length} 条，其中 $replayable 条可生成 Mock',
                    ),
                    const SizedBox(height: Space.m),
                    Row(
                      children: [
                        OutlinedButton(
                          onPressed: () => unawaited(
                            library.export(session).catchError((Object e) {
                              if (context.mounted) {
                                toast(context, '导出失败：${describeError(e)}');
                              }
                            }),
                          ),
                          child: const Text('导出文件'),
                        ),
                        const SizedBox(width: Space.s),
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: p.signal,
                          ),
                          onPressed: () async {
                            if (await deleteRecording(
                                  context,
                                  library,
                                  session,
                                ) &&
                                context.mounted) {
                              context.go(Routes.home);
                            }
                          },
                          child: const Text('删除'),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.m),
                    Text(
                      '要把这段录制变成 Mock：进入设备调试页，在「规则」列的更多菜单中选择'
                      '「从录制生成录制组」。失败请求、二进制响应和无法还原的请求体只供查看，不会生成规则。',
                      style: context.text.bodySmall,
                    ),
                  ],
                ),
              ),
              const Hairline(strong: true),
              Expanded(
                child: TrafficList(
                  entries: _entries,
                  selected: _selected,
                  onSelect: (entry) => setState(() => _selected = entry),
                  empty: const EmptyState(title: '这段录制里没有请求'),
                ),
              ),
            ],
          ),
        ),
        const Hairline(vertical: true),
        Expanded(
          flex: 7,
          child: _selected == null
              ? const Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SectionHeading(index: '03', title: '请求详情'),
                    Hairline(strong: true),
                    Expanded(child: EmptyState(title: '在左侧选择一个请求查看详情')),
                  ],
                )
              : TrafficDetail(key: ObjectKey(_selected), entry: _selected!),
        ),
      ],
    );
  }
}
