# local_mock_dio

local_mock 的 Dio 适配器。同一份代码支持 Dio 4.x（≥ 4.0.6）和 5.x。Debug / Profile 构建中生效，Release 构建中不做任何事。

## 安装

在 `pubspec.yaml` 中添加依赖，然后运行 `flutter pub get`：

```yaml
dependencies:
  dio: ^5.0.0
  local_mock_dio: ^1.0.0
```

`local_mock_core` 和 `local_mock_transport` 会自动作为依赖引入。

## 接入

```dart
import 'package:local_mock_dio/local_mock_dio.dart';

final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
dio.interceptors.add(AuthInterceptor()); // 会改写 URL / 方法 / 参数的拦截器放在前面
LocalMockDio.attach(dio);                // 然后接入 local_mock

LocalMock.connect(
  serverUrl: 'https://example.trycloudflare.com',
  deviceId: installationId,
  deviceName: 'QA Android',
);
```

- `LocalMockDio.attach` 在 Release 中返回 `false`；对同一个 Dio 重复调用不会重复添加。
- 也可以自己 `dio.interceptors.add(LocalMockInterceptor())`。
- 规则在 `onRequest` 中匹配，看到的是前面拦截器处理后的请求，所以要排在改写请求的拦截器之后。
- 本包重新导出 `local_mock_core`，`LocalMock.connect` 等直接可用。Relay 和控制台的启动见[根目录 README](../../README.md#快速开始)。

## 命中规则时

**整包替换**

- 不发起网络请求，在等待 `delayMs` 后直接返回 `Response`；`data` 是规则 `body` 的深拷贝。
- 只支持 `ResponseType.json`。其他响应类型（`plain`、`bytes`、`stream`）的请求命中整包规则时，会得到一个 `DioError` / `DioException`，而不是透传。
- 响应会继续经过后续拦截器的 `onResponse` / `onError`，业务里的统一解包、错误处理照常工作。
- 状态码不满足 `validateStatus` 时，和真实请求一样抛出 bad response 类型的错误；`receiveDataWhenStatusError` 为 `false` 时 `data` 为 `null`。
- `delayMs` 期间可以用 `CancelToken` 取消。

**字段补丁**

- 照常发出真实请求，在 `onResponse` 中对 `data` 应用补丁，再等待 `delayMs`。真实状态码保留；HTTP 错误响应只要是 JSON 也会被补丁。
- 只作用于 `ResponseType.json`，其他响应类型原样返回。补丁不适用时（路径不存在、类型不符）也原样返回。
- 网络错误照常抛出，不会被补丁掩盖。
- 改写后会移除 `content-length`、`etag`、`content-md5` 响应头。

**参数条件** 支持 URL query、JSON 或 URL 编码表单请求体，以及 `FormData` 的普通字段（文件字段不参与）。

被 Mock 或补丁的响应在 `response.extra` 中带有 `local_mock: true` 和 `local_mock_rule_id`，方便在日志里区分。

规则字段和匹配细节见 [`local_mock_core` 的规则参考](../local_mock_core/README.md#规则参考)。

## 请求记录

经过拦截器的请求都会被记录并上报到控制台，包括命中规则的和走真实网络的：

- 走网络的请求在 `onResponse` / `onError` 中记录真实结果。被后面的拦截器直接 `resolve` 掉的请求不会被记录。
- 请求体：字符串和可 JSON 编码的对象原样记录；`FormData` 记录为 `<FormData: N fields, M files>`。这类请求在录制中只能查看，不能生成录制组接口。

## 测试

```bash
flutter test
```

默认解析到 Dio 5。验证 Dio 4 时，在 `pubspec_overrides.yaml` 中临时加入下面的覆盖，`flutter pub get && flutter test` 后再改回：

```yaml
dependency_overrides:
  dio: 4.0.6
```
