import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:local_mock_core/local_mock_core.dart';

import '../app.dart';
import '../format.dart';
import '../mock_connection.dart';
import '../rule_book.dart';
import '../rule_drafts.dart';
import '../panes/group_editor.dart';
import '../panes/rule_editor.dart';
import '../panes/rules_pane.dart';
import '../panes/traffic_detail.dart';
import '../panes/traffic_list.dart';
import '../panes/traffic_pane.dart';
import '../ui/primitives.dart';
import '../ui/theme.dart';

/// What column 03 shows.
sealed class Inspect {
  const Inspect();
}

class InspectNothing extends Inspect {
  const InspectNothing();
}

class InspectTraffic extends Inspect {
  const InspectTraffic(this.entry);
  final Entry entry;
}

/// Editing a rule; [original] is null for a rule that is not saved yet.
class InspectRule extends Inspect {
  const InspectRule(this.draft, {this.original});
  final Rule draft;
  final Rule? original;
}

class InspectGroup extends Inspect {
  const InspectGroup(this.draft, {this.original});
  final Rule draft;
  final Rule? original;
}

/// `/devices/:deviceId` — rules, live requests and the inspector side by
/// side.
class DevicePage extends StatefulWidget {
  const DevicePage({super.key, required this.deviceId});

  final String deviceId;

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  late final AppServices _services = AppScope.of(context);
  MockConnection get _connection => _services.connection;
  RuleBook get _book => _services.rules;

  Inspect _inspect = const InspectNothing();
  bool _dirty = false;
  bool _seen = false;
  String? _selectError;
  bool _selecting = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_listening) {
      _listening = true;
      _connection.addListener(_reconcile);
      _book.addListener(_rulesChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) => _reconcile());
    }
  }

  bool _listening = false;

  @override
  void dispose() {
    _connection.removeListener(_reconcile);
    _book.removeListener(_rulesChanged);
    super.dispose();
  }

  MockTarget? get _target {
    for (final target in _connection.targets) {
      if (target.id == widget.deviceId) return target;
    }
    return null;
  }

  bool get _active => _connection.selectedId == widget.deviceId;

  /// Points the connection at this page's device whenever it is online but
  /// another (or no) device is selected — e.g. after a relay reconnect.
  void _reconcile() {
    if (!mounted) return;
    if (_active && !_seen) setState(() => _seen = true);
    final target = _target;
    if (_active ||
        _selecting ||
        !_connection.connected ||
        _connection.working ||
        target == null ||
        !target.online) {
      return;
    }
    _selecting = true;
    unawaited(
      _connection
          .selectTarget(widget.deviceId)
          .then((_) {
            if (mounted) setState(() => _selectError = null);
          })
          .catchError((Object error) {
            if (mounted) setState(() => _selectError = describeError(error));
          })
          .whenComplete(() => _selecting = false),
    );
  }

  /// Keeps an open, unmodified editor pointing at the live rule object
  /// after the device replaced the list.
  void _rulesChanged() {
    if (!mounted || _dirty) return;
    final current = _inspect;
    final original = switch (current) {
      InspectRule(:final original) => original,
      InspectGroup(:final original) => original,
      _ => null,
    };
    if (original == null || _book.rules.any((r) => identical(r, original))) {
      return;
    }
    final fresh = _book.byId(original['id'] as String);
    setState(() {
      _inspect = fresh == null
          ? const InspectNothing()
          : isGroup(fresh)
          ? InspectGroup(fresh, original: fresh)
          : InspectRule(fresh, original: fresh);
    });
  }

  Future<void> _show(Inspect next) async {
    if (_dirty &&
        !await confirm(
          context,
          title: '放弃未保存的修改？',
          body: '当前编辑器中的修改还没有保存。',
          confirmLabel: '放弃修改',
          destructive: true,
        )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _dirty = false;
      _inspect = next;
    });
  }

  void _openRule(Rule rule) => unawaited(
    _show(
      isGroup(rule)
          ? InspectGroup(rule, original: rule)
          : InspectRule(rule, original: rule),
    ),
  );

  void _newRule() =>
      unawaited(_show(InspectRule(blankRule(_book.nextRuleId()))));

  void _ruleFromTraffic(Entry entry) => unawaited(
    _show(InspectRule(ruleFromTraffic(entry, existingIds: _book.ids))),
  );

  void _groupFromRecording(TrafficSession session) {
    if (_connection.connected && !_connection.supportsRecordingMocks) {
      toast(context, '设备上的 local_mock 版本不支持录制组，请升级 App 中的 core 和适配器');
      return;
    }
    try {
      final (:group, :isNew) = groupForSession(session, _book);
      unawaited(
        _show(
          isNew ? InspectGroup(group) : InspectGroup(group, original: group),
        ),
      );
    } catch (error) {
      toast(context, describeError(error));
    }
  }

  Future<void> _saveRule(Rule? original, Rule rule) async {
    // A stale [original] throws synchronously and reaches the editor; push
    // failures are asynchronous and surface through [RuleBook.syncError].
    final saving = original == null
        ? _book.add(rule)
        : _book.replace(original, rule);
    await saving.catchError((_) {});
    if (!mounted) return;
    final saved = _book.byId(rule['id'] as String) ?? rule;
    setState(() {
      _dirty = false;
      _inspect = isGroup(saved)
          ? InspectGroup(saved, original: saved)
          : InspectRule(saved, original: saved);
    });
    final error = _book.syncError;
    toast(
      context,
      error == null
          ? (_connection.ready ? '已保存并同步到设备' : '已保存（设备未连接，尚未同步）')
          : '已保存，但同步失败：$error',
    );
  }

  Future<void> _saveGroup(Rule? original, Rule group) async {
    if (original != null &&
        !_book.rules.any((rule) => identical(rule, original))) {
      throw StateError('这个录制组已被设备或其他操作更新，请重新打开后再保存');
    }
    await _book.upsertGroup(group).catchError((_) {});
    if (!mounted) return;
    final saved = _book.byId(group['id'] as String) ?? group;
    setState(() {
      _dirty = false;
      _inspect = InspectGroup(saved, original: saved);
    });
    final error = _book.syncError;
    toast(
      context,
      error == null ? '录制组「${group['name']}」已保存' : '录制组已保存，但同步失败：$error',
    );
  }

  void _delete(Rule rule) {
    final inspected = switch (_inspect) {
      InspectRule(:final original) => original,
      InspectGroup(:final original) => original,
      _ => null,
    };
    final index = _book.remove(rule);
    if (index < 0) return;
    if (identical(inspected, rule)) {
      setState(() {
        _dirty = false;
        _inspect = const InspectNothing();
      });
    }
    final label = isGroup(rule) ? '录制组「${rule['name']}」' : '规则 ${rule['id']}';
    toast(
      context,
      '已删除$label',
      actionLabel: '撤销',
      onAction: () {
        if (_book.byId(rule['id'] as String) == null) {
          unawaited(_book.insert(index, rule).catchError((_) {}));
        }
      },
    );
  }

  void _cancelEdit() => unawaited(_show(const InspectNothing()));

  void _setDirty(bool dirty) {
    if (_dirty != dirty) setState(() => _dirty = dirty);
  }

  // ---- build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _connection,
    builder: (context, _) {
      final target = _target;
      final name = target?.name ?? widget.deviceId;
      return AppFrame(
        crumbs: [
          const Crumb('设备', location: Routes.home),
          Crumb(name),
        ],
        status: _active || _seen ? _StatusText(connection: _connection) : null,
        body: _body(context, target),
      );
    },
  );

  Widget _body(BuildContext context, MockTarget? target) {
    final retained = _seen && !_active;
    if (!_active && !retained) {
      if (_selectError != null) {
        return EmptyState(
          mark: '!',
          title: '无法打开这台设备',
          body: _selectError,
          action: FilledButton(
            onPressed: () {
              setState(() => _selectError = null);
              _reconcile();
            },
            child: const Text('重试'),
          ),
        );
      }
      if (target != null && target.online && _connection.connected) {
        return const Column(
          children: [
            LinearProgressIndicator(),
            Expanded(child: SizedBox()),
          ],
        );
      }
      return EmptyState(
        mark: '—',
        title: _connection.connected ? '设备不在线' : '正在连接 Relay',
        body: _connection.connected
            ? '设备 ${widget.deviceId} 当前没有连接。App 重新调用 LocalMock.connect 后，'
                  '本页会自动载入它的规则和请求。'
            : '${_connection.status}。连上之后，如果这台设备在线会自动载入。',
        action: OutlinedButton(
          onPressed: () => context.go(Routes.home),
          child: const Text('返回设备列表'),
        ),
      );
    }

    final online = _active && target?.online == true && _connection.connected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_connection.working)
          const LinearProgressIndicator()
        else
          const SizedBox(height: 2),
        if (!online)
          Notice(
            message: _connection.connected
                ? '设备已离线。下面是断开前的规则和请求；App 内已生效的规则不受影响，设备重新连接后自动刷新。'
                : 'Relay 连接已断开，正在重连。下面是断开前的数据，期间的修改不会同步到设备。',
          ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 3,
                child: RulesPane(
                  selected: switch (_inspect) {
                    InspectRule(:final original) => original,
                    InspectGroup(:final original) => original,
                    _ => null,
                  },
                  onOpen: _openRule,
                  onNew: _newRule,
                  onFromRecording: _groupFromRecording,
                  onDelete: _delete,
                ),
              ),
              const Hairline(vertical: true),
              Expanded(
                flex: 4,
                child: TrafficPane(
                  selected: switch (_inspect) {
                    InspectTraffic(:final entry) => entry,
                    _ => null,
                  },
                  onSelect: (entry) => unawaited(_show(InspectTraffic(entry))),
                  onCreateRule: _ruleFromTraffic,
                ),
              ),
              const Hairline(vertical: true),
              Expanded(flex: 5, child: _inspector()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _inspector() {
    final otherIds = _book.ids;
    switch (_inspect) {
      case InspectNothing():
        return const _InspectorIntro();
      case InspectTraffic(:final entry):
        return TrafficDetail(
          key: ObjectKey(entry),
          entry: entry,
          onCreateRule: () => _ruleFromTraffic(entry),
        );
      case InspectRule(:final draft, :final original):
        return RuleEditor(
          key: ObjectKey(original ?? draft),
          initial: draft,
          isNew: original == null,
          existingIds: original == null
              ? otherIds
              : otherIds.difference({original['id']}),
          onDirtyChanged: _setDirty,
          onCancel: _cancelEdit,
          onDelete: original == null ? null : () => _delete(original),
          onSave: (rule) => _saveRule(original, rule),
        );
      case InspectGroup(:final draft, :final original):
        // The id the group already holds in the list is not a conflict.
        final ownId = _book.recordingGroups
            .where((g) => g['recordingId'] == draft['recordingId'])
            .map((g) => g['id'])
            .toSet();
        return GroupEditor(
          key: ObjectKey(original ?? draft),
          initial: draft,
          isNew: original == null,
          existingIds: otherIds.difference(ownId),
          onDirtyChanged: _setDirty,
          onCancel: _cancelEdit,
          onDelete: original == null ? null : () => _delete(original),
          onSave: (group) => _saveGroup(original, group),
        );
    }
  }
}

class _StatusText extends StatelessWidget {
  const _StatusText({required this.connection});

  final MockConnection connection;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 420),
    child: Text(
      connection.status,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: context.text.bodySmall,
    ),
  );
}

/// Column 03 when nothing is selected: how matching works, in brief.
class _InspectorIntro extends StatelessWidget {
  const _InspectorIntro();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget point(String n, String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: Space.xl),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 40,
            child: Text(n, style: mono(context, size: 12, color: p.signal)),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeading(index: '03', title: '详情'),
        const Hairline(strong: true),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Space.gutter),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '选中一条规则来编辑，或选中一个请求查看详情。',
                    style: context.text.headlineSmall,
                  ),
                  const SizedBox(height: Space.xxl),
                  point(
                    'A',
                    '整包替换',
                    '命中后不访问网络，直接返回规则里的状态码、响应头和响应体。'
                        '适合接口未就绪或需要固定数据的场景。',
                  ),
                  point(
                    'B',
                    '字段补丁',
                    '照常请求真实接口，只改写响应 JSON 中的几个字段，其余保持真实。'
                        '适合验证长文本、极端数值等界面边界。',
                  ),
                  point('C', '参数条件', '让规则只对某个 ID、某种传参生效，其他请求不受影响。可与以上两种方式组合。'),
                  point('D', '录制组', '把一段录制里的全部请求变成一组规则，整组开关，用于离线复现一条完整流程。'),
                  Text(
                    '规则保存在设备的内存里：保存、开关、删除、排序都会立即同步，'
                    '从设备的下一个请求开始生效。App 冷启动后需要重新连接，'
                    'Relay 会自动恢复它上次确认的规则。',
                    style: context.text.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
