---
name: local-mock-rules
description: 为 local_mock 生成、修改或校验 Mock 规则文件（JSON 数组，在 Web 控制台“导入规则文件”后下发到 App）。当用户要求 mock 接口、构造假数据、模拟错误码 / 慢接口 / 空列表 / 超长文本，只改某个参数对应的响应，或要求检查 local_mock 规则时使用。
---

# 生成 local_mock 规则

## 产出物

一个 **规则文件**：顶层是 JSON 数组，每个元素是一条规则。用户在控制台的设备调试页中，通过「规则」列右上角的 `⋯` → 「导入规则文件…」导入。

导入会 **替换该设备当前的全部规则**。因此：

- 用户给了现有的规则文件（控制台「导出规则文件」得到的）时，在它的基础上增改，保留其中所有已有规则（包括 `"type": "recording"` 的录制组，原样保留，不要改写）。
- 没有给时，提醒用户：导入会覆盖现有规则，如需保留请先导出并发给你。
- 只有一两条简单规则时，也可以告诉用户直接在控制台里「新建」，并给出每个字段该填什么。

## 流程

1. 确定接口：HTTP 方法、完整路径、（可选）域名。
   - 从业务代码中找：`dio.get/post(...)`、Retrofit 注解、`http.get(Uri.parse(...))` 等。
   - 路径要拼上 `baseUrl` 的路径部分：`baseUrl: 'https://api.example.com/v1'` + `'/user'` → `path` 是 `/v1/user`。
   - 路径中的动态段写成具体值（`/api/order/123`）。规则不支持路径通配符或正则；需要按 ID 区分时优先考虑 query / 请求体参数配合 `params`。
2. 确定响应结构：以项目里的模型类（`fromJson`、`json_serializable`、`freezed`）和接口文档为准，字段名、类型、外层包装（如 `{"code":0,"msg":"","data":{…}}`）都要一致。找不到依据时向用户确认，或在回复中说明哪些是推测的。
3. 选择方式：
   - 要完全控制返回内容 → 整包替换（写 `statusCode` / `body`）。
   - 只想改真实响应中的几个字段 → 字段补丁（写 `patchBody`）。
   - 只影响某个 ID / 某种传参 → 加 `params`。
4. 写好后用脚本校验：

   ```bash
   python3 <skill 目录>/scripts/validate_rules.py rules.json
   cat rules.json | python3 <skill 目录>/scripts/validate_rules.py
   ```

5. 回复中给出完整的规则文件（一个 `json` 代码块，或写入用户指定的文件），并用一两句话说明每条规则覆盖什么场景、排列顺序的理由。

## 字段

| 字段 | 类型 | 默认 | 约束 |
| --- | --- | --- | --- |
| `id` | string | 必填 | 非空，整个文件内唯一 |
| `enabled` | bool | `true` | |
| `method` | string | 必填 | 只含 ASCII 字母 |
| `path` | string | 必填 | 以 `/` 开头，不含 `?`、`#` |
| `host` | string | 不限 | 不含端口，不区分大小写 |
| `params` | object | `{}` | 值只能是字符串、数字、布尔值或 `null` |
| `statusCode` | int | `200` | 100–599，必须是整数 |
| `delayMs` | int | `0` | 0–60000 |
| `headers` | object | `{}` | 值必须是字符串；默认已有 `content-type: application/json; charset=utf-8` |
| `body` | 任意 JSON | `null` | 整包替换时的响应体 |
| `patchBody` | object | `{}` | 字段路径 → 新值；非空时规则变为字段补丁 |

## 语义要点

- **顺序**：自上而下，第一条启用且命中的规则生效，不叠加。带 `params` 的精确规则要排在同接口的通用规则前面。
- **命中条件**：方法、路径完全相同；写了 `host` 时域名也相同；写了 `params` 时每个参数都相等。
- **`params`**：先查 URL query（有这个键就只看 query），再查 JSON / 表单请求体；嵌套字段写 `filter.id`、`items[0].id`。两边都按字符串比较；键缺失时不命中。请求里其他参数不影响。
- **`patchBody`**：照常请求真实接口，只改写响应 JSON 中的字段，状态码、响应头和其他字段保持真实；规则里的 `statusCode` / `headers` / `body` 不生效，`delayMs` 是拿到真实响应后的额外延迟。
  - 路径：`data.title`、`data.items[0].name`、`data.items[*].name`（每个元素）、`groups[*].items[*].name`、`[*].name`（根数组）。
  - 值整体替换，不合并；按书写顺序应用，可以先 `[*]` 批量改再 `[0]` 单独改。
  - 下标越界只跳过该路径；中间层不存在、类型不符或响应不是 JSON 时整个响应原样返回。
  - 依赖后端可用，不能用来模拟离线成功。
- **同一接口多个场景**：可以都写上，只把当前要测的设为 `enabled: true`，其他设为 `false`，用户在控制台里切换开关即可。

## 适配器限制

- `local_mock_dio`：整包替换只支持 `ResponseType.json`，其他响应类型命中会报错；状态码不满足 `validateStatus` 时与真实请求一样抛出 bad response 错误；`params` 还能匹配 `FormData` 的普通字段。
- `local_mock_http`：`HEAD` 以及 204 / 304 不返回响应体，这类规则 `body` 写 `null`。
- 整包替换返回 JSON 编码的 `body`，不能模拟二进制或文件下载；字段补丁只作用于 JSON 响应。

## 常见场景

| 场景 | 写法 |
| --- | --- |
| 正常数据 | `statusCode` 200，`body` 贴近真实 |
| 空数据 | 空数组、`null` 字段、分页 `total: 0` |
| 业务错误 | HTTP 200 + 项目约定的错误码 |
| HTTP 错误 | 401（登录失效）、403、404、500、503 |
| 慢接口 / 超时 | `delayMs` 大于客户端 `receiveTimeout`（上限 60000） |
| 界面边界 | 用 `patchBody` 改真实响应中的文本长度、数值、可选字段 |
| 只改一个对象 | `params: {"id": "123"}`，必要时再加 `patchBody` |

## 示例

```json
[
  {
    "id": "order-123-paid",
    "method": "GET",
    "path": "/v1/order/detail",
    "params": { "id": "123" },
    "patchBody": { "data.status": "PAID" }
  },
  {
    "id": "user-profile-ok",
    "method": "GET",
    "path": "/v1/user/profile",
    "host": "api.example.com",
    "delayMs": 300,
    "body": { "code": 0, "msg": "", "data": { "id": 1001, "name": "测试用户", "level": 10 } }
  },
  {
    "id": "user-profile-unauthorized",
    "enabled": false,
    "method": "GET",
    "path": "/v1/user/profile",
    "statusCode": 401,
    "body": { "code": 40101, "msg": "登录已失效" }
  },
  {
    "id": "album-long-names",
    "method": "GET",
    "path": "/v1/site/home",
    "patchBody": { "data.sitePhotoAlbumList[*].name": "很长很长很长很长的相册名称" }
  }
]
```

## 注意

- 使用虚构的姓名、手机号、地址；不要写入真实用户数据或真实 token。
- `id` 用短横线命名，能看出接口和场景，例如 `order-detail-not-found`。
