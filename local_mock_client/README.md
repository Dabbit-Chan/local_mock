# local_mock_client

local_mock 的 Web 控制台和 Relay。使用方法见[根目录 README](../README.md)，这里说明这个包本身：怎么运行、代码怎么组织、界面遵循什么约定。

## 运行

```bash
flutter pub get
flutter build web --no-web-resources-cdn
dart run tool/relay_host.dart 9090
```

打开 <http://127.0.0.1:9090/>。

`tool/relay_host.dart` 是一个独立的 Dart 进程：

- `GET /…` 托管 `build/web` 里的控制台（每次请求从磁盘读取，重新 `flutter build web` 后刷新页面即可）；
- `/ws/app` 接收 App 连接，`/ws/console` 接收控制台连接；
- 在内存里保存每台设备最后确认的规则和最近 500 条请求。

控制台总是连接 **提供它的那个地址**（`Uri.base.origin`），所以页面本身没有地址输入框，构建时也不需要 `--dart-define`。`LOCAL_MOCK_SERVER` 只给 App 用。

Relay 默认只监听 `127.0.0.1`。部署到服务器或容器时可以用环境变量调整：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `LOCAL_MOCK_HOST` | `127.0.0.1` | 监听地址，`0.0.0.0` 表示允许其他机器访问 |
| `LOCAL_MOCK_WEB_DIR` | `build/web` | 控制台网页所在目录 |

部署时不需要 Dart 环境，可以交叉编译成可执行文件：`dart compile exe tool/relay_host.dart --target-os=linux --target-arch=x64 -o local_mock_relay`。Relay 没有鉴权，只应在内网访问。

只调界面时可以 `flutter run -d chrome`，但开发服务器不是 Relay，页面会一直显示“正在连接 Relay”。需要真实数据时用 Relay 托管的构建。

## 页面

路由使用 `go_router` 的 hash 模式，任何静态服务器都能直接打开深链接。

| 路由 | 页面 | 内容 |
| --- | --- | --- |
| `/#/` | `HomePage` | 01 设备列表（在线 / 离线，点击进入调试）· 02 本地录制；没有设备时显示接入步骤和当前 Relay 地址对应的 `LocalMock.connect` 代码 |
| `/#/devices/:deviceId` | `DevicePage` | 三列工作区：01 规则 · 02 请求 · 03 详情（请求详情 / 规则编辑器 / 录制组编辑器） |
| `/#/recordings/:id` | `RecordingPage` | 离线查看一段录制：概要、请求列表、请求详情，可导出或删除 |

调试页的路由参数就是设备 ID。打开时如果该设备在线，控制台会自动切换到它；Relay 重连后也会自动切回。设备离线时保留断开前的规则和请求，并在页面顶部说明。

界面按浏览器全屏设计（建议宽度 ≥ 1280px），不考虑窄屏。

## 代码结构

```
lib/
  main.dart                    入口
  src/
    app.dart                   LocalMockApp、路由、AppServices、页面框架（顶栏）
    mock_connection.dart       控制台到 Relay 的连接：设备列表、选择设备、同步规则、请求流、录制
    rule_book.dart             当前设备的有序规则列表；每次修改都推送到设备
    recording_library.dart     浏览器内保存的录制；录制结束后自动保存
    rule_drafts.dart           从请求 / 录制生成规则草稿
    capture_session_store*.dart  录制的 localStorage 读写和文件导入导出
    rule_file_transfer*.dart   浏览器文件选择与下载
    preferences*.dart          外观偏好的持久化
    format.dart                时间、JSON、错误信息格式化
    pages/                     三个路由页面
    panes/                     调试页的各列：规则、请求、请求详情、规则编辑器、录制组编辑器
    ui/
      theme.dart               设计令牌（Palette、Space）和 ThemeData
      primitives.dart          基础组件：分隔线、标签、方形开关、列表行、提示条、确认框
      code_panel.dart          基于 re_editor 的 JSON 查看 / 编辑器
```

状态分两层：

- **页面级服务**（`AppServices`，经 `AppScope` 提供）：`MockConnection`、`RuleBook`、`RecordingLibrary`、`ThemeController`。它们在整个页面生命周期内存在，所以录制可以在页面之间切换时继续进行。
- **调试页本地状态**：第 03 列当前显示什么（`Inspect`），以及编辑器里是否有未保存的修改。切换选中项前如果有未保存修改，会先确认。

规则编辑的并发保护：保存时按对象身份查找原规则。如果设备在编辑期间推送了新的规则列表，保存会失败并提示重新打开；如果编辑器没有改动，会自动切换到设备的新版本。

## 界面约定

风格是 Swiss International Style：

- **网格与分栏**：页面按 12 列分配（首页 8 / 4，调试页 3 / 4 / 5），栏间用 1px 细线分隔，不使用卡片和阴影。
- **字体**：Inter（界面）和 JetBrains Mono（代码、路径、时间），随包打包在 `assets/fonts`，中文回退到系统字体。左对齐，大字号标题，章节用 `01` `02` `03` 编号。
- **颜色**：墨色与纸色两种中性色，加一个信号红。红色只用于“正在发生或需要注意”的东西：录制中、Mock 响应、错误、品牌标记。
- **形状**：所有元素直角。开关、筛选按钮、模式切换都是方形。
- **明暗模式**：顶栏右侧按钮在“跟随系统 / 浅色 / 深色”之间切换，选择保存在 localStorage。两套配色定义在 `Palette.light` / `Palette.dark`。

所有 JSON 的展示与编辑都使用 `CodePanel`（[re_editor](https://pub.dev/packages/re_editor)）：语法高亮、行号、折叠、查找（⌘/Ctrl F）、右键菜单、格式化，以及输入时的 JSON 校验（错误定位到行列）。编辑器中按 ⌘/Ctrl S 保存。

新增界面时：间距用 `Space` 中的常量，颜色从 `context.palette` 取，不直接写颜色值；列表行用 `ListRow`，空状态用 `EmptyState`，需要用户确认的破坏性操作用 `confirm(..., destructive: true)`。

## 测试

```bash
flutter analyze
flutter test
```

- `test/device_page_test.dart`、`test/home_and_recordings_test.dart`：界面行为，使用 `test/support/harness.dart` 中的 `FakeConnection`（一台就绪的设备 `phone`，记录推送的规则）。
- `test/rules_logic_test.dart`：`RuleBook` 和规则草稿的逻辑。
- `test/mock_connection_test.dart`、`test/http_outbound_connection_test.dart`：启动真实 Relay，验证连接、同步、重连和请求流。

浏览器平台的测试：

```bash
# 录制在 localStorage 中的持久化
flutter test --platform chrome test/capture_session_browser_test.dart

# 浏览器连接真实 Relay（先启动 dart run tool/relay_host.dart 9090）
flutter test --platform chrome test/browser_connection_test.dart \
  --dart-define=LOCAL_MOCK_TEST_SERVER=http://127.0.0.1:9090
```
