import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:local_mock_core/local_mock_core.dart';

import 'rule_edit_dialog.dart';

class RecordingMockDialog extends StatefulWidget {
  const RecordingMockDialog({
    super.key,
    required this.initial,
    required this.existingIds,
    this.isNew = false,
  });

  final Map<String, dynamic> initial;
  final Set<String> existingIds;
  final bool isNew;

  @override
  State<RecordingMockDialog> createState() => _RecordingMockDialogState();
}

class _RecordingMockDialogState extends State<RecordingMockDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(
    text: widget.initial['name'] as String,
  );
  late final _id = TextEditingController(text: widget.initial['id'] as String);
  late final List<Map<String, dynamic>> _rules =
      (jsonDecode(jsonEncode(widget.initial['rules'])) as List)
          .cast<Map<String, dynamic>>();
  late bool _matchParams = widget.initial['matchParams'] == true;
  late bool _enabled = widget.initial['enabled'] != false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _id.dispose();
    super.dispose();
  }

  Future<void> _edit(int index) async {
    final updated = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => RuleEditDialog(
        initial: _rules[index],
        existingIds: {
          for (final (other, rule) in _rules.indexed)
            if (other != index) rule['id'] as String,
        },
        matchRecordedParams: _matchParams,
      ),
    );
    if (updated != null && mounted) {
      setState(() => _rules[index] = updated);
    }
  }

  void _move(int from, int to) {
    setState(() {
      final rule = _rules.removeAt(from);
      _rules.insert(to, rule);
    });
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    try {
      final group = MockRule.fromJson({
        ...widget.initial,
        'id': _id.text.trim(),
        'name': _name.text.trim(),
        'enabled': _enabled,
        'matchParams': _matchParams,
        'rules': _rules,
      });
      Navigator.pop(context, group.toJson());
    } on FormatException catch (error) {
      setState(() => _error = _rules.isEmpty ? '至少保留一条接口规则' : error.message);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 840, maxHeight: 760),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.isNew ? '录制 Mock 配置' : '编辑录制 Mock',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Mock 组名称'),
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '名称不能为空' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _id,
                decoration: const InputDecoration(labelText: 'Mock 组 ID'),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'ID 不能为空'
                    : widget.existingIds.contains(value.trim())
                    ? 'ID 已存在'
                    : null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('只 Mock 录制时的传参'),
                subtitle: Text(
                  _matchParams
                      ? '同时匹配录制 query 和请求体；可在下一级接口编辑弹窗修改。'
                      : '忽略录制 query 和请求体，只按方法、域名和路径匹配。',
                ),
                value: _matchParams,
                onChanged: (value) => setState(() => _matchParams = value),
              ),
              const Text(
                '整段录制作为一个 Mock 组。组内第一条启用且匹配的规则生效，不按请求次数切换响应；重复录到的相同请求保留最后一次响应。可拖动调整组内优先级。',
              ),
              const SizedBox(height: 8),
              Text(
                '接口规则（${_rules.length}）· ${_rules.where((rule) => rule['enabled'] != false).length} 条启用',
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: _rules.length,
                  onReorderItem: _move,
                  itemBuilder: (context, index) {
                    final rule = _rules[index];
                    return ListTile(
                      key: ValueKey(rule['id']),
                      contentPadding: EdgeInsets.zero,
                      leading: Switch(
                        value: rule['enabled'] != false,
                        onChanged: (value) => setState(
                          () => _rules[index] = {...rule, 'enabled': value},
                        ),
                      ),
                      title: Text(
                        '${rule['method']} ${rule['host'] ?? ''}${rule['path']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${rule['patchBody'] is Map && (rule['patchBody'] as Map).isNotEmpty ? '字段补丁' : rule['statusCode']} · ${rule['delayMs']}ms'
                        '${_matchParams ? ' · ${jsonEncode(rule['recordedRequest'] ?? {})}' : ''}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _edit(index),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '编辑接口',
                            onPressed: () => _edit(index),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: '移除接口',
                            onPressed: () =>
                                setState(() => _rules.removeAt(index)),
                            icon: const Icon(Icons.delete_outline),
                          ),
                          ReorderableDragStartListener(
                            index: index,
                            child: const Padding(
                              padding: EdgeInsets.all(8),
                              child: Icon(Icons.drag_handle),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用整个 Mock 组'),
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
              ),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: _save,
                    child: Text(widget.isNew ? '保存录制 Mock' : '保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
