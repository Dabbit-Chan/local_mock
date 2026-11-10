import 'dart:async';

import 'package:flutter/material.dart';
import 'package:local_mock_core/local_mock_core.dart';

import '../app.dart';
import '../format.dart';
import '../rule_book.dart';
import '../rule_drafts.dart';
import '../ui/primitives.dart';
import '../ui/theme.dart';

/// Column 01: the device's ordered rule list.
class RulesPane extends StatelessWidget {
  const RulesPane({
    super.key,
    required this.selected,
    required this.onOpen,
    required this.onNew,
    required this.onFromRecording,
    required this.onDelete,
  });

  final Rule? selected;
  final ValueChanged<Rule> onOpen;
  final VoidCallback onNew;
  final ValueChanged<TrafficSession> onFromRecording;
  final ValueChanged<Rule> onDelete;

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final book = services.rules;
    return ListenableBuilder(
      listenable: Listenable.merge([
        book,
        services.connection,
        services.library,
      ]),
      builder: (context, _) {
        final rules = book.rules;
        return LayoutBuilder(
          builder: (context, constraints) {
            // Wide panes keep every action in the heading row; narrow ones drop
            // the text buttons to their own row instead of overflowing.
            final inline = constraints.maxWidth >= _inlineActionsWidth;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeading(
                  index: '01',
                  title: '规则',
                  count: '${rules.length}',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (inline) ...[
                        _RulesActions(
                          onFromRecording: onFromRecording,
                          inline: true,
                        ),
                        const SizedBox(width: Space.s),
                      ],
                      FilledButton(
                        key: const Key('new-rule'),
                        onPressed: onNew,
                        child: const Text('新建'),
                      ),
                    ],
                  ),
                ),
                if (!inline) _RulesActions(onFromRecording: onFromRecording),
                const Hairline(strong: true),
                _SyncLine(book: book),
                const Hairline(),
                Expanded(
                  child: rules.isEmpty
                      ? EmptyState(
                          title: '还没有规则',
                          body:
                              '新建一条规则，或在右侧请求列表中选中一个请求，'
                              '以它的真实响应为起点创建。',
                          action: OutlinedButton(
                            onPressed: onNew,
                            child: const Text('新建规则'),
                          ),
                        )
                      : ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          itemCount: rules.length,
                          onReorderItem: (from, to) =>
                              unawaited(book.move(from, to).catchError((_) {})),
                          itemBuilder: (context, index) {
                            final rule = rules[index];
                            return _RuleRow(
                              key: ValueKey('rule-${rule['id']}'),
                              index: index,
                              rule: rule,
                              selected:
                                  identical(rule, selected) ||
                                  (selected != null &&
                                      selected!['id'] == rule['id']),
                              onOpen: () => onOpen(rule),
                              onDelete: () => onDelete(rule),
                              onToggle: (value) => unawaited(
                                book.setEnabled(rule, value).catchError((_) {}),
                              ),
                            );
                          },
                        ),
                ),
                const Hairline(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.gutter,
                    Space.m,
                    Space.gutter,
                    Space.l,
                  ),
                  child: Text(
                    '自上而下匹配，第一条启用且命中的规则生效，规则之间不叠加。'
                    '未命中的请求照常访问网络。拖动 ⠿ 调整顺序。',
                    style: context.text.bodySmall,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _SyncLine extends StatelessWidget {
  const _SyncLine({required this.book});

  final RuleBook book;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final connection = book.connection;
    final error = book.syncError;
    final String text;
    Color color = p.muted;
    if (book.storageError != null) {
      text = book.storageError!;
      color = p.signal;
    } else if (error != null) {
      text = '同步失败：$error';
      color = p.signal;
    } else if (connection.syncingRules) {
      text = '正在同步到设备…';
    } else if (!connection.ready && connection.working) {
      text = connection.status;
    } else if (!connection.ready) {
      text = '设备未连接：规则保存在此浏览器中';
      color = p.signal;
    } else if (!book.autoSyncEnabled) {
      text = 'App 已重启、规则未下发';
      color = p.signal;
    } else {
      final remote = connection.remoteRuleCount;
      text = remote == null ? '修改后自动同步到设备' : '已同步 · 设备上有 $remote 条规则 · 修改后自动同步';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.gutter,
        vertical: 10,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: context.text.bodySmall!.copyWith(color: color),
            ),
          ),
          if (!book.autoSyncEnabled || error != null) ...[
            const SizedBox(width: Space.s),
            OutlinedButton(
              key: const Key('sync-rules-to-device'),
              onPressed: connection.ready
                  ? () => unawaited(book.push().catchError((_) {}))
                  : null,
              child: const Text('同步到设备'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Width at which the rule actions move into the heading row: the five text
/// buttons plus the title and 新建 need roughly this much room.
const _inlineActionsWidth = 460.0;

/// The rule-list actions, always visible, as plain text buttons like 新建: in
/// the heading row when the pane is wide enough, otherwise on their own row
/// right below it. No second-level menu for the things that get used all the
/// time.
class _RulesActions extends StatelessWidget {
  const _RulesActions({required this.onFromRecording, this.inline = false});

  final ValueChanged<TrafficSession> onFromRecording;

  /// Compact row for [SectionHeading] instead of the strip under it.
  final bool inline;

  Future<void> _import(BuildContext context) async {
    final services = AppScope.of(context);
    final book = services.rules;
    final before = book.rules;
    final deviceId = services.connection.selectedId;
    try {
      final text = await services.ruleFiles.pickRules();
      if (text == null || !context.mounted) return;
      final imported = RuleBook.parseFile(text);
      final ok = await confirm(
        context,
        title: '导入规则',
        body:
            '文件中有 ${imported.length} 条规则，将替换当前全部 ${before.length} 条规则'
            '${book.canAutoSync && services.connection.ready ? '，并立即同步到设备' : '，保存在此浏览器中'}。',
        confirmLabel: '替换',
      );
      if (!ok || !context.mounted) return;
      if (!identical(before, book.rules) ||
          deviceId != services.connection.selectedId) {
        throw StateError('导入期间设备或规则发生了变化，请重新导入');
      }
      await book.replaceAll(imported);
      if (context.mounted) toast(context, '已导入 ${imported.length} 条规则');
    } catch (error) {
      if (context.mounted) toast(context, '导入失败：${describeError(error)}');
    }
  }

  Future<void> _export(BuildContext context) async {
    final services = AppScope.of(context);
    try {
      await services.ruleFiles.saveRules(
        'mock-rules-${fileStamp()}.json',
        services.rules.exportText(),
      );
    } catch (error) {
      if (context.mounted) toast(context, '导出失败：${describeError(error)}');
    }
  }

  Future<void> _clearDevice(BuildContext context) async {
    final book = AppScope.of(context).rules;
    final ok = await confirm(
      context,
      title: '清空设备上的规则',
      body: '此浏览器保存的规则将全部删除，已开启自动同步时也会清空设备上的规则。之后所有请求都照常访问网络。',
      confirmLabel: '清空',
      destructive: true,
    );
    if (!ok) return;
    try {
      await book.clearDevice();
    } catch (error) {
      if (context.mounted) toast(context, '清空失败：${describeError(error)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final connection = services.connection;
    final sessions = services.library.sessions;
    final groupsSupported =
        !connection.connected || connection.supportsRecordingMocks;

    Widget action({
      required Key key,
      required String label,
      required String tooltip,
      required VoidCallback? onPressed,
    }) => _TextAction(
      key: key,
      label: label,
      tooltip: tooltip,
      onPressed: onPressed,
    );

    final buttons = <Widget>[
      MenuAnchor(
        alignmentOffset: const Offset(0, 4),
        menuChildren: [
          if (sessions.isEmpty) const MenuItemButton(child: Text('还没有录制')),
          for (final session in sessions)
            MenuItemButton(
              onPressed:
                  groupsSupported &&
                      !connection.recording &&
                      session.replayableEntries.isNotEmpty
                  ? () => onFromRecording(session)
                  : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  '${session.name}  ·  ${session.replayableEntries.length} 个可用请求',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          if (!groupsSupported)
            const MenuItemButton(child: Text('设备上的 local_mock 版本过旧，不支持录制组')),
        ],
        builder: (context, controller, _) => action(
          key: const Key('rules-from-recording'),
          label: '录制组',
          tooltip: '从录制生成录制组',
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
        ),
      ),
      action(
        key: const Key('rules-import'),
        label: '导入',
        tooltip: '导入规则文件',
        onPressed: () => unawaited(_import(context)),
      ),
      action(
        key: const Key('rules-export'),
        label: '导出',
        tooltip: '导出规则文件',
        onPressed: () => unawaited(_export(context)),
      ),
      action(
        key: const Key('rules-resync'),
        label: '同步',
        tooltip: '重新同步到设备',
        onPressed: connection.ready
            ? () => unawaited(services.rules.push().catchError((_) {}))
            : null,
      ),
      action(
        key: const Key('rules-clear'),
        label: '清空',
        tooltip: '清空设备上的规则',
        onPressed: connection.ready
            ? () => unawaited(_clearDevice(context))
            : null,
      ),
    ];

    if (inline) {
      return Row(mainAxisSize: MainAxisSize.min, children: buttons);
    }
    return Padding(
      // Buttons pad their labels by 10, so this lines the text up with the
      // heading and the rule list below.
      padding: const EdgeInsets.fromLTRB(
        Space.gutter - 10,
        0,
        Space.s,
        Space.s,
      ),
      child: Wrap(spacing: Space.xs, runSpacing: Space.xs, children: buttons),
    );
  }
}

/// A rule action rendered as a text-only button, next to 新建.
class _TextAction extends StatelessWidget {
  const _TextAction({
    super.key,
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final String label;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Tooltip(
      message: tooltip,
      child: TextButton(
        onPressed: onPressed,
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? p.faint : p.ink,
          ),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 10),
          ),
        ),
        child: Text(label),
      ),
    );
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({
    super.key,
    required this.index,
    required this.rule,
    required this.selected,
    required this.onOpen,
    required this.onDelete,
    required this.onToggle,
  });

  final int index;
  final Rule rule;
  final bool selected;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = rule['enabled'] != false;
    final group = isGroup(rule);

    final Widget title;
    final List<String> facts;
    if (group) {
      final children = groupChildren(rule);
      final on = children.where((r) => r['enabled'] != false).length;
      title = Row(
        children: [
          const Tag('录制组', tone: TagTone.inverse),
          const SizedBox(width: Space.s),
          Expanded(
            child: Text(
              '${rule['name']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.titleSmall,
            ),
          ),
        ],
      );
      facts = [
        '${children.length} 个接口',
        if (on != children.length) '$on 个启用',
        rule['matchParams'] == true ? '匹配录制传参' : '不比对传参',
      ];
    } else {
      final params = (rule['params'] as Map?) ?? const {};
      title = Row(
        children: [
          MethodText('${rule['method']}', width: 52),
          Expanded(
            child: Text(
              '${rule['path']}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono(context, size: 12.5, weight: FontWeight.w600),
            ),
          ),
        ],
      );
      facts = [
        if (rule['host'] != null) '${rule['host']}',
        if (isPatchRule(rule)) '字段补丁' else '${rule['statusCode']}',
        if ((rule['delayMs'] ?? 0) != 0) '${rule['delayMs']} ms',
        if (params.isNotEmpty)
          params.entries.map((e) => '${e.key}=${e.value}').join('&'),
      ];
    }

    return Column(
      children: [
        ListRow(
          selected: selected,
          onTap: onOpen,
          padding: const EdgeInsets.fromLTRB(Space.gutter, 10, 4, 10),
          hoverInset: 40,
          hoverActions: ToolButton(
            icon: Icons.delete_outline,
            tooltip: '删除',
            onPressed: onDelete,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                child: Text(
                  (index + 1).toString().padLeft(2, '0'),
                  style: mono(context, size: 11.5, color: p.faint),
                ),
              ),
              SquareToggle(
                value: enabled,
                onChanged: onToggle,
                semanticLabel: '启用规则 ${rule['id']}',
              ),
              const SizedBox(width: Space.s),
              Expanded(
                child: Opacity(
                  opacity: enabled ? 1 : 0.45,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      title,
                      const SizedBox(height: 3),
                      Text(
                        facts.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              ReorderableDragStartListener(
                index: index,
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(Icons.drag_indicator, size: 18, color: p.faint),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Hairline(),
      ],
    );
  }
}
