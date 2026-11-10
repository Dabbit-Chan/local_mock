# local_mock_dio

local_mock 的 Dio 适配器，同一份代码同时支持 Dio 4.x 和 5.x。只在 Debug / Profile 构建中生效，Release 构建中不做任何事。

<a href="README.md">中文</a> · <a href="README.en.md">English</a>

## 使用示例

```dart
import 'package:local_mock_dio/local_mock_dio.dart';

final dio = Dio();
LocalMockDio.attach(dio); // 放在会改写请求的拦截器之后

LocalMock.connect(
  serverUrl: 'http://192.168.1.10:9090',
  deviceId: 'my-device-id',
  deviceName: 'my-device-name',
);
```

## 技术原理

- 以 Dio 拦截器的形式接入，在 `onRequest` 中匹配规则，所以看到的是前面拦截器处理过之后的请求。
- 被 Mock 的响应会在 `response.extra` 中带上标记，方便在日志里区分。
