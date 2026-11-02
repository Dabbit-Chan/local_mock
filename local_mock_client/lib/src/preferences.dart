import 'preferences_stub.dart'
    if (dart.library.js_interop) 'preferences_web.dart'
    as platform;

/// Small key/value persistence for UI preferences (browser localStorage).
class Preferences {
  const Preferences();

  String? read(String key) => platform.read(key);

  void write(String key, String value) => platform.write(key, value);
}
