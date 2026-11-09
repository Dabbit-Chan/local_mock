import 'package:flutter/material.dart';

import '../format.dart';
import '../ui/primitives.dart';
import '../ui/theme.dart';

typedef Entry = Map<String, dynamic>;

/// Filterable request table, newest first.
class TrafficList extends StatefulWidget {
  const TrafficList({
    super.key,
    required this.entries,
    required this.onSelect,
    this.selected,
    this.onCreateRule,
    this.empty,
  });

  /// Oldest first, as delivered by the connection or a recording.
  final List<Entry> entries;
  final Entry? selected;
  final ValueChanged<Entry> onSelect;

  /// Shows a "create rule" action per row when set.
  final ValueChanged<Entry>? onCreateRule;

  /// Shown when [entries] is empty.
  final Widget? empty;

  @override
  State<TrafficList> createState() => _TrafficListState();
}

class _TrafficListState extends State<TrafficList> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  bool _onlyMocked = false;
  bool _onlyFailed = false;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  static bool _failed(Entry e) {
    final code = e['statusCode'] as int?;
    return e['error'] != null || code == null || code >= 400;
  }

  List<Entry> get _visible {
    final query = _query.text.trim().toLowerCase();
    return [
      for (final entry in widget.entries.reversed)
        if ((!_onlyMocked || entry['mocked'] == true) &&
            (!_onlyFailed || _failed(entry)) &&
            (query.isEmpty ||
                '${entry['method'] ?? ''} ${entry['uri'] ?? ''}'
                    .toLowerCase()
                    .contains(query)))
          entry,
    ];
  }

  bool _isSelected(Entry entry) {
    final selected = widget.selected;
    return selected != null &&
        (identical(selected, entry) ||
            (selected['revision'] == entry['revision'] &&
                selected['startedAt'] == entry['startedAt'] &&
                selected['uri'] == entry['uri']));
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final filtered =
        _query.text.trim().isNotEmpty || _onlyMocked || _onlyFailed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.gutter,
            Space.m,
            Space.gutter,
            Space.m,
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: TextField(
                    controller: _query,
                    style: mono(context, size: 12.5),
                    decoration: InputDecoration(
                      hintText: '筛选：方法、域名或路径',
                      prefixIcon: const Icon(Icons.search, size: 16),
                      prefixIconConstraints: const BoxConstraints(minWidth: 36),
                      suffixIcon: _query.text.isEmpty
                          ? null
                          : ToolButton(
                              icon: Icons.close,
                              tooltip: '清除筛选',
                              onPressed: _query.clear,
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: Space.s),
                _FilterChip(
                  label: 'Mock',
                  on: _onlyMocked,
                  tooltip: '只看由规则返回或修改的响应',
                  onTap: () => setState(() => _onlyMocked = !_onlyMocked),
                ),
                const SizedBox(width: 4),
                _FilterChip(
                  label: '异常',
                  on: _onlyFailed,
                  tooltip: '只看失败或状态码 ≥ 400 的请求',
                  onTap: () => setState(() => _onlyFailed = !_onlyFailed),
                ),
              ],
            ),
          ),
        ),
        const _HeaderRow(),
        const Hairline(),
        Expanded(
          child: widget.entries.isEmpty
              ? (widget.empty ?? const SizedBox.shrink())
              : visible.isEmpty
              ? EmptyState(
                  title: '没有符合筛选条件的请求',
                  body: '共 ${widget.entries.length} 条请求被筛掉。',
                  action: filtered
                      ? OutlinedButton(
                          onPressed: () => setState(() {
                            _query.clear();
                            _onlyMocked = false;
                            _onlyFailed = false;
                          }),
                          child: const Text('清除筛选'),
                        )
                      : null,
                )
              : Scrollbar(
                  controller: _scroll,
                  child: ListView.builder(
                    controller: _scroll,
                    primary: false,
                    itemCount: visible.length,
                    itemExtent: 40,
                    itemBuilder: (context, index) {
                      final entry = visible[index];
                      return TrafficRow(
                        entry: entry,
                        selected: _isSelected(entry),
                        onTap: () => widget.onSelect(entry),
                        onCreateRule: widget.onCreateRule == null
                            ? null
                            : () => widget.onCreateRule!(entry),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.on,
    required this.onTap,
    required this.tooltip,
  });

  final String label;
  final bool on;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        toggled: on,
        button: true,
        child: InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? p.ink : Colors.transparent,
              border: Border.all(color: on ? p.ink : p.rule),
            ),
            child: Text(
              label,
              style: context.text.labelLarge!.copyWith(
                color: on ? p.paper : p.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const _timeWidth = 72.0;
const _methodWidth = 60.0;
const _statusWidth = 44.0;
const _durationWidth = 64.0;

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, 6),
    child: Row(
      children: [
        SizedBox(width: _timeWidth, child: Eyebrow('时间')),
        SizedBox(width: _methodWidth, child: Eyebrow('方法')),
        SizedBox(width: _statusWidth, child: Eyebrow('状态')),
        Expanded(child: Eyebrow('地址')),
        SizedBox(
          width: _durationWidth,
          child: Align(alignment: Alignment.centerRight, child: Eyebrow('耗时')),
        ),
      ],
    ),
  );
}

/// One request: time, method, status, host + path, duration, mock marker.
class TrafficRow extends StatelessWidget {
  const TrafficRow({
    super.key,
    required this.entry,
    required this.onTap,
    this.selected = false,
    this.onCreateRule,
  });

  final Entry entry;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onCreateRule;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final host = entry['host'] as String? ?? '';
    final path = entry['path'] as String? ?? '';
    final uri = Uri.tryParse(entry['uri'] as String? ?? '');
    final query = uri == null || uri.query.isEmpty ? '' : '?${uri.query}';
    final mocked = entry['mocked'] == true;
    return ListRow(
      selected: selected,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
      hoverActions: onCreateRule == null
          ? null
          : ToolButton(
              icon: Icons.add_box_outlined,
              tooltip: '用这个请求新建规则',
              onPressed: onCreateRule,
            ),
      child: SizedBox(
        height: 40,
        child: Row(
          children: [
            SizedBox(
              width: _timeWidth,
              child: Text(
                formatClock(entry['startedAt'] as int? ?? 0),
                style: mono(context, size: 12, color: p.muted),
              ),
            ),
            MethodText('${entry['method'] ?? '?'}', width: _methodWidth),
            SizedBox(
              width: _statusWidth,
              child: StatusText(code: entry['statusCode'] as int?),
            ),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: host,
                      style: mono(context, size: 12, color: p.muted),
                    ),
                    TextSpan(text: path, style: mono(context, size: 12)),
                    TextSpan(
                      text: query,
                      style: mono(context, size: 12, color: p.faint),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (mocked) ...[
              const SizedBox(width: Space.s),
              const Tag('MOCK', tone: TagTone.signal),
            ],
            SizedBox(
              width: _durationWidth,
              child: Text(
                '${entry['durationMs'] ?? 0} ms',
                textAlign: TextAlign.right,
                style: mono(context, size: 12, color: p.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
