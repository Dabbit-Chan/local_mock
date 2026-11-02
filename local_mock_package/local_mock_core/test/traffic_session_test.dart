import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_core/local_mock_core.dart';

TrafficEntry captured({
  int revision = 1,
  int startedAt = 100,
  String method = 'GET',
  String uri = 'https://api.test/value?a=1&b=2',
  String? requestBody,
  String? responseBody = '{"value":1}',
  String? contentType = 'application/json',
  int? statusCode = 201,
  String? error,
}) => TrafficEntry(
  revision: revision,
  startedAt: startedAt,
  durationMs: 0,
  mocked: false,
  method: method,
  uri: uri,
  path: Uri.parse(uri).path,
  requestBody: requestBody,
  responseBody: responseBody,
  contentType: contentType,
  statusCode: statusCode,
  error: error,
);

TrafficSession session(List<TrafficEntry> entries) => TrafficSession(
  id: 'session-1',
  name: '下单流程',
  deviceId: 'phone',
  deviceName: '测试手机',
  startedAt: 100,
  endedAt: 1000,
  entries: entries,
);

void installRecording(TrafficSession saved, {bool matchParams = true}) =>
    LocalMock.debugReplaceRules([
      recordingMockFromSession(saved, matchParams: matchParams).toJson(),
    ]);

void main() {
  tearDown(LocalMock.debugClear);

  test('sessions round trip without losing bodies, errors or ordering', () {
    final original = session([
      captured(responseBody: '你好\n${'x' * 10000}', contentType: 'text/plain'),
      captured(revision: 2, error: 'SocketException', statusCode: null),
    ]);
    final decoded = TrafficSession.fromJson(
      jsonDecode(jsonEncode(original.toJson())),
    );
    expect(decoded.toJson(), original.toJson());
    expect(() => decoded.entries.clear(), throwsUnsupportedError);
  });

  test('invalid and unsupported files are rejected before use', () {
    final value = session([captured()]).toJson();
    for (final invalid in [
      null,
      [],
      {...value, 'version': 2},
      {...value, 'name': ''},
      {...value, 'endedAt': 0},
      {
        ...value,
        'entries': [<String, dynamic>{}],
      },
      {
        ...value,
        'entries': [
          {...captured().toJson(), 'statusCode': 999},
        ],
      },
      {
        ...value,
        'entries': [
          {...captured().toJson(), 'responseBody': []},
        ],
      },
      {
        ...value,
        'entries': [
          {...captured().toJson(), 'uri': 'file:///value'},
        ],
      },
      {
        ...value,
        'entries': [
          {...captured().toJson(), 'path': '/other'},
        ],
      },
    ]) {
      expect(() => TrafficSession.fromJson(invalid), throwsFormatException);
    }
  });

  test(
    'a recording is one Mock group using the latest response for identical parameters',
    () {
      installRecording(
        session([
          captured(revision: 1, startedAt: 200, responseBody: '{"value":2}'),
          captured(revision: 2, startedAt: 100),
        ]),
      );
      final uri = Uri.parse('https://api.test/value?b=2&a=1');
      expect(LocalMock.hasCandidates('GET', uri), isTrue);
      expect(LocalMock.match('GET', uri)!.body, {'value': 2});
      expect(LocalMock.match('GET', uri)!.body, {'value': 2});
      expect(
        LocalMock.match('GET', Uri.parse('https://api.test/value?a=2&b=2')),
        isNull,
      );
      expect(LocalMock.match('POST', uri), isNull);
    },
  );

  test('request bodies compare JSON values rather than object key order', () {
    installRecording(
      session([
        captured(
          method: 'POST',
          requestBody: '{"name":"你好","nested":{"enabled":true,"id":1}}',
        ),
      ]),
    );
    final uri = Uri.parse('https://api.test/value?a=1&b=2');
    expect(
      LocalMock.match(
        'POST',
        uri,
        requestBody: {
          'nested': {'id': 1, 'enabled': true},
          'name': '你好',
        },
      )!.statusCode,
      201,
    );
    expect(
      LocalMock.match('POST', uri, requestBody: '{"name":"other"}'),
      isNull,
    );
    expect(LocalMock.match('POST', uri), isNull);
  });

  test(
    'form bodies are normalized and plain response text is not JSON quoted',
    () {
      installRecording(
        session([
          captured(
            method: 'POST',
            requestBody: 'name=hello&id=1',
            responseBody: 'hello\nworld',
            contentType: 'text/plain',
          ),
        ]),
      );
      final rule = LocalMock.match(
        'POST',
        Uri.parse('https://api.test/value?a=1&b=2'),
        requestBody: {'id': '1', 'name': 'hello'},
      )!;
      expect(rule.responseText, 'hello\nworld');
      expect(rule.bodyCopy, 'hello\nworld');
      expect(rule.responseHeaders['content-type'], 'text/plain');
    },
  );

  test(
    'binary placeholders and failures remain inspectable but are not replayed',
    () {
      final saved = session([
        captured(error: 'failed', statusCode: null),
        captured(responseBody: '<binary 20 bytes>'),
        captured(responseBody: '<20 bytes>'),
        captured(requestBody: '<FormData: 1 fields, 1 files>'),
        captured(),
      ]);
      expect(saved.entries, hasLength(5));
      expect(saved.replayableEntries, hasLength(1));
      expect(
        () => installRecording(session(saved.entries.take(4).toList())),
        throwsFormatException,
      );
    },
  );

  test('manual rules survive replay and unmatched requests use them', () {
    LocalMock.debugReplaceRules([
      recordingMockFromSession(
        session([captured()]),
        matchParams: true,
      ).toJson(),
      {'id': 'manual', 'method': 'GET', 'path': '/value', 'body': 'manual'},
    ]);
    expect(
      LocalMock.match('GET', Uri.parse('https://api.test/value?a=1&b=2'))!.body,
      {'value': 1},
    );
    expect(
      LocalMock.match(
        'GET',
        Uri.parse('https://api.test/value?other=true'),
      )!.body,
      'manual',
    );
    expect(
      LocalMock.candidates(
        'GET',
        Uri.parse('https://api.test/value'),
      ).map((rule) => rule.id),
      ['request-1', 'manual'],
    );
  });

  test(
    'ignoring recorded parameters is optional and still respects method host and path',
    () {
      installRecording(
        session([captured(method: 'POST', requestBody: '{"id":1}')]),
        matchParams: false,
      );
      expect(
        LocalMock.match(
          'POST',
          Uri.parse('https://api.test/value?unrelated=2'),
          requestBody: {'id': 999},
        )!.body,
        {'value': 1},
      );
      expect(
        LocalMock.match('POST', Uri.parse('https://other.test/value')),
        isNull,
      );
      expect(
        LocalMock.match('GET', Uri.parse('https://api.test/value')),
        isNull,
      );
      expect(
        LocalMock.match('POST', Uri.parse('https://api.test/other')),
        isNull,
      );
    },
  );

  test(
    'recording groups and child rules can be edited disabled ordered and round tripped',
    () {
      final group = recordingMockFromSession(
        session([
          captured(
            uri: 'https://api.test/value?id=1',
            responseBody: '{"value":1}',
          ),
          captured(
            revision: 2,
            uri: 'https://api.test/value?id=2',
            responseBody: '{"value":2}',
          ),
        ]),
        matchParams: true,
      ).toJson();
      final children = (group['rules'] as List).cast<Map<String, dynamic>>();
      children[1] = {
        ...children[1],
        'responseText': 'changed',
        'body': 'changed',
        'statusCode': 202,
      };
      group['rules'] = children;
      final restored = MockRule.fromJson(
        jsonDecode(jsonEncode(group)) as Map<String, dynamic>,
      );
      expect(restored.isRecording, isTrue);
      expect(restored.rules, hasLength(2));
      LocalMock.debugReplaceRules([restored.toJson()]);
      final uri = Uri.parse('https://api.test/value?id=2');
      expect(LocalMock.match('GET', uri)!.responseText, 'changed');
      expect(LocalMock.match('GET', uri)!.statusCode, 202);
      LocalMock.debugReplaceRules([
        {...group, 'enabled': false},
      ]);
      expect(LocalMock.hasCandidates('GET', uri), isFalse);
      expect(LocalMock.match('GET', uri), isNull);
      LocalMock.debugReplaceRules([
        {...group, 'matchParams': false, 'rules': children.reversed.toList()},
      ]);
      expect(
        LocalMock.match(
          'GET',
          Uri.parse('https://api.test/value?id=other'),
        )!.responseText,
        'changed',
      );
      LocalMock.debugReplaceRules([
        {
          ...group,
          'matchParams': false,
          'rules': [
            {...children[1], 'enabled': false},
            children[0],
          ],
        },
      ]);
      expect(LocalMock.match('GET', uri)!.body, {'value': 1});
    },
  );

  test(
    'invalid groups do not replace existing rules and nested groups are rejected',
    () {
      final group = recordingMockFromSession(session([captured()])).toJson();
      LocalMock.debugReplaceRules([group]);
      final child = (group['rules'] as List).first as Map<String, dynamic>;
      for (final invalid in [
        {...group, 'matchParams': 'true'},
        {...group, 'rules': []},
        {
          ...group,
          'rules': [group],
        },
        {
          ...group,
          'rules': [child, child],
        },
        {
          ...group,
          'rules': [
            {
              ...child,
              'recordedRequest': {
                'query': {'id': 1},
              },
            },
          ],
        },
      ]) {
        expect(
          () => LocalMock.debugReplaceRules([invalid]),
          throwsFormatException,
        );
        expect(
          LocalMock.match('GET', Uri.parse('https://api.test/value'))!.body,
          {'value': 1},
        );
      }
    },
  );

  test(
    'missing response payloads are not invented but bodyless HTTP responses replay',
    () {
      final saved = session([
        captured(responseBody: null),
        captured(revision: 2, method: 'HEAD', responseBody: null),
        captured(revision: 3, statusCode: 204, responseBody: null),
        captured(revision: 4, statusCode: 304, responseBody: null),
      ]);
      expect(saved.replayableEntries.map((entry) => entry.revision), [2, 3, 4]);
    },
  );
}
