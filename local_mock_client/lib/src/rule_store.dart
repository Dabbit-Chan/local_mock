import 'dart:convert';

import 'package:local_mock_core/local_mock_core.dart';

import 'rule_store_stub.dart'
    if (dart.library.js_interop) 'rule_store_web.dart'
    as platform;

/// Browser-owned rules and the app session explicitly approved by the user.
class SavedRules {
  SavedRules({required this.rules, this.syncedSession});

  List<Map<String, dynamic>> rules;
  String? syncedSession;
  bool pending = false;
  int version = 0;
}

class RuleStore {
  const RuleStore();

  static String keyFor(String deviceId) =>
      'local_mock.rules.v1.${Uri.encodeComponent(deviceId)}';

  SavedRules? load(String deviceId) {
    final text = platform.read(keyFor(deviceId));
    if (text == null) return null;
    final data = jsonDecode(text) as Map<String, dynamic>;
    return SavedRules(
      rules: MockRule.parseList(data['rules']).map((r) => r.toJson()).toList(),
      syncedSession: data['syncedSession'] as String?,
    )..pending = data['pending'] == true;
  }

  void save(String deviceId, SavedRules value) => platform.write(
    keyFor(deviceId),
    jsonEncode({
      'rules': value.rules,
      'syncedSession': value.syncedSession,
      'pending': value.pending,
    }),
  );
}
