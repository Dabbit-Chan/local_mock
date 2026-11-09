# local_mock_core

local_mock 的核心包，不依赖任何具体的 HTTP 客户端。它负责规则、请求记录和与 Relay 的连接，适配器在它的基础上接入 Dio、`HttpClient` 等客户端。

## 主要内容

- **规则模型**：负责规则的解析、校验和匹配，支持整包替换、字段补丁、参数条件和录制组。
- **规则表**：每个 isolate 在内存里保存一份有序的规则列表。
- **请求记录与录制**：缓冲最近的请求，并能把一段请求序列化成录制文件。
- **连接入口**：`LocalMock.connect` 会启动 `LocalMockAgent`（连 Relay 的 `/ws/app`），并创建 `VmServiceBridge`（连本机 VM Service，首次使用时建立连接）。控制台命令由 Relay 转到 Agent，再由 Bridge 交给 `ext.local_mock.*` 扩展执行；抓包事件走相反方向。

## 技术原理

- 规则按列表顺序依次匹配，只采用第一条命中的规则。请求方法和路径必须完全一致，域名和参数条件可以按需加上。
- App 里的规则只保存在内存中，冷启动后为空。控制台按设备把规则保存在浏览器中；用户点击“同步到设备”后，本次 App 会话内的修改会自动下发。
- **两条通道**：Relay 通道负责跨设备传输；VM Service 通道只在本机，负责在 App isolate 内执行规则命令和收集抓包事件。
- **抓包链路**：适配器调用 `LocalMock.beginTraffic`，记录完成后由 `developer.postEvent` 发出事件，`VmServiceBridge` 收到后交给 `LocalMockAgent` 上报 Relay。
