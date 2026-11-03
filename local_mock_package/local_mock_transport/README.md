# local_mock_transport

App、Relay 和 Web 控制台之间的 WebSocket 通信，不依赖 Flutter。业务 App 不直接使用本包，它由 `local_mock_core` 引入；Relay 的实现在 `local_mock_client/tool/relay_host.dart`。

## 安装

如需独立使用通信协议，在 `pubspec.yaml` 中添加：

```yaml
dependencies:
  local_mock_transport: ^1.0.0
```

然后运行 `flutter pub get`。

## 内容

- `relayUri(address, role)`：把服务地址转换为 WebSocket 入口。`http` → `ws`，`https` → `wss`；保留端口和路径前缀，末尾已有的 `/ws/app` 或 `/ws/console` 会被替换。例如 `https://host/prefix` 的 App 入口是 `wss://host/prefix/ws/app`。
- `RelayPeer`：一条 JSON 消息连接。提供请求 / 应答（8 秒超时）、事件回调，连接断开时让所有未完成的请求失败。
- `LocalMockAgent`：App 一侧的连接。断线后按 `reconnectDelay`（默认 2 秒）重试；连上后发送当前状态和请求缓冲，之后实时上报新请求，并执行 Relay 转发来的命令。

## 协议

协议版本 `relayProtocolVersion = 1`，与旧的 VM Service 接口无关。

所有消息都是 JSON 文本：

| 类型 | 形状 |
| --- | --- |
| 请求 | `{"id": "1", "method": "…", "args": {…}}` |
| 应答 | `{"id": "1", "result": {…}}` 或 `{"id": "1", "error": "…"}` |
| 事件 | `{"event": "…", …}`（没有 `id`） |

### 握手

连接后的第一条消息必须是 `hello`，`args.protocolVersion` 必须等于 1，否则 Relay 关闭连接。8 秒内未完成握手也会被关闭。

- App 连接 `/ws/app`，`hello` 另外携带 `deviceId`、`deviceName`、`sessionId`（每次 App 进程启动生成）和当前 `state`（规则与 `supportsRecordingMocks`）。
- 控制台连接 `/ws/console`，`hello` 的应答包含当前设备列表 `devices`。

### 控制台 → Relay → App

控制台发送 `command`，`args` 为 `{deviceId, method, args}`。Relay 把命令转发给对应 App，等待 App 应答后再应答控制台。

| method | 作用 | App 应答 |
| --- | --- | --- |
| `getState` | 读取规则和请求缓冲 | 规则、`supportsRecordingMocks`、请求快照 |
| `replaceRules` | 整体替换规则（`args.rules`） | 替换后的状态；规则不合法时返回错误，原规则不变 |
| `clear` | 清空规则 | 状态 |
| `clearTraffic` | 清空请求缓冲 | 请求快照 |

### 事件

| 方向 | 事件 | 内容 |
| --- | --- | --- |
| App → Relay | `snapshot` | 连上后发送的整个请求缓冲 |
| App → Relay | `traffic` | 新完成的请求 |
| Relay → 控制台 | `devices` | 设备列表：`id`、`name`、`online` |
| Relay → 控制台 | `state` | 某台设备的规则和请求（重连、恢复后） |
| Relay → 控制台 | `traffic` | 某台设备的新请求，带 `sessionId` 和 `epoch` |

每条请求带单调递增的 `revision`，用于重连补发时去重。`sessionId` 变化表示 App 重启，`epoch` 变化表示请求被清空；控制台在两者变化时丢弃旧记录。

### Relay 的设备状态

- 设备离线后仍保留在列表中（`online: false`）。
- 同一 `deviceId` 以 **同一** `sessionId` 重连时替换旧连接；以 **不同** `sessionId` 连接而旧连接仍在线时被拒绝，提示设置唯一的 `deviceId`。
- Relay 已认识的设备重连时，Relay 把最后一次被 App 确认的规则推回给它；第一次见到的设备以 App 上报的规则为准。
- 每台设备保留最近 500 条请求；App 换了 `sessionId` 时清空。

## 安全

协议没有鉴权；传输是否加密取决于是否使用 `wss`。能访问 Relay 地址的人都能读取请求内容并修改规则，只在本地或临时隧道中使用。

## 测试

本包没有独立测试。协议由 `local_mock_client` 中启动真实 Relay 的测试覆盖：

```bash
cd ../../local_mock_client
flutter test test/mock_connection_test.dart test/http_outbound_connection_test.dart test/relay_uri_test.dart
```
