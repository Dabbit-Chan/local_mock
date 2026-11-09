import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import '../curl.dart';
import '../format.dart';
import '../ui/code_panel.dart';
import '../ui/primitives.dart';
import '../ui/theme.dart';
import 'traffic_list.dart';

/// Inspector for one captured request: summary, query and both bodies.
class TrafficDetail extends StatefulWidget {
  const TrafficDetail({super.key, required this.entry, this.onCreateRule});

  final Entry entry;
  final VoidCallback? onCreateRule;

  @override
  State<TrafficDetail> createState() => _TrafficDetailState();
}

class _TrafficDetailState extends State<TrafficDetail> {
  late final CodeLineEditingController _request;
  late final CodeLineEditingController _response;

  @override
  void initState() {
    super.initState();
    _request = readOnlyCode(widget.entry['requestBody'] as String?);
    _response = readOnlyCode(widget.entry['responseBody'] as String?);
  }

  @override
  void dispose() {
    _request.dispose();
    _response.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final e = widget.entry;
    final uriText = '${e['uri'] ?? ''}';
    final uri = Uri.tryParse(uriText);
    Map<String, List<String>> query = const {};
    try {
      query = uri?.queryParametersAll ?? const {};
    } on FormatException {
      // Malformed escapes: the full URL above still shows the raw query.
    }
    final hasRequestBody =
        (e['requestBody'] as String?)?.trim().isNotEmpty ?? false;
    final hasResponseBody =
        (e['responseBody'] as String?)?.trim().isNotEmpty ?? false;
    final error = e['error'] as String?;
    final requestHeaders = _readHeaders(e['requestHeaders']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeading(
          index: '03',
          title: '请求详情',
          trailing: widget.onCreateRule == null
              ? null
              : FilledButton(
                  onPressed: widget.onCreateRule,
                  child: const Text('用此请求新建规则'),
                ),
        ),
        const Hairline(strong: true),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.gutter,
            Space.l,
            Space.gutter,
            Space.m,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    '${e['method'] ?? '?'}'.toUpperCase(),
                    style: context.text.headlineMedium,
                  ),
                  const SizedBox(width: Space.l),
                  StatusText(code: e['statusCode'] as int?, size: 22),
                  const SizedBox(width: Space.l),
                  Text(
                    '${e['durationMs'] ?? 0} ms · ${formatClock(e['startedAt'] as int? ?? 0)}',
                    style: context.text.bodyMedium!.copyWith(color: p.muted),
                  ),
                  const Spacer(),
                  if (e['mocked'] == true)
                    const Tooltip(
                      message: '响应由 Mock 规则返回或经字段补丁修改',
                      child: Tag('MOCK', tone: TagTone.signal),
                    ),
                ],
              ),
              const SizedBox(height: Space.m),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SelectableText(
                      uriText,
                      style: mono(context, size: 13),
                    ),
                  ),
                  ToolButton(
                    icon: Icons.copy_outlined,
                    tooltip: '复制 URL',
                    onPressed: () => copyText(context, uriText, ' URL'),
                  ),
                  const SizedBox(width: Space.xs),
                  Tooltip(
                    message: '复制为可直接执行的 cURL 命令',
                    child: OutlinedButton(
                      key: const Key('copy-curl'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(
                          horizontal: Space.m,
                        ),
                      ),
                      onPressed: () =>
                          copyText(context, curlForEntry(e), ' cURL 命令'),
                      child: const Text('复制 cURL'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.s),
              if (e['contentType'] != null)
                Fact('Content-Type', '${e['contentType']}'),
              if (error != null) Fact('错误', error, color: p.signal),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              0,
              Space.gutter,
              Space.gutter,
            ),
            child: _TrafficDetailSections(
              query: query,
              requestHeaders: requestHeaders,
              requestController: _request,
              responseController: _response,
              hasRequestBody: hasRequestBody,
              hasResponseBody: hasResponseBody,
            ),
          ),
        ),
      ],
    );
  }
}

class _TrafficDetailSections extends StatefulWidget {
  const _TrafficDetailSections({
    required this.query,
    required this.requestHeaders,
    required this.requestController,
    required this.responseController,
    required this.hasRequestBody,
    required this.hasResponseBody,
  });

  final Map<String, List<String>> query;
  final Map<String, List<String>> requestHeaders;
  final CodeLineEditingController requestController;
  final CodeLineEditingController responseController;
  final bool hasRequestBody;
  final bool hasResponseBody;

  @override
  State<_TrafficDetailSections> createState() => _TrafficDetailSectionsState();
}

class _TrafficDetailSectionsState extends State<_TrafficDetailSections> {
  final _weights = [1.2, 1.2, 2.0, 4.0];
  final _collapsed = [false, false, false, false];
  final _overflowScroll = ScrollController();
  final _layoutRevision = ValueNotifier<int>(0);

  /// Set while a splitter is being dragged: the two panes on either side of it
  /// keep their content laid out at a fixed height and are only clipped, so a
  /// drag re-positions cached layers instead of re-laying out and repainting
  /// every visible line on each pointer move.
  _PaneFreeze? _freeze;
  static const _labels = ['Query 参数', '请求头', '请求体', '响应体'];
  static const _collapsedHeight = 34.0;
  static const _splitterHeight = 20.0;
  static const _minPaneHeight = 96.0;

  List<int> get _visible => [
    if (widget.query.isNotEmpty) 0,
    if (widget.requestHeaders.isNotEmpty) 1,
    if (widget.hasRequestBody) 2,
    if (widget.hasResponseBody) 3,
  ];

  @override
  void dispose() {
    _overflowScroll.dispose();
    _layoutRevision.dispose();
    super.dispose();
  }

  void _resize(int before, int after, double delta, Map<int, double> sizes) {
    // Clamp the shared delta, not each pane separately: other panes must not
    // move, and the pair's total height must remain constant at either limit.
    final change = delta.clamp(
      _minPaneHeight - sizes[before]!,
      sizes[after]! - _minPaneHeight,
    );
    // At either limit the layout would not change; skip the frame.
    if (change == 0) return;
    for (final index in sizes.keys) {
      if (!_collapsed[index]) {
        _weights[index] = sizes[index]! - _minPaneHeight;
      }
    }
    _weights[before] += change;
    _weights[after] -= change;
    _layoutRevision.value++;
  }

  /// Freezes (or releases) the content of the pane pair being dragged. No
  /// [setState]: the layout revision that every pointer move bumps already
  /// rebuilds the size-driven subtree, and the pane widgets stay identical.
  void _setFreeze(_PaneFreeze? value) {
    if (_freeze == value) return;
    _freeze = value;
    _layoutRevision.value++;
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    if (visible.isEmpty) return const SizedBox.shrink();
    // Reuse the content widgets while resizing; only their constraints change.
    final panes = {for (final index in visible) index: _pane(context, index)};
    return LayoutBuilder(
      builder: (context, constraints) {
        final expanded = [
          for (final i in visible)
            if (!_collapsed[i]) i,
        ];
        final fixedHeight =
            (visible.length - expanded.length) * _collapsedHeight +
            (visible.length - 1) * _splitterHeight;
        final minimumHeight = fixedHeight + expanded.length * _minPaneHeight;
        // On short windows, scroll the stack instead of crushing editor
        // toolbars or making collapsed sections impossible to reopen.
        final layoutHeight = constraints.maxHeight < minimumHeight
            ? minimumHeight
            : constraints.maxHeight;
        final extraHeight = layoutHeight - minimumHeight;
        // Keep the scroll view (and its scrollbar) outside the revision
        // builder: a drag only changes pane heights, never the viewport.
        return ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: Scrollbar(
            controller: _overflowScroll,
            child: SingleChildScrollView(
              controller: _overflowScroll,
              primary: false,
              child: ValueListenableBuilder<int>(
                valueListenable: _layoutRevision,
                builder: (context, _, child) {
                  final totalWeight = expanded.fold<double>(
                    0,
                    (sum, i) => sum + _weights[i],
                  );
                  final sizes = <int, double>{
                    for (final i in visible)
                      i: _collapsed[i]
                          ? _collapsedHeight
                          : _minPaneHeight +
                                extraHeight *
                                    (totalWeight > 0
                                        ? _weights[i] / totalWeight
                                        : 1 / expanded.length),
                  };

                  return SizedBox(
                    height: layoutHeight,
                    child: Column(
                      children: [
                        for (
                          var position = 0;
                          position < visible.length;
                          position++
                        ) ...[
                          SizedBox(
                            key: Key('detail-pane-${visible[position]}'),
                            height: sizes[visible[position]],
                            child: _PaneContent(
                              frozenHeight: _frozenHeightFor(visible[position]),
                              child: panes[visible[position]]!,
                            ),
                          ),
                          if (position < visible.length - 1)
                            _splitter(visible, position, sizes),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  /// While its pair is dragged, a pane's content keeps the pair's combined
  /// height (an upper bound for either side) and is clipped to the pane, so no
  /// descendant is laid out or repainted until the drag ends.
  double? _frozenHeightFor(int index) {
    final freeze = _freeze;
    if (freeze == null || _collapsed[index]) return null;
    if (index != freeze.before && index != freeze.after) return null;
    return freeze.height;
  }

  Widget _pane(BuildContext context, int index) {
    final count = switch (index) {
      0 => widget.query.length,
      1 => widget.requestHeaders.length,
      _ => null,
    };
    if (_collapsed[index]) return _sectionHeader(context, index, count);
    if (index >= 2) {
      return CodePanel(
        label: _labels[index],
        controller: index == 2
            ? widget.requestController
            : widget.responseController,
        readOnly: true,
        finalAction: _collapseButton(index),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(context, index, count),
        Expanded(
          child: _KeyValueTable(
            index == 0 ? widget.query : widget.requestHeaders,
          ),
        ),
      ],
    );
  }

  Widget _collapseButton(int index) => ToolButton(
    icon: _collapsed[index] ? Icons.unfold_more : Icons.unfold_less,
    tooltip: _collapsed[index] ? '展开${_labels[index]}' : '折叠${_labels[index]}',
    onPressed: () => setState(() => _collapsed[index] = !_collapsed[index]),
  );

  Widget _sectionHeader(BuildContext context, int index, int? count) {
    final p = context.palette;
    return SizedBox(
      height: _collapsedHeight,
      child: Row(
        children: [
          Eyebrow(_labels[index]),
          if (count != null) ...[
            const SizedBox(width: 6),
            Text(
              '$count',
              style: context.text.labelSmall!.copyWith(color: p.faint),
            ),
          ],
          const Spacer(),
          if (index <= 1)
            ToolButton(
              icon: Icons.copy_outlined,
              tooltip: index == 0 ? '复制全部 Query 参数' : '复制全部请求头',
              onPressed: () => copyText(
                context,
                index == 0
                    ? Uri(queryParameters: widget.query).query
                    : _headerLines(widget.requestHeaders),
                _labels[index],
              ),
            ),
          _collapseButton(index),
        ],
      ),
    );
  }

  Widget _splitter(List<int> visible, int position, Map<int, double> sizes) {
    final before = visible[position];
    // A collapsed pane occupies only its header; allow the expanded panes
    // above and below it to keep sharing the available space.
    final following = visible.skip(position + 1).where((i) => !_collapsed[i]);
    if (_collapsed[before] || following.isEmpty) {
      return const SizedBox(height: _splitterHeight);
    }
    final after = following.first;
    return _DetailSplitter(
      key: Key('detail-splitter-$before'),
      height: _splitterHeight,
      label: '上下拖动调整「${_labels[before]}」与「${_labels[after]}」的高度',
      // The pair's combined height cannot change during the drag, so it is a
      // tight upper bound for freezing either pane's content.
      onDragStart: () => _setFreeze(
        _PaneFreeze(before, after, sizes[before]! + sizes[after]!),
      ),
      onDragEnd: () => _setFreeze(null),
      onDrag: (delta) => _resize(before, after, delta, sizes),
    );
  }
}

/// The pane pair being dragged, and the content height both panes keep while
/// the drag is in flight.
class _PaneFreeze {
  const _PaneFreeze(this.before, this.after, this.height);

  final int before;
  final int after;
  final double height;

  @override
  bool operator ==(Object other) =>
      other is _PaneFreeze &&
      other.before == before &&
      other.after == after &&
      other.height == height;

  @override
  int get hashCode => Object.hash(before, after, height);
}

/// Lays its child out at a fixed [frozenHeight] (top-aligned) while the splitter
/// is dragged, and clipped to the pane's current bounds. The widget structure
/// never changes, so the pane's subtree (and each editor's scroll position)
/// survives the drag; the child also sits behind a [RepaintBoundary] so moving
/// the clip only re-composites an already recorded layer.
class _PaneContent extends StatelessWidget {
  const _PaneContent({required this.frozenHeight, required this.child});

  final double? frozenHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      // Only pay for a clip layer while the pane is actually being clipped.
      clipBehavior: frozenHeight == null ? Clip.none : Clip.hardEdge,
      child: OverflowBox(
        alignment: Alignment.topCenter,
        minHeight: frozenHeight,
        maxHeight: frozenHeight,
        child: RepaintBoundary(child: child),
      ),
    );
  }
}

/// A quiet divider with a generous hit target and immediate pointer tracking.
class _DetailSplitter extends StatefulWidget {
  const _DetailSplitter({
    super.key,
    required this.height,
    required this.label,
    required this.onDragStart,
    required this.onDragEnd,
    required this.onDrag,
  });

  final double height;
  final String label;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  final ValueChanged<double> onDrag;

  @override
  State<_DetailSplitter> createState() => _DetailSplitterState();
}

class _DetailSplitterState extends State<_DetailSplitter> {
  bool _hovered = false;
  int? _pointer;
  double _startY = 0;
  ValueChanged<double>? _resizeFromStart;

  void _endDrag(PointerEvent event) {
    if (event.pointer != _pointer) return;
    setState(() {
      _pointer = null;
      _resizeFromStart = null;
    });
    widget.onDragEnd();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final active = _hovered || _pointer != null;
    return Semantics(
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (_pointer != null || event.buttons != kPrimaryButton) return;
            // Keep the original layout callback throughout this drag. Absolute
            // screen coordinates include every move, even between two frames.
            setState(() {
              _pointer = event.pointer;
              _startY = event.position.dy;
              _resizeFromStart = widget.onDrag;
            });
            widget.onDragStart();
          },
          onPointerMove: (event) {
            if (event.pointer == _pointer) {
              _resizeFromStart?.call(event.position.dy - _startY);
            }
          },
          onPointerUp: _endDrag,
          onPointerCancel: _endDrag,
          child: SizedBox(
            height: widget.height,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  child: Container(height: 1, color: active ? p.faint : p.rule),
                ),
                Container(
                  width: 44,
                  height: 8,
                  alignment: Alignment.center,
                  color: p.paper,
                  child: Container(
                    width: 28,
                    height: 3,
                    decoration: BoxDecoration(
                      color: active ? p.muted : p.rule,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Header names/values from either the current app (`name: [values]`) or
/// older recordings (`name: value`).
Map<String, List<String>> _readHeaders(Object? value) {
  if (value is! Map) return const {};
  final headers = <String, List<String>>{};
  for (final entry in value.entries) {
    final raw = entry.value;
    final values = raw is List
        ? [
            for (final item in raw)
              if (item != null) '$item',
          ]
        : [if (raw != null) '$raw'];
    if (values.isNotEmpty) headers['${entry.key}'] = values;
  }
  return headers;
}

/// `Name: value` lines, one per header value, for the copy button.
String _headerLines(Map<String, List<String>> headers) => [
  for (final header in headers.entries)
    for (final value in header.value) '${header.key}: $value',
].join('\n');

/// Two-column name / value table; keys keep their exact case. Used for query
/// parameters and request headers.
class _KeyValueTable extends StatefulWidget {
  const _KeyValueTable(this.values);

  final Map<String, List<String>> values;

  @override
  State<_KeyValueTable> createState() => _KeyValueTableState();
}

class _KeyValueTableState extends State<_KeyValueTable> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return LayoutBuilder(
      builder: (context, constraints) => Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.rule)),
        ),
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: Scrollbar(
            controller: _scroll,
            child: SingleChildScrollView(
              controller: _scroll,
              primary: false,
              padding: const EdgeInsets.only(right: 10),
              child: Column(
                children: [
                  for (final param in widget.values.entries)
                    for (final value
                        in param.value.isEmpty ? [''] : param.value)
                      Container(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: p.rule)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: (constraints.maxWidth * 0.35).clamp(
                                0.0,
                                160.0,
                              ),
                              child: SelectableText(
                                param.key,
                                style: mono(
                                  context,
                                  size: 12.5,
                                  color: p.muted,
                                ),
                              ),
                            ),
                            Expanded(
                              child: SelectableText(
                                value,
                                style: mono(context, size: 12.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
