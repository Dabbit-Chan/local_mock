import 'package:web/web.dart' as web;

String? read(String key) => web.window.localStorage.getItem(key);

void write(String key, String value) {
  try {
    web.window.localStorage.setItem(key, value);
  } catch (_) {
    throw StateError('浏览器保存失败（空间不足或存储被禁用），请导出规则备份');
  }
}
