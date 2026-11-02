import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

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
    final hasRequestBody = e['requestBody'] != null;
    final hasResponseBody = e['responseBody'] != null;
    final error = e['error'] as String?;

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
                ],
              ),
              const SizedBox(height: Space.s),
              if (e['contentType'] != null)
                Fact('Content-Type', '${e['contentType']}'),
              if (error != null) Fact('错误', error, color: p.signal),
              if (query.isNotEmpty) ...[
                const SizedBox(height: Space.m),
                const Eyebrow('Query 参数'),
                const SizedBox(height: 4),
                _QueryTable(query),
              ],
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (hasRequestBody) ...[
                  Expanded(
                    flex: 2,
                    child: CodePanel(
                      label: '请求体',
                      controller: _request,
                      readOnly: true,
                    ),
                  ),
                  const SizedBox(height: Space.l),
                ],
                Expanded(
                  flex: 5,
                  child: hasResponseBody
                      ? CodePanel(
                          label: '响应体',
                          controller: _response,
                          readOnly: true,
                        )
                      : Align(
                          alignment: Alignment.topLeft,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Eyebrow('响应体'),
                              const SizedBox(height: Space.s),
                              Text(
                                error != null
                                    ? '请求失败，没有响应体。'
                                    : '没有记录到响应体（空响应或适配器未捕获）。',
                                style: context.text.bodyMedium!.copyWith(
                                  color: p.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Query parameters as a two-column table; keys keep their exact case.
class _QueryTable extends StatelessWidget {
  const _QueryTable(this.query);

  final Map<String, List<String>> query;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      constraints: const BoxConstraints(maxHeight: 160),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.rule)),
      ),
      child: SingleChildScrollView(
        child: Column(
          children: [
            for (final param in query.entries)
              for (final value in param.value.isEmpty ? [''] : param.value)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: p.rule)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 180,
                        child: SelectableText(
                          param.key,
                          style: mono(context, size: 12.5, color: p.muted),
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
    );
  }
}
