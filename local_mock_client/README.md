# local_mock_client

local_mock 的 Web 控制台和 Relay 服务。控制台用 Flutter Web 编写，可以查看设备、实时请求和录制，也可以编辑规则；Relay 是一个独立的 Dart 进程，负责托管控制台页面，并在 App 和控制台之间转发消息。

## 技术原理

- **Relay**（`tool/relay_host.dart`）：托管 `build/web` 中的控制台页面，在 `/ws/app` 和 `/ws/console` 两个入口上分别接收 App 和控制台的连接。它在内存中保存每台设备最后确认的规则和最近的请求。
- **控制台**：总是连接提供这个页面的 Relay 地址，不需要额外配置。路由使用 hash 模式，录制保存在浏览器的 localStorage 中。

## 本地部署

```bash
flutter pub get
flutter build web --no-web-resources-cdn
dart run tool/relay_host.dart 9090
```

浏览器打开 <http://127.0.0.1:9090/> 即可。Relay 默认只监听 `127.0.0.1`。手机等其他设备需要访问时，可以设置 `LOCAL_MOCK_HOST=0.0.0.0`，或者通过隧道（如 `cloudflared`）暴露地址。

> Relay 没有鉴权，请只在本地或内网中使用。
