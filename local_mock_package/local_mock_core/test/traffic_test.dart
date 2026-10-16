import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_core/local_mock_core.dart';

void main() {
  late TrafficRecorder recorder;

  setUp(() {
    recorder = TrafficRecorder();
    LocalMock.debugClearTraffic();
  });

  test('finish records entry fields with monotonic revisions', () {
    recorder.begin('GET', Uri.parse('https://Api.Test:8443/x/y?b=1'))
      ..requestBody = '{"a":1}'
      ..finish(
        statusCode: 200,
        contentType: 'application/json',
        body: '{"ok":true}',
      );
    final failed = recorder.begin('POST', Uri.parse('https://api.test/z'));
    failed.fail('boom');

    final entries = recorder.since(0);
    expect(entries, hasLength(2));
    expect(entries.first.revision, 1);
    expect(entries.first.method, 'GET');
    // Uri normalizes the host to lowercase, matching rule `host` semantics.
    expect(entries.first.uri, 'https://api.test:8443/x/y?b=1');
    expect(entries.first.host, 'api.test');
    expect(entries.first.path, '/x/y');
    expect(entries.first.requestBody, '{"a":1}');
    expect(entries.first.statusCode, 200);
    expect(entries.first.contentType, 'application/json');
    expect(entries.first.responseBody, '{"ok":true}');
    expect(entries.first.mocked, isFalse);
    expect(entries.first.error, isNull);
    expect(entries.first.durationMs, greaterThanOrEqualTo(0));

    expect(entries.last.revision, 2);
    expect(entries.last.statusCode, isNull);
    expect(entries.last.responseBody, isNull);
    expect(entries.last.error, 'boom');
  });

  test('second finish or fail is ignored', () {
    final recording = recorder.begin('GET', Uri.parse('https://a.test/x'))
      ..finish(statusCode: 200, body: 'first')
      ..fail('late')
      ..finish(statusCode: 500, body: 'late');

    expect(recorder.since(0), hasLength(1));
    expect(recorder.since(0).single.responseBody, 'first');
    expect(recorder.revision, 1);
    expect(recording.method, 'GET');
  });

  test('long bodies are clipped and flagged as truncated', () {
    final long = 'x' * (TrafficRecorder.maxBodyChars + 10);
    recorder.begin('POST', Uri.parse('https://a.test/x'))
      ..collectRequestText(long)
      ..finish(statusCode: 200, body: long);

    final entry = recorder.since(0).single;
    expect(entry.requestBody, hasLength(TrafficRecorder.maxBodyChars));
    expect(entry.responseBody, hasLength(TrafficRecorder.maxBodyChars));
    expect(entry.truncated, isTrue);
  });

  test('request body from collected bytes is decoded', () {
    recorder.begin('POST', Uri.parse('https://a.test/x'))
      ..collectRequestBytes(utf8.encode('{"k":"v"}'))
      ..finish(statusCode: 201);

    expect(recorder.since(0).single.requestBody, '{"k":"v"}');
  });

  test('caps entries and only returns entries after the cursor', () {
    for (var i = 0; i < TrafficRecorder.maxEntries + 10; i++) {
      recorder
          .begin('GET', Uri.parse('https://a.test/$i'))
          .finish(statusCode: 200);
    }

    expect(recorder.since(0), hasLength(TrafficRecorder.maxEntries));
    expect(recorder.since(recorder.revision), isEmpty);
    final middle = recorder.since(recorder.revision - 3);
    expect(middle, hasLength(3));
    expect(middle.last.revision, recorder.revision);
  });

  test('clear drops entries but keeps the revision counter monotonic', () {
    recorder.begin('GET', Uri.parse('https://a.test/a')).finish();
    recorder.clear();
    expect(recorder.since(0), isEmpty);
    expect(recorder.revision, 1);

    recorder.begin('GET', Uri.parse('https://a.test/b')).finish();
    expect(recorder.since(0).single.revision, 2);
    expect(recorder.since(1).single.path, '/b');
  });

  test('entry JSON round trip preserves fields', () {
    recorder.begin('GET', Uri.parse('https://a.test/x?a=1'))
      ..requestBody = 'q'
      ..finish(mocked: true, statusCode: 404, body: 'not found');

    final json = recorder.since(0).single.toJson();
    final restored = TrafficEntry.fromJson(json);
    expect(restored.toJson(), json);
    expect(restored.mocked, isTrue);
    expect(restored.statusCode, 404);
  });

  test('LocalMock records traffic in debug mode through debug hooks', () {
    final traffic = LocalMock.beginTraffic(
      'GET',
      Uri.parse('https://a.test/x'),
    );
    expect(traffic, isNotNull);
    traffic!.finish(statusCode: 200, body: 'ok');

    expect(LocalMock.debugTrafficEntries(), hasLength(1));
    LocalMock.debugClearTraffic();
    expect(LocalMock.debugTrafficEntries(), isEmpty);
  });
}
