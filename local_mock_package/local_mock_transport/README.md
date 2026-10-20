# local_mock_transport

不依赖 Flutter 的 App / Web 控制台通信包。当前用于本地可行性测试：relay 由 `local_mock_desktop/tool/relay_host.dart` 启动，不是独立服务项目。

- `relayUri`：将 HTTP(S) / WS(S) 地址转换为 App 或控制台 WebSocket 入口。
- `RelayPeer`：WebSocket 连接、请求 / 响应、超时和断连清理。
- `LocalMockAgent`：App 主动连接、断线每 2 秒重试、连接后上报缓冲快照和实时流量。

## 协议

主动上报协议版本为 `relayProtocolVersion = 1`，与旧 VM Service 协议独立。

1. App 连接 `/ws/app`，控制台连接 `/ws/console`。
2. 首条请求为 `{"id":"1","method":"hello","args":{"protocolVersion":1,...}}`。App 额外提交 `deviceId`、`deviceName`、`sessionId` 和当前状态。
3. 控制台调用 `command`，参数含 `deviceId`、`method` 和 `args`；支持 `getState`、`replaceRules`、`clear`、`clearTraffic`。
4. relay 将命令转发到 App，并等待 App 确认。
5. App 推送 `traffic` / `snapshot` 事件，relay 向控制台推送 `devices`、`state`、`traffic` 事件。
6. 流量包含单调递增的 `revision`；`sessionId` 和 `epoch` 用于区分 App 重启与清空操作。

当前协议不包含访问令牌或账号鉴权，仅适用于本地可行性测试。网络错误和重连不会阻塞业务请求；控制连接本身由 core 排除在抓包和 Mock 匹配之外。
