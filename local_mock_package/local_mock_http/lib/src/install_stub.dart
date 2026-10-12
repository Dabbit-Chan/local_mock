/// Platforms without `dart:io` (Web): nothing is intercepted.
abstract final class LocalMockHttp {
  /// Always false: `HttpOverrides` is not available on this platform.
  static bool install() => false;
}
