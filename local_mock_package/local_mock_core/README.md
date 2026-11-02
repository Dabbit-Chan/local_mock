# local_mock_core

local_mock 的核心包，与具体 HTTP 客户端无关。负责：

- Mock 规则模型（`MockRule`）的解析与校验
- isolate 内的规则表与请求匹配（`LocalMock.match`）
- 请求抓包记录（`LocalMock.beginTraffic` / `TrafficRecorder`）
- App 主动连接服务端、上报流量、接收规则（`LocalMock.connect`）
- Debug 模式保留旧 VM Service 扩展（`LocalMockProtocol`），新版控制台不依赖它

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
| `params` | object | 否 | `{}` | 参数子集精确匹配，值为字符串 / 数字 / 布尔值 / null，解析后统一转为字符串 |
| `patchBody` | object | 否 | `{}` | 字段路径到新 JSON 值的映射；非空时修改真实响应，而非整包替换 |

匹配规则：

- 按顺序查找，第一条 `enabled` 且 `method`、`path`、`host`（如有）、`params`（如有）都匹配的规则生效；规则不会叠加。
- `params` 留空时继续忽略参数。填写时逐项匹配，额外参数不影响结果；同名参数以 URL query 为准，没有时才查请求体。重复 query 中有一个值相等即可。
- 请求体支持 JSON 对象、JSON 字符串和 URL 编码表单；Dio 适配器另外支持 `FormData` 普通字段。请求体可用 `filter.id`、`items[0].id` 定位嵌套值；不支持对整个对象 / 数组进行参数比较。缺失的键不会匹配 `null`。
- 默认响应头为 `content-type: application/json; charset=utf-8`，可被 `headers` 覆盖；响应头名统一转小写。
- 整个规则列表先完整校验再替换，任一规则不合法时保留原有规则不变。

响应补丁：

- `patchBody: {"data.product": {...}}` 会先访问真实后端，再替换指定字段；对象 / 数组字段是整体替换，不递归合并。
- 支持点分隔路径和非负数组下标，例如 `data.items[0].name`、`data.items.0.name`；可设置 `null`、新增已有对象的叶子字段，但不创建缺失的父级，不扩展数组。不支持名称本身带点或方括号的字段。
- 补丁在深拷贝上执行；任何路径父级不存在、类型不符或数组越界时，适配器保留整个原始响应。非 JSON 响应同样透传，不伪造成功或吞掉网络错误。
- 真实 HTTP 状态码和业务响应头保留，规则的 `body` / `statusCode` / `headers` 被忽略；适配器会移除失效的长度 / 校验头，HttpClient 重新计算字节长度。`delayMs` 是读取真实响应后的额外延迟。
- 可以同时设置 `params` 与 `patchBody`，只补丁指定参数对应的响应。示例见[根 README](../../README.md#只修改真实响应中的字段)。

## 连接服务端

Debug 和 Profile 默认启用，Release 始终禁用，无需额外启用参数。

```dart
LocalMock.connect(
  serverUrl: 'https://example.trycloudflare.com',
  deviceId: installationId, // 由业务 App 持久化，每个安装 / isolate 唯一
  deviceName: 'QA Android',
);
LocalMock.connected; // 当前上报通道是否已连接
LocalMock.disconnect(); // 停止上报和重连，保留内存规则
```

`connect` 在后台建立连接，网络不可用时每 2 秒重试，不等待连接建立；返回值表示是否启用了连接功能。无效配置在启用时会同步抛出异常。再次调用会替换旧连接。HTTP(S) 地址自动转换为 WS(S) `/ws/app`，也支持完整 WebSocket 地址。当前可行性测试不包含访问令牌。

## API

```dart
import 'package:local_mock_core/local_mock_core.dart';

// 初始化适配器；禁用模式返回 false。Debug 下额外注册 VM Service 扩展。
LocalMock.ensureInitialized();

// 查找匹配规则；禁用模式始终返回 null。
final MockRule? rule = LocalMock.match('GET', uri, requestBody: requestData);
if (rule != null) {
  rule.statusCode;       // 状态码
  rule.delayMs;          // 延迟
  rule.responseHeaders;  // 含默认 content-type 的响应头
  rule.bodyCopy;         // 响应体的深拷贝，可安全修改
}

// 开始记录一条请求（抓包）；禁用模式返回 null。
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
2. 每个请求发出前调用 `LocalMock.beginTraffic(method, uri)` 开始记录，并调用 `LocalMock.match(method, uri, requestBody: data)` 查找规则。若请求体尚未写入，可先取 `LocalMock.candidates(method, uri)`，体收集完成后按原顺序调用 `rule.matches(..., requestBody: data)`。
3. 非补丁命中时按 `statusCode` / `delayMs` / `responseHeaders` / `bodyCopy` 构造响应；`rule.isPatch` 为真时走真实网络，再用 `rule.applyPatch(decodedBody)` 修改深拷贝，捕获 `FormatException` 后透传原响应。
4. 用 `TrafficRecording.finish(mocked: true, ...)` 记录实际返回的 Mock / 补丁响应；其他请求结束时 `finish` / `fail` 记录真实结果。

## 规则生命周期

- App 规则仅保存在当前 isolate 内存，冷启动时为空。
- relay 保存每台设备最后确认的规则；相同设备 ID 重新连接后自动恢复，不要求 Web 控制台在线。
- Hot Restart / 冷启动应重新调用 `connect`。恢复前请求使用当前空规则表；relay 重启则丢失其内存状态。
- 重复接入适配器不会清空当前 isolate 中的规则。

## 抓包行为

- 每条记录包含：方法、完整 URI、host、path、请求体（尽力而为）、状态码、耗时、响应体文本、是否 Mock、错误信息。
- App 缓冲区保留最近 500 条；请求/响应体按适配器能力完整记录，不截断。
- 连接后主动推送新记录，重连补发缓冲并按序号去重。控制连接本身不参与抓包或 Mock。
- 独立使用 `TrafficRecorder` 时，可通过 `maxEntries` 配置数量上限、`onEntry` 订阅完成事件。
- 二进制响应体不记录内容，只记录大小占位符（由适配器处理）。

## 旧 VM Service 协议（仅 Debug）

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

参数不合法时返回 `invalidParams` 错误，`message` 字段说明原因。此接口保留给已有自定义工具；新版 Web 控制台使用独立的主动上报协议。

## 测试

```bash
flutter test
```
