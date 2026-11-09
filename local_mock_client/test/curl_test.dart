import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_client/src/curl.dart';

Map<String, dynamic> entry({
  String method = 'GET',
  String uri = 'https://api.test/orders?page=2',
  String? body,
  Map<String, dynamic>? headers,
}) => {
  'method': method,
  'uri': uri,
  if (body != null) 'requestBody': body,
  if (headers != null) 'requestHeaders': headers,
};

void main() {
  test('GET keeps the URL and repeats each header value', () {
    final curl = curlForEntry(
      entry(
        headers: {
          'Authorization': ['Bearer token'],
          'Accept': ['application/json', 'text/plain'],
        },
      ),
    );

    expect(curl, contains("curl -X GET 'https://api.test/orders?page=2'"));
    expect(curl, contains("-H 'Authorization: Bearer token'"));
    expect(curl, contains("-H 'Accept: application/json'"));
    expect(curl, contains("-H 'Accept: text/plain'"));
    expect(curl, isNot(contains('--data-raw')));
  });

  test('POST body is sent verbatim and single quotes are escaped', () {
    const body = '''{"name":"O'Brien"}''';
    final curl = curlForEntry(
      entry(
        method: 'POST',
        body: body,
        headers: {
          'Content-Type': ['application/json'],
          'Content-Length': ['17'],
        },
      ),
    );

    expect(curl, contains('-X POST'));
    expect(curl, contains('--data-raw ${shellQuote(body)}'));
    // curl sets its own Content-Length; a stale copy would break the replay.
    expect(curl, isNot(contains('Content-Length')));
  });

  test('shellQuote keeps a body safe for POSIX shells', () {
    expect(shellQuote("a'b"), r"'a'\''b'");
  });

  test('unusable placeholder bodies become a comment', () {
    final curl = curlForEntry(
      entry(method: 'POST', body: '<FormData: 2 fields, 1 files>'),
    );

    expect(curl, startsWith('# 请求体未能捕获'));
    expect(curl, contains('<FormData: 2 fields, 1 files>'));
    expect(curl, isNot(contains('--data-raw')));
  });

  test('legacy string headers and missing fields still produce a command', () {
    expect(
      curlForEntry({'method': 'GET', 'uri': 'https://a.test/x'}),
      "curl -X GET 'https://a.test/x'",
    );
    expect(
      curlForEntry({
        'method': 'GET',
        'uri': 'https://a.test/x',
        'requestHeaders': {'X-Trace': 'abc'},
      }),
      contains("-H 'X-Trace: abc'"),
    );
  });
}
