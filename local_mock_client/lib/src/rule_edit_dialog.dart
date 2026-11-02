import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:local_mock_core/local_mock_core.dart';

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
  late final _params = TextEditingController(
    text: widget.initial['params'] == null
        ? ''
        : const JsonEncoder.withIndent('  ').convert(widget.initial['params']),
  );
  late final _patchBody = TextEditingController(
    text: widget.initial['patchBody'] == null
        ? ''
        : const JsonEncoder.withIndent(
            '  ',
          ).convert(widget.initial['patchBody']),
  );
  late String _method = (widget.initial['method'] ?? 'GET').toUpperCase();
  String? _error;

  bool get _hasPatch {
    final text = _patchBody.text.trim();
    if (text.isEmpty) return false;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map && decoded.isNotEmpty;
    } on FormatException {
      return true;
    }
  }

  @override
  void dispose() {
    _id.dispose();
    _path.dispose();
    _host.dispose();
    _statusCode.dispose();
    _delayMs.dispose();
    _headers.dispose();
    _body.dispose();
    _params.dispose();
    _patchBody.dispose();
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

  String? _conditionValidator(String? value, {bool params = false}) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return '必须是 JSON 对象';
      if (decoded.keys.any((key) => key.trim().isEmpty)) return '字段名不能为空';
      if (params &&
          decoded.values.any(
            (value) =>
                value != null &&
                value is! String &&
                value is! num &&
                value is! bool,
          )) {
        return '参数的值只能是字符串、数字、布尔值或 null';
      }
      if (!params) {
        MockRule.fromJson({
          'id': 'validate',
          'method': 'GET',
          'path': '/',
          'patchBody': decoded,
        });
      }
      return null;
    } on FormatException catch (error) {
      return '不是合法的 JSON 或字段路径：${error.message}';
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
      'statusCode': _hasPatch
          ? widget.initial['statusCode'] ?? 200
          : int.parse(_statusCode.text.trim()),
      'delayMs': int.parse(_delayMs.text.trim()),
      if (_hasPatch) ...{
        'headers': widget.initial['headers'] ?? <String, dynamic>{},
        'body': widget.initial['body'],
      } else ...{
        if (headersText.isNotEmpty) 'headers': jsonDecode(headersText),
        if (bodyText.isNotEmpty) 'body': jsonDecode(bodyText),
      },
      if (_params.text.trim().isNotEmpty) 'params': jsonDecode(_params.text),
      if (_patchBody.text.trim().isNotEmpty)
        'patchBody': jsonDecode(_patchBody.text),
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
                      TextFormField(
                        controller: _params,
                        maxLines: 3,
                        minLines: 2,
                        decoration: _decoration(
                          '参数匹配（可选）',
                          hint: '{"id": "123"}，留空匹配所有参数',
                        ),
                        style: const TextStyle(fontFamily: 'monospace'),
                        validator: (value) =>
                            _conditionValidator(value, params: true),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '只匹配填写的参数，其他参数不限。先查 URL query，再查 JSON / 表单请求体；多个条件需全部满足。',
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _patchBody,
                        maxLines: 5,
                        minLines: 2,
                        decoration: _decoration(
                          '字段补丁（可选）',
                          hint: '{"data.product": {"sku": "A1"}}',
                        ),
                        style: const TextStyle(fontFamily: 'monospace'),
                        validator: _conditionValidator,
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _hasPatch
                            ? '已启用字段补丁：请求真实接口，只修改指定字段；保留状态码、响应头和其他字段，整包响应体不生效。'
                            : '填写“字段路径: 新值”即可只修改真实响应中的字段；支持 data.product 和 data.items[0].name，可与参数匹配组合使用。',
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _statusCode,
                              enabled: !_hasPatch,
                              keyboardType: TextInputType.number,
                              decoration: _decoration('状态码'),
                              validator: (value) =>
                                  _hasPatch ? null : _intRange(value, 100, 599),
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
                        enabled: !_hasPatch,
                        maxLines: 3,
                        decoration: _decoration(
                          '响应头 JSON（可选）',
                          hint: '{"content-type": "text/html"}',
                        ),
                        style: const TextStyle(fontFamily: 'monospace'),
                        validator: (value) => _hasPatch
                            ? null
                            : _jsonValidator(value, objectOnly: true),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _body,
                        enabled: !_hasPatch,
                        maxLines: 8,
                        minLines: 4,
                        textAlignVertical: TextAlignVertical.top,
                        decoration: _decoration('响应体 JSON（留空视为 null）'),
                        style: const TextStyle(fontFamily: 'monospace'),
                        validator: (value) =>
                            _hasPatch ? null : _jsonValidator(value),
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
