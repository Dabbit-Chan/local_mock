# local_mock_dio

The Dio adapter for local_mock — a single codebase supporting both Dio 4.x and 5.x. Only active in Debug / Profile builds; does nothing in Release.

<a href="README.md">中文</a> · <a href="README.en.md">English</a>

## Usage

```dart
import 'package:local_mock_dio/local_mock_dio.dart';

final dio = Dio();
LocalMockDio.attach(dio); // after interceptors that rewrite the request

LocalMock.connect(
  serverUrl: 'http://192.168.1.10:9090',
  deviceId: 'my-device-id',
  deviceName: 'my-device-name',
);
```

## How it works

- It hooks in as a Dio interceptor and matches rules in `onRequest`, so it sees the request after the preceding interceptors have processed it.
- Mocked responses are flagged in `response.extra`, which makes them easy to spot in logs.
