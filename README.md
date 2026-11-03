# local_mock

给 Flutter App 用的接口 Mock 与抓包工具。App 在 Debug / Profile 包里主动连接一个 Relay，把经过适配器的请求实时上报；你在浏览器里的控制台查看请求、编写规则，规则下发到 App 后在 App 内部匹配生效。没有命中规则的请求照常访问真实网络。

```
 ┌──────────────┐   wss /ws/app    ┌──────────────┐  wss /ws/console  ┌──────────────┐
 │  Flutter App │ ───────────────▶ │    Relay     │ ◀──────────────── │  Web 控制台  │
 │  + 适配器    │  上报请求 / 接收规则 │ (Dart 进程)  │  查看请求 / 下发规则 │  (浏览器)    │
 └──────────────┘                  └──────────────┘                   └──────────────┘
```

- **不需要代理或证书**：拦截发生在 App 的 HTTP 客户端里（Dio 拦截器 / `HttpOverrides`）。
- **规则在 App 内存里生效**：控制台关掉后规则仍然有效；App 冷启动后由 Relay 自动恢复。
- **Release 包完全禁用**：`LocalMock.enabled` 等于 `!kReleaseMode`，Release 构建里所有入口都是空操作。

## 能做什么

| 场景 | 做法 |
| --- | --- |
| 接口还没好，先用假数据开发 | **整包替换**：命中后不访问网络，直接返回规则里的状态码、响应头和响应体 |
| 验证超长文本、极端数值等界面边界 | **字段补丁**：照常请求真实接口，只改写响应 JSON 中的几个字段 |
| 只改某一个订单、某一种传参 | **参数条件**：规则只在指定 query / 请求体参数相等时命中 |
| 离线复现一整条操作流程 | **录制** 一段操作，再把它生成为 **录制组**，整组开关 |
| 看 App 实际发了什么、收到了什么 | 控制台的 **请求** 列实时显示，可筛选、查看请求体和响应体 |

## 快速开始

### 1. 启动 Relay 和控制台

Relay 是 `local_mock_client/tool/relay_host.dart`，它同时托管控制台网页和两个 WebSocket 入口。

```bash
cd local_mock_client
flutter pub get
flutter build web --no-web-resources-cdn
dart run tool/relay_host.dart 9090        # 端口可改
```

浏览器打开 <http://127.0.0.1:9090/>。控制台会自动连接提供它的这个 Relay，断开后每 2 秒重连，不需要填写地址。

> 用 `flutter run -d chrome` 打开的页面只能预览界面：Flutter 开发服务器不是 Relay，页面会一直处于“正在连接”。

### 2. 让手机访问到 Relay

手机访问不到电脑上的 `127.0.0.1`。同一局域网可以直接用电脑的局域网 IP；否则用隧道暴露一个 HTTPS 地址，例如：

```bash
cloudflared tunnel --url http://127.0.0.1:9090
# 输出类似 https://example.trycloudflare.com
```

### 3. 在 App 中接入

按所用的 HTTP 客户端选择适配器：

- Dio 4.x / 5.x → [`local_mock_dio`](local_mock_package/local_mock_dio/README.md)
- `HttpClient` / `package:http` → [`local_mock_http`](local_mock_package/local_mock_http/README.md)

在 App 的 `pubspec.yaml` 中添加所选适配器，然后运行 `flutter pub get`。例如使用 Dio：

```yaml
dependencies:
  dio: ^5.0.0
  local_mock_dio: ^1.0.0
```

使用 `HttpClient` / `package:http` 时，添加 `local_mock_http: ^1.0.0`。`local_mock_core` 和 `local_mock_transport` 会自动作为依赖引入。

```dart
import 'package:local_mock_dio/local_mock_dio.dart';

void setUpLocalMock(Dio dio, String installationId) {
  LocalMockDio.attach(dio);              // 或 LocalMockHttp.install();
  LocalMock.connect(
    serverUrl: 'https://example.trycloudflare.com',
    deviceId: installationId,            // 每个 App 安装唯一且稳定
    deviceName: 'QA Android',            // 显示在控制台设备列表里
  );
}
```

`serverUrl` 写 Relay 的 http(s) 地址即可，会自动转换为 `ws(s)://…/ws/app`。也可以在构建时注入：

```bash
flutter build apk --profile --dart-define=LOCAL_MOCK_SERVER=https://example.trycloudflare.com
```

```dart
LocalMock.connect(
  serverUrl: const String.fromEnvironment('LOCAL_MOCK_SERVER'),
  deviceId: installationId,
);
```

`connect` 立即返回，连接在后台建立，失败时每 2 秒重试，不会阻塞 App 启动或业务请求。

### 4. 在控制台中调试

App 连上后出现在首页的设备列表里，点击进入该设备的调试页。调试页分三列，同时可见：

| 列 | 内容 |
| --- | --- |
| **01 规则** | 设备上的规则列表，自上而下匹配。可开关、拖动排序、删除；更多菜单里有导入 / 导出规则文件和“从录制生成录制组” |
| **02 请求** | App 发出的请求，最新的在上面。可按文本筛选，或只看 Mock / 异常请求；在这里开始和停止录制 |
| **03 详情** | 选中请求时显示完整 URL、Query、请求体和响应体；选中规则时就是规则编辑器 |

所有修改（保存、开关、删除、排序、导入）都会立即同步到设备，从设备的下一个请求开始生效。顶栏显示设备是否已确认。

## 规则

一条规则描述“哪些请求”以及“返回什么”。完整字段与匹配细节见 [`local_mock_core` 的规则参考](local_mock_package/local_mock_core/README.md#规则参考)。

```json
{
  "id": "user-profile",
  "method": "GET",
  "path": "/api/user/profile",
  "host": "api.example.com",
  "statusCode": 200,
  "delayMs": 300,
  "body": { "name": "测试用户", "level": 10 }
}
```

- **匹配**：方法和路径必须完全相同；`host` 不填则不限域名。路径不支持通配符。
- **顺序**：自上而下找第一条启用且命中的规则，规则之间不叠加。精确的规则（带参数条件）要排在同接口的通用规则前面。
- **参数条件** `params`：`{"id": "123"}` 只命中 `id` 为 123 的请求。先查 URL query，再查 JSON 或表单请求体，嵌套字段写成 `filter.id`。
- **字段补丁** `patchBody`：`{"data.items[*].name": "很长的名称"}` 会照常请求真实接口，只改这个字段，状态码和其他字段保持真实。补丁路径不适用（父级不存在、类型不符、响应不是 JSON）时，原样返回真实响应。

控制台的规则编辑器把“整包替换”和“字段补丁”做成二选一：选择补丁时，规则里保存的状态码、响应头和响应体会被保留但不生效，切回整包替换即可恢复。

## 录制与录制组

1. 在调试页的 **请求** 列点击“录制”，起个名字后开始。
2. 在 App 里完成要复现的操作。只收录 **开始之后完成** 的请求，不受设备 500 条缓冲的限制。
3. 点击“停止并保存”。录制保存在当前浏览器（localStorage），首页的“录制”列可以查看、导出、删除，打开后可以离线浏览每个请求。
4. 在 **规则** 列的更多菜单中选择“从录制生成录制组”。一段录制生成 **一个** 录制组：
   - 每个不同的请求（方法 + 域名 + 路径 + 传参）对应组内一个接口；同一请求录到多次时保留最后一次的响应。
   - “只匹配录制时的传参”关闭时只看方法、域名和路径；打开时 query 和请求体也要与录制时一致（JSON 键顺序、表单键顺序不影响）。
   - 组内接口可以单独开关、排序、编辑；接口的修改先保存在录制组草稿里，保存录制组时才同步。
   - 同一段录制再次生成时会打开已有的录制组，保留之前的编辑。
5. 录制组和普通规则在同一个列表里排序，同样遵循“第一条命中生效”。每次命中都返回同一份响应，**不会按调用次数轮换**。

不会生成接口的请求：失败的请求、没有记录到响应体的请求（HEAD、204、304 除外）、二进制响应、无法还原的请求体（如 FormData）。它们仍可在录制里查看。

需要注意：

- 录制期间保持控制台页面打开、设备在线。设备离线、Relay 断开或 App 重启都会结束录制，已收到的请求会自动保存。
- 浏览器存储写入失败时，录制留在页面内存里，可以“重试保存”或“导出文件”；刷新页面会丢失。
- 录制按浏览器和地址（含端口）隔离。换浏览器、换端口或换隧道地址前，先导出文件再导入。
- 录制组需要 App 使用当前版本的 `local_mock_core` 和适配器，旧版本的设备不能接收录制组。

## 生命周期

| 事件 | 结果 |
| --- | --- |
| 关闭控制台页面 | App 内规则继续生效 |
| App 断线后重连（同一 `deviceId`） | Relay 把它最后确认的规则推回 App |
| App 冷启动 / Hot Restart | 内存规则清空；重新调用 `connect` 后由 Relay 恢复，恢复前的请求不会被 Mock |
| Relay 进程重启 | Relay 内存清空；App 重连后以 App 当前的规则为准 |
| 同一 `deviceId` 被另一个正在运行的 App 使用 | Relay 拒绝后来的连接 |

App 和 Relay 各保留每台设备最近 500 条请求。App 重连时会补发缓冲并按序号去重；App 重启后使用新的会话，旧记录不会混入。

## 覆盖范围与限制

- 只覆盖经过适配器的请求。原生 SDK、WebView、平台通道里的网络请求不会被看到或 Mock。
- 二进制响应只记录大小，不记录内容。
- Dio 的整包替换只支持 `ResponseType.json`；其他响应类型命中整包规则会返回错误。字段补丁只作用于 JSON 响应。
- **没有任何鉴权**。能访问 Relay 地址的人都能看到请求内容并修改规则。只在本地或临时隧道中使用，不要把 Relay 暴露在公网上长期运行。请求、录制文件和浏览器存储都未加密，可能包含账号、令牌等敏感信息，分享前请检查。

## 仓库结构

| 目录 | 内容 |
| --- | --- |
| [`local_mock_client`](local_mock_client/README.md) | Web 控制台（Flutter Web）和 Relay 启动脚本 |
| [`local_mock_package/local_mock_core`](local_mock_package/local_mock_core/README.md) | 规则模型与匹配、请求记录、录制、App 连接入口 |
| [`local_mock_package/local_mock_dio`](local_mock_package/local_mock_dio/README.md) | Dio 4.x / 5.x 适配器 |
| [`local_mock_package/local_mock_http`](local_mock_package/local_mock_http/README.md) | `HttpClient` / `package:http` 适配器 |
| [`local_mock_package/local_mock_transport`](local_mock_package/local_mock_transport/README.md) | App、Relay、控制台之间的 WebSocket 协议 |
| [`skills/local-mock-rules`](skills/local-mock-rules/SKILL.md) | 让 AI 助手按项目代码生成并校验规则文件的 Skill |

## 开发

```bash
cd local_mock_client
flutter analyze
flutter test
flutter build web --no-web-resources-cdn
```

各包在自己的目录下运行 `flutter test`。控制台的浏览器测试见 [`local_mock_client/README.md`](local_mock_client/README.md#测试)。
