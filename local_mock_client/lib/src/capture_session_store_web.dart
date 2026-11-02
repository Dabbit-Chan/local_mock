import 'package:web/web.dart' as web;

const _storageKey = 'local_mock.capture_sessions.v1';

String? readSessions() => web.window.localStorage.getItem(_storageKey);

void writeSessions(String contents) {
  try {
    web.window.localStorage.setItem(_storageKey, contents);
  } catch (_) {
    throw StateError('浏览器保存失败（空间不足或存储被禁用），录制仍保留在页面中，请导出未保存录制备份');
  }
}
