# local_mock_http

local_mock 的 `dart:io` 适配器，通过 `HttpOverrides` 拦截所有 `HttpClient`。在 Debug 和 Profile 模式默认生效，Release 始终禁用，Web 平台上是空操作。

覆盖范围：

- `package:http`（`IOClient`，移动端 / 桌面端默认实现）
- Dio 默认的 `IOHttpClientAdapter`
- 直接使用 `HttpClient` 的代码和三方库

## 安装

```yaml
dependencies:
  local_mock_http:
    git:
      url: https://github.com/Dabbit-Chan/local_mock.git
      path: local_mock_package/local_mock_http

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
import 'package:local_mock_http/local_mock_http.dart';

void main() {
  HttpOverrides.global = MyProxyOverrides(); // 自己的 overrides（如有）先装
  LocalMockHttp.install();                   // 再装 local_mock
  runApp(const MyApp());
}
```

- `install()` 会把当前的 `HttpOverrides` 保存为兜底，未命中规则的请求仍由原来的 overrides（代理、证书等）创建的客户端处理。
- 只有调用之后创建的 `HttpClient` 会被拦截，所以要尽早在 `main()` 中调用。
- 禁用模式和 Web 平台返回 `false`；重复调用不会重复安装。
- 调用 `LocalMock.connect(serverUrl: ..., deviceId: ...)` 开始主动连接；Debug 和 Profile 默认启用。当前可行性测试不需要访问令牌。
- 上报连接本身会排除在抓包与规则匹配之外。

## 响应行为

- 命中普通规则时不建立连接，请求体被接收后丢弃。
- `params` 支持 URL query、JSON / URL 编码表单请求体。存在同端点候选规则时，请求体先缓冲到 `close()` 再完整匹配；参数不匹配的请求按原字节、请求头和设置交给真实客户端，不会被丢弃。无候选规则的请求仍按原方式流式透传。
- 非空 `patchBody` 会请求真实后端，再只修改指定 JSON 字段；保留真实 HTTP 状态和业务响应头，修正长度 / 压缩 / 校验头。非 JSON、路径不适用时返回完整原响应。补丁会缓冲 JSON 响应，不适用于 SSE / 下载流；路径语法见[核心规则说明](../local_mock_core/README.md#规则字段)。
- 普通 Mock 的 `delayMs` 从请求 `close()` 时开始计算；字段补丁则在真实响应读取后额外延迟，取消仍会终止等待。
- `HEAD` 请求和 `204` / `304` 状态码没有响应体。
- 支持 `abort()` 和 `close(force: true)`（Dio 4 的取消方式）。
- Mock 响应不支持重定向，`detachSocket()` 永不完成。

## 抓包

所有经过该 overrides 创建的 `HttpClient` 的请求（Mock 命中与未命中走网络的）都会被记录，供桌面端“抓包”页实时展示、一键生成规则：

- 未命中规则的请求由包装层透传字节并记录：请求体收集原始字节，响应体在流结束时按 content-type 转为文本；二进制响应只记录大小占位符。
- 记录不影响请求本身的行为；在 Debug 和 Profile 模式生效。
- 连接后实时上报到服务端，由新版 Web / 桌面控制台展示。

## 与 local_mock_dio 一起使用

Dio 使用默认适配器时，两个包都会生效，`local_mock_dio` 的拦截器先命中。只用 Dio 的项目建议接入 `local_mock_dio`，可以保留 Dio 的拦截器链和 `response.extra` 标记。

## 测试

```bash
flutter test
```
