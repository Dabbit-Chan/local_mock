import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/widgets.dart';
import 'package:local_mock_core/local_mock_core.dart';

import 'src/capture_panel.dart';
import 'src/draft_store.dart';
import 'src/mock_connection.dart';
import 'src/rule_edit_dialog.dart';

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
  const MockPage({super.key, this.draftStore, this.connection});

  /// Overrides the file-backed store, e.g. for tests.
  final DraftStore? draftStore;

  /// Overrides the VM Service client, e.g. for tests; not disposed by the
  /// page when injected.
  final MockConnection? connection;

  @override
  State<MockPage> createState() => _MockPageState();
}

/// Top-level navigation between the rules editor and the capture view.
enum MockPageView { rules, capture }

class _MockPageState extends State<MockPage> {
  late final MockConnection _connection = widget.connection ?? MockConnection();
  late final bool _ownsConnection = widget.connection == null;
  late final _draftStore = widget.draftStore ?? DraftStore();
  final _address = TextEditingController();
  final _scrollController = ScrollController();
  final _gridKey = GlobalKey();
  List<Map<String, dynamic>> _rules = const [];
  String? _message;
  String? _brokenDraft;
  bool _loadingDraft = true;
  bool _savingDraft = false;
  MockPageView _view = MockPageView.rules;

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

  void _selectView(MockPageView view) => setState(() {
    _view = view;
    // Poll traffic only while the capture tab is actually visible.
    _connection.setCaptureLive(view == MockPageView.capture);
  });

  @override
  void dispose() {
    if (_ownsConnection) _connection.dispose();
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
            SegmentedButton<MockPageView>(
              segments: const [
                ButtonSegment(
                  value: MockPageView.rules,
                  icon: Icon(Icons.dashboard_customize_outlined),
                  label: Text('Mock 规则'),
                ),
                ButtonSegment(
                  value: MockPageView.capture,
                  icon: Icon(Icons.wifi_tethering),
                  label: Text('抓包'),
                ),
              ],
              selected: {_view},
              onSelectionChanged: (selection) => _selectView(selection.single),
            ),
            if (_message != null) ...[
              const SizedBox(height: 8),
              SelectableText(
                _message!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: _view == MockPageView.rules
                  ? _buildRulesView()
                  : _buildCaptureView(),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildRulesView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
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
      if (_brokenDraft != null) ...[
        const SizedBox(height: 8),
        _BrokenDraftBanner(
          onView: () => unawaited(_viewBrokenDraft()),
          onDismiss: () => setState(() => _brokenDraft = null),
        ),
      ],
      const SizedBox(height: 12),
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
      const SizedBox(height: 12),
      Expanded(child: _buildRulesArea()),
      const SizedBox(height: 12),
      const Text(
        '查询参数不参与匹配。应用后需在手机重新请求。\n'
        '断开连接不会清空手机规则；多 isolate 时，已确认的规则会同步到所选目标。',
      ),
    ],
  );

  Widget _buildCaptureView() => CapturePanel(
    connected: _connection.connected,
    ready: _connection.ready,
    available: _connection.captureAvailable,
    live: _connection.captureLive,
    entries: _connection.traffic,
    existingRuleIds: _rules.map((rule) => rule['id'] as String).toSet(),
    onRuleCreated: (rule) => setState(() => _rules = [..._rules, rule]),
    onViewRules: () => _selectView(MockPageView.rules),
    onClear: _connection.ready && _connection.captureAvailable
        ? () => unawaited(_action(_connection.clearTraffic))
        : null,
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
