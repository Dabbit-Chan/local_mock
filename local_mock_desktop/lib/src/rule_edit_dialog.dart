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
