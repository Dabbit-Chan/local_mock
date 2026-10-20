import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_core/local_mock_core.dart';

void main() {
  test(
    'build mode gates initialization, matching, recording and connections',
    () {
      const expected = bool.fromEnvironment(
        'EXPECT_MOCK_ENABLED',
        defaultValue: true,
      );
      LocalMock.debugReplaceRules([
        {'id': 'mode', 'method': 'GET', 'path': '/mode', 'body': 'enabled'},
      ]);
      final uri = Uri.parse('https://api.test/mode');
      expect(LocalMock.enabled, expected);
      expect(LocalMock.ensureInitialized(), expected);
      expect(LocalMock.match('GET', uri)?.body, expected ? 'enabled' : null);
      expect(LocalMock.beginTraffic('GET', uri) != null, expected);
      if (!expected) {
        // Disabled builds must not even validate/connect the supplied URL.
        expect(
          LocalMock.connect(serverUrl: 'invalid', deviceId: ''),
          isFalse,
        );
        expect(LocalMock.connected, isFalse);
      }
      LocalMock.debugClear();
    },
  );
}
