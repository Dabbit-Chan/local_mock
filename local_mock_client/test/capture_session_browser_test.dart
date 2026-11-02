@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_client/src/capture_session_store.dart';
import 'package:local_mock_core/local_mock_core.dart';
import 'package:web/web.dart' as web;

void main() {
  test(
    'invalid browser data is reported without overwriting saved content',
    () async {
      const key = 'local_mock.capture_sessions.v1';
      final previous = web.window.localStorage.getItem(key);
      addTearDown(() {
        if (previous == null) {
          web.window.localStorage.removeItem(key);
        } else {
          web.window.localStorage.setItem(key, previous);
        }
      });
      for (final text in ['not json', '{}', '[null]']) {
        web.window.localStorage.setItem(key, text);
        await expectLater(
          const CaptureSessionStore().load(),
          throwsFormatException,
        );
        expect(web.window.localStorage.getItem(key), text);
      }
    },
  );

  test(
    'browser storage reloads complete sessions and persists deletion',
    () async {
      const store = CaptureSessionStore();
      final previous = await store.load();
      addTearDown(() => store.save(previous));
      final saved = TrafficSession(
        id: 'browser-storage-test',
        name: '浏览器持久化',
        deviceId: 'phone',
        deviceName: '设备',
        startedAt: 1,
        endedAt: 2,
        entries: [
          TrafficEntry(
            revision: 1,
            startedAt: 1,
            durationMs: 0,
            mocked: false,
            method: 'GET',
            uri: 'https://api.test/value',
            path: '/value',
            statusCode: 200,
            responseBody: '{"text":"你好"}',
          ),
        ],
      );
      await store.save([saved]);
      final reloaded = await const CaptureSessionStore().load();
      expect(reloaded.single.toJson(), saved.toJson());
      await store.save([]);
      expect(await const CaptureSessionStore().load(), isEmpty);
    },
  );
}
