import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'rule_edit_dialog.dart';

/// Builds the mock-rule draft pre-filled from one captured request.
///
/// The response body is parsed as JSON when possible so the rule replays the
/// exact payload; otherwise it is kept as a plain string body.
Map<String, dynamic> ruleFromTraffic(
  Map<String, dynamic> entry, {
  required Set<String> existingIds,
}) {
  dynamic body;
  final text = entry['responseBody'] as String?;
  if (text != null && text.isNotEmpty) {
    try {
      body = jsonDecode(text);
    } on FormatException {
      body = text;
    }
  }
  final method = '${entry['method'] ?? 'GET'}'.toUpperCase();
  final path = '${entry['path'] ?? '/'}';
  final host = entry['host'] as String?;
  final statusCode = entry['statusCode'] as int? ?? 200;

  var id = _suggestRuleId(path);
  if (existingIds.contains(id)) {
    var suffix = 2;
    while (existingIds.contains('$id-$suffix')) {
      suffix++;
    }
    id = '$id-$suffix';
  }
  return {
    'id': id,
    'enabled': true,
    'method': method,
    'path': path,
    if (host != null && host.isNotEmpty) 'host': host,
    'statusCode': statusCode,
    'delayMs': 0,
    if (body != null) 'body': body,
  };
}

String _suggestRuleId(String path) {
  final segments = path
      .split(RegExp(r'[^a-zA-Z0-9]+'))
      .where((segment) => segment.isNotEmpty);
  if (segments.isEmpty) return 'capture';
  final joined = segments.take(4).join('-').toLowerCase();
  return joined.length > 40 ? joined.substring(0, 40) : joined;
}

String formatTrafficTime(int millis) {
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int value) => '$value'.padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}

/// Pretty-prints captured body text: JSON gets indented, everything else is
/// shown verbatim.
String prettyTrafficBody(String? text) {
  if (text == null) return '';
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
  } on FormatException {
    return text;
  }
}

/// The capture tab: live list of requests recorded by the app adapters.
///
/// Requires [RuleEditDialog] flow from the host page: [onRuleCreated] is
/// invoked with the rule saved in the edit dialog.
class CapturePanel extends StatefulWidget {
  const CapturePanel({
    super.key,
    required this.connected,
    required this.ready,
    required this.available,
    required this.live,
    required this.entries,
    required this.existingRuleIds,
    required this.onRuleCreated,
    required this.onViewRules,
    this.onClear,
  });

  final bool connected;
  final bool ready;

  /// False when the selected isolate runs an app older than protocol v2.
  final bool available;
  final bool live;

  /// Oldest first, as reported by [MockConnection].
  final List<Map<String, dynamic>> entries;
  final Set<String> existingRuleIds;
  final ValueChanged<Map<String, dynamic>> onRuleCreated;
  final VoidCallback onViewRules;
  final VoidCallback? onClear;

  @override
  State<CapturePanel> createState() => _CapturePanelState();
}

class _CapturePanelState extends State<CapturePanel> {
  final _filter = TextEditingController();

  @override
  void initState() {
    super.initState();
    _filter.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _visible {
    final query = _filter.text.trim().toLowerCase();
    final entries = widget.entries.reversed.toList();
    if (query.isEmpty) return entries;
    return entries
        .where(
          (entry) => '${entry['method'] ?? ''} ${entry['uri'] ?? ''}'
              .toLowerCase()
              .contains(query),
        )
        .toList();
  }

  Future<void> _showDetail(Map<String, dynamic> entry) => showDialog<void>(
    context: context,
    builder: (_) => _TrafficDetailDialog(
      entry: entry,
      onGenerateRule: () {
        Navigator.of(context).pop();
        _generateRule(entry);
      },
    ),
  );

  Future<void> _generateRule(Map<String, dynamic> entry) async {
    final initial = ruleFromTraffic(entry, existingIds: widget.existingRuleIds);
    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) =>
          RuleEditDialog(initial: initial, existingIds: widget.existingRuleIds),
    );
    if (created == null || !mounted) return;
    widget.onRuleCreated(created);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('已从抓包生成规则 ${created['id']}，连接就绪时自动应用'),
          action: SnackBarAction(label: '查看规则', onPressed: widget.onViewRules),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (!widget.connected && widget.entries.isEmpty) {
      return _HintState(
        icon: Icons.link_off,
        text: '未连接。先在上方连接 App，App 内经过 local_mock 适配器的请求会显示在这里。',
      );
    }
    if (widget.connected && !widget.ready && widget.entries.isEmpty) {
      return const _HintState(
        icon: Icons.hourglass_top,
        text: '等待目标就绪…（发现 isolate 后自动选中，或从下拉框选择）',
      );
    }
    if (widget.connected &&
        widget.ready &&
        !widget.available &&
        widget.entries.isEmpty) {
      return _HintState(
        icon: Icons.system_update,
        text:
            'App 端 local_mock 版本过旧（协议 v1），不支持抓包。'
            '请将业务 App 的 local_mock_dio / local_mock_http 升级到 0.2.0+ 后重新运行。',
        iconColor: scheme.error,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '抓包记录（${widget.entries.length}）'
                '${!widget.connected
                    ? ' · 已断开，保留记录'
                    : widget.live
                    ? ' · 实时同步中'
                    : ''}',
                style: theme.textTheme.titleSmall,
              ),
            ),
            OutlinedButton.icon(
              onPressed: widget.onClear,
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('清空记录'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _filter,
          decoration: const InputDecoration(
            isDense: true,
            labelText: '筛选',
            hintText: '方法 / 域名 / 路径关键字',
            prefixIcon: Icon(Icons.filter_alt_outlined),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: _buildList()),
      ],
    );
  }

  Widget _buildList() {
    if (widget.entries.isEmpty) {
      return const _HintState(
        icon: Icons.wifi_tethering,
        text: '实时捕获中。在 App 里发起请求，经过 local_mock 适配器的请求会出现在这里。',
      );
    }
    final visible = _visible;
    if (visible.isEmpty) {
      return _HintState(
        icon: Icons.search_off,
        text: '没有匹配“${_filter.text}”的记录',
      );
    }
    return Scrollbar(
      child: ListView.separated(
        itemCount: visible.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final entry = visible[index];
          return _TrafficTile(
            entry: entry,
            onTap: () => unawaited(_showDetail(entry)),
            onGenerateRule: () => unawaited(_generateRule(entry)),
          );
        },
      ),
    );
  }
}

class _TrafficTile extends StatelessWidget {
  const _TrafficTile({required this.entry, this.onTap, this.onGenerateRule});

  final Map<String, dynamic> entry;
  final VoidCallback? onTap;
  final VoidCallback? onGenerateRule;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final method = '${entry['method'] ?? '?'}';
    final path = '${entry['path'] ?? ''}';
    final host = '${entry['host'] ?? ''}';
    final startedAt = entry['startedAt'] as int? ?? 0;
    final durationMs = entry['durationMs'] as int? ?? 0;
    final error = entry['error'] as String?;
    final hasRequestBody = entry['requestBody'] != null;

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      onTap: onTap,
      leading: SizedBox(
        width: 56,
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: _MethodBadge(method),
        ),
      ),
      title: Text(
        host.isEmpty ? path : '$host$path',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        '${formatTrafficTime(startedAt)} · ${durationMs}ms'
        '${hasRequestBody ? ' · 有请求体' : ''}'
        '${error == null ? '' : ' · ${_firstLine(error)}'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: error == null
              ? theme.colorScheme.onSurfaceVariant
              : scheme.error,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (entry['mocked'] == true) ...[
            const _MockBadge(),
            const SizedBox(width: 6),
          ],
          _StatusBadge(statusCode: entry['statusCode'] as int?, error: error),
          const SizedBox(width: 4),
          IconButton(
            tooltip: '从此请求生成规则',
            visualDensity: VisualDensity.compact,
            onPressed: onGenerateRule,
            icon: const Icon(Icons.bolt_outlined, size: 20),
          ),
        ],
      ),
    );
  }
}

String _firstLine(String text) => text.split('\n').first;

class _MethodBadge extends StatelessWidget {
  const _MethodBadge(this.method);

  final String method;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        method,
        maxLines: 1,
        overflow: TextOverflow.fade,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontFamily: 'monospace',
          fontWeight: FontWeight.bold,
          color: scheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _MockBadge extends StatelessWidget {
  const _MockBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'MOCK',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.bold,
          color: scheme.onTertiaryContainer,
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({this.statusCode, this.error});

  final int? statusCode;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final code = statusCode;
    final Color background;
    final Color foreground;
    final String label;
    if (code == null) {
      background = scheme.errorContainer;
      foreground = scheme.onErrorContainer;
      label = '失败';
    } else if (code < 300) {
      background = scheme.primaryContainer;
      foreground = scheme.onPrimaryContainer;
      label = '$code';
    } else if (code < 500) {
      background = scheme.secondaryContainer;
      foreground = scheme.onSecondaryContainer;
      label = '$code';
    } else {
      background = scheme.errorContainer;
      foreground = scheme.onErrorContainer;
      label = '$code';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

class _HintState extends StatelessWidget {
  const _HintState({required this.icon, required this.text, this.iconColor});

  final IconData icon;
  final String text;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: iconColor ?? theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrafficDetailDialog extends StatelessWidget {
  const _TrafficDetailDialog({required this.entry, this.onGenerateRule});

  final Map<String, dynamic> entry;
  final VoidCallback? onGenerateRule;

  @override
  Widget build(BuildContext context) {
    final requestBody = entry['requestBody'] as String?;
    final responseBody = entry['responseBody'] as String?;

    return AlertDialog(
      title: const Text('请求详情'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _kv('请求', '${entry['method']} ${entry['uri']}'),
              _kv(
                '状态',
                entry['statusCode'] != null
                    ? '${entry['statusCode']} · ${entry['durationMs']}ms'
                    : '失败 · ${entry['durationMs']}ms',
              ),
              if (entry['mocked'] == true)
                const _Kv(label: '来源', value: 'Mock 规则'),
              if (entry['contentType'] != null)
                _kv('Content-Type', '${entry['contentType']}'),
              if (entry['error'] != null) _kv('错误', '${entry['error']}'),
              if (requestBody != null) ...[
                const SizedBox(height: 8),
                _Block(title: '请求体', text: prettyTrafficBody(requestBody)),
              ],
              if (responseBody != null) ...[
                const SizedBox(height: 8),
                _Block(title: '响应体', text: prettyTrafficBody(responseBody)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: Navigator.of(context).pop,
          child: const Text('关闭'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: onGenerateRule,
          icon: const Icon(Icons.bolt_outlined),
          label: const Text('生成 Mock 规则'),
        ),
      ],
    );
  }

  Widget _kv(String label, String value) => _Kv(label: label, value: value);
}

class _Kv extends StatelessWidget {
  const _Kv({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          constraints: const BoxConstraints(maxHeight: 260),
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ],
    );
  }
}
