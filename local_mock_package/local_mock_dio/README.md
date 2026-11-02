# local_mock_dio

local_mock 的 Dio 适配器，同一份代码同时支持 Dio 4.x（>=4.0.6）和 Dio 5.x。在 Debug 和 Profile 模式默认生效，Release 始终禁用。

## 安装

```yaml
dependencies:
  dio: ^5.0.0
  local_mock_dio:
    git:
      url: https://github.com/Dabbit-Chan/local_mock.git
      path: local_mock_package/local_mock_dio

dependency_overrides:
  local_mock_transport:
    git:
      url: https://github.com/Dabbit-Chan/local_mock.git
      path: local_mock_package/local_mock_transport
  local_mock_core:
    git:
      url: https://github.com/Dabbit-Chan/local_mock.git
      path: local_mock_package/local_mock_core
```

`local_mock_core` 和 `local_mock_transport` 尚未发布到 pub.dev，需要通过 `dependency_overrides` 同时指定来源（git 或本地 `path`）。服务端与控制台启动方式见[根 README](../../README.md)。

## 使用

```dart
import 'package:local_mock_dio/local_mock_dio.dart';

final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
dio.interceptors.add(AuthInterceptor()); // 会修改 URL / method 的拦截器放前面
LocalMockDio.attach(dio);                // 再挂 local_mock
```

- `LocalMockDio.attach` 在禁用模式下返回 `false`；重复调用不会重复添加。
- 调用 `LocalMock.connect(serverUrl: ..., deviceId: ...)` 开始主动连接 relay。当前可行性测试不需要访问令牌。
- Debug 和 Profile 默认启用，无需额外启用参数。
- 也可以手动添加 `LocalMockInterceptor()`，禁用模式下只透传请求。
- 拦截器在 `onRequest` 中匹配，所以需要排在会改写请求 URL / method 的拦截器之后。

## 响应行为

- 命中普通规则时不发起网络请求，直接返回 `Response`，`data` 为规则 `body` 的深拷贝。
- `params` 支持 URL query、JSON / URL 编码表单请求体及 `FormData` 普通字段；只有指定参数全部匹配才生效，其余请求仍走原传输层。
- 非空 `patchBody` 会先发起真实请求，再只修改 JSON 响应的指定字段，保留真实状态码和其他字段；网络错误不会变成 Mock 成功，HTTP 错误的 JSON 响应也可补丁。路径、失败兜底和组合示例见[核心规则说明](../local_mock_core/README.md#规则字段)。
- `response.extra` 中带有 `local_mock: true` 和 `local_mock_rule_id`，便于日志区分。
- 响应会继续经过后续拦截器的 `onResponse` / `onError`（例如业务反序列化、统一错误处理）。
- `validateStatus` 不通过时，与真实请求一样抛出 bad response 类型的 `DioError` / `DioException`；`receiveDataWhenStatusError` 为 `false` 时 `data` 为 `null`。
- `delayMs` 期间支持 `CancelToken` 取消。
- 整包 Mock 只支持 `ResponseType.json`，其他类型命中时会返回错误；字段补丁仅作用于 JSON，其他响应类型不修改。

## 抓包

经过该拦截器的所有请求（Mock 命中与未命中走网络的）都会被记录到 isolate 内的抓包缓冲，供桌面端“抓包”页实时展示、一键生成规则：

- 未命中规则的请求在 `onResponse` / `onError` 里记录真实结果；被后续拦截器提前 resolve 的请求不记录。
- 请求体：`String` / JSON 可编码对象直接记录；`FormData` 只记录字段与文件数量。
- 在 Debug 和 Profile 模式记录；连接后实时上报到服务端，再由 Web / 桌面控制台展示。
- 新版 Web 控制台将一整段录制作为一个可编辑 Mock 组，可选是否只匹配录制传参；与普通规则共用优先级、整组开关和导入导出，命中后固定返回对应子规则响应，不按次数切换响应。一级弹窗管理组，二级弹窗编辑参数及响应。整包 Mock 仍要求 `ResponseType.json`，FormData / 二进制占位符及失败请求只保留查看。需同步更新 core 和本适配器，详见根 README 的“录制与回放”。

## 测试

```bash
flutter test
```

测试同时适用于 Dio 4 和 Dio 5。默认解析到 Dio 5，验证 Dio 4 时在 `pubspec_overrides.yaml` 中临时加入：

```yaml
dependency_overrides:
  dio: 4.0.6
```

然后重新执行 `flutter pub get && flutter test`，验证后记得改回。
