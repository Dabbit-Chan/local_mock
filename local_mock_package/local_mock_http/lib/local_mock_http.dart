/// `dart:io` HttpClient interception for local_mock, via HttpOverrides.
/// Covers package:http (IOClient), Dio's default adapter, and direct
/// `HttpClient` usage. No-op on Web.
library;

export 'package:local_mock_core/local_mock_core.dart';

export 'src/install_stub.dart' if (dart.library.io) 'src/install_io.dart';
