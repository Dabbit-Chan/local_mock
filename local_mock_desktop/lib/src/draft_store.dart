import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Stores only JSON drafts, never authenticated VM Service addresses.
class DraftStore {
  Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File('${directory.path}${Platform.pathSeparator}rules.json');
  }

  Future<String?> load() async {
    final file = await _file();
    return await file.exists() ? file.readAsString() : null;
  }

  Future<String> save(String text) async {
    final file = await _file();
    await file.writeAsString(text, flush: true);
    return file.path;
  }
}
