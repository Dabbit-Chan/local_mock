# local_mock

Flutter 接口 Mock 与请求抓包工具。目标 App 主动通过 WebSocket 连接本地 relay，上报经过适配器的请求；Web 控制台连接同一个 relay，选择设备后编辑并下发 Mock 规则。规则在 App 内匹配，未命中的请求继续访问真实业务 API。

当前可行性测试只保留 Web：`local_mock_client` 是 Flutter Web 控制台，不再提供 macOS / Windows 应用，也不使用独立的 `local_mock_server` 项目。

## 构建模式

| 目标 App 模式 | 行为 |
| --- | --- |
| Debug | 默认启用拦截与记录；调用 `LocalMock.connect` 后主动连接 |
| Profile | 默认启用拦截与记录；调用 `LocalMock.connect` 后主动连接 |
| Release | 始终禁用 |

## 仓库结构

| 目录 | 说明 |
| --- | --- |
| [`local_mock_client`](local_mock_client/README.md) | Flutter Web 控制台、WebSocket relay 启动脚本、规则编辑和抓包界面 |
| [`local_mock_package/local_mock_transport`](local_mock_package/local_mock_transport/README.md) | App 与 Web 控制台共用的 WebSocket 协议 |
| [`local_mock_package/local_mock_core`](local_mock_package/local_mock_core/README.md) | 规则模型、匹配、流量记录和 App 连接入口 |
| [`local_mock_package/local_mock_dio`](local_mock_package/local_mock_dio/README.md) | Dio 4.x / 5.x 适配器 |
| [`local_mock_package/local_mock_http`](local_mock_package/local_mock_http/README.md) | `dart:io HttpClient` / `package:http` 适配器 |

## 本地可行性测试

Flutter Web 页面本身不能监听来自手机的 WebSocket，所以不能把 `flutter run -d chrome` 的开发服务器直接当成 App 接入端。项目提供了同一 `local_mock_client` 目录下的 Dart relay 启动脚本；它同时托管 `build/web` 和 `/ws/app`、`/ws/console`，不是独立的服务项目。

终端一：构建 Web 并启动 relay：

```bash
cd local_mock_client
flutter pub get
flutter build web --no-web-resources-cdn
dart run tool/relay_host.dart 9090
```

终端二：打开控制台：

```text
http://127.0.0.1:9090/
```

终端三：你自己启动 cloudflared：

```bash
cloudflared tunnel --url http://127.0.0.1:9090
```

假设 cloudflared 输出：

```text
https://example.trycloudflare.com
```

目标 App 直接使用这个 HTTPS 地址：

```dart
LocalMock.connect(
  serverUrl: 'https://example.trycloudflare.com',
  deviceId: installationId,
  deviceName: 'QA Android',
);
```

地址会自动转换为：

```text
App:      wss://example.trycloudflare.com/ws/app
Web:      wss://example.trycloudflare.com/ws/console
```

**不需要访问令牌。** 这是当前本地可行性测试协议，任何能访问该隧道的人都可以连接和修改 Mock 规则，因此不要把隧道地址用于正式环境。

如果只运行 `flutter run -d chrome`，它只能提供 Web 页面；要让 App 连接，必须让 cloudflared 指向 `tool/relay_host.dart` 监听的端口，而不是 Flutter 开发服务器端口。

## 目标 App 接入

业务 App 先按适配器 README 配置依赖。尚未发布的包需要同时指定 `local_mock_core` 和 `local_mock_transport` 的 git / path 来源，业务项目不能依赖本仓库内的 `pubspec_overrides.yaml` 自动生效。

Dio 示例：

```dart
import 'package:dio/dio.dart';
import 'package:local_mock_dio/local_mock_dio.dart';

void configureQaTools(Dio dio, String installationId) {
  LocalMockDio.attach(dio);
  LocalMock.connect(
    serverUrl: const String.fromEnvironment('LOCAL_MOCK_SERVER'),
    deviceId: installationId,
    deviceName: 'QA Android',
  );
}
```

使用 `package:http` / `HttpClient` 时，在创建业务客户端之前调用 `LocalMockHttp.install()`，再以相同方式调用 `LocalMock.connect(...)`。网络不可用时连接在后台重试，不阻塞业务请求；服务地址也可以由 App 的测试入口在运行时提供。

Profile QA 包的构建示例：

```bash
flutter build apk --profile
```

也可以把服务地址作为默认配置：

```bash
flutter build apk --profile \
  --dart-define=LOCAL_MOCK_SERVER=https://example.trycloudflare.com
```

手机必须能访问 cloudflared 地址。HTTPS 页面 / 地址对应 WSS；目标 App 不要使用电脑的 `localhost`。本地测试的明文 WS 仅适用于 `http://` relay 地址，Android 配置还需要允许对应明文连接。

## 使用与生命周期

1. App 启动后主动连接，失败时每 2 秒重试，不阻塞业务启动或真实网络请求。
2. Web 控制台部署后打开即自动连接同源 relay 开始监听，连接失败或断开时每 2 秒自动重连，无需手动输入地址；只有一台在线设备时自动选中，多台时从下拉框选择。
3. 保存、开关、删除、排序变更后自动下发，等待 App 确认后生效。
4. 抓包持续由 App 上报，页面切换不停止记录；可筛选、查看详情并从请求生成规则。
5. 每台设备保留最近 500 条抓包记录。App 重连会补发缓冲并去重；App 重启使用新的会话，避免旧序号污染新记录。
6. Web 页面断开不会清空 App 内规则。relay 进程重启后内存状态丢失；App 重新连接后会重新上报当前规则和缓冲。
7. `deviceId` 必须对每个 App 安装唯一；同一个设备 ID 的多个在线连接会被拒绝。

抓包覆盖经过已接入 Dio / `HttpClient` 适配器的请求，不覆盖原生 SDK 或 WebView 的独立网络栈。二进制响应只记录大小占位信息。

## 录制与回放

1. 在“抓包”页选择在线设备，点击“开始录制”并输入场景名称。
2. 在 App 中执行需要保存的操作。录制独立收集开始后、停止前**完成**的请求，不包含开始前已有的历史记录，也不受实时列表最近 500 条的限制；开始前发出、录制期间完成的请求会计入，停止时尚未完成的请求不计入。切换到规则页不会中断录制。
3. 点击“停止并保存”，会话自动保存到当前浏览器。下次打开同一来源的页面，从“实时抓包”下拉框选择录制即可离线查看、筛选和打开请求详情。
4. 点击“导出录制”可保存 JSON 文件，用于备份或分享；“导入录制”会完整校验文件，取消或文件无效不会修改已有会话。同一 ID 不会重复导入。需要跨浏览器、端口或 cloudflared 地址使用时，请导出后再导入。
5. 选择已保存会话，点击“回放 / 配置 Mock”，打开**录制 Mock 配置**弹窗。整段录制生成规则页中的一个 Mock 组，而不是临时的顺序响应播放器；同一录制再次配置时会复用已有组及其编辑，不重复创建。
6. 在一级弹窗选择“只 Mock 录制时的传参”：关闭时忽略录制的 query / 请求体，仅按方法、域名和路径匹配；开启时还需与录制的 query 和请求体一致。query 键顺序、JSON 对象键顺序及普通表单键顺序不影响匹配。
7. 一级弹窗可修改组名、整组开关、接口开关、删除接口或拖动调整优先级；点击接口的编辑按钮打开**二级规则编辑弹窗**，修改方法、域名、路径、录制参数、状态码、延迟、响应头和响应体，也可配置字段补丁。二级保存仅更新组内草稿，一级保存后才提交；任一级取消均不把该级草稿应用到手机。
8. 保存后在“Mock 规则”页以**一个录制 Mock 卡片**管理，支持整组开关、编辑、删除、拖动排序，连接就绪时自动同步。通过“导出规则 / 导入规则”备份编辑后的组；“导出录制”保留原始抓包，不会被 Mock 编辑改写。

录制 Mock 与普通规则共用一个有序规则列表：按顶层卡片顺序、再按组内接口顺序，第一条启用且匹配的规则生效。生成时同一方法 / 域名 / 路径 / 传参的重复请求保留最后一次开始的请求响应；**不会按请求次数依次切换响应**。忽略录制参数后同一接口可能有多条规则，由组内顺序决定。默认使用录制状态码、Content-Type、文本和耗时（每条最多 60 秒），之后可编辑。未命中任何规则的请求仍走真实网络，不会自动重发录制中的请求。

注意：

- 需要同时更新 Web 控制台、relay、目标 App 的 `local_mock_core` 和所用适配器。旧 App 可继续抓包，但不能应用录制 Mock 组。Dio 仍只支持 `ResponseType.json` 的整包 Mock；`HttpClient` 支持已记录的文本响应。
- 失败请求、未捕获响应体的请求、二进制占位响应和不可还原的请求体（如 FormData 占位符）会保留用于查看，但不参与回放（HEAD / 204 / 304 等无响应体场景除外）；不恢复未记录的响应头或二进制内容。
- 录制期间须保持页面打开且设备在线。设备 / 服务断开或 App 会话变化会停止录制，已收到的记录自动保存；禁止录制中切换设备，避免混入另一台设备。不会补录断开期间的请求。
- 浏览器空间不足或禁用存储时，未保存的录制仍保留在当前页面，可重试保存或“导出未保存录制”。刷新或关闭页面会丢失未保存内容；清理浏览器站点数据会删除本地会话，重要录制请导出备份。
- 浏览器断开不会关闭已在 App 启用的录制 Mock 组；和普通规则一样，相同设备重新连接时 relay 恢复最后确认的规则，relay 重启则依靠 App 内存状态。关闭对应录制 Mock 卡片即可停止该组 Mock。
- 请求和响应可能含账号、令牌及业务敏感数据，录制文件和浏览器存储未加密，分享前请自行检查。

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

### 只修改真实响应中的字段

在规则编辑器的“字段补丁（可选）”中填写字段路径和新值。例如，让不同订单都显示同一个商品，但保留各自真实的订单状态：

```json
{
  "id": "order-same-product",
  "method": "GET",
  "path": "/api/order/detail",
  "patchBody": {
    "data.product": { "id": 1001, "name": "测试商品", "price": 99 }
  }
}
```

补丁模式仍会访问真实接口；只替换 `data.product`，其他字段和 HTTP 状态码保留。支持 `data.items[0].name` 这样的数组路径，也支持 `data.items[*].name` 批量修改所有元素。填写非空 `patchBody` 后，规则里的 `body`、`statusCode` 和 `headers` 不生效；`delayMs` 是取得真实响应后的额外延迟。

例如，下面填写在“字段补丁（可选）”中，就会修改所有相册名，同时修改标题：

```json
{
  "data.sitePhotoAlbumList[*].name": "很长很长的相册名",
  "data.siteBaseInfo.title": "测试标题很长很长很长"
}
```

`[*]` 支持嵌套数组；空数组不修改。数组下标越界时只跳过对应路径 / 分支，其他补丁继续生效，不会扩展数组。例如只有 4 个相册时，`data.sitePhotoAlbumList[9].name` 会被跳过，但标题和其他相册的修改仍然保留。多个路径按填写顺序应用，可先用 `[*]` 批量修改，再用 `[0]` 单独覆盖第一个。接口不是 JSON、补丁父级不存在或类型不符时，仍保留整个原始响应。

### 只修改某个参数对应的返回值

在“参数匹配（可选）”中填写 `{"id": "123"}`。只有这个 ID 命中，其他 ID 正常访问后端；不必列出其他请求参数。参数先从 URL query 查找，再从 JSON / URL 编码表单请求体查找，多个条件必须全部满足。

```json
{
  "id": "order-123-only",
  "method": "GET",
  "path": "/api/order/detail",
  "params": { "id": "123" },
  "body": {
    "code": 0,
    "data": { "id": "123", "status": "PAID", "product": { "name": "仅此订单替换" } }
  }
}
```

两种能力可以组合：在同一条规则里同时填写 `params` 和 `patchBody`，就能只修改某个 ID 的某些响应字段。规则仍然是“第一条匹配生效”，请把精确参数规则放在同接口的通用规则前面。

旧规则不填这两个字段时行为不变。使用新功能需要同时更新控制台和目标 App 的 core / 适配器代码，仅更新 Web 页面不够。

## 验证

```bash
cd local_mock_client
flutter analyze
flutter test
flutter build web --no-web-resources-cdn
```

浏览器网络用例需要 relay 已启动：

```bash
flutter test --platform chrome test/browser_connection_test.dart \
  --dart-define=LOCAL_MOCK_TEST_SERVER=http://127.0.0.1:9090
```

仓库还提供 [`skills/local-mock-rules`](skills/local-mock-rules/SKILL.md) 用于生成和校验规则。
