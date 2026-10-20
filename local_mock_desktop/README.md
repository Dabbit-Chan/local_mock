# local_mock_desktop

Flutter Web 控制台，复用规则编辑、抓包详情、从请求生成规则等界面。目标 App 主动连接同一个 WebSocket relay，控制台选择设备后下发规则。

当前只保留 Web，不再提供 macOS / Windows 应用，也不需要独立的 `local_mock_server` 项目。

## 本地可行性测试

浏览器不能监听来自手机的 WebSocket，因此 `flutter run -d chrome` 的开发服务器不能直接作为 App 接入端。项目提供同目录下的 `tool/relay_host.dart`：它是一个本地开发启动脚本，同时托管 Web 构建产物和 App / 控制台 WebSocket 连接。

终端一：

```bash
cd local_mock_desktop
flutter pub get
flutter build web --no-web-resources-cdn
dart run tool/relay_host.dart 9090
```

终端二打开：

```text
http://127.0.0.1:9090/
```

终端三由你自己运行：

```bash
cloudflared tunnel --url http://127.0.0.1:9090
```

目标 App 使用 cloudflared 输出的 HTTPS 地址连接：

```dart
LocalMock.connect(
  serverUrl: 'https://example.trycloudflare.com',
  deviceId: installationId,
  deviceName: 'QA Android',
);
```

HTTPS 会自动转换成 `wss://example.trycloudflare.com/ws/app`。Web 页面会连接同一地址的 `/ws/console`。**没有访问令牌。** 这是可行性测试，隧道地址的访问者都可以修改规则。

不要把 cloudflared 指向 `flutter run -d chrome` 的端口；Flutter 开发服务器只提供页面，不能处理本项目的 App WebSocket 协议。

如果只想单独调试页面，可以运行：

```bash
flutter run -d chrome
```

此时页面中填写 relay 地址，例如 `http://127.0.0.1:9090`；App 仍然连接 relay 端口。

## 控制台行为

- App 在线后自动出现在设备列表；多台设备时手动选择。
- 选择设备后加载该设备规则和抓包记录，不会把上一台设备的规则混过去。
- 规则保存、开关、删除和排序变更后自动同步，App 确认后生效。
- 抓包由 App 持续上报，不依赖当前是否打开抓包页面；保留最近 500 条。
- Web 页面断开不会清空 App 规则。relay 重启会丢失内存状态，App 重连后重新上报。

## App 接入

适配器接入和构建模式见[根 README](../README.md#目标-app-接入)。连接方法不需要令牌：

```dart
LocalMock.connect(
  serverUrl: serverAddress,
  deviceId: installationId,
  deviceName: 'QA Android',
);
```

## 构建与测试

```bash
flutter analyze
flutter test
flutter build web --no-web-resources-cdn
```

构建产物在 `build/web`。`tool/relay_host.dart` 需要先完成 Web 构建再运行。

浏览器网络用例需要一个已运行的 relay：

```bash
flutter test --platform chrome test/browser_connection_test.dart \
  --dart-define=LOCAL_MOCK_TEST_SERVER=http://127.0.0.1:9090
```
