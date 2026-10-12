import 'dart:io';

import 'package:local_mock_core/local_mock_core.dart';

import 'http_overrides.dart';

/// Debug-only `dart:io` interception via [HttpOverrides].
abstract final class LocalMockHttp {
  /// Wraps the current [HttpOverrides] (kept as the fallback) and sets
  /// [HttpOverrides.global]. Only `HttpClient`s created afterwards are
  /// intercepted, so call it early in `main()`, after installing your own
  /// overrides. Returns false outside Debug mode; repeated calls are no-ops.
  static bool install() {
    if (!LocalMock.ensureInitialized()) return false;
    final current = HttpOverrides.current;
    if (current is! LocalMockHttpOverrides) {
      HttpOverrides.global = LocalMockHttpOverrides(current);
    }
    return true;
  }
}
