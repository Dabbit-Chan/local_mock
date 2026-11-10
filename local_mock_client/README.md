# local_mock_client

local_mock 的 Web 控制台和 Relay 服务。控制台用 Flutter Web 编写，可以查看设备、实时请求和录制，也可以编辑规则；Relay 是一个独立进程，负责托管控制台页面，并在 App 和控制台之间转发消息。Dart 版 Relay 随控制台一起运行，Go 版见 `../local_mock_relay/go`。

<a href="README.md">中文</a> · <a href="README.en.md">English</a>

## 技术原理

- **Relay**（Dart 版 `tool/relay_host.dart`，Go 版 `../local_mock_relay/go`）：托管 `build/web` 中的控制台页面，在 `/ws/app` 和 `/ws/console` 两个入口上分别接收 App 和控制台的连接。它在内存中缓存每台设备当前确认的规则和最近的请求，重连时以 App 上报的规则为准。
- **App 侧**：`LocalMockAgent` 维护到 Relay 的 `/ws/app` 连接；`VmServiceBridge` 是 App 内部的另一条 WebSocket，负责把 Relay 命令转给 VM Service 扩展并接收抓包事件。
- **控制台**：总是连接提供这个页面的 Relay 地址，不需要额外配置。路由使用 hash 模式，录制和规则保存在浏览器的 localStorage 中，规则按设备 ID 分开保存。
- **规则同步**：App 冷启动后规则为空，设备页显示“App 已重启、规则未下发”。点击“同步到设备”并成功后，本次 App 会话内保存、开关、删除和排序都会自动下发。普通网络断线、Relay 重启或浏览器刷新不会重新关闭同一 App 会话的自动同步；新 App 会话必须再次手动同步。浏览器保存的规则不会被 App 的空规则覆盖。

## 本地部署

```bash
flutter pub get
flutter build web --no-web-resources-cdn
dart run tool/relay_host.dart 9090
```

也可以改用 Go 版 Relay（默认读取当前目录下的 `build/web`）：

```bash
cd ../local_mock_relay/go
LOCAL_MOCK_WEB_DIR=../../local_mock_client/build/web go run . 9090
```

浏览器打开 <http://127.0.0.1:9090/> 即可。Relay 默认只监听 `127.0.0.1`。手机等其他设备需要访问时，可以设置 `LOCAL_MOCK_HOST=0.0.0.0`，或者通过隧道（如 `cloudflared`）暴露地址。Go 版还提供 <http://127.0.0.1:9090/diag>，可以查看在线连接和最近的断开原因。

> Relay 没有鉴权，请只在本地或内网中使用。
