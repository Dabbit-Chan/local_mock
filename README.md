# local_mock

local_mock 是给 Flutter App 用的接口 Mock 与抓包工具，面向开发和测试阶段。它能实时查看 App 发出的网络请求，并在浏览器里编辑规则来改写接口响应。用它可以在接口未完成时用假数据开发、验证界面边界情况，也可以离线复现一整条操作流程。

## 技术原理

```
 ┌──────────────┐   WebSocket   ┌──────────────┐   WebSocket   ┌──────────────┐
 │  Flutter App │ ────────────▶ │    Relay     │ ◀──────────── │  Web 控制台  │
 │  + 适配器    │               │ (Dart 进程)  │               │  (浏览器)    │
 └──────────────┘               └──────────────┘               └──────────────┘
```

- **在 App 内部拦截**：适配器接入 App 的 HTTP 客户端（Dio 拦截器或 `HttpOverrides`），在请求发出前匹配规则，所以不需要系统代理，也不需要安装证书。
- **反向连接**：App 主动连上 Relay，把请求记录实时上报。Relay 再把控制台的操作转发给对应设备。
- **规则在 App 内存中生效**：规则下发后由 App 自己匹配。命中时可以直接返回整包数据，也可以只改写真实响应里的部分字段；没有命中的请求照常走真实网络。
- **只在开发构建中启用**：只在 Debug / Profile 构建中生效，Release 构建里所有入口都不做任何事。

## 仓库结构

| 目录 | 简介 |
| --- | --- |
| [`local_mock_client`](local_mock_client/README.md) | Web 控制台与 Relay 服务 |
| [`local_mock_core`](local_mock_package/local_mock_core/README.md) | 规则模型与匹配、请求记录、录制，不依赖具体 HTTP 客户端 |
| [`local_mock_dio`](local_mock_package/local_mock_dio/README.md) | Dio 4.x / 5.x 适配器 |
| [`local_mock_http`](local_mock_package/local_mock_http/README.md) | `HttpClient` / `package:http` 适配器 |
| [`local_mock_transport`](local_mock_package/local_mock_transport/README.md) | App、Relay、控制台之间的 WebSocket 通信协议 |
| [`skills/local-mock-rules`](skills/local-mock-rules/SKILL.md) | 帮助 AI 助手生成规则文件的 Skill |

> Relay 没有鉴权，请只在本地或内网中使用。
