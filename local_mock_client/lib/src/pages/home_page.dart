import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:local_mock_core/local_mock_core.dart';

import '../app.dart';
import '../format.dart';
import '../mock_connection.dart';
import '../recording_library.dart';
import '../ui/primitives.dart';
import '../ui/theme.dart';

/// `/` — every app that has connected to this relay, and the recordings
/// saved in this browser.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    return AppFrame(
      crumbs: const [Crumb('设备')],
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 8,
            child: ListenableBuilder(
              listenable: services.connection,
              builder: (context, _) =>
                  _DeviceColumn(connection: services.connection),
            ),
          ),
          const Hairline(vertical: true),
          Expanded(
            flex: 4,
            child: ListenableBuilder(
              listenable: Listenable.merge([
                services.library,
                services.connection,
              ]),
              builder: (context, _) => _RecordingColumn(
                library: services.library,
                connection: services.connection,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ColumnHeader extends StatelessWidget {
  const _ColumnHeader({
    required this.index,
    required this.title,
    required this.summary,
    this.action,
  });

  final String index;
  final String title;
  final String summary;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.gutter,
        Space.xxl,
        Space.gutter,
        Space.xl,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(index, style: mono(context, size: 12, color: p.signal)),
                const SizedBox(height: Space.s),
                Text(title, style: context.text.displayMedium),
                const SizedBox(height: Space.m),
                Text(
                  summary,
                  style: context.text.bodyMedium!.copyWith(color: p.muted),
                ),
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _DeviceColumn extends StatelessWidget {
  const _DeviceColumn({required this.connection});

  final MockConnection connection;

  @override
  Widget build(BuildContext context) {
    final devices = connection.targets;
    final online = devices.where((d) => d.online).length;
    final summary = !connection.connected
        ? connection.status
        : devices.isEmpty
        ? '还没有 App 连接到 ${pageOrigin()}'
        : '$online 台在线${devices.length > online ? ' · ${devices.length - online} 台离线' : ''}'
              ' · 选择一台设备进入调试';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ColumnHeader(index: '01', title: '设备', summary: summary),
        const Hairline(strong: true),
        Expanded(
          child: !connection.connected
              ? _RelayOffline(connection: connection)
              : devices.isEmpty
              ? const _ConnectGuide()
              : ListView.separated(
                  itemCount: devices.length,
                  separatorBuilder: (_, _) => const Hairline(),
                  itemBuilder: (context, index) => _DeviceRow(
                    device: devices[index],
                    connection: connection,
                  ),
                ),
        ),
      ],
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, required this.connection});

  final MockTarget device;
  final MockConnection connection;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final current = connection.selectedId == device.id;
    final recording = current && connection.recording;
    // Offline devices only open when this page still holds their data.
    final openable = device.online || current;
    return ListRow(
      onTap: openable ? () => context.go(Routes.device(device.id)) : null,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.gutter,
        vertical: 18,
      ),
      child: Row(
        children: [
          StatusSquare(on: device.online),
          const SizedBox(width: Space.l),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.name,
                  style: context.text.headlineSmall!.copyWith(
                    color: device.online ? p.ink : p.muted,
                  ),
                ),
                const SizedBox(height: 4),
                Text(device.id, style: mono(context, size: 12, color: p.muted)),
              ],
            ),
          ),
          if (recording) ...[
            const Tag('录制中', tone: TagTone.signal),
            const SizedBox(width: Space.s),
          ],
          if (current && device.online) ...[
            const Tag('当前', tone: TagTone.outline),
            const SizedBox(width: Space.s),
          ],
          SizedBox(
            width: 64,
            child: Text(
              device.online ? '在线' : '离线',
              textAlign: TextAlign.right,
              style: context.text.labelLarge!.copyWith(
                color: device.online ? p.ink : p.faint,
              ),
            ),
          ),
          const SizedBox(width: Space.l),
          Icon(
            Icons.arrow_forward,
            size: 20,
            color: openable ? p.ink : Colors.transparent,
          ),
        ],
      ),
    );
  }
}

class _RelayOffline extends StatelessWidget {
  const _RelayOffline({required this.connection});

  final MockConnection connection;

  @override
  Widget build(BuildContext context) => EmptyState(
    mark: '—',
    title: '正在连接 Relay',
    body:
        '${connection.status}\n\n'
        '页面每 2 秒自动重试。控制台必须由 tool/relay_host.dart 托管'
        '（例如 http://127.0.0.1:9090/）才能连上 Relay；'
        '通过 flutter run 打开的页面只能预览界面，会一直重试。',
  );
}

/// Shown when the relay is up but no app has connected yet.
class _ConnectGuide extends StatelessWidget {
  const _ConnectGuide();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final origin = pageOrigin();
    final host = Uri.parse(origin).host;
    final loopback =
        host == 'localhost' || host == '127.0.0.1' || host == '::1';
    final snippet =
        "LocalMockDio.attach(dio);          // 或 LocalMockHttp.install();\n"
        "LocalMock.connect(\n"
        "  serverUrl: '$origin',\n"
        "  deviceId: installationId,       // 每个 App 安装唯一且稳定\n"
        "  deviceName: 'QA Android',\n"
        ");";

    Widget step(String n, String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: Space.xl),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 40,
            child: Text(n, style: mono(context, size: 13, color: p.signal)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.text.titleMedium),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: context.text.bodyMedium!.copyWith(color: p.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(Space.gutter),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('接入一台设备', style: context.text.headlineMedium),
            const SizedBox(height: Space.xl),
            step(
              '1',
              '在 App 中接入适配器并连接这个 Relay',
              'Dio 用 local_mock_dio，HttpClient / package:http 用 local_mock_http。'
                  '适配器要在业务请求发出前接入。',
            ),
            Container(
              margin: const EdgeInsets.only(left: 40, bottom: Space.xl),
              padding: const EdgeInsets.all(Space.l),
              width: double.infinity,
              color: p.well,
              child: SelectableText(snippet, style: mono(context, size: 12.5)),
            ),
            step(
              '2',
              '以 Debug 或 Profile 模式运行 App',
              'Release 构建中 local_mock 完全禁用。连接在后台进行，失败时每 2 秒重试，不会阻塞业务请求。',
            ),
            step(
              '3',
              '设备会自动出现在这里',
              '点击设备进入调试页：编辑 Mock 规则、查看 App 发出的请求、录制一段操作。',
            ),
            if (loopback)
              Notice(
                signal: false,
                message:
                    '当前地址 $origin 只有本机能访问。真机请连接电脑的局域网地址，'
                    '或用 cloudflared tunnel --url $origin 暴露一个 HTTPS 地址，'
                    '再把该地址填入 serverUrl。',
              ),
          ],
        ),
      ),
    );
  }
}

class _RecordingColumn extends StatelessWidget {
  const _RecordingColumn({required this.library, required this.connection});

  final RecordingLibrary library;
  final MockConnection connection;

  Future<void> _import(BuildContext context) async {
    try {
      final session = await library.importFile();
      if (session != null && context.mounted) {
        toast(context, '已导入录制「${session.name}」');
      }
    } catch (error) {
      if (context.mounted) toast(context, '导入失败：${describeError(error)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessions = library.sessions;
    final pending = connection.pendingRecording;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ColumnHeader(
          index: '02',
          title: '录制',
          summary: library.loaded ? '${sessions.length} 段 · 保存在当前浏览器' : '读取中…',
          action: OutlinedButton(
            onPressed: library.loaded
                ? () => unawaited(_import(context))
                : null,
            child: const Text('导入文件'),
          ),
        ),
        const Hairline(strong: true),
        if (library.loadError != null)
          Notice(
            message: library.loadError!,
            actions: [
              TextButton(
                onPressed: () => unawaited(library.load()),
                child: const Text('重试'),
              ),
            ],
          ),
        if (pending != null && library.saveError != null)
          PendingRecordingNotice(library: library, session: pending),
        Expanded(
          child: sessions.isEmpty
              ? const EmptyState(
                  title: '还没有录制',
                  body:
                      '在设备调试页点击「录制」，在 App 里完成一段操作后停止，'
                      '这段时间内完成的请求会保存在这里，可离线查看、导出分享，'
                      '或一键生成一组 Mock 规则。',
                )
              : ListView.separated(
                  itemCount: sessions.length,
                  separatorBuilder: (_, _) => const Hairline(),
                  itemBuilder: (context, index) =>
                      RecordingRow(session: sessions[index], library: library),
                ),
        ),
      ],
    );
  }
}

/// Recording list row with export / delete on hover.
class RecordingRow extends StatelessWidget {
  const RecordingRow({super.key, required this.session, required this.library});

  final TrafficSession session;
  final RecordingLibrary library;

  @override
  Widget build(BuildContext context) {
    return ListRow(
      onTap: () => context.go(Routes.recording(session.id)),
      hoverActions: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ToolButton(
            icon: Icons.file_download_outlined,
            tooltip: '导出为文件',
            onPressed: () => unawaited(library.export(session)),
          ),
          ToolButton(
            icon: Icons.delete_outline,
            tooltip: '删除',
            onPressed: () =>
                unawaited(deleteRecording(context, library, session)),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            session.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            '${session.entries.length} 条请求 · ${session.deviceName} · '
            '${formatDateTime(session.startedAt)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Asks, then deletes. Returns true when the recording was deleted.
Future<bool> deleteRecording(
  BuildContext context,
  RecordingLibrary library,
  TrafficSession session,
) async {
  final ok = await confirm(
    context,
    title: '删除录制',
    body:
        '「${session.name}」将从当前浏览器中删除，无法恢复。'
        '已经由它生成的录制组规则不受影响。',
    confirmLabel: '删除',
    destructive: true,
  );
  if (!ok) return false;
  try {
    await library.delete(session);
    return true;
  } catch (error) {
    if (context.mounted) toast(context, '删除失败：${describeError(error)}');
    return false;
  }
}

/// A finished recording that could not be written to browser storage.
class PendingRecordingNotice extends StatelessWidget {
  const PendingRecordingNotice({
    super.key,
    required this.library,
    required this.session,
  });

  final RecordingLibrary library;
  final TrafficSession session;

  @override
  Widget build(BuildContext context) => Notice(
    message:
        '录制「${session.name}」未能保存：${library.saveError}。'
        '它仍在页面内存中，刷新或关闭页面会丢失。',
    actions: [
      TextButton(
        onPressed: library.saving
            ? null
            : () => unawaited(library.savePending()),
        child: const Text('重试保存'),
      ),
      TextButton(
        onPressed: () => unawaited(
          library.exportPending().catchError((Object error) {
            if (context.mounted) {
              toast(context, '导出失败：${describeError(error)}');
            }
          }),
        ),
        child: const Text('导出文件'),
      ),
    ],
  );
}
