import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/widgets.dart';
import 'package:local_mock_core/local_mock_core.dart';

import 'src/draft_store.dart';
import 'src/mock_connection.dart';

void main() => runApp(const LocalMockApp());

class LocalMockApp extends StatelessWidget {
  const LocalMockApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Local Mock',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff2563eb)),
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      switchTheme: const SwitchThemeData(
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    home: const MockPage(),
  );
}

/// FormatException and friends print multi-line source snippets; keep the
/// status line compact so it never crowds out the rule cards.
String _firstLine(Object error) => error.toString().split('\n').first;

Map<String, dynamic> _exampleRule() => {
  'id': 'user-profile',
  'enabled': true,
  'method': 'GET',
  'path': '/api/user/profile',
  'statusCode': 200,
  'delayMs': 300,
  'body': {'name': '测试用户', 'level': 10},
};

List<Map<String, dynamic>> _parseRules(String text) => [
  for (final rule in MockRule.parseList(jsonDecode(text))) rule.toJson(),
];

class MockPage extends StatefulWidget {
  const MockPage({super.key, this.draftStore});

  /// Overrides the file-backed store, e.g. for tests.
  final DraftStore? draftStore;

  @override
  State<MockPage> createState() => _MockPageState();
}

class _MockPageState extends State<MockPage> {
  final _connection = MockConnection();
  late final _draftStore = widget.draftStore ?? DraftStore();
  final _address = TextEditingController();
  final _scrollController = ScrollController();
  final _gridKey = GlobalKey();
  List<Map<String, dynamic>> _rules = const [];
  String? _message;
  String? _brokenDraft;
  bool _loadingDraft = true;
  bool _savingDraft = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDraft());
  }

  Future<void> _loadDraft() async {
    try {
      final text = await _draftStore.load();
      if (!mounted) return;
      setState(() {
        if (text == null) {
          _rules = [_exampleRule()];
        } else {
          try {
            _rules = _parseRules(text);
          } on FormatException catch (error) {
            _brokenDraft = text;
            _rules = const [];
            _message = '本地草稿解析失败：${_firstLine(error)}';
          } on TypeError catch (error) {
            _brokenDraft = text;
            _rules = const [];
            _message = '本地草稿结构不合法：${_firstLine(error)}';
          }
        }
      });
    } catch (error) {
      if (mounted) setState(() => _message = '读取草稿失败：${_firstLine(error)}');
    } finally {
      if (mounted) setState(() => _loadingDraft = false);
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    setState(() => _message = null);
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _message = _firstLine(error));
    }
  }

  Future<void> _saveDraft() async {
    setState(() => _savingDraft = true);
    try {
      final path = await _draftStore.save(
        const JsonEncoder.withIndent('  ').convert(_rules),
      );
      if (mounted) {
        setState(() {
          _brokenDraft = null;
          _message = '草稿已保存到 $path（未下发）';
        });
      }
    } finally {
      if (mounted) setState(() => _savingDraft = false);
    }
  }

  String _newRuleId() {
    var index = _rules.length + 1;
    while (_rules.any((rule) => rule['id'] == 'rule-$index')) {
      index++;
    }
    return 'rule-$index';
  }

  void _setRule(int index, Map<String, dynamic> rule) => setState(() {
    final rules = List.of(_rules);
    rules[index] = rule;
    _rules = rules;
  });

  Future<void> _addRule() async {
    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => RuleEditDialog(
        isNewRule: true,
        initial: {
          'id': _newRuleId(),
          'enabled': true,
          'method': 'GET',
          'path': '/',
          'statusCode': 200,
          'delayMs': 0,
          'body': <String, dynamic>{},
        },
        existingIds: _rules.map((rule) => rule['id'] as String).toSet(),
      ),
    );
    if (created != null) setState(() => _rules = [..._rules, created]);
  }

  Future<void> _editRule(int index) async {
    final current = _rules[index];
    final updated = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => RuleEditDialog(
        isNewRule: false,
        initial: current,
        existingIds: {
          for (final (i, rule) in _rules.indexed)
            if (i != index) rule['id'] as String,
        },
      ),
    );
    if (updated != null) _setRule(index, updated);
  }

  void _deleteRule(int index) {
    final removed = _rules[index];
    setState(() => _rules = List.of(_rules)..removeAt(index));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已删除规则 ${removed['id']}'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () {
              if (!mounted) return;
              setState(() {
                final at = index.clamp(0, _rules.length);
                _rules = List.of(_rules)..insert(at, removed);
              });
            },
          ),
        ),
      );
  }

  Future<void> _viewBrokenDraft() async {
    final text = _brokenDraft;
    if (text == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('原始草稿内容'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: Navigator.of(context).pop,
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _connection.dispose();
    _address.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Local Mock')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: ListenableBuilder(
        listenable: _connection,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('通过 VM Service 调试连接下发规则，无代理、无需 Hot Reload。'),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _address,
                    enabled: !_connection.connected && !_connection.working,
                    decoration: const InputDecoration(
                      labelText: 'VM Service 地址',
                      hintText: 'http://127.0.0.1:12345/auth-token=/',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _connection.working
                      ? null
                      : () {
                          if (_connection.connected) {
                            _connection.disconnect();
                          } else {
                            unawaited(
                              _action(() => _connection.connect(_address.text)),
                            );
                          }
                        },
                  child: Text(_connection.connected ? '断开' : '连接'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SelectableText(
              '${_connection.status}'
              '${_connection.remoteRuleCount == null ? '' : ' · 手机规则 ${_connection.remoteRuleCount} 条'}',
            ),
            if (_connection.targets.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButton<String>(
                value: _connection.selectedId,
                hint: const Text('选择目标 isolate'),
                isExpanded: true,
                items: [
                  for (final target in _connection.targets)
                    DropdownMenuItem(
                      value: target.id,
                      child: Text('${target.name} (${target.id})'),
                    ),
                ],
                onChanged: _connection.working
                    ? null
                    : (id) {
                        if (id != null) {
                          unawaited(
                            _action(() => _connection.selectTarget(id)),
                          );
                        }
                      },
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _connection.ready && !_loadingDraft
                      ? () => unawaited(
                          _action(() => _connection.apply(jsonEncode(_rules))),
                        )
                      : null,
                  icon: const Icon(Icons.sync),
                  label: const Text('应用到手机'),
                ),
                OutlinedButton(
                  onPressed: _connection.ready
                      ? () => unawaited(_action(_connection.clear))
                      : null,
                  child: const Text('清空手机规则'),
                ),
                OutlinedButton(
                  onPressed: _loadingDraft || _savingDraft
                      ? null
                      : () => unawaited(_action(_saveDraft)),
                  child: _savingDraft
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('保存本地草稿'),
                ),
              ],
            ),
            if (_message != null) ...[
              const SizedBox(height: 8),
              SelectableText(
                _message!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Mock 规则（${_rules.length}）· 拖动卡片调整顺序，第一条启用且匹配的规则生效',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: _loadingDraft || _savingDraft
                      ? null
                      : () => unawaited(_addRule()),
                  icon: const Icon(Icons.add),
                  label: const Text('添加规则'),
                ),
              ],
            ),
            if (_brokenDraft != null) ...[
              const SizedBox(height: 8),
              _BrokenDraftBanner(
                onView: () => unawaited(_viewBrokenDraft()),
                onDismiss: () => setState(() => _brokenDraft = null),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(child: _buildRulesArea()),
            const SizedBox(height: 12),
            const Text(
              '查询参数不参与匹配。应用后需在手机重新请求。\n'
              '断开连接不会清空手机规则；多 isolate 时，已确认的规则会同步到所选目标。',
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildRulesArea() {
    if (_loadingDraft) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_rules.isEmpty) {
      return Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.dashboard_customize_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 12),
              const Text('暂无规则，添加一条开始 Mock'),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () => unawaited(_addRule()),
                icon: const Icon(Icons.add),
                label: const Text('添加规则'),
              ),
            ],
          ),
        ),
      );
    }
    return ReorderableBuilder<Map<String, dynamic>>(
      scrollController: _scrollController,
      // No long-press delay: dragging starts as soon as the card moves.
      longPressDelay: Duration.zero,
      onReorder: (reorder) => setState(() => _rules = reorder(_rules)),
      builder: (children) => LayoutBuilder(
        builder: (context, constraints) {
          const cardWidth = 300.0;
          const spacing = 10.0;
          final columns = math.max(
            1,
            ((constraints.maxWidth + spacing) / (cardWidth + spacing)).floor(),
          );
          // Give the grid only the space its fixed-width columns need, so
          // adding a column never redistributes the width of existing cards.
          final width = constraints.maxWidth < cardWidth
              ? constraints.maxWidth
              : columns * (cardWidth + spacing) - spacing;
          return Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: GridView(
                key: _gridKey,
                controller: _scrollController,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisExtent: cardWidth / 1.35,
                  mainAxisSpacing: spacing,
                  crossAxisSpacing: spacing,
                ),
                children: children,
              ),
            ),
          );
        },
      ),
      children: [
        for (final (index, rule) in _rules.indexed)
          RuleCard(
            key: ValueKey('rule-${rule['id']}'),
            rule: rule,
            onToggle: (value) => _setRule(index, {...rule, 'enabled': value}),
            onEdit: () => unawaited(_editRule(index)),
            onDelete: () => _deleteRule(index),
          ),
      ],
    );
  }
}

class _BrokenDraftBanner extends StatelessWidget {
  const _BrokenDraftBanner({required this.onView, required this.onDismiss});

  final VoidCallback onView;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '本地草稿无法解析，已显示为空规则。可查看原始内容，或编辑后保存覆盖。',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          TextButton(onPressed: onView, child: const Text('查看原始')),
          TextButton(onPressed: onDismiss, child: const Text('忽略')),
        ],
      ),
    );
  }
}

class RuleCard extends StatelessWidget {
  const RuleCard({
    super.key,
    required this.rule,
    this.onToggle,
    this.onEdit,
    this.onDelete,
  });

  final Map<String, dynamic> rule;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = rule['enabled'] == true;
    final bodyText = rule['body'] == null ? 'null' : jsonEncode(rule['body']);
    final headers = (rule['headers'] as Map<String, dynamic>? ?? const {});

    return Card(
      margin: EdgeInsets.zero,
      elevation: enabled ? 1 : 0,
      color: enabled
          ? null
          : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      clipBehavior: Clip.antiAlias,
      child: Opacity(
        opacity: enabled ? 1 : 0.65,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Switch(value: enabled, onChanged: onToggle),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${rule['method']} ${rule['path']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${rule['id']}'
                          '${rule['host'] == null ? '' : ' · ${rule['host']}'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '编辑',
                    visualDensity: VisualDensity.compact,
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined, size: 20),
                  ),
                  IconButton(
                    tooltip: '删除',
                    visualDensity: VisualDensity.compact,
                    onPressed: onDelete,
                    icon: Icon(
                      Icons.delete_outline,
                      size: 20,
                      color: scheme.error,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _MetaChip(label: '${rule['statusCode']}'),
                  if (rule['delayMs'] != 0)
                    _MetaChip(label: '${rule['delayMs']}ms'),
                  if (headers.isNotEmpty)
                    _MetaChip(label: '${headers.length} headers'),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  alignment: AlignmentDirectional.centerStart,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(
                      alpha: 0.55,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    bodyText,
                    maxLines: 12,
                    overflow: TextOverflow.fade,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: scheme.onSecondaryContainer),
      ),
    );
  }
}

class RuleEditDialog extends StatefulWidget {
  const RuleEditDialog({
    super.key,
    required this.initial,
    required this.existingIds,
    this.isNewRule = false,
  });

  final Map<String, dynamic> initial;
  final Set<String> existingIds;
  final bool isNewRule;

  @override
  State<RuleEditDialog> createState() => _RuleEditDialogState();
}

class _RuleEditDialogState extends State<RuleEditDialog> {
  static const _methods = [
    'GET',
    'POST',
    'PUT',
    'DELETE',
    'PATCH',
    'HEAD',
    'OPTIONS',
  ];

  final _formKey = GlobalKey<FormState>();
  late final _id = TextEditingController(text: '${widget.initial['id'] ?? ''}');
  late final _path = TextEditingController(
    text: '${widget.initial['path'] ?? ''}',
  );
  late final _host = TextEditingController(
    text: '${widget.initial['host'] ?? ''}',
  );
  late final _statusCode = TextEditingController(
    text: '${widget.initial['statusCode'] ?? 200}',
  );
  late final _delayMs = TextEditingController(
    text: '${widget.initial['delayMs'] ?? 0}',
  );
  late final _headers = TextEditingController(
    text: widget.initial['headers'] is Map
        ? const JsonEncoder.withIndent('  ').convert(widget.initial['headers'])
        : '',
  );
  late final _body = TextEditingController(
    text: widget.initial['body'] == null
        ? ''
        : const JsonEncoder.withIndent('  ').convert(widget.initial['body']),
  );
  late String _method = (widget.initial['method'] ?? 'GET').toUpperCase();
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _path.dispose();
    _host.dispose();
    _statusCode.dispose();
    _delayMs.dispose();
    _headers.dispose();
    _body.dispose();
    super.dispose();
  }

  InputDecoration _decoration(String label, {String? hint}) =>
      InputDecoration(labelText: label, hintText: hint);

  String? _requiredId(String? value) {
    final id = value?.trim() ?? '';
    if (id.isEmpty) return 'ID 不能为空';
    if (widget.existingIds.contains(id)) return 'ID 已存在';
    return null;
  }

  String? _pathValidator(String? value) {
    final path = value?.trim() ?? '';
    if (!path.startsWith('/') || path.contains('?') || path.contains('#')) {
      return '必须以 / 开头，且不含查询参数或 fragment';
    }
    return null;
  }

  String? _intRange(String? value, int min, int max) {
    final parsed = int.tryParse(value?.trim() ?? '');
    if (parsed == null || parsed < min || parsed > max) {
      return '需要 $min-$max 的整数';
    }
    return null;
  }

  String? _jsonValidator(String? value, {bool objectOnly = false}) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (objectOnly && decoded is! Map<String, dynamic>) {
        return '必须是 JSON 对象，例如 {"content-type": "text/html"}';
      }
      if (objectOnly && decoded.values.any((v) => v is! String)) {
        return 'header 的值必须是字符串';
      }
      return null;
    } on FormatException {
      return '不是合法的 JSON';
    }
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final headersText = _headers.text.trim();
    final bodyText = _body.text.trim();
    final draft = <String, dynamic>{
      'id': _id.text.trim(),
      'enabled': widget.initial['enabled'] == true,
      'method': _method,
      'path': _path.text.trim(),
      if (_host.text.trim().isNotEmpty) 'host': _host.text.trim(),
      'statusCode': int.parse(_statusCode.text.trim()),
      'delayMs': int.parse(_delayMs.text.trim()),
      if (headersText.isNotEmpty) 'headers': jsonDecode(headersText),
      if (bodyText.isNotEmpty) 'body': jsonDecode(bodyText),
    };
    try {
      final normalized = MockRule.fromJson(draft).toJson();
      Navigator.of(context).pop(normalized);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640, maxHeight: 640),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.isNewRule ? '添加规则' : '编辑规则',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _id,
                              decoration: _decoration('ID（唯一标识）'),
                              validator: _requiredId,
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            width: 168,
                            child: DropdownButtonFormField<String>(
                              initialValue: _method,
                              decoration: _decoration('方法'),
                              items: [
                                for (final method in _methods)
                                  DropdownMenuItem(
                                    value: method,
                                    child: Text(method),
                                  ),
                              ],
                              onChanged: (value) =>
                                  setState(() => _method = value ?? 'GET'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _path,
                        decoration: _decoration(
                          '路径',
                          hint: '/api/user/profile',
                        ),
                        validator: _pathValidator,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _host,
                        decoration: _decoration('Host（可选，留空匹配任意域名）'),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _statusCode,
                              keyboardType: TextInputType.number,
                              decoration: _decoration('状态码'),
                              validator: (value) => _intRange(value, 100, 599),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: _delayMs,
                              keyboardType: TextInputType.number,
                              decoration: _decoration('延迟'),
                              validator: (value) => _intRange(value, 0, 60000),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _headers,
                        maxLines: 3,
                        decoration: _decoration(
                          '响应头 JSON（可选）',
                          hint: '{"content-type": "text/html"}',
                        ),
                        style: const TextStyle(fontFamily: 'monospace'),
                        validator: (value) =>
                            _jsonValidator(value, objectOnly: true),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _body,
                        maxLines: 8,
                        minLines: 4,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: _decoration('响应体 JSON（留空视为 null）'),
                        style: const TextStyle(fontFamily: 'monospace'),
                        validator: _jsonValidator,
                      ),
                    ],
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 16),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _submit, child: const Text('保存')),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
