# local_mock_core

local_mock 的核心包，与具体 HTTP 客户端无关。负责：

- Mock 规则模型（`MockRule`）的解析与校验
- isolate 内的规则表与请求匹配（`LocalMock.match`）
- 请求抓包记录（`LocalMock.beginTraffic` / `TrafficRecorder`）
- 注册供桌面端调用的 VM Service 扩展（`LocalMockProtocol`）

业务 App 通常不直接依赖本包，而是使用 [`local_mock_dio`](../local_mock_dio/README.md) 或 [`local_mock_http`](../local_mock_http/README.md)，两者都会重新导出本包的 API。

## 规则字段

| 字段 | 类型 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| `id` | string | 是 | | 规则唯一 ID，列表内不能重复 |
| `enabled` | bool | 否 | `true` | 是否启用 |
| `method` | string | 是 | | HTTP 方法，只能是 ASCII 字母，大小写不敏感 |
| `path` | string | 是 | | 以 `/` 开头的路径，精确匹配，不能带 `?` 或 `#` |
| `host` | string | 否 | `null` | 主机名，大小写不敏感；不填则匹配任意 host |
| `statusCode` | int | 否 | `200` | 响应状态码，范围 100..599 |
| `delayMs` | int | 否 | `0` | 响应延迟毫秒数，范围 0..60000 |
| `headers` | object | 否 | `{}` | 响应头，值必须为字符串 |
| `body` | any | 否 | `null` | 任意 JSON 值，作为响应体 |

匹配规则：

- 按顺序查找，第一条 `enabled` 且 `method`、`path`、`host`（如有）都匹配的规则生效。
- 查询参数不参与匹配。
- 默认响应头为 `content-type: application/json; charset=utf-8`，可被 `headers` 覆盖；响应头名统一转小写。
- 整个规则列表先完整校验再替换，任一规则不合法时保留原有规则不变。

## API

```dart
import 'package:local_mock_core/local_mock_core.dart';

// 注册 VM Service 扩展（每个 isolate 只注册一次）。非 Debug 模式返回 false。
LocalMock.ensureInitialized();

// 查找匹配规则；非 Debug 模式始终返回 null。
final MockRule? rule = LocalMock.match('GET', uri);
if (rule != null) {
  rule.statusCode;       // 状态码
  rule.delayMs;          // 延迟
  rule.responseHeaders;  // 含默认 content-type 的响应头
  rule.bodyCopy;         // 响应体的深拷贝，可安全修改
}

// 开始记录一条请求（抓包）；非 Debug 模式返回 null。
final traffic = LocalMock.beginTraffic('GET', uri);
// ... 请求结束后：
traffic?.finish(statusCode: 200, contentType: 'application/json', body: text);
// 或请求失败时：
traffic?.fail(error);
```

测试中可以绕过 VM Service 直接操作规则表和抓包缓冲：

```dart
LocalMock.debugReplaceRules([{'id': 'a', 'method': 'GET', 'path': '/x'}]);
LocalMock.debugClear();
LocalMock.debugTrafficEntries();
LocalMock.debugClearTraffic();
```

## 编写自定义适配器

1. 在适配器初始化时调用 `LocalMock.ensureInitialized()`。
2. 每个请求发出前调用 `LocalMock.beginTraffic(method, uri)` 开始记录，并调用 `LocalMock.match(method, uri)` 查找规则。
3. 命中时按 `statusCode` / `delayMs` / `responseHeaders` / `bodyCopy` 构造响应，并用 `TrafficRecording.finish(mocked: true, ...)` 记录；否则走原始网络请求，结束时 `finish` / `fail` 记录真实结果。

## 抓包行为

- 每条记录包含：方法、完整 URI、host、path、请求体（尽力而为）、状态码、耗时、响应体文本、是否 Mock、错误信息。
- 缓冲区为 isolate 内队列，不限制保留条数；请求/响应体完整记录，不截断。
- 二进制响应体不记录内容，只记录大小占位符（由适配器处理）。

## VM Service 协议

协议版本：`LocalMockProtocol.version = 2`

| 扩展方法 | 参数 | 说明 |
| --- | --- | --- |
| `ext.local_mock.getState` | 无 | 获取当前状态 |
| `ext.local_mock.replaceRules` | `protocolVersion`：版本号字符串；`rules`：规则数组的 JSON 字符串 | 整体替换规则 |
| `ext.local_mock.clear` | 无 | 清空规则 |
| `ext.local_mock.getTraffic` | `sinceRevision`：非负整数（可选，默认 0） | 增量拉取抓包记录 |
| `ext.local_mock.clearTraffic` | 无 | 清空抓包缓冲 |

规则相关的三个方法成功时返回当前状态：

```json
{ "protocolVersion": 2, "revision": 3, "rules": [ ... ] }
```

抓包相关的两个方法返回抓包快照（`clearTraffic` 后 `entries` 为空，但 `trafficRevision` 继续递增，保证桌面端增量游标不回退）：

```json
{
  "protocolVersion": 2,
  "trafficRevision": 12,
  "entries": [ { "revision": 11, "method": "GET", "uri": "...", "path": "/api/x", "statusCode": 200, "responseBody": "{...}", ... } ]
}
```

参数不合法时返回 `invalidParams` 错误，`message` 字段说明原因。v2 桌面端连接 v1 App 端会被拒绝并提示升级。

## 测试

```bash
flutter test
```
