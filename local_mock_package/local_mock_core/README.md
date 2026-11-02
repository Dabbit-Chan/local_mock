# local_mock_core

与具体 HTTP 客户端无关的核心包：

- 规则模型 `MockRule`：解析、校验、匹配、字段补丁；
- 规则表：每个 isolate 一份，内存保存；
- 请求记录 `TrafficRecorder` / `TrafficEntry`，以及可序列化的录制 `TrafficSession`；
- App 到 Relay 的连接入口 `LocalMock.connect`。

业务 App 一般不直接依赖本包，而是使用 [`local_mock_dio`](../local_mock_dio/README.md) 或 [`local_mock_http`](../local_mock_http/README.md)，它们会重新导出这里的 API。

## 启用条件

`LocalMock.enabled == !kReleaseMode`：Debug 和 Profile 构建中启用，Release 构建中所有入口都是空操作（`connect` 返回 `false`，`match` 返回 `null`，不记录请求）。

## 规则参考

规则列表是一个 JSON 数组。整个数组先完整校验，任意一条不合法则整体拒绝，App 保留原有规则；ID 在列表内不能重复。

### 普通规则

| 字段 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `id` | string | 必填 | 非空，列表内唯一 |
| `enabled` | bool | `true` | 关闭后不参与匹配 |
| `method` | string | 必填 | 只含 ASCII 字母，不区分大小写 |
| `path` | string | 必填 | 以 `/` 开头，不含 `?` 和 `#`；与请求路径完全相等才命中 |
| `host` | string | 不限 | 不含端口，不区分大小写 |
| `params` | object | `{}` | 参数条件，见下文。值只能是字符串、数字、布尔值或 `null` |
| `statusCode` | int | `200` | 100–599 |
| `delayMs` | int | `0` | 0–60000 |
| `headers` | object | `{}` | 响应头，值必须是字符串 |
| `body` | 任意 JSON | `null` | 响应体 |
| `patchBody` | object | `{}` | 字段补丁，见下文。非空时规则变为“补丁”模式 |
| `responseText` | string | — | 原始响应文本，由录制生成；存在时整包替换按原文返回，可保留非 JSON 文本 |
| `recordedRequest` | object | — | 录制组内接口使用的录制参数：`{"query": {"k": ["v"]}, "body": "…"}` |

响应头默认带 `content-type: application/json; charset=utf-8`，可以在 `headers` 里覆盖；响应头名统一转小写。

### 匹配顺序

1. 自上而下遍历规则列表；录制组展开成组内接口，按组内顺序参与。
2. 方法、路径相同，且 `host`（如果写了）相同，才算候选。
3. 依次检查录制参数（仅录制组开启“只匹配录制时的传参”时）和 `params`。
4. 第一条全部满足的规则生效。规则之间不叠加、不合并。

没有任何规则命中时，请求照常走真实网络。

### 参数条件 `params`

`{"id": "123"}` 表示“请求里的 `id` 等于 123”。对每个键：

- 先查 URL query。query 里有这个键时，只要其中一个值相等即可，**不再查请求体**。
- query 里没有时查请求体。请求体支持 JSON 对象、JSON 字符串和 URL 编码表单；Dio 适配器还支持 `FormData` 的普通字段。
- 键可以是嵌套路径：`filter.id`、`items[0].id`、`items.0.id`。请求体顶层恰好有一个带点的键时优先按原样匹配。
- 比较时两边都转成字符串：`123` 和 `"123"` 相等。目标是对象或数组时不匹配；键缺失时不匹配（即使条件值是 `null`）。
- 所有条件都满足才命中；请求里多出来的参数不影响。

### 字段补丁 `patchBody`

`patchBody` 非空时，规则不再整包替换，而是：先照常请求真实接口，拿到响应后改写其中的字段。真实的状态码、响应头和未提及的字段都保持不变；规则自身的 `statusCode`、`headers`、`body` 被忽略；`delayMs` 是在拿到真实响应 **之后** 额外等待的时间。

```json
{
  "id": "site-long-names",
  "method": "GET",
  "path": "/api/site/home",
  "patchBody": {
    "data.sitePhotoAlbumList[*].name": "很长很长很长的相册名",
    "data.sitePhotoAlbumList[0].name": "第一个单独改",
    "data.siteBaseInfo.title": null
  }
}
```

- 键是字段路径，值是新的 JSON 值（对象和数组整体替换，不做合并）。
- 路径写法：`data.title`、`data.items[0].name`、`data.items.0.name`；`[*]` 表示数组的每个元素，可以嵌套（`groups[*].items[*].name`），也可以用在根数组上（`[*].name`）。
- 按填写顺序依次应用，所以可以先用 `[*]` 批量改，再用 `[0]` 单独覆盖。
- 可以给已有对象新增一个叶子字段；不会创建缺失的中间层，也不会扩展数组。
- 数组下标越界：只跳过这一条路径（或 `[*]` 下的这一个分支），其他补丁照常生效。空数组上的 `[*]` 什么也不做。
- 以下情况 **整个响应原样返回**，不做任何修改：响应不是 JSON、中间层不存在、类型不符（例如对对象用 `[*]`）。网络错误也照常抛出，不会被补丁变成成功。
- 字段名本身含 `.` 或 `[` `]` 的字段无法定位。

`params` 和 `patchBody` 可以同时使用：只改某个 ID 的响应中的某些字段。

### 录制组

```json
{
  "type": "recording",
  "id": "recording-1730538207000",
  "name": "下单流程",
  "recordingId": "1730538207000",
  "enabled": true,
  "matchParams": false,
  "rules": [ { "id": "request-1", "method": "POST", "path": "/api/order", "...": "…" } ]
}
```

- `rules` 不能为空，只能包含普通规则（不能嵌套组）；组内 ID 在组内唯一，组 ID 在顶层唯一。
- `enabled: false` 关闭整组。
- `matchParams` 为 `true` 时，组内接口还要求请求的 query 和请求体与各自的 `recordedRequest` 一致：query 键顺序、JSON 对象键顺序和表单键顺序不影响比较。为 `false` 时忽略 `recordedRequest`。手写的 `params` 无论如何都生效。
- `recordingMockFromSession(session, matchParams: …)` 从一段录制生成组：只使用 `TrafficSession.replayableEntries`；同一方法 + 域名 + 路径 + 传参的请求只保留最后开始的那一次；状态码、Content-Type、原始响应文本和耗时（最多 60 秒）作为默认值。
- 设备通过状态里的 `supportsRecordingMocks: true` 表明支持录制组；不支持的设备收到含组的规则列表会整体拒绝。

## API

```dart
// 连接 Relay。立即返回；失败时后台每 2 秒重试。再次调用会替换旧连接。
LocalMock.connect(
  serverUrl: 'https://example.trycloudflare.com', // http(s) 自动转为 ws(s)://…/ws/app，也可直接写 ws(s) 地址
  deviceId: installationId,                       // 非空；每个 App 安装（每个 isolate）唯一且稳定
  deviceName: 'QA Android',                       // 可选，默认等于 deviceId
);
LocalMock.connected;    // 上报通道当前是否连通
LocalMock.disconnect(); // 停止上报和重连；内存中的规则保留

// 适配器使用
LocalMock.ensureInitialized();                             // 禁用时返回 false
final rule = LocalMock.match('GET', uri, requestBody: data); // 第一条命中的规则或 null
LocalMock.hasCandidates('GET', uri);                       // 是否存在同端点的候选（用于决定是否缓冲请求体）
LocalMock.candidates('GET', uri);                          // 同端点候选，录制组已展开
final traffic = LocalMock.beginTraffic('GET', uri);       // 开始记录一个请求；禁用时为 null
```

与 Relay 之间的连接本身会被识别出来，既不记录也不参与匹配。

### 编写适配器

1. 初始化时调用 `LocalMock.ensureInitialized()`。
2. 请求发出前调用 `beginTraffic`，再用 `match(method, uri, requestBody: …)` 查找规则。请求体要等写完才能拿到时，先用 `hasCandidates` 判断，有候选再缓冲请求体，最后调用 `match`；没有候选就直接透传。
3. 命中且 `rule.isPatch == false`：等待 `delayMs`，返回 `statusCode`、`responseHeaders` 和响应体。需要字节时用 `rule.responseText`（保留录制原文），需要对象时用 `rule.bodyCopy`（深拷贝，可随意修改）。
4. 命中且 `rule.isPatch == true`：照常请求，对解码后的 JSON 调用 `rule.applyPatch(body)` 得到新对象；捕获 `FormatException` 时返回原始响应。改写后要移除失效的 `content-length`、校验类响应头。
5. 请求结束时调用 `traffic.finish(…, mocked: …)` 或 `traffic.fail(error)`。二进制响应体请记录为 `<binary N bytes>` 这样的占位文本。

### 测试辅助

```dart
LocalMock.debugReplaceRules([{'id': 'a', 'method': 'GET', 'path': '/x'}]);
LocalMock.debugClear();
LocalMock.debugTrafficEntries();
LocalMock.debugClearTraffic();
```

## 请求记录

- 每条记录：序号 `revision`、开始时间、耗时、方法、完整 URI、host、path、请求体文本（尽力而为）、状态码、Content-Type、响应体文本、错误信息、是否由规则产生（`mocked`）。
- App 内保留最近 500 条；连接 Relay 后先发送缓冲快照，之后实时上报每条完成的请求。
- 请求体和响应体不截断；二进制内容只记录大小。
- `TrafficRecorder(maxEntries:, onEntry:)` 可以独立使用。

## 录制文件格式

`TrafficSession.toJson()` 产生控制台导出的录制文件：

```json
{
  "format": "local_mock_capture",
  "version": 1,
  "id": "1730538207000",
  "name": "下单流程",
  "deviceId": "pixel-8-qa",
  "deviceName": "Pixel 8 · QA",
  "startedAt": 1730538207000,
  "endedAt": 1730538251000,
  "entries": [ { "revision": 1, "method": "POST", "uri": "https://…", "...": "…" } ]
}
```

`TrafficSession.fromJson` 完整校验文件（格式标记、版本、时间、每条请求的字段与 URL），任何一处不合法都会拒绝整个文件。`replayableEntries` 返回可以生成 Mock 的请求：成功、有响应体（HEAD / 204 / 304 除外），且请求体和响应体都不是占位文本。

## 规则的生命周期

- 规则只保存在当前 isolate 的内存中，App 冷启动或 Hot Restart 后为空。
- Relay 记住每台设备最后一次确认的规则；同一 `deviceId` 重新连接时自动推回。恢复完成之前发出的请求不会被 Mock。
- Relay 重启后不再记得规则；App 重连时以 App 当前的规则为准。
- 重复接入适配器不会清空规则。

## 旧版 VM Service 接口

Debug 模式下还会注册以下 VM Service 扩展（协议版本 `LocalMockProtocol.version == 2`），供已有的自定义工具使用；Web 控制台不依赖它们。

| 方法 | 参数 | 返回 |
| --- | --- | --- |
| `ext.local_mock.getState` | — | `{protocolVersion, revision, rules}` |
| `ext.local_mock.replaceRules` | `protocolVersion`、`rules`（规则数组的 JSON 字符串） | 同上 |
| `ext.local_mock.clear` | — | 同上 |
| `ext.local_mock.getTraffic` | `sinceRevision`（非负整数，默认 0） | `{protocolVersion, trafficRevision, entries}` |
| `ext.local_mock.clearTraffic` | — | 同上，`entries` 为空，`trafficRevision` 不回退 |

参数不合法时返回 `invalidParams` 错误，`message` 说明原因。

## 测试

```bash
flutter test
```
