# local_mock_http

local_mock 的 `dart:io` 适配器。通过 `HttpOverrides` 包装应用创建的每个 `HttpClient`，因此覆盖：

- `package:http`（移动端和桌面端默认的 `IOClient`）
- Dio 默认的 `IOHttpClientAdapter`
- 直接使用 `HttpClient` 的代码和三方库

Debug / Profile 构建中生效；Release 构建和 Web 平台上不做任何事。

## 安装

`local_mock_core` 和 `local_mock_transport` 没有发布到 pub.dev，需要用 `dependency_overrides` 一起指定来源：

```yaml
dependencies:
  local_mock_http:
    git:
      url: https://github.com/Dabbit-Chan/local_mock.git
      path: local_mock_package/local_mock_http

dependency_overrides:
  local_mock_core:
    git:
      url: https://github.com/Dabbit-Chan/local_mock.git
      path: local_mock_package/local_mock_core
  local_mock_transport:
    git:
      url: https://github.com/Dabbit-Chan/local_mock.git
      path: local_mock_package/local_mock_transport
```

## 接入

```dart
import 'package:local_mock_http/local_mock_http.dart';

void main() {
  HttpOverrides.global = MyProxyOverrides(); // 自己的 overrides（如果有）先装
  LocalMockHttp.install();                   // 再装 local_mock
  LocalMock.connect(
    serverUrl: 'https://example.trycloudflare.com',
    deviceId: installationId,
    deviceName: 'QA Android',
  );
  runApp(const MyApp());
}
```

- `install()` 把当前的 `HttpOverrides` 保存下来作为兜底：没有命中规则的请求仍由原来的 overrides 创建的客户端处理，代理、证书配置不受影响。
- 只有 **之后创建** 的 `HttpClient` 会被包装，所以要在 `main()` 里尽早调用。
- Release 和 Web 上返回 `false`；重复调用不会重复安装。
- 同时使用 Dio 默认适配器和 `local_mock_dio` 时，`local_mock_dio` 的拦截器先命中。只用 Dio 的项目建议用 `local_mock_dio`，可以保留 Dio 的拦截器链和 `response.extra` 标记。

## 命中规则时

**整包替换**

- 不建立网络连接；请求体照常接收后丢弃。
- 返回规则的状态码、响应头和响应体字节（有录制原文时按原文返回）。`delayMs` 从请求 `close()` 时开始计算。
- `HEAD` 请求以及 204、304 状态码不返回响应体。
- 支持 `abort()` 和 `close(force: true)`（Dio 4 的取消方式）。
- Mock 响应不支持重定向；`detachSocket()` 永远不会完成。

**字段补丁**

- 发出真实请求，读取完整响应后应用补丁，再等待 `delayMs`。真实状态码和业务响应头保留；会修正长度、压缩、校验类响应头，并按新内容重新计算字节长度。
- 响应不是 JSON 或补丁不适用时，返回完整的原始响应。
- 补丁需要缓冲整个 JSON 响应，不适合 SSE 和大文件下载。

**参数条件** 支持 URL query、JSON 或 URL 编码表单请求体。存在同端点候选规则时，请求体会先缓冲到 `close()` 再匹配；不匹配的请求以原始字节、请求头和设置交给真实客户端，不会丢失。没有候选规则的请求按原方式流式透传。

规则字段和匹配细节见 [`local_mock_core` 的规则参考](../local_mock_core/README.md#规则参考)。

## 请求记录

所有经过包装的请求都会被记录并上报到控制台：

- 走网络的请求透传字节，同时记录请求体和响应体；响应体在流结束时按 Content-Type 转成文本。
- 二进制响应只记录为 `<binary N bytes>`。
- 记录不改变请求本身的行为。与 Relay 之间的连接不被记录。

## 测试

```bash
flutter test
```
