# local_mock_http

The `dart:io` adapter for local_mock, covering `package:http`, Dio's default adapter, and any code or third-party library that uses `HttpClient` directly. Only active in Debug / Profile builds; does nothing in Release or on the web.

<a href="README.md">中文</a> · <a href="README.en.md">English</a>

## Usage

```dart
import 'package:local_mock_http/local_mock_http.dart';

void main() {
  LocalMockHttp.install(); // call it early so later HttpClients get wrapped
  LocalMock.connect(
    serverUrl: 'http://192.168.1.10:9090',
    deviceId: 'my-device-id',
    deviceName: 'my-device-name',
  );
  runApp(const MyApp());
}
```

## How it works

- Wraps every `HttpClient` the app creates via `HttpOverrides`, matching rules before a request goes out.
- A pre-existing `HttpOverrides` is kept as a fallback, so requests that match no rule still go through it and proxy or certificate settings are unaffected.
- The request body is buffered to match parameter conditions only when candidate rules exist for the same endpoint; every other request streams through as usual.
