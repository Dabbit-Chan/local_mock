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
4. 在编辑器中编写规则 JSON 数组，点击“应用到手机”。状态栏显示 App 确认后的规则条数，下一次请求生效。

| 按钮 | 作用 |
| --- | --- |
| 应用到手机 | 校验规则后整体替换 App 内的规则表 |
| 清空手机规则 | 清空 App 内的规则表 |
| 保存本地草稿 | 校验后保存到应用支持目录下的 `rules.json`，不下发 |
| 校验并格式化 | 按 `MockRule` 规则校验并格式化编辑器内容 |

## 行为说明

- 断开连接不会清空 App 内的规则。
- App Hot Restart 后会出现新的 isolate，桌面端会把上一次确认应用成功的规则自动恢复过去。
- 连接或调用前会检查协议版本（`LocalMockProtocol.version`），不兼容时拒绝操作。
- 草稿只保存规则 JSON，不保存 VM Service 地址（地址带鉴权 token）。

## 代码结构

```
lib/
├── main.dart                 # UI
└── src/
    ├── mock_connection.dart  # VM Service 连接、isolate 发现、规则同步
    ├── vm_service_uri.dart   # 地址校验与规范化
    └── draft_store.dart      # 本地草稿读写
```

## 测试

```bash
flutter test
```
