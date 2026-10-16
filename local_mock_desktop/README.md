# local_mock_desktop

local_mock 的桌面控制端（macOS / Windows）。通过 Dart VM Service 连接调试中的 Flutter App，编辑并下发 Mock 规则。

## 运行

```bash
flutter pub get
flutter run -d macos     # 或 -d windows
```

打包：

```bash
flutter build macos
flutter build windows
```

依赖通过相对路径引用 `../local_mock_package/local_mock_core`，需要保持仓库目录结构。

## 使用

1. 业务 App 以 Debug 模式运行，并已接入 `local_mock_dio` 或 `local_mock_http`。
2. 把 `flutter run` 输出的 VM Service 地址粘贴到“VM Service 地址”输入框，点击“连接”。
   - 支持 `http(s)://` 和 `ws(s)://` 两种形式，会自动转换为 WebSocket 地址并补全 `/ws`。
   - DevTools 页面地址（带查询参数）会被拒绝。
3. 连接后每 2 秒轮询一次，发现注册了 `ext.local_mock.*` 扩展的 isolate：
   - 只有一个时自动选中；
   - 有多个时需要在下拉框里选择目标。
4. 在规则卡片中编辑规则，点击“应用到手机”。状态栏显示 App 确认后的规则条数，下一次请求生效。

连接后可在顶部切换“Mock 规则” / “抓包”两个视图：

- 抓包页会实时同步（每秒增量拉取）App 内经过 local_mock 适配器的请求，包括真实请求与 Mock 命中的请求（带 MOCK 标记）。
- 列表支持按方法 / 域名 / 路径筛选，点击记录查看详情（请求体、状态码、耗时、格式化后的响应体）。
- 点击记录右侧的闪电按钮或详情里的“生成 Mock 规则”，用该请求预填规则弹窗；保存后规则进入本地列表，回到规则页“应用到手机”生效。
- “清空记录”会同时清空 App 端缓冲和本地列表。
- 连接的 App 端版本过旧（协议 v1）时，抓包页会提示升级，规则功能不受影响。

规则以卡片为单位管理：

- 点击“添加规则”新建卡片，在弹窗中填写 ID、方法、路径、状态码、延迟、响应头与响应体；
- 卡片上的开关可单独启用 / 停用某条规则；
- 按住卡片直接拖动调整顺序（第一条启用且匹配的规则生效），无需长按；
- 卡片右上角的按钮可编辑或删除规则（删除后可在提示条里撤销）。

| 按钮 | 作用 |
| --- | --- |
| 应用到手机 | 校验规则后整体替换 App 内的规则表 |
| 清空手机规则 | 清空 App 内的规则表 |
| 保存本地草稿 | 保存到应用支持目录下的 `rules.json`，不下发 |
| 添加规则 | 新建一张规则卡片并弹出编辑窗 |

## 行为说明

- 断开连接不会清空 App 内的规则。
- App Hot Restart 后会出现新的 isolate，桌面端会把上一次确认应用成功的规则自动恢复过去；抓包记录会重新开始。
- 连接或调用前会检查协议版本（`LocalMockProtocol.version`），不兼容时拒绝操作；旧版 App 端（v1）会提示升级到 0.2.0+。
- 草稿只保存规则 JSON，不保存 VM Service 地址（地址带鉴权 token）。
- 草稿解析失败时会显示空规则列表与告警条，可查看原始草稿内容；编辑后保存即可覆盖。
- 卡片为固定尺寸并靠左排列，窗口变宽时只会增加列数，多余空间留在右侧，第一列不会随窗口宽度左右移动。
- 抓包仅在“抓包”页可见时轮询，切回规则页自动停止。

## 代码结构

```
lib/
├── main.dart                 # UI（规则页 + 视图切换）
└── src/
    ├── mock_connection.dart  # VM Service 连接、isolate 发现、规则同步、抓包轮询
    ├── capture_panel.dart    # 抓包页 UI：列表、筛选、详情、从请求生成规则
    ├── rule_edit_dialog.dart # 规则编辑弹窗（规则页与抓包页共用）
    ├── vm_service_uri.dart   # 地址校验与规范化
    └── draft_store.dart      # 本地草稿读写
```

## 测试

```bash
flutter test
```
