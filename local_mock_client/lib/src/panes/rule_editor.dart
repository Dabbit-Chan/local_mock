import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_mock_core/local_mock_core.dart';
import 'package:re_editor/re_editor.dart';

import '../format.dart';
import '../rule_book.dart';
import '../ui/code_panel.dart';
import '../ui/primitives.dart';
import '../ui/theme.dart';

enum ResponseMode { replace, patch }

/// Keys of the editors, for tests.
abstract final class RuleEditorKeys {
  static const params = Key('rule-params');
  static const headers = Key('rule-headers');
  static const body = Key('rule-body');
  static const patch = Key('rule-patch');
  static const recordedQuery = Key('rule-recorded-query');
  static const recordedBody = Key('rule-recorded-body');
  static const save = Key('rule-save');
}

/// Inline editor for one response rule.
///
/// Used for top-level rules and, with [groupName] set, for an interface
/// inside a recording group (where saving only updates the group draft).
class RuleEditor extends StatefulWidget {
  const RuleEditor({
    super.key,
    required this.initial,
    required this.existingIds,
    required this.onSave,
    required this.onCancel,
    this.isNew = false,
    this.onDelete,
    this.onDirtyChanged,
    this.groupName,
    this.matchRecordedParams = true,
  });

  final Rule initial;

  /// IDs used by sibling rules.
  final Set<String> existingIds;

  /// Receives the validated, normalized rule. May throw to report failure.
  final Future<void> Function(Rule rule) onSave;
  final VoidCallback onCancel;
  final VoidCallback? onDelete;
  final ValueChanged<bool>? onDirtyChanged;
  final bool isNew;

  /// Name of the recording group this interface belongs to.
  final String? groupName;

  /// Whether the parent group currently matches recorded query / body.
  final bool matchRecordedParams;

  @override
  State<RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<RuleEditor> {
  static const _methods = [
    'GET',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'HEAD',
    'OPTIONS',
  ];

  Rule get _i => widget.initial;
  bool get _inGroup => widget.groupName != null;
  bool get _hasRecordedRequest => _i['recordedRequest'] != null;

  /// Rules generated from recordings keep the original response text so
  /// non-JSON bodies survive; the body field then accepts any text.
  bool get _rawResponse => _i['responseText'] != null;

  static String _pretty(Object? value) =>
      value == null ? '' : prettyJson(value);

  late final _id = TextEditingController(text: '${_i['id'] ?? ''}');
  late final _path = TextEditingController(text: '${_i['path'] ?? '/'}');
  late final _host = TextEditingController(text: '${_i['host'] ?? ''}');
  late final _status = TextEditingController(
    text: '${_i['statusCode'] ?? 200}',
  );
  late final _delay = TextEditingController(text: '${_i['delayMs'] ?? 0}');
  late final _params = CodeLineEditingController.fromText(
    _pretty(
      _i['params'] is Map && (_i['params'] as Map).isNotEmpty
          ? _i['params']
          : null,
    ),
  );
  late final _headers = CodeLineEditingController.fromText(
    _i['headers'] is Map && (_i['headers'] as Map).isNotEmpty
        ? _pretty(_i['headers'])
        : '',
  );
  late final _body = CodeLineEditingController.fromText(
    _rawResponse
        ? prettyBody(_i['responseText'] as String)
        : _pretty(_i['body']),
  );
  late final _patch = CodeLineEditingController.fromText(
    _pretty(
      _i['patchBody'] is Map && (_i['patchBody'] as Map).isNotEmpty
          ? _i['patchBody']
          : null,
    ),
  );
  late final _recordedQuery = CodeLineEditingController.fromText(
    prettyJson((_i['recordedRequest'] as Map?)?['query'] ?? {}),
  );
  late final _recordedBody = CodeLineEditingController.fromText(
    (_i['recordedRequest'] as Map?)?['body'] as String? ?? '',
  );
  late String _method = '${_i['method'] ?? 'GET'}'.toUpperCase();
  // Optional editors stay folded to one line until they have content.
  late bool _showParams = _params.text.trim().isNotEmpty;
  late bool _showHeaders = _headers.text.trim().isNotEmpty;

  late ResponseMode _mode =
      _i['patchBody'] is Map && (_i['patchBody'] as Map).isNotEmpty
      ? ResponseMode.patch
      : ResponseMode.replace;

  final _errors = <String, String>{};
  String? _failure;
  bool _saving = false;
  late final String _baseline = _snapshot();
  bool _dirty = false;

  List<Listenable> get _inputs => [
    _id,
    _path,
    _host,
    _status,
    _delay,
    _params,
    _headers,
    _body,
    _patch,
    _recordedQuery,
    _recordedBody,
  ];

  @override
  void initState() {
    super.initState();
    for (final input in _inputs) {
      input.addListener(_changed);
    }
  }

  @override
  void dispose() {
    for (final input in _inputs) {
      input.removeListener(_changed);
      (input as ChangeNotifier).dispose();
    }
    super.dispose();
  }

  String _snapshot() => jsonEncode([
    _id.text,
    _path.text,
    _host.text,
    _status.text,
    _delay.text,
    _params.text,
    _headers.text,
    _body.text,
    _patch.text,
    _recordedQuery.text,
    _recordedBody.text,
    _method,
    _mode.name,
  ]);

  void _changed() {
    final dirty = widget.isNew || _snapshot() != _baseline;
    if (dirty != _dirty) {
      setState(() => _dirty = dirty);
      widget.onDirtyChanged?.call(dirty);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.isNew && !_dirty) {
      _dirty = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.onDirtyChanged?.call(true),
      );
    }
  }

  // ---- validation --------------------------------------------------------

  int? _int(String key, String text, int min, int max, String label) {
    final value = int.tryParse(text.trim());
    if (value == null || value < min || value > max) {
      _errors[key] = '$label需为 $min–$max 的整数';
      return null;
    }
    return value;
  }

  Map<String, dynamic>? _object(String key, String text, String label) {
    if (text.trim().isEmpty) return null;
    try {
      final value = jsonDecode(text);
      if (value is Map<String, dynamic>) return value;
      _errors[key] = '$label需为 JSON 对象';
    } on FormatException {
      _errors[key] = '$label不是合法的 JSON';
    }
    return null;
  }

  Rule? _build() {
    _errors.clear();
    final id = _id.text.trim();
    if (id.isEmpty) {
      _errors['id'] = '请填写 ID';
    } else if (widget.existingIds.contains(id)) {
      _errors['id'] = '已有规则使用这个 ID';
    }
    final path = _path.text.trim();
    if (!path.startsWith('/') || path.contains('?') || path.contains('#')) {
      _errors['path'] = '以 / 开头，不含 ? 或 #（参数请写在参数条件里）';
    }
    final delay = _int('delay', _delay.text, 0, 60000, '延迟');
    final patching = _mode == ResponseMode.patch;

    final params = _object('params', _params.text, '参数条件');
    if (params != null) {
      if (params.keys.any((k) => k.trim().isEmpty)) {
        _errors['params'] = '参数名不能为空';
      } else if (params.values.any(
        (v) => v != null && v is! String && v is! num && v is! bool,
      )) {
        _errors['params'] = '参数值只能是字符串、数字、布尔值或 null';
      }
    }

    Map<String, dynamic>? patch;
    int? status;
    Map<String, dynamic>? headers;
    dynamic body;
    if (patching) {
      patch = _object('patch', _patch.text, '字段补丁');
      if (patch == null && !_errors.containsKey('patch')) {
        _errors['patch'] = '至少填写一个“字段路径: 新值”';
      } else if (patch != null && patch.isEmpty) {
        _errors['patch'] = '至少填写一个“字段路径: 新值”';
      } else if (patch != null) {
        try {
          MockRule.fromJson({
            'id': 'check',
            'method': 'GET',
            'path': '/',
            'patchBody': patch,
          });
        } on FormatException catch (error) {
          _errors['patch'] = '字段路径无效：${error.message}';
        }
      }
    } else {
      status = _int('status', _status.text, 100, 599, '状态码');
      headers = _object('headers', _headers.text, '响应头');
      if (headers != null && headers.values.any((v) => v is! String)) {
        _errors['headers'] = '响应头的值必须是字符串';
      }
      if (_rawResponse) {
        try {
          body = jsonDecode(_body.text);
        } on FormatException {
          body = _body.text;
        }
      } else if (_body.text.trim().isNotEmpty) {
        try {
          body = jsonDecode(_body.text);
        } on FormatException {
          _errors['body'] = '响应体不是合法的 JSON';
        }
      }
    }

    Map<String, dynamic>? recordedQuery;
    if (_hasRecordedRequest) {
      try {
        recordedQuery = jsonDecode(_recordedQuery.text) as Map<String, dynamic>;
        RecordedRequest.fromJson({'query': recordedQuery});
      } catch (_) {
        _errors['recordedQuery'] = '需为 JSON 对象，值为字符串数组，例如 {"id": ["1"]}';
      }
    }
    if (_errors.isNotEmpty) return null;

    return {
      'id': id,
      'enabled': _i['enabled'] != false,
      'method': _method,
      'path': path,
      if (_host.text.trim().isNotEmpty) 'host': _host.text.trim(),
      // Patch rules keep the stored response so switching back restores it.
      'statusCode': patching ? _i['statusCode'] ?? 200 : status,
      'delayMs': delay,
      if (patching) ...{
        'headers': _i['headers'] ?? <String, dynamic>{},
        'body': _i['body'],
      } else ...{
        'headers': ?headers,
        'body': body,
      },
      if (_rawResponse)
        'responseText': patching ? _i['responseText'] : _body.text,
      if (_hasRecordedRequest)
        'recordedRequest': {
          'query': recordedQuery,
          if (_recordedBody.text.isNotEmpty) 'body': _recordedBody.text,
        },
      'params': ?params,
      'patchBody': ?patch,
    };
  }

  Future<void> _submit() async {
    if (_saving) return;
    final draft = _build();
    if (draft == null) {
      setState(() => _failure = '有 ${_errors.length} 处需要修改');
      return;
    }
    Rule normalized;
    try {
      normalized = MockRule.fromJson(draft).toJson();
    } on FormatException catch (error) {
      setState(() => _failure = error.message);
      return;
    }
    setState(() {
      _failure = null;
      _saving = true;
    });
    try {
      await widget.onSave(normalized);
    } catch (error) {
      if (mounted) setState(() => _failure = describeError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ---- layout ------------------------------------------------------------

  Widget _textField(
    String key,
    TextEditingController controller, {
    String? hint,
    bool monospace = true,
    TextInputType? keyboard,
    List<TextInputFormatter>? formatters,
  }) => TextField(
    key: ValueKey('rule-field-$key'),
    controller: controller,
    keyboardType: keyboard,
    inputFormatters: formatters,
    style: monospace ? mono(context, size: 13) : context.text.bodyMedium,
    onSubmitted: (_) => unawaited(_submit()),
    decoration: InputDecoration(
      hintText: hint,
      errorText: _errors[key],
      errorMaxLines: 2,
    ),
  );

  Widget _code(
    Key key,
    String errorKey,
    String label,
    CodeLineEditingController controller,
    double height, {
    TextValidator? validator,
    String? hint,
    String? help,
    bool format = true,
    VoidCallback? onExpand,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (onExpand != null)
        SizedBox(
          height: 32,
          child: Row(
            children: [
              Eyebrow(label),
              const Spacer(),
              TextButton(
                key: Key('expand-$errorKey'),
                onPressed: onExpand,
                child: const Text('+ 添加'),
              ),
            ],
          ),
        )
      else
        SizedBox(
          height: height,
          child: CodePanel(
            label: label,
            controller: controller,
            validator: validator,
            hint: hint,
            formatAction: format,
            editorKey: key,
            onSave: () => unawaited(_submit()),
          ),
        ),
      if (_errors[errorKey] != null && onExpand == null) ...[
        const SizedBox(height: 4),
        Text(
          _errors[errorKey]!,
          style: context.text.bodySmall!.copyWith(
            color: context.palette.signal,
          ),
        ),
      ] else if (help != null) ...[
        const SizedBox(height: 6),
        Text(help, style: context.text.bodySmall),
      ],
    ],
  );

  Widget _section(
    String title,
    String? note,
    List<Widget> children, {
    bool first = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (!first) const Hairline(),
      const SizedBox(height: Space.l),
      Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(title, style: context.text.titleLarge),
          if (note != null) ...[
            const SizedBox(width: Space.m),
            Expanded(child: Text(note, style: context.text.bodySmall)),
          ],
        ],
      ),
      const SizedBox(height: Space.m),
      ...children,
      const SizedBox(height: Space.xl),
    ],
  );

  Widget _row(List<Widget> children) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final (i, child) in children.indexed) ...[
        if (i > 0) const SizedBox(width: Space.m),
        child,
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final patching = _mode == ResponseMode.patch;
    final digitsOnly = [FilteringTextInputFormatter.digitsOnly];

    final header = SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
        child: Row(
          children: [
            Text('03', style: mono(context, size: 12, color: p.signal)),
            const SizedBox(width: Space.m),
            Flexible(
              child: Text(
                _inGroup
                    ? '录制组接口'
                    : widget.isNew
                    ? '新建规则'
                    : '编辑规则',
                overflow: TextOverflow.ellipsis,
                style: context.text.headlineSmall,
              ),
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
              child: Text(_inGroup ? '返回' : '取消'),
            ),
            const SizedBox(width: Space.s),
            Tooltip(
              message: saveShortcut,
              child: FilledButton(
                key: RuleEditorKeys.save,
                onPressed: _saving ? null : () => unawaited(_submit()),
                child: Text(_inGroup ? '应用到录制组' : '保存'),
              ),
            ),
          ],
        ),
      ),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
            unawaited(_submit()),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
            unawaited(_submit()),
      },
      child: FocusScope(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            const Hairline(strong: true),
            if (_inGroup)
              Notice(
                signal: false,
                message:
                    '录制组「${widget.groupName}」中的接口。修改先保存在录制组草稿里，'
                    '保存录制组后才会同步到设备。',
              ),
            if (_failure != null) Notice(message: _failure!),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final tall = math.max(320.0, constraints.maxHeight - 160);
                  return SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(
                      Space.gutter,
                      0,
                      Space.gutter,
                      Space.gutter,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _section('匹配', '方法、路径和域名完全相同的请求才会命中', [
                          _row([
                            SizedBox(
                              width: 132,
                              child: Labeled(
                                label: '方法',
                                child: _MethodPicker(
                                  value: _method,
                                  options: {..._methods, _method}.toList(),
                                  onChanged: (value) {
                                    setState(() => _method = value);
                                    _changed();
                                  },
                                ),
                              ),
                            ),
                            Expanded(
                              child: Labeled(
                                label: '路径',
                                child: _textField(
                                  'path',
                                  _path,
                                  hint: '/api/user/profile',
                                ),
                              ),
                            ),
                          ]),
                          const SizedBox(height: Space.m),
                          _row([
                            Expanded(
                              child: Labeled(
                                label: '域名',
                                child: _textField(
                                  'host',
                                  _host,
                                  hint: '留空匹配任意域名',
                                ),
                              ),
                            ),
                            Expanded(
                              child: Labeled(
                                label: 'ID',
                                child: _textField('id', _id),
                              ),
                            ),
                          ]),
                          const SizedBox(height: Space.l),
                          _code(
                            RuleEditorKeys.params,
                            'params',
                            '参数条件（可选）',
                            _params,
                            128,
                            onExpand: _showParams
                                ? null
                                : () => setState(() => _showParams = true),
                            validator: validateJsonObject,
                            hint: '{"id": "123"}',
                            help:
                                '只在这些参数全部相等时命中，其他参数不限。'
                                '先查 URL query，再查 JSON 或表单请求体；'
                                '嵌套字段写成 "filter.id"。留空则不看参数。',
                          ),
                          if (_hasRecordedRequest) ...[
                            const SizedBox(height: Space.l),
                            Text(
                              widget.matchRecordedParams
                                  ? '录制参数：录制组开启了“只匹配录制时的传参”，'
                                        '请求的 query 和请求体需与下面完全一致（键顺序不限）。'
                                  : '录制参数：录制组当前不比对录制参数，'
                                        '以下内容会保留，开启后生效。',
                              style: context.text.bodySmall,
                            ),
                            const SizedBox(height: Space.s),
                            _row([
                              Expanded(
                                child: _code(
                                  RuleEditorKeys.recordedQuery,
                                  'recordedQuery',
                                  '录制 query',
                                  _recordedQuery,
                                  140,
                                  validator: validateJsonObject,
                                ),
                              ),
                              Expanded(
                                child: _code(
                                  RuleEditorKeys.recordedBody,
                                  'recordedBody',
                                  '录制请求体',
                                  _recordedBody,
                                  140,
                                  format: false,
                                ),
                              ),
                            ]),
                          ],
                        ], first: true),
                        _section('响应', null, [
                          _ModeSwitch(
                            value: _mode,
                            onChanged: (mode) {
                              setState(() => _mode = mode);
                              _changed();
                            },
                          ),
                          const SizedBox(height: Space.s),
                          Text(
                            patching
                                ? '照常请求真实接口，只改写响应 JSON 中的指定字段；'
                                      '状态码、响应头和其余字段保持真实值。'
                                : '不访问网络，直接返回下面的状态码、响应头和响应体。',
                            style: context.text.bodySmall,
                          ),
                          const SizedBox(height: Space.l),
                          _row([
                            if (!patching)
                              Expanded(
                                child: Labeled(
                                  label: '状态码',
                                  child: _textField(
                                    'status',
                                    _status,
                                    keyboard: TextInputType.number,
                                    formatters: digitsOnly,
                                  ),
                                ),
                              ),
                            Expanded(
                              child: Labeled(
                                label: patching ? '额外延迟（毫秒）' : '延迟（毫秒）',
                                child: _textField(
                                  'delay',
                                  _delay,
                                  keyboard: TextInputType.number,
                                  formatters: digitsOnly,
                                ),
                              ),
                            ),
                          ]),
                          const SizedBox(height: Space.l),
                          if (patching)
                            _code(
                              RuleEditorKeys.patch,
                              'patch',
                              '字段补丁',
                              _patch,
                              tall,
                              validator: validateJsonObject,
                              hint: '{"data.items[*].name": "很长的名称"}',
                              help:
                                  '键是字段路径，值是新的 JSON 值，按顺序应用。'
                                  'data.items[0].name 改单个元素，data.items[*].name 改全部元素；'
                                  '越界下标会被跳过。响应不是 JSON 或父级不存在时，原样返回真实响应。',
                            )
                          else ...[
                            _code(
                              RuleEditorKeys.headers,
                              'headers',
                              '响应头（可选）',
                              _headers,
                              128,
                              onExpand: _showHeaders
                                  ? null
                                  : () => setState(() => _showHeaders = true),
                              validator: validateJsonObject,
                              hint: '{"content-type": "application/json"}',
                              help:
                                  '默认 content-type 为 application/json; charset=utf-8。',
                            ),
                            const SizedBox(height: Space.l),
                            _code(
                              RuleEditorKeys.body,
                              'body',
                              _rawResponse ? '响应体（原始文本）' : '响应体',
                              _body,
                              tall,
                              validator: _rawResponse ? null : validateJson,
                              hint: _rawResponse ? '' : '留空时响应体为 null',
                            ),
                          ],
                        ]),
                      ],
                    ),
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

/// Two-option selector for the response mode.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.value, required this.onChanged});

  final ResponseMode value;
  final ValueChanged<ResponseMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget option(ResponseMode mode, String label) {
      final on = mode == value;
      return Expanded(
        child: Semantics(
          selected: on,
          button: true,
          child: InkWell(
            onTap: () => onChanged(mode),
            child: Container(
              height: 40,
              alignment: Alignment.center,
              color: on ? p.ink : Colors.transparent,
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

    return Container(
      decoration: BoxDecoration(border: Border.all(color: p.ink)),
      child: Row(
        children: [
          option(ResponseMode.replace, '整包替换'),
          Container(width: 1, height: 40, color: p.ink),
          option(ResponseMode.patch, '字段补丁'),
        ],
      ),
    );
  }
}

class _MethodPicker extends StatelessWidget {
  const _MethodPicker({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    key: const ValueKey('rule-field-method'),
    initialValue: value,
    isExpanded: true,
    style: mono(context, size: 13, weight: FontWeight.w600),
    dropdownColor: context.palette.paper,
    borderRadius: BorderRadius.zero,
    elevation: 0,
    items: [
      for (final method in options)
        DropdownMenuItem(value: method, child: Text(method)),
    ],
    onChanged: (method) {
      if (method != null) onChanged(method);
    },
  );
}
