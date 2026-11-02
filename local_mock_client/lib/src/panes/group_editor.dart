import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_mock_core/local_mock_core.dart';

import '../format.dart';
import '../rule_book.dart';
import '../rule_drafts.dart';
import '../ui/code_panel.dart';
import '../ui/primitives.dart';
import '../ui/theme.dart';
import 'rule_editor.dart';

/// Inline editor for a recording group: its settings and the ordered list
/// of interfaces. Opening an interface swaps in a [RuleEditor]; interface
/// changes stay in this draft until the group itself is saved.
class GroupEditor extends StatefulWidget {
  const GroupEditor({
    super.key,
    required this.initial,
    required this.existingIds,
    required this.onSave,
    required this.onCancel,
    this.isNew = false,
    this.onDelete,
    this.onDirtyChanged,
  });

  final Rule initial;
  final Set<String> existingIds;
  final Future<void> Function(Rule group) onSave;
  final VoidCallback onCancel;
  final VoidCallback? onDelete;
  final ValueChanged<bool>? onDirtyChanged;
  final bool isNew;

  @override
  State<GroupEditor> createState() => _GroupEditorState();
}

class _GroupEditorState extends State<GroupEditor> {
  late final _name = TextEditingController(
    text: '${widget.initial['name'] ?? ''}',
  );
  late final _id = TextEditingController(text: '${widget.initial['id'] ?? ''}');
  late final List<Rule> _children =
      (jsonDecode(jsonEncode(widget.initial['rules'])) as List)
          .cast<Map<String, dynamic>>();
  late bool _matchParams = widget.initial['matchParams'] == true;
  late bool _enabled = widget.initial['enabled'] != false;
  late final String _baseline = _snapshot();
  int? _openChild;
  bool _childDirty = false;
  bool _dirty = false;
  bool _saving = false;
  String? _failure;
  final _errors = <String, String>{};

  @override
  void initState() {
    super.initState();
    _name.addListener(_changed);
    _id.addListener(_changed);
    if (widget.isNew) {
      _dirty = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.onDirtyChanged?.call(true),
      );
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _id.dispose();
    super.dispose();
  }

  String _snapshot() =>
      jsonEncode([_name.text, _id.text, _matchParams, _enabled, _children]);

  void _changed() {
    final dirty = widget.isNew || _childDirty || _snapshot() != _baseline;
    if (dirty != _dirty) {
      setState(() => _dirty = dirty);
      widget.onDirtyChanged?.call(dirty);
    }
  }

  void _update(VoidCallback change) {
    setState(change);
    _changed();
  }

  Future<void> _closeChild() async {
    if (_childDirty &&
        !await confirm(
          context,
          title: '放弃对这个接口的修改？',
          body: '尚未应用到录制组的修改将丢失。',
          confirmLabel: '放弃修改',
          destructive: true,
        )) {
      return;
    }
    _update(() {
      _openChild = null;
      _childDirty = false;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    _errors.clear();
    final name = _name.text.trim();
    final id = _id.text.trim();
    if (name.isEmpty) _errors['name'] = '请填写名称';
    if (id.isEmpty) {
      _errors['id'] = '请填写 ID';
    } else if (widget.existingIds.contains(id)) {
      _errors['id'] = '已有规则使用这个 ID';
    }
    if (_children.isEmpty) _errors['children'] = '录制组至少要保留一个接口';
    if (_errors.isNotEmpty) {
      setState(() => _failure = '有 ${_errors.length} 处需要修改');
      return;
    }
    Rule group;
    try {
      group = MockRule.fromJson({
        ...widget.initial,
        'id': id,
        'name': name,
        'enabled': _enabled,
        'matchParams': _matchParams,
        'rules': _children,
      }).toJson();
    } on FormatException catch (error) {
      setState(() => _failure = error.message);
      return;
    }
    setState(() {
      _failure = null;
      _saving = true;
    });
    try {
      await widget.onSave(group);
    } catch (error) {
      if (mounted) setState(() => _failure = describeError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final open = _openChild;
    if (open != null && open < _children.length) {
      return RuleEditor(
        key: ValueKey(('child', open, identityHashCode(_children[open]))),
        initial: _children[open],
        groupName: _name.text.trim().isEmpty ? '未命名' : _name.text.trim(),
        matchRecordedParams: _matchParams,
        existingIds: {
          for (final (i, rule) in _children.indexed)
            if (i != open) rule['id'] as String,
        },
        onDirtyChanged: (dirty) {
          _childDirty = dirty;
          _changed();
        },
        onCancel: () => unawaited(_closeChild()),
        onSave: (rule) async => _update(() {
          _children[open] = rule;
          _openChild = null;
          _childDirty = false;
        }),
      );
    }
    return _buildGroup(context);
  }

  Widget _buildGroup(BuildContext context) {
    final p = context.palette;
    final enabledCount = _children.where((r) => r['enabled'] != false).length;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
            unawaited(_save()),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
            unawaited(_save()),
      },
      child: FocusScope(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 64,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                child: Row(
                  children: [
                    Text('03', style: mono(context, size: 12, color: p.signal)),
                    const SizedBox(width: Space.m),
                    Text(
                      widget.isNew ? '新建录制组' : '编辑录制组',
                      style: context.text.headlineSmall,
                    ),
                    if (_dirty && !widget.isNew) ...[
                      const SizedBox(width: Space.m),
                      const Tag('未保存', tone: TagTone.outline),
                    ],
                    const Spacer(),
                    if (widget.onDelete != null) ...[
                      TextButton(
                        onPressed: widget.onDelete,
                        style: TextButton.styleFrom(foregroundColor: p.signal),
                        child: const Text('删除'),
                      ),
                      const SizedBox(width: Space.s),
                    ],
                    OutlinedButton(
                      onPressed: widget.onCancel,
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: Space.s),
                    Tooltip(
                      message: saveShortcut,
                      child: FilledButton(
                        key: const Key('group-save'),
                        onPressed: _saving ? null : () => unawaited(_save()),
                        child: Text(widget.isNew ? '创建录制组' : '保存'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Hairline(strong: true),
            if (_failure != null) Notice(message: _failure!),
            Padding(
              padding: const EdgeInsets.all(Space.gutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child: Labeled(
                          label: '名称',
                          child: TextField(
                            key: const Key('group-name'),
                            controller: _name,
                            decoration: InputDecoration(
                              errorText: _errors['name'],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: Space.m),
                      Expanded(
                        flex: 2,
                        child: Labeled(
                          label: 'ID',
                          child: TextField(
                            key: const Key('group-id'),
                            controller: _id,
                            style: mono(context, size: 13),
                            decoration: InputDecoration(
                              errorText: _errors['id'],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.l),
                  _SwitchLine(
                    label: '启用整个录制组',
                    value: _enabled,
                    onChanged: (v) => _update(() => _enabled = v),
                  ),
                  _SwitchLine(
                    label: '只匹配录制时的传参',
                    value: _matchParams,
                    help: _matchParams
                        ? '请求的 query 和请求体要与录制时一致才会命中（键顺序不限）。'
                        : '不比对 query 和请求体，只按方法、域名和路径命中。',
                    onChanged: (v) => _update(() => _matchParams = v),
                  ),
                  const SizedBox(height: Space.s),
                  Text(
                    '组内自上而下匹配，第一条启用且命中的接口生效；同一请求每次都返回同一份响应，'
                    '不会按调用次数轮换。未命中的请求照常访问网络。',
                    style: context.text.bodySmall,
                  ),
                ],
              ),
            ),
            const Hairline(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.gutter,
                Space.m,
                Space.gutter,
                Space.s,
              ),
              child: Row(
                children: [
                  Text('接口', style: context.text.titleLarge),
                  const SizedBox(width: Space.s),
                  Text(
                    '${_children.length} 个 · $enabledCount 个启用',
                    style: context.text.bodySmall,
                  ),
                  const Spacer(),
                  Text('拖动 ⠿ 调整优先级', style: context.text.bodySmall),
                ],
              ),
            ),
            if (_errors['children'] != null)
              Notice(message: _errors['children']!),
            Expanded(
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                itemCount: _children.length,
                onReorderItem: (from, to) => _update(() {
                  final rule = _children.removeAt(from);
                  _children.insert(to, rule);
                }),
                itemBuilder: (context, index) {
                  final rule = _children[index];
                  return _ChildRow(
                    key: ValueKey(rule['id']),
                    index: index,
                    rule: rule,
                    showRecorded: _matchParams,
                    onOpen: () => setState(() => _openChild = index),
                    onToggle: (v) => _update(
                      () => _children[index] = {...rule, 'enabled': v},
                    ),
                    onRemove: () => _update(() => _children.removeAt(index)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwitchLine extends StatelessWidget {
  const _SwitchLine({
    required this.label,
    required this.value,
    required this.onChanged,
    this.help,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? help;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SquareToggle(value: value, onChanged: onChanged, semanticLabel: label),
        const SizedBox(width: Space.s),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: context.text.titleSmall),
                if (help != null) ...[
                  const SizedBox(height: 2),
                  Text(help!, style: context.text.bodySmall),
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _ChildRow extends StatelessWidget {
  const _ChildRow({
    super.key,
    required this.index,
    required this.rule,
    required this.showRecorded,
    required this.onOpen,
    required this.onToggle,
    required this.onRemove,
  });

  final int index;
  final Rule rule;
  final bool showRecorded;
  final VoidCallback onOpen;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = rule['enabled'] != false;
    final recorded = rule['recordedRequest'] as Map?;
    final query = (recorded?['query'] as Map?) ?? const {};
    final detail = [
      if (isPatchRule(rule)) '字段补丁' else '${rule['statusCode']}',
      '${rule['delayMs']} ms',
      if (query.isNotEmpty)
        query.entries
            .map((e) => '${e.key}=${(e.value as List).join(',')}')
            .join('&'),
      if (recorded?['body'] != null) '含请求体',
      if (!showRecorded && (query.isNotEmpty || recorded?['body'] != null))
        '（未比对）',
    ].join(' · ');
    return Column(
      children: [
        ListRow(
          onTap: onOpen,
          padding: const EdgeInsets.fromLTRB(Space.gutter, 10, Space.m, 10),
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  (index + 1).toString().padLeft(2, '0'),
                  style: mono(context, size: 11.5, color: p.faint),
                ),
              ),
              SquareToggle(
                value: enabled,
                onChanged: onToggle,
                semanticLabel: '启用接口',
              ),
              const SizedBox(width: Space.s),
              Expanded(
                child: Opacity(
                  opacity: enabled ? 1 : 0.45,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          MethodText('${rule['method']}', width: 60),
                          Expanded(
                            child: Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: '${rule['host'] ?? ''}',
                                    style: mono(
                                      context,
                                      size: 12.5,
                                      color: p.muted,
                                    ),
                                  ),
                                  TextSpan(
                                    text: '${rule['path']}',
                                    style: mono(context, size: 12.5),
                                  ),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Padding(
                        padding: const EdgeInsets.only(left: 60),
                        child: Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              ToolButton(
                icon: Icons.edit_outlined,
                tooltip: '编辑接口',
                onPressed: onOpen,
              ),
              ToolButton(
                icon: Icons.remove_circle_outline,
                tooltip: '从录制组移除',
                onPressed: onRemove,
              ),
              ReorderableDragStartListener(
                index: index,
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Icon(Icons.drag_indicator, size: 18, color: p.muted),
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
