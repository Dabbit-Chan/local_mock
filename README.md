# local_mock

Flutter 调试期接口 Mock 工具。桌面端通过 Dart VM Service 把 Mock 规则直接下发到运行中的 App，不需要代理和证书，也不需要 Hot Reload，规则在下一次请求时生效。同时提供抓包能力：App 内经过适配器的请求会实时同步到桌面端，可以从单条请求一键生成 Mock 规则。

所有能力只在 Debug 模式下启用。Profile / Release 构建中不会注册 VM Service 扩展，也不会拦截任何请求。

## 仓库结构

| 目录 | 说明 |
| --- | --- |
| [`local_mock_desktop`](local_mock_desktop/README.md) | 桌面控制端（macOS / Windows），连接 VM Service 后编辑并下发规则 |
| [`local_mock_package/local_mock_core`](local_mock_package/local_mock_core/README.md) | 与 HTTP 客户端无关的核心：规则模型、匹配、VM Service 扩展协议 |
| [`local_mock_package/local_mock_dio`](local_mock_package/local_mock_dio/README.md) | Dio 4.x / 5.x 适配器（拦截器） |
| [`local_mock_package/local_mock_http`](local_mock_package/local_mock_http/README.md) | `dart:io` `HttpClient` 适配器（`HttpOverrides`），覆盖 `package:http` 等 |

## 工作原理

1. App 接入 `local_mock_dio` 或 `local_mock_http` 后，会在当前 isolate 注册 `ext.local_mock.getState` / `replaceRules` / `clear` / `getTraffic` / `clearTraffic` 五个 VM Service 扩展。
2. 桌面端连接 App 的 VM Service 地址，自动发现注册了扩展的 isolate。
3. 每次连接自动应用桌面端全部规则；新增、编辑保存和开关变更后也会自动同步，整体替换 App 内存中的规则表。命中规则的请求直接返回 Mock 响应，其余请求照常走网络。
4. 适配器同时会把经过的每条请求（含真实响应与 Mock 响应）记录到 isolate 内的环形缓冲区；桌面端切到“抓包”页后增量拉取展示。

## 快速开始

1. 在业务 App 中接入适配器（二选一或同时使用），详见各包 README：

   ```dart
   // Dio
   final dio = Dio();
   LocalMockDio.attach(dio);

   // dart:io HttpClient / package:http
   void main() {
     LocalMockHttp.install();
     runApp(const MyApp());
   }
   ```

2. 以 Debug 模式运行 App，从 `flutter run` 输出中复制 VM Service 地址：

   ```
   A Dart VM Service on iPhone is available at: http://127.0.0.1:12345/xxxxxx=/
   ```

   `http(s)://` 和 `ws(s)://` 开头的地址都可以，例如 `ws://127.0.0.1:12345/xxxxxx=/ws`，桌面端会自动转换为 WebSocket 地址并补全 `/ws`。注意要复制 VM Service 地址，不是 DevTools 页面地址。

3. 启动桌面端，粘贴地址并连接，规则会自动应用；编辑保存后也会自动同步：

   ```bash
   cd local_mock_desktop
   flutter run -d macos
   ```

## 抓包生成规则

连接后切换到“抓包”页，桌面端会实时同步 App 内经过 `local_mock_dio` / `local_mock_http` 的请求（未命中 Mock 规则的真实请求和 Mock 命中的请求都会记录）：

- 点击某条记录查看详情：完整 URL、请求体、状态码、耗时、响应体（JSON 自动格式化）。
- 点击记录右侧的闪电按钮（或详情弹窗里的“生成 Mock 规则”），会用该请求的 method / host / path / 状态码 / 响应体预填规则编辑弹窗，确认保存后规则进入本地规则列表，连接就绪时自动应用。
- 响应体是 JSON 时会解析为结构化 body；非 JSON 文本会作为字符串 body；二进制内容不会记录。
- 抓包记录只存在 App 内存中，不限制条数，请求/响应体完整保留。

## 规则格式

规则是一个 JSON 数组，第一条启用且匹配的规则生效：

```json
[
  {
    "id": "user-profile",
    "enabled": true,
    "method": "GET",
    "path": "/api/user/profile",
    "host": "api.example.com",
    "statusCode": 200,
    "delayMs": 300,
    "headers": { "x-mock": "1" },
    "body": { "name": "测试用户", "level": 10 }
  }
]
```

字段说明见 [`local_mock_core`](local_mock_package/local_mock_core/README.md#规则字段)。

### 用 AI 生成规则

仓库提供了 Agent Skill [`skills/local-mock-rules`](skills/local-mock-rules/SKILL.md)。它会根据业务代码中的接口定义和模型类生成规则，并用 `scripts/validate_rules.py` 校验格式。需要安装到业务 App 仓库或全局后使用：

```bash
# pi：作为 package 安装（自动发现 skills/ 目录），-l 表示只装到当前项目
pi install git:github.com/Dabbit-Chan/local_mock
pi install -l git:github.com/Dabbit-Chan/local_mock

# 其他支持 Agent Skills 的工具：复制到业务仓库或全局 skills 目录
git clone --depth 1 https://github.com/Dabbit-Chan/local_mock.git /tmp/local_mock
cp -R /tmp/local_mock/skills/local-mock-rules <业务仓库>/.agents/skills/   # 或 ~/.agents/skills/
```

不同工具的 skills 目录不同（如 Claude Code 为 `.claude/skills/`），按所用工具的约定放置即可。

## 注意事项

- 协议版本 v2（0.2.0+）：新版桌面端连接旧版 App 端（协议 v1）时会提示升级，不再兼容混用；请同时升级仓库内所有包。
- VM Service 地址带有鉴权 token，等同于 App 的调试权限，不要分享给他人。桌面端只保存规则草稿，不保存地址。
- 断开桌面端连接不会清空 App 规则；桌面端保留抓包记录供查看，下次连接时清空本地和 App 端抓包缓冲。Hot Restart 后抓包重新开始记录。
- 规则仅保存在 App isolate 内存中，冷启动时为空，不读取上一次运行的规则。
- Hot Restart 后，只有桌面端保持连接时，才会在发现新 isolate 后自动重新下发当前全部规则；未连接桌面端时，规则为空。重新连接桌面端也会自动应用当前全部规则。
