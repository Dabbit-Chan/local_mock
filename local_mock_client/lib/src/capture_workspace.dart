import 'dart:async';

import 'package:flutter/material.dart';
import 'package:local_mock_core/local_mock_core.dart';

import 'capture_panel.dart';
import 'capture_session_store.dart';
import 'mock_connection.dart';
import 'recording_mock_dialog.dart';

class CaptureWorkspace extends StatefulWidget {
  const CaptureWorkspace({
    super.key,
    required this.connection,
    required this.existingRuleIds,
    required this.onRuleCreated,
    required this.onViewRules,
    this.recordingMocks = const [],
    this.store = const CaptureSessionStore(),
  });

  final MockConnection connection;
  final Set<String> existingRuleIds;
  final ValueChanged<Map<String, dynamic>> onRuleCreated;
  final VoidCallback onViewRules;
  final CaptureSessionStore store;
  final List<Map<String, dynamic>> recordingMocks;

  @override
  State<CaptureWorkspace> createState() => _CaptureWorkspaceState();
}

class _CaptureWorkspaceState extends State<CaptureWorkspace> {
  List<TrafficSession> _sessions = [];
  String? _selectedId;
  String? _message;
  bool _loaded = false;
  bool _busy = false;
  bool _saving = false;
  String? _attemptedSave;

  TrafficSession? get _selected {
    for (final session in _sessions) {
      if (session.id == _selectedId) return session;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    widget.connection.addListener(_connectionChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.connection.removeListener(_connectionChanged);
    super.dispose();
  }

  void _connectionChanged() {
    final pending = widget.connection.pendingRecording;
    if (_loaded &&
        !_busy &&
        !_saving &&
        pending != null &&
        _attemptedSave != pending.id) {
      unawaited(_savePending());
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() => _message = error.toString().split('\n').first);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _connectionChanged();
      }
    }
  }

  Future<void> _load() => _run(() async {
    final sessions = await widget.store.load();
    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _loaded = true;
    });
  });

  Future<void> _persist(List<TrafficSession> sessions) async {
    if (!_loaded) throw StateError('请先成功加载本地录制');
    await widget.store.save(sessions);
    if (mounted) setState(() => _sessions = sessions);
  }

  Future<void> _savePending() async {
    final session = widget.connection.pendingRecording;
    if (session == null || _saving) return;
    _saving = true;
    _attemptedSave = session.id;
    await _run(() async {
      await _persist([
        session,
        ..._sessions.where((saved) => saved.id != session.id),
      ]);
      widget.connection.acknowledgeRecording(session.id);
      if (mounted) {
        setState(
          () =>
              _message = '已保存录制“${session.name}”（${session.entries.length} 条）',
        );
      }
    });
    _saving = false;
  }

  Future<void> _startRecording() async {
    var draftName =
        '录制 ${DateTime.now().toLocal().toString().split('.').first}';
    final deviceId = widget.connection.selectedId;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('开始录制'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                initialValue: draftName,
                onChanged: (value) => draftName = value,
                autofocus: true,
                maxLength: 100,
                decoration: const InputDecoration(labelText: '录制名称'),
                onFieldSubmitted: (value) {
                  if (value.trim().isNotEmpty) {
                    Navigator.pop(context, value.trim());
                  }
                },
              ),
              const SizedBox(height: 12),
              const Text(
                '记录开始后完成的请求，停止后保存到当前浏览器。录制期间请保持页面和设备连接。请求可能包含敏感信息，分享前请检查。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (draftName.trim().isNotEmpty) {
                Navigator.pop(context, draftName.trim());
              }
            },
            child: const Text('开始'),
          ),
        ],
      ),
    );
    if (!mounted || name == null) return;
    if (deviceId != widget.connection.selectedId) {
      throw StateError('设备已变更，请重新开始录制');
    }
    widget.connection.startRecording(name);
    setState(() => _selectedId = null);
  }

  Future<void> _import() async {
    final session = await widget.store.importSession();
    if (session == null || !mounted) return;
    if (_sessions.any((saved) => saved.id == session.id)) {
      throw StateError('该录制已存在，请先删除同名 ID 的录制后再导入');
    }
    await _persist([session, ..._sessions]);
    if (mounted) setState(() => _selectedId = session.id);
  }

  Future<void> _delete(TrafficSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除录制'),
        content: Text('确定删除“${session.name}”？此操作不能撤销。已创建的录制 Mock 组不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _persist(_sessions.where((saved) => saved.id != session.id).toList());
    if (mounted) setState(() => _selectedId = null);
  }

  Future<void> _replay(TrafficSession session) async {
    final deviceId = widget.connection.selectedId;
    final previous = widget.recordingMocks
        .where((group) => group['recordingId'] == session.id)
        .firstOrNull;
    final existingIds = widget.existingRuleIds.difference({
      if (previous != null) previous['id'] as String,
    });
    var id = 'recording-${session.id}';
    var suffix = 2;
    while (existingIds.contains(id)) {
      id = 'recording-${session.id}-${suffix++}';
    }
    final configured = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => RecordingMockDialog(
        initial: previous == null
            ? recordingMockFromSession(session, id: id).toJson()
            : {...previous, 'enabled': true},
        existingIds: existingIds,
        isNew: previous == null,
      ),
    );
    if (configured == null || !mounted) return;
    if (deviceId != widget.connection.selectedId) {
      throw StateError('设备已变更，请重新配置录制 Mock');
    }
    if (previous != null && !widget.recordingMocks.contains(previous)) {
      throw StateError('录制 Mock 已变更，请重新打开配置');
    }
    widget.onRuleCreated(configured);
    if (mounted) {
      setState(
        () => _message =
            '已保存录制 Mock“${configured['name']}”，可在 Mock 规则页整组开关和编辑；连接就绪时自动同步。',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final connection = widget.connection;
    final selected = _selected;
    final pending = connection.pendingRecording;
    final enabled = !_busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed:
                  enabled &&
                      _loaded &&
                      (connection.recording ||
                          (connection.ready && pending == null))
                  ? () {
                      if (connection.recording) {
                        connection.stopRecording();
                      } else {
                        unawaited(_run(_startRecording));
                      }
                    }
                  : null,
              icon: Icon(
                connection.recording ? Icons.stop : Icons.fiber_manual_record,
              ),
              label: Text(connection.recording ? '停止并保存' : '开始录制'),
            ),
            if (connection.recording)
              Text(
                '正在录制“${connection.recordingName}” · ${connection.recordedCount} 条',
              ),
            if (!_loaded && enabled)
              TextButton(
                onPressed: () => unawaited(_load()),
                child: const Text('重试加载录制'),
              ),
            if (pending != null) ...[
              OutlinedButton(
                onPressed: enabled && _loaded
                    ? () => unawaited(_savePending())
                    : null,
                child: const Text('重试保存录制'),
              ),
              OutlinedButton(
                onPressed: enabled
                    ? () => unawaited(
                        _run(() async {
                          await widget.store.exportSession(pending);
                          connection.acknowledgeRecording(pending.id);
                        }),
                      )
                    : null,
                child: const Text('导出未保存录制'),
              ),
            ],
            OutlinedButton.icon(
              onPressed: enabled && _loaded
                  ? () => unawaited(_run(_import))
                  : null,
              icon: const Icon(Icons.file_upload_outlined),
              label: const Text('导入录制'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        DropdownButton<String>(
          value: _selectedId ?? '',
          isExpanded: true,
          items: [
            const DropdownMenuItem(value: '', child: Text('实时抓包')),
            for (final session in _sessions)
              DropdownMenuItem(
                value: session.id,
                child: Text(
                  '${session.name} · ${session.entries.length} 条 · ${session.deviceName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: enabled
              ? (value) =>
                    setState(() => _selectedId = value == '' ? null : value)
              : null,
        ),
        if (selected != null) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed:
                    enabled &&
                        (!connection.connected ||
                            connection.supportsRecordingMocks) &&
                        !connection.recording &&
                        selected.replayableEntries.isNotEmpty
                    ? () => unawaited(_run(() => _replay(selected)))
                    : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('回放 / 配置 Mock'),
              ),
              OutlinedButton.icon(
                onPressed: enabled
                    ? () => unawaited(
                        _run(() => widget.store.exportSession(selected)),
                      )
                    : null,
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('导出录制'),
              ),
              TextButton.icon(
                onPressed: enabled
                    ? () => unawaited(_run(() => _delete(selected)))
                    : null,
                icon: const Icon(Icons.delete_outline),
                label: const Text('删除录制'),
              ),
              Text(
                '${selected.replayableEntries.length} 条可回放',
              ),
              if (connection.ready && !connection.supportsRecordingMocks)
                const Text('请更新 App 的 core / 适配器以支持录制 Mock'),
            ],
          ),
        ],
        if (_message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SelectableText(_message!),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: CapturePanel(
            connected: connection.connected,
            ready: connection.ready,
            available: connection.captureAvailable,
            live: connection.captureLive,
            historyName: selected?.name,
            entries: selected == null
                ? connection.traffic
                : [for (final entry in selected.entries) entry.toJson()],
            existingRuleIds: widget.existingRuleIds,
            onRuleCreated: widget.onRuleCreated,
            onViewRules: widget.onViewRules,
            onClear:
                selected == null &&
                    connection.ready &&
                    connection.captureAvailable
                ? () => unawaited(_run(connection.clearTraffic))
                : null,
          ),
        ),
      ],
    );
  }
}
