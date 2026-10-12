import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_core/local_mock_core.dart';
import 'package:local_mock_core/src/mock_registry.dart';

Map<String, dynamic> rule({
  String id = 'profile',
  bool enabled = true,
  String? host,
  dynamic body = const {'name': 'mock'},
}) => {
  'id': id,
  'enabled': enabled,
  'method': 'get',
  'path': '/api/profile',
  if (host != null) 'host': host,
  'body': body,
};

void main() {
  test('method + exact path; query parameters do not affect matching', () {
    final parsed = MockRule.fromJson(rule());
    expect(
      parsed.matches('GET', Uri.parse('https://api.test/api/profile?a=1')),
      isTrue,
    );
    expect(
      parsed.matches('POST', Uri.parse('https://api.test/api/profile')),
      isFalse,
    );
    expect(
      parsed.matches('GET', Uri.parse('https://api.test/api/profiles')),
      isFalse,
    );
  });

  test('optional hostname is case-insensitive and does not include port', () {
    final parsed = MockRule.fromJson(rule(host: 'API.TEST'));
    expect(
      parsed.matches('GET', Uri.parse('https://api.test:8080/api/profile')),
      isTrue,
    );
    expect(
      parsed.matches('GET', Uri.parse('https://other.test/api/profile')),
      isFalse,
    );
  });

  test('disabled rules never match', () {
    expect(
      MockRule.fromJson(
        rule(enabled: false),
      ).matches('GET', Uri.parse('https://api.test/api/profile')),
      isFalse,
    );
  });

  test('wire round trip preserves body and defaults', () {
    final original = MockRule.fromJson(rule(body: [1, null, 'text']));
    final restored = MockRule.fromJson(original.toJson());
    expect(restored.toJson(), original.toJson());
    expect(restored.statusCode, 200);
    expect(restored.delayMs, 0);
  });

  test('response headers default to JSON and can be overridden', () {
    final parsed = MockRule.fromJson({
      ...rule(),
      'headers': {'Content-Type': 'text/plain', 'X-Debug': '1'},
    });
    expect(parsed.responseHeaders, {
      'content-type': 'text/plain',
      'x-debug': '1',
    });
    expect(
      MockRule.fromJson(rule()).responseHeaders['content-type'],
      'application/json; charset=utf-8',
    );
  });

  test('invalid fields are rejected', () {
    for (final invalid in <Map<String, dynamic>>[
      {...rule(), 'id': ''},
      {...rule(), 'path': 'api/profile'},
      {...rule(), 'path': '/api/profile?x=1'},
      {...rule(), 'method': 'GET /'},
      {...rule(), 'enabled': 'true'},
      {...rule(), 'statusCode': 999},
      {...rule(), 'delayMs': -1},
      {...rule(), 'delayMs': 60001},
      {...rule(), 'host': 1},
      {
        ...rule(),
        'headers': {'x-test': 123},
      },
    ]) {
      expect(() => MockRule.fromJson(invalid), throwsFormatException);
    }
    expect(() => MockRule.parseList({}), throwsFormatException);
    expect(() => MockRule.parseList([1]), throwsFormatException);
    expect(() => MockRule.parseList([rule(), rule()]), throwsFormatException);
  });

  test('invalid replacement is atomic; first enabled match wins', () {
    final registry = MockRegistry();
    registry.replace([
      rule(id: 'disabled', enabled: false),
      rule(id: 'first'),
      rule(id: 'second'),
    ]);
    expect(
      () => registry.replace([
        rule(),
        {'id': 'invalid'},
      ]),
      throwsFormatException,
    );
    expect(registry.state['revision'], 1);
    expect(registry.state['protocolVersion'], LocalMockProtocol.version);
    expect(
      registry.match('GET', Uri.parse('https://api.test/api/profile'))?.id,
      'first',
    );
    registry.clear();
    expect(registry.state['rules'], isEmpty);
    expect(registry.state['revision'], 2);
  });
}
