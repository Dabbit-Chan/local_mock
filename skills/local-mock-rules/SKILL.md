---
name: local-mock-rules
description: 为 local_mock 生成 Mock 规则 JSON 对象（粘贴到 local_mock_client 编辑器的规则数组中下发到 App）。当用户要求 mock 接口、构造假数据、模拟错误码 / 超时 / 空列表等场景，或要求编写、修改、校验 local_mock 规则时使用。
---

# 生成 local_mock 规则

产出物是一条或多条规则的 JSON 对象（map），不要包裹成 JSON 数组（list）。用户会把它们粘贴到 local_mock_client 编辑器已有的规则数组 `[...]` 中，点击“应用到手机”后生效。

## 流程

1. 确定要 mock 的接口：HTTP 方法、完整请求路径、（可选）host。
   - 用户给了业务代码时，从接口定义里找：`dio.get/post(...)`、Retrofit 注解、`http.get(Uri.parse(...))` 等。
   - 路径要拼上 `baseUrl` 里的路径部分：`baseUrl: 'https://api.example.com/v1'` + `'/user'` 的规则 `path` 是 `/v1/user`。
   - 路径中的动态参数要替换成具体值（如 `/api/order/123`），规则不支持通配符或正则。
2. 确定响应体结构：优先参考项目里的模型类（`fromJson`、`json_serializable`、`freezed` 等）和已有的接口文档，字段名、类型、嵌套结构、通用外层包装（如 `{"code":0,"msg":"","data":{...}}`）都要与之一致。找不到依据时，向用户确认或在回复中说明是推测的。
3. 按用户要测的场景生成规则（见下方“常见场景”）。
4. 写好后用校验脚本检查，再交给用户：

   ```bash
   python3 <skill 目录>/scripts/validate_rules.py rules.json
   # 或从标准输入读取
   echo '{...}, {...}' | python3 <skill 目录>/scripts/validate_rules.py
   ```

   脚本接受单个对象、逗号分隔的多个对象或数组。

5. 回复中把所有规则放在一个 `json` 代码块里：每条规则是一个 JSON 对象，多条之间用逗号分隔，最外层不加 `[` `]`。然后简要说明每条规则覆盖的场景。

## 规则字段

| 字段 | 类型 | 必填 | 默认值 | 约束 |
| --- | --- | --- | --- | --- |
| `id` | string | 是 | | 非空，不能与编辑器中已有规则重复 |
| `enabled` | bool | 否 | `true` | |
| `method` | string | 是 | | 只能是 ASCII 字母，大小写不敏感 |
| `path` | string | 是 | | 以 `/` 开头，不能含 `?` 或 `#` |
| `host` | string | 否 | 不限 host | 非空字符串，大小写不敏感，不含端口 |
| `statusCode` | int | 否 | `200` | 100..599，必须是整数（不能写 `200.0`） |
| `delayMs` | int | 否 | `0` | 0..60000 |
| `headers` | object | 否 | `{}` | 值必须是字符串 |
| `body` | 任意 JSON | 否 | `null` | 作为 JSON 响应体 |
| `params` | object | 否 | `{}` | 参数子集匹配，值为字符串 / 数字 / 布尔值 / null，统一转字符串比较 |
| `patchBody` | object | 否 | `{}` | 字段路径到新值的映射；非空时只修改真实 JSON 响应中的这些字段 |

## 匹配语义

- 按数组顺序匹配，第一条 `enabled` 且 `method`、`path`、`host`（如设置）、`params`（如设置）全部匹配的规则生效，不叠加。
- `params` 不填时忽略参数；填写 `{"id":"123"}` 可只修改一个 ID 的响应。指定键先查 URL query，再查 JSON / URL 编码表单请求体，支持嵌套请求体路径；同名 query 优先。多条件全满足、额外参数不限，缺失键不匹配 null。
- 用 `patchBody: {"data.product": {...}}` 固定不同订单中的商品，但保留各自状态；用 `params` + `patchBody` 仅补丁指定 ID。路径支持 `data.items[0].name`，数组 / 对象的值整体替换。父级不存在、类型不符、数组越界或非 JSON 时保留整个真实响应。
- 非空 `patchBody` 仍会访问真实后端，忽略规则中的 `body`、`statusCode`、`headers`；真实 HTTP 状态码和其他字段不变。`delayMs` 是得到真实响应后的额外延迟。补丁依赖后端可用，不能用来模拟离线成功。
- 同一接口的多个场景可以一起输出，只把要测的那条设为 `enabled: true`，其余设为 `false`。
- 默认响应头为 `content-type: application/json; charset=utf-8`，一般不用写 `headers`。
- 用户粘贴到已有数组中时，新规则和已有规则一起参与匹配；排在前面的同接口规则会先命中。

## 适配器限制

- `local_mock_dio`：整包替换只支持 `ResponseType.json`，补丁对其他响应类型直接透传；非 2xx（或不满足 `validateStatus`）会像真实请求一样抛出 bad response 错误，`response.extra['local_mock_rule_id']` 可用于确认命中。参数匹配也支持 `FormData` 普通字段。
- `local_mock_http`：`HEAD` 请求以及 `204` / `304` 状态码不返回响应体，这类规则的 `body` 写 `null` 即可。
- 整包 Mock 响应体以 JSON 编码返回，无法 mock 二进制、文件下载或非 JSON 文本；字段补丁仅适用于 JSON，其他响应原样透传。

## 常见场景

- 正常数据：`statusCode` 200，`body` 填写贴近真实的数据。
- 空数据：空数组、`null` 字段、分页 `total: 0`。
- 业务错误：HTTP 200 + 业务错误码（按项目的外层包装约定）。
- HTTP 错误：401（登录失效）、403、404、500、503 等。
- 慢接口 / 超时：设置 `delayMs`，大于客户端 `receiveTimeout` 即可模拟超时（上限 60000）。
- 边界数据：超长文本、特殊字符、极大数值、缺省可选字段。

## 示例

```json
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
  "id": "order-list-timeout",
  "method": "POST",
  "path": "/v1/order/list",
  "delayMs": 30000,
  "body": { "code": 0, "data": { "list": [], "total": 0 } }
}
```

## 注意

- 示例数据使用虚构的姓名、手机号、地址等，不要填入真实用户信息或真实 token。
- `id` 用能看出接口和场景的短横线命名，如 `order-detail-not-found`。
