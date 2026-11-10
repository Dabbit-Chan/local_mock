# local_mock_http

local_mock 的 `dart:io` 适配器，覆盖 `package:http`、Dio 默认适配器，以及直接使用 `HttpClient` 的代码和三方库。只在 Debug / Profile 构建中生效，Release 构建和 Web 平台上不做任何事。

<a href="README.md">中文</a> · <a href="README.en.md">English</a>

## 使用示例

```dart
import 'package:local_mock_http/local_mock_http.dart';

void main() {
  LocalMockHttp.install(); // 尽早调用，之后创建的 HttpClient 才会被包装
  LocalMock.connect(
    serverUrl: 'http://192.168.1.10:9090',
    deviceId: 'my-device-id',
    deviceName: 'my-device-name',
  );
  runApp(const MyApp());
}
```

## 技术原理

- 通过 `HttpOverrides` 包装 App 创建的每个 `HttpClient`，在请求发出前匹配规则。
- 原来已有的 `HttpOverrides` 会作为兜底，没有命中规则的请求仍交给它处理，代理和证书配置不受影响。
- 只有存在同一接口的候选规则时，才会先缓冲请求体来匹配参数条件；其他请求照常以流的方式透传。
