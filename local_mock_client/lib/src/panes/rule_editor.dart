import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:local_mock_core/local_mock_core.dart';
import 'package:re_editor/re_editor.dart';

import '../format.dart';
import '../json_paths.dart';
import '../rule_book.dart';
import '../rule_drafts.dart';
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
  static const reference = Key('rule-reference');
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
    this.sample,
  });

  final Rule initial;

  /// A captured request for this endpoint: its parameters are offered as
  /// conditions and its JSON response is shown as the patch reference.
  final Map<String, dynamic>? sample;

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

  late final List<ParamCandidate> _candidates = widget.sample == null
      ? const []
      : requestParams(widget.sample!);
  late final _reference = referenceResponse(_i, widget.sample);

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
    // The parameter picker and the patch reference reflect these texts.
    _params.addListener(_refresh);
    _patch.addListener(_refresh);
  }

  late String _paramsText = _params.text;
  late String _patchText = _patch.text;

  void _refresh() {
    if (_params.text == _paramsText && _patch.text == _patchText) return;
    _paramsText = _params.text;
    _patchText = _patch.text;
    _rebuild();
  }

  /// re_editor controllers can notify while the editor is being built;
  /// anything that rebuilds widgets then must wait for the frame to finish.
  void _afterBuild(VoidCallback action) {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) action();
      });
    } else {
      action();
    }
  }

  void _rebuild() => _afterBuild(() {
    if (mounted) setState(() {});
  });

  /// Decoded JSON object of [controller], `{}` when empty, null when invalid.
  static Map<String, dynamic>? _objectOf(CodeLineEditingController controller) {
    if (controller.text.trim().isEmpty) return {};
    try {
      final value = jsonDecode(controller.text);
      return value is Map<String, dynamic> ? value : null;
    } on FormatException {
      return null;
    }
  }

  void _expandParams() {
    if (_params.text.trim().isEmpty) {
      final initial = {
        for (final c in _candidates)
          if (c.topLevel) c.key: c.value,
      };
      if (initial.isNotEmpty) _params.text = prettyJson(initial);
    }
    setState(() => _showParams = true);
  }

  void _removeParams() {
    _params.text = '';
    setState(() {
      _showParams = false;
      _errors.remove('params');
    });
  }

  void _removeHeaders() {
    _headers.text = '';
    setState(() {
      _showHeaders = false;
      _errors.remove('headers');
    });
  }

  /// The params condition flattened to `path: value`, or null when the text
  /// is not a valid condition.
  Map<String, Object?>? _flatParams() {
    final raw = _objectOf(_params);
    if (raw == null) return null;
    try {
      return flattenParams(raw);
    } on FormatException {
      return null;
    }
  }

  void _toggleParam(ParamCandidate candidate) {
    final params = _flatParams();
    if (params == null) {
      toast(context, '参数条件不是合法的 JSON，先修正再点选');
      return;
    }
    if (params.containsKey(candidate.key)) {
      params.remove(candidate.key);
    } else {
      params[candidate.key] = candidate.value;
    }
    _params.text = params.isEmpty ? '' : prettyJson(params);
  }

  /// Adds `path: value` to the patch, keeping existing entries and order.
  void _addPatch(String path, Object? value) {
    final patch = _objectOf(_patch);
    if (patch == null) {
      toast(context, '字段补丁不是合法的 JSON，先修正再点选');
      return;
    }
    if (patch.containsKey(path)) {
      toast(context, '补丁里已经有 $path');
      return;
    }
    patch[path] = value;
    _patch.text = prettyJson(patch);
    setState(() => _errors.remove('patch'));
  }

  @override
  void dispose() {
    _params.removeListener(_refresh);
    _patch.removeListener(_refresh);
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
      _dirty = dirty;
      _rebuild();
      _afterBuild(() => widget.onDirtyChanged?.call(dirty));
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

    Map<String, Object?>? params;
    final rawParams = _object('params', _params.text, '参数条件');
    if (rawParams != null) {
      if (rawParams.keys.any((k) => k.trim().isEmpty)) {
        _errors['params'] = '参数名不能为空';
      } else {
        try {
          params = flattenParams(rawParams);
        } on FormatException catch (error) {
          _errors['params'] = error.message;
        }
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
    VoidCallback? onRemove,
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
            trailing: onRemove == null
                ? null
                : TextButton(
                    key: Key('remove-$errorKey'),
                    onPressed: onRemove,
                    child: const Text('移除'),
                  ),
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
                            onExpand: _showParams ? null : _expandParams,
                            onRemove: _removeParams,
                            validator: validateJsonObject,
                            hint: '{"id": "123"}',
                            help:
                                '只在这些参数全部相等时命中，其他参数不限。'
                                '先查 URL query，再查 JSON 或表单请求体；'
                                '嵌套字段可直接写嵌套 JSON，也可写成路径 "filter.id"、'
                                '"modules[0]"，保存时统一展开为路径。'
                                '数组按下标逐个比较，请求里多出的元素不影响命中。'
                                '留空则不看参数。',
                          ),
                          if (_showParams && _candidates.isNotEmpty) ...[
                            const SizedBox(height: Space.m),
                            _ParamPicker(
                              candidates: _candidates,
                              selected: _flatParams()?.keys.toSet() ?? const {},
                              onToggle: _toggleParam,
                            ),
                          ],
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
                          if (patching) ...[
                            _PatchReference(
                              key: RuleEditorKeys.reference,
                              reference: _reference,
                              height: _reference == null ? 0 : tall * 0.55,
                              patched:
                                  _objectOf(_patch)?.keys.toSet() ?? const {},
                              onPick: _addPatch,
                            ),
                            const SizedBox(height: Space.l),
                            _code(
                              RuleEditorKeys.patch,
                              'patch',
                              '字段补丁',
                              _patch,
                              _reference == null
                                  ? tall
                                  : math.max(200.0, tall * 0.45),
                              validator: validateJsonObject,
                              hint: '{"data.items[*].name": "很长的名称"}',
                              help:
                                  '键是字段路径，值是新的 JSON 值，按顺序应用。'
                                  'data.items[0].name 改单个元素，data.items[*].name 改全部元素；'
                                  '越界下标会被跳过。响应不是 JSON 或父级不存在时，原样返回真实响应。',
                            ),
                          ] else ...[
                            _code(
                              RuleEditorKeys.headers,
                              'headers',
                              '响应头（可选）',
                              _headers,
                              128,
                              onExpand: _showHeaders
                                  ? null
                                  : () => setState(() => _showHeaders = true),
                              onRemove: _removeHeaders,
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

/// Parameters of the sample request as toggle chips.
class _ParamPicker extends StatelessWidget {
  const _ParamPicker({
    required this.candidates,
    required this.selected,
    required this.onToggle,
  });

  final List<ParamCandidate> candidates;
  final Set<String> selected;
  final ValueChanged<ParamCandidate> onToggle;

  static const _limit = 60;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final shown = candidates.take(_limit);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Eyebrow('抓包请求中的参数'),
            const SizedBox(width: Space.s),
            Text('点击加入或移除', style: context.text.bodySmall),
          ],
        ),
        const SizedBox(height: Space.s),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final c in shown)
              Tooltip(
                message: c.fromQuery ? 'URL query' : '请求体',
                child: Semantics(
                  button: true,
                  selected: selected.contains(c.key),
                  child: InkWell(
                    key: ValueKey('param-${c.key}'),
                    onTap: () => onToggle(c),
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 320),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: selected.contains(c.key)
                            ? p.ink
                            : Colors.transparent,
                        border: Border.all(
                          color: selected.contains(c.key) ? p.ink : p.rule,
                        ),
                      ),
                      child: Text(
                        '${c.key} = ${c.value is String ? c.value : jsonEncode(c.value)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono(
                          context,
                          size: 12,
                          color: selected.contains(c.key) ? p.paper : p.ink,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (candidates.length > _limit) ...[
          const SizedBox(height: 4),
          Text(
            '另有 ${candidates.length - _limit} 个参数未列出，可直接在上方 JSON 中填写。',
            style: context.text.bodySmall,
          ),
        ],
      ],
    );
  }
}

/// Read-only response to write patches against. Clicking a field name or
/// value selects it; the bar below turns the selection into a patch entry.
class _PatchReference extends StatefulWidget {
  const _PatchReference({
    super.key,
    required this.reference,
    required this.height,
    required this.patched,
    required this.onPick,
  });

  final ({Object? json, String label})? reference;
  final double height;

  /// Paths already present in the patch.
  final Set<String> patched;
  final void Function(String path, Object? value) onPick;

  @override
  State<_PatchReference> createState() => _PatchReferenceState();
}

class _PatchReferenceState extends State<_PatchReference> {
  late final String _text = widget.reference == null
      ? ''
      : prettyJson(widget.reference!.json);
  late final _controller = CodeLineEditingController.fromText(_text);
  late final List<JsonNode> _nodes = indexJson(_text) ?? const [];
  late final List<int> _lineStarts = () {
    final starts = [0];
    for (var i = 0; i < _text.length; i++) {
      if (_text.codeUnitAt(i) == 0x0A) starts.add(i + 1);
    }
    return starts;
  }();
  List<Object>? _path;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_selectionChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_selectionChanged);
    _controller.dispose();
    super.dispose();
  }

  void _selectionChanged() {
    final sel = _controller.selection;
    if (sel.extentIndex >= _lineStarts.length) return;
    final offset = _lineStarts[sel.extentIndex] + sel.extentOffset;
    final path = pathAt(_nodes, offset);
    if (path == null || path.isEmpty) return;
    if (_path == null || formatPath(_path!) != formatPath(path)) {
      setState(() => _path = path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final reference = widget.reference;
    if (reference == null) {
      return Container(
        padding: const EdgeInsets.all(Space.l),
        color: p.well,
        child: Text(
          '没有可参照的 JSON 响应。用这个接口的请求新建规则，'
          '或让 App 先请求一次这个接口，就可以在这里点选字段生成补丁。',
          style: context.text.bodySmall,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: widget.height,
          child: CodePanel(
            label: '参照响应 · ${reference.label}',
            controller: _controller,
            readOnly: true,
            editorKey: const Key('rule-reference-editor'),
          ),
        ),
        _selectionBar(context, reference.json),
      ],
    );
  }

  Widget _selectionBar(BuildContext context, Object? json) {
    final p = context.palette;
    final path = _path;
    Widget bar(List<Widget> children) => Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: 6),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: p.rule),
          right: BorderSide(color: p.rule),
          bottom: BorderSide(color: p.rule),
        ),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Space.s,
        runSpacing: 4,
        children: children,
      ),
    );

    if (path == null) {
      return bar([
        Text('点击上方响应中的任意字段名或值，即可为它生成补丁。', style: context.text.bodySmall),
      ]);
    }
    if (!isAddressable(path)) {
      return bar([
        Text(
          '这个字段的名称包含 . 或 [ ]，无法用补丁路径定位。',
          style: context.text.bodySmall!.copyWith(color: p.signal),
        ),
      ]);
    }
    final value = valueAt(json, path);
    final exact = formatPath(path);
    final arrays = {
      for (final (i, s) in path.indexed)
        if (s is int) i,
    };
    final wildcard = arrays.isEmpty
        ? null
        : formatPath(path, wildcards: arrays);
    final preview = value is Map
        ? '{…} ${value.length} 个字段'
        : value is List
        ? '[…] ${value.length} 个元素'
        : jsonEncode(value);

    Widget action(String label, String target, Key key) {
      final done = widget.patched.contains(target);
      return OutlinedButton(
        key: key,
        onPressed: done ? null : () => widget.onPick(target, value),
        child: Text(done ? '$label（已添加）' : label),
      );
    }

    return bar([
      const Eyebrow('已选'),
      SelectableText(
        exact,
        style: mono(context, size: 12.5, weight: FontWeight.w600),
      ),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: Text(
          preview,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: mono(context, size: 12, color: p.muted),
        ),
      ),
      action('补丁此字段', exact, const Key('patch-exact')),
      if (wildcard != null)
        Tooltip(
          message: wildcard,
          child: action('补丁全部元素', wildcard, const Key('patch-wildcard')),
        ),
    ]);
  }
}
