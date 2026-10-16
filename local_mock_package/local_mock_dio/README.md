# local_mock_dio

local_mock 的 Dio 适配器，同一份代码同时支持 Dio 4.x（>=4.0.6）和 Dio 5.x。仅在 Debug 模式生效。

## 安装

```yaml
dependencies:
  dio: ^5.0.0
  local_mock_dio:
    git:
      url: https://github.com/Dabbit-Chan/local_mock.git
      path: local_mock_package/local_mock_dio

dependency_overrides:
  local_mock_core:
    git:
      url: https://github.com/Dabbit-Chan/local_mock.git
      path: local_mock_package/local_mock_core
```

`local_mock_core` 尚未发布到 pub.dev，需要通过 `dependency_overrides` 指定来源（git 或本地 `path`）。

## 使用

```dart
import 'package:local_mock_dio/local_mock_dio.dart';

final dio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
dio.interceptors.add(AuthInterceptor()); // 会修改 URL / method 的拦截器放前面
LocalMockDio.attach(dio);                // 再挂 local_mock
```

- `LocalMockDio.attach` 非 Debug 模式下返回 `false` 且不做任何事；重复调用不会重复添加。
- 也可以手动添加 `LocalMockInterceptor()`，它同样会注册 VM Service 扩展。
- 拦截器在 `onRequest` 中匹配，所以需要排在会改写请求 URL / method 的拦截器之后。

## 响应行为

- 命中规则时不发起网络请求，直接返回 `Response`，`data` 为规则 `body` 的深拷贝。
- `response.extra` 中带有 `local_mock: true` 和 `local_mock_rule_id`，便于日志区分。
- 响应会继续经过后续拦截器的 `onResponse` / `onError`（例如业务反序列化、统一错误处理）。
- `validateStatus` 不通过时，与真实请求一样抛出 bad response 类型的 `DioError` / `DioException`；`receiveDataWhenStatusError` 为 `false` 时 `data` 为 `null`。
- `delayMs` 期间支持 `CancelToken` 取消。
- 只支持 `ResponseType.json`，其他类型命中规则时会返回错误。

## 抓包

经过该拦截器的所有请求（Mock 命中与未命中走网络的）都会被记录到 isolate 内的抓包缓冲，供桌面端“抓包”页实时展示、一键生成规则：

- 未命中规则的请求在 `onResponse` / `onError` 里记录真实结果；被后续拦截器提前 resolve 的请求不记录。
- 请求体：`String` / JSON 可编码对象直接记录；`FormData` 只记录字段与文件数量。
- 仅 Debug 模式生效；需要将桌面端同步升级到 0.2.0+（协议 v2）。

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
