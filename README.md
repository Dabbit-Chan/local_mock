# local_mock

Flutter 接口 Mock 与请求抓包工具。目标 App 主动通过 WebSocket 连接本地 relay，上报经过适配器的请求；Web 控制台连接同一个 relay，选择设备后编辑并下发 Mock 规则。规则在 App 内匹配，未命中的请求继续访问真实业务 API。

当前可行性测试只保留 Web：`local_mock_client` 是 Flutter Web 控制台，不再提供 macOS / Windows 应用，也不使用独立的 `local_mock_server` 项目。

## 构建模式

| 目标 App 模式 | 行为 |
| --- | --- |
| Debug | 默认启用拦截与记录；调用 `LocalMock.connect` 后主动连接 |
| Profile | 默认启用拦截与记录；调用 `LocalMock.connect` 后主动连接 |
| Release | 始终禁用 |

## 仓库结构

| 目录 | 说明 |
| --- | --- |
| [`local_mock_client`](local_mock_client/README.md) | Flutter Web 控制台、WebSocket relay 启动脚本、规则编辑和抓包界面 |
| [`local_mock_package/local_mock_transport`](local_mock_package/local_mock_transport/README.md) | App 与 Web 控制台共用的 WebSocket 协议 |
| [`local_mock_package/local_mock_core`](local_mock_package/local_mock_core/README.md) | 规则模型、匹配、流量记录和 App 连接入口 |
| [`local_mock_package/local_mock_dio`](local_mock_package/local_mock_dio/README.md) | Dio 4.x / 5.x 适配器 |
| [`local_mock_package/local_mock_http`](local_mock_package/local_mock_http/README.md) | `dart:io HttpClient` / `package:http` 适配器 |

## 本地可行性测试

Flutter Web 页面本身不能监听来自手机的 WebSocket，所以不能把 `flutter run -d chrome` 的开发服务器直接当成 App 接入端。项目提供了同一 `local_mock_client` 目录下的 Dart relay 启动脚本；它同时托管 `build/web` 和 `/ws/app`、`/ws/console`，不是独立的服务项目。

终端一：构建 Web 并启动 relay：

```bash
cd local_mock_client
flutter pub get
flutter build web --no-web-resources-cdn
dart run tool/relay_host.dart 9090
```

终端二：打开控制台：

```text
http://127.0.0.1:9090/
```

终端三：你自己启动 cloudflared：

```bash
cloudflared tunnel --url http://127.0.0.1:9090
```

假设 cloudflared 输出：

```text
https://example.trycloudflare.com
```

目标 App 直接使用这个 HTTPS 地址：

```dart
LocalMock.connect(
  serverUrl: 'https://example.trycloudflare.com',
  deviceId: installationId,
  deviceName: 'QA Android',
);
```

地址会自动转换为：

```text
App:      wss://example.trycloudflare.com/ws/app
Web:      wss://example.trycloudflare.com/ws/console
```

**不需要访问令牌。** 这是当前本地可行性测试协议，任何能访问该隧道的人都可以连接和修改 Mock 规则，因此不要把隧道地址用于正式环境。

如果只运行 `flutter run -d chrome`，它只能提供 Web 页面；要让 App 连接，必须让 cloudflared 指向 `tool/relay_host.dart` 监听的端口，而不是 Flutter 开发服务器端口。

## 目标 App 接入

业务 App 先按适配器 README 配置依赖。尚未发布的包需要同时指定 `local_mock_core` 和 `local_mock_transport` 的 git / path 来源，业务项目不能依赖本仓库内的 `pubspec_overrides.yaml` 自动生效。

Dio 示例：

```dart
import 'package:dio/dio.dart';
import 'package:local_mock_dio/local_mock_dio.dart';

void configureQaTools(Dio dio, String installationId) {
  LocalMockDio.attach(dio);
  LocalMock.connect(
    serverUrl: const String.fromEnvironment('LOCAL_MOCK_SERVER'),
    deviceId: installationId,
    deviceName: 'QA Android',
  );
}
```

使用 `package:http` / `HttpClient` 时，在创建业务客户端之前调用 `LocalMockHttp.install()`，再以相同方式调用 `LocalMock.connect(...)`。网络不可用时连接在后台重试，不阻塞业务请求；服务地址也可以由 App 的测试入口在运行时提供。

Profile QA 包的构建示例：

```bash
flutter build apk --profile
```

也可以把服务地址作为默认配置：

```bash
flutter build apk --profile \
  --dart-define=LOCAL_MOCK_SERVER=https://example.trycloudflare.com
```

手机必须能访问 cloudflared 地址。HTTPS 页面 / 地址对应 WSS；目标 App 不要使用电脑的 `localhost`。本地测试的明文 WS 仅适用于 `http://` relay 地址，Android 配置还需要允许对应明文连接。

## 使用与生命周期

1. App 启动后主动连接，失败时每 2 秒重试，不阻塞业务启动或真实网络请求。
2. Web 控制台显示设备列表；只有一台在线设备时自动选中，多台时从下拉框选择。
3. 保存、开关、删除、排序变更后自动下发，等待 App 确认后生效。
4. 抓包持续由 App 上报，页面切换不停止记录；可筛选、查看详情并从请求生成规则。
5. 每台设备保留最近 500 条抓包记录。App 重连会补发缓冲并去重；App 重启使用新的会话，避免旧序号污染新记录。
6. Web 页面断开不会清空 App 内规则。relay 进程重启后内存状态丢失；App 重新连接后会重新上报当前规则和缓冲。
7. `deviceId` 必须对每个 App 安装唯一；同一个设备 ID 的多个在线连接会被拒绝。

抓包覆盖经过已接入 Dio / `HttpClient` 适配器的请求，不覆盖原生 SDK 或 WebView 的独立网络栈。二进制响应只记录大小占位信息。

## 规则格式

规则是一个 JSON 数组，第一条启用且匹配的规则生效：

```json
[
  {
    "id": "user-profile",
    "enabled": true,
    "method": "GET",
    "path": "/api/user/profile",
    "host": "api.example.com",
    "statusCode": 200,
    "delayMs": 300,
    "headers": { "x-mock": "1" },
    "body": { "name": "测试用户", "level": 10 }
  }
]
```

字段说明见 [`local_mock_core`](local_mock_package/local_mock_core/README.md#规则字段)。

## 验证

```bash
cd local_mock_client
flutter analyze
flutter test
flutter build web --no-web-resources-cdn
```

浏览器网络用例需要 relay 已启动：

```bash
flutter test --platform chrome test/browser_connection_test.dart \
  --dart-define=LOCAL_MOCK_TEST_SERVER=http://127.0.0.1:9090
```

仓库还提供 [`skills/local-mock-rules`](skills/local-mock-rules/SKILL.md) 用于生成和校验规则。
