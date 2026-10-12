import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
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
    ),
    home: const MockPage(),
  );
}

class MockPage extends StatefulWidget {
  const MockPage({super.key});

  @override
  State<MockPage> createState() => _MockPageState();
}

class _MockPageState extends State<MockPage> {
  static const _example = '''[
  {
    "id": "user-profile",
    "enabled": true,
    "method": "GET",
    "path": "/api/user/profile",
    "statusCode": 200,
    "delayMs": 300,
    "body": {
      "name": "测试用户",
      "level": 10
    }
  }
]''';

  final _connection = MockConnection();
  final _draftStore = DraftStore();
  final _address = TextEditingController();
  final _editor = TextEditingController(text: _example);
  String? _message;
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
      if (mounted && text != null) _editor.text = text;
    } catch (error) {
      if (mounted) setState(() => _message = '读取草稿失败：$error');
    } finally {
      if (mounted) setState(() => _loadingDraft = false);
    }
  }

  Future<void> _action(Future<void> Function() action) async {
    setState(() => _message = null);
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    }
  }

  String _validatedJson() {
    final rules = MockRule.parseList(jsonDecode(_editor.text));
    return const JsonEncoder.withIndent(
      '  ',
    ).convert(rules.map((rule) => rule.toJson()).toList());
  }

  Future<void> _saveDraft() async {
    setState(() => _savingDraft = true);
    try {
      final path = await _draftStore.save(_validatedJson());
      if (mounted) setState(() => _message = '草稿已保存到 $path（未下发）');
    } finally {
      if (mounted) setState(() => _savingDraft = false);
    }
  }

  @override
  void dispose() {
    _connection.dispose();
    _address.dispose();
    _editor.dispose();
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
                          _action(() => _connection.apply(_editor.text)),
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
                  child: const Text('保存本地草稿'),
                ),
                TextButton(
                  onPressed: _loadingDraft
                      ? null
                      : () => unawaited(
                          _action(() async {
                            _editor.text = _validatedJson();
                          }),
                        ),
                  child: const Text('校验并格式化'),
                ),
              ],
            ),
            if (_message != null) ...[
              const SizedBox(height: 8),
              SelectableText(_message!),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _editor,
                enabled: !_loadingDraft,
                expands: true,
                maxLines: null,
                minLines: null,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                autocorrect: false,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                decoration: const InputDecoration(
                  labelText: 'Mock 规则 JSON 数组',
                  alignLabelWithHint: true,
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '第一条启用且匹配的规则生效；查询参数不参与匹配。应用后需在手机重新请求。\n'
              '断开连接不会清空手机规则；多 isolate 时，已确认的规则会同步到所选目标。',
            ),
          ],
        ),
      ),
    ),
  );
}
