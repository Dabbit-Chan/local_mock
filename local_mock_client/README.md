# local_mock_client

local_mock 的 Web 控制台和 Relay 服务。控制台用 Flutter Web 编写，可以查看设备、实时请求和录制，也可以编辑规则；Relay 是一个独立的 Dart 进程，负责托管控制台页面，并在 App 和控制台之间转发消息。

## 技术原理

- **Relay**（`tool/relay_host.dart`）：托管 `build/web` 中的控制台页面，在 `/ws/app` 和 `/ws/console` 两个入口上分别接收 App 和控制台的连接。它在内存中缓存每台设备当前确认的规则和最近的请求，重连时以 App 上报的规则为准。
- **控制台**：总是连接提供这个页面的 Relay 地址，不需要额外配置。路由使用 hash 模式，录制和规则保存在浏览器的 localStorage 中，规则按设备 ID 分开保存。
- **规则同步**：App 冷启动后规则为空，设备页显示“App 已重启、规则未下发”。点击“同步到设备”并成功后，本次 App 会话内保存、开关、删除和排序都会自动下发。普通网络断线、Relay 重启或浏览器刷新不会重新关闭同一 App 会话的自动同步；新 App 会话必须再次手动同步。浏览器保存的规则不会被 App 的空规则覆盖。

## 本地部署

```bash
flutter pub get
flutter build web --no-web-resources-cdn
dart run tool/relay_host.dart 9090
```

浏览器打开 <http://127.0.0.1:9090/> 即可。Relay 默认只监听 `127.0.0.1`。手机等其他设备需要访问时，可以设置 `LOCAL_MOCK_HOST=0.0.0.0`，或者通过隧道（如 `cloudflared`）暴露地址。

> Relay 没有鉴权，请只在本地或内网中使用。
