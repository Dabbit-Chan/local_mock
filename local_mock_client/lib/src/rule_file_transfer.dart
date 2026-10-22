import 'rule_file_transfer_stub.dart'
    if (dart.library.js_interop) 'rule_file_transfer_web.dart'
    as platform;

class RuleFileTransfer {
  const RuleFileTransfer();

  Future<String?> pickRules() => platform.pickRules();

  Future<void> saveRules(String filename, String contents) =>
      platform.saveRules(filename, contents);
}
