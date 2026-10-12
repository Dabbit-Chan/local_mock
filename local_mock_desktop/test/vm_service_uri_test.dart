import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_desktop/src/vm_service_uri.dart';

void main() {
  test('HTTP VM Service URL keeps its authentication path', () {
    expect(
      normalizeVmServiceUri(' http://127.0.0.1:12345/token=/ ').toString(),
      'ws://127.0.0.1:12345/token=/ws',
    );
  });

  test('existing WebSocket URL is not duplicated', () {
    expect(
      normalizeVmServiceUri('ws://localhost:12345/token=/ws').toString(),
      'ws://localhost:12345/token=/ws',
    );
    expect(normalizeVmServiceUri('ws://localhost:12345/ws/').path, '/ws');
  });

  test('secure URLs and IPv6 are supported', () {
    expect(
      normalizeVmServiceUri('https://localhost:12345/token=/').scheme,
      'wss',
    );
    expect(
      normalizeVmServiceUri('http://[::1]:12345/').toString(),
      'ws://[::1]:12345/ws',
    );
  });

  test('DevTools URLs and unsupported schemes are rejected', () {
    for (final value in [
      '',
      'localhost:12345',
      'file:///tmp/ws',
      'http://localhost:9100/?uri=http%3A%2F%2Flocalhost%3A12345',
      'ws://localhost:12345/ws#fragment',
    ]) {
      expect(() => normalizeVmServiceUri(value), throwsFormatException);
    }
  });
}
