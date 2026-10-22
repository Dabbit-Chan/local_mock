import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<String?> pickRules() async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = '.json,application/json'
    ..style.display = 'none';
  final selected = Completer<web.File?>();
  final onChange = ((web.Event event) {
    if (!selected.isCompleted) selected.complete(input.files?.item(0));
  }).toJS;
  final onCancel = ((web.Event event) {
    if (!selected.isCompleted) selected.complete(null);
  }).toJS;
  input.addEventListener('change', onChange);
  input.addEventListener('cancel', onCancel);
  web.document.body!.appendChild(input);
  try {
    input.click();
    final file = await selected.future;
    if (file == null) return null;
    return (await file.text().toDart).toDart;
  } finally {
    input.removeEventListener('change', onChange);
    input.removeEventListener('cancel', onCancel);
    input.remove();
  }
}

Future<void> saveRules(String filename, String contents) async {
  final blob = web.Blob(
    [contents.toJS].toJS,
    web.BlobPropertyBag(type: 'application/json;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename
    ..style.display = 'none';
  web.document.body!.appendChild(anchor);
  try {
    anchor.click();
  } finally {
    anchor.remove();
    Timer(const Duration(seconds: 1), () => web.URL.revokeObjectURL(url));
  }
}
