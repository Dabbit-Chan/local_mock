<div align="center">

<img src="local_mock_client/web/favicon.svg" width="96" height="96" alt="local_mock logo" />

# local_mock

**给 Flutter App 用的接口 Mock 与抓包工具**

不需要代理，不需要证书，在浏览器里实时查看请求、改写响应。

<p>
  <img src="https://img.shields.io/badge/Flutter-%E2%89%A53.32-02569B?style=flat-square&logo=flutter&logoColor=white" alt="Flutter" />
  <img src="https://img.shields.io/badge/Dart-%E2%89%A53.8-0175C2?style=flat-square&logo=dart&logoColor=white" alt="Dart" />
  <img src="https://img.shields.io/badge/Dio-4.x%20%7C%205.x-E2231A?style=flat-square" alt="Dio" />
  <img src="https://img.shields.io/badge/build-Debug%20%7C%20Profile-111111?style=flat-square" alt="Debug / Profile" />
  <a href="https://github.com/Dabbit-Chan/local_mock/stargazers"><img src="https://img.shields.io/github/stars/Dabbit-Chan/local_mock?style=flat-square&color=E2231A" alt="Stars" /></a>
</p>

<p>
  <a href="#-特性">特性</a> ·
  <a href="#-技术原理">技术原理</a> ·
  <a href="#-仓库结构">仓库结构</a>
</p>

</div>

---

local_mock 是给 Flutter App 用的接口 Mock 与抓包工具，面向开发和测试阶段。它能实时查看 App 发出的网络请求，并在浏览器里编辑规则来改写接口响应。用它可以在接口未完成时用假数据开发、验证界面边界情况，也可以离线复现一整条操作流程。

## ✨ 特性

<table>
  <tr>
    <td width="50%" valign="top">
      <h4>🔌 零代理接入</h4>
      在 App 的 HTTP 客户端内部拦截，不需要配置系统代理，也不需要安装证书。
    </td>
    <td width="50%" valign="top">
      <h4>📡 实时抓包</h4>
      请求和响应实时上报到浏览器控制台，可以筛选，也可以查看完整的请求体和响应体。
    </td>
  </tr>
  <tr>
    <td valign="top">
      <h4>🎭 整包替换与字段补丁</h4>
      既可以直接返回假数据，也可以只改写真实响应里的几个字段。
    </td>
    <td valign="top">
      <h4>🎬 录制与回放</h4>
      录下一整段操作流程，生成录制组后可以离线回放。
    </td>
  </tr>
  <tr>
    <td valign="top">
      <h4>🎯 参数级匹配</h4>
      按 query 或请求体参数命中规则，可以只改某一个订单、某一种传参。
    </td>
    <td valign="top">
      <h4>🛡️ Release 安全</h4>
      只在 Debug / Profile 构建中生效，Release 构建里所有入口都不做任何事。
    </td>
  </tr>
</table>

## 🧭 技术原理

```mermaid
flowchart LR
    A["📱 Flutter App<br/>+ 适配器"] -- "WebSocket<br/>上报请求 / 接收规则" --> R["⚙️ Relay<br/>Dart 进程"]
    C["🖥️ Web 控制台<br/>浏览器"] -- "WebSocket<br/>查看请求 / 下发规则" --> R
```

- **在 App 内部拦截**：适配器接入 App 的 HTTP 客户端（Dio 拦截器或 `HttpOverrides`），在请求发出前匹配规则，所以不需要系统代理，也不需要安装证书。
- **反向连接**：App 主动连上 Relay，把请求记录实时上报。Relay 再把控制台的操作转发给对应设备。
- **规则在 App 内存中生效**：规则下发后由 App 自己匹配。命中时可以直接返回整包数据，也可以只改写真实响应里的部分字段；没有命中的请求照常走真实网络。
- **只在开发构建中启用**：只在 Debug / Profile 构建中生效，Release 构建里所有入口都不做任何事。

## 📦 仓库结构

| 模块 | 简介 |
| --- | --- |
| 🖥️ [`local_mock_client`](local_mock_client/README.md) | Web 控制台与 Relay 服务 |
| 🧩 [`local_mock_core`](local_mock_package/local_mock_core/README.md) | 规则模型与匹配、请求记录、录制，不依赖具体 HTTP 客户端 |
| 🔗 [`local_mock_dio`](local_mock_package/local_mock_dio/README.md) | Dio 4.x / 5.x 适配器 |
| 🌐 [`local_mock_http`](local_mock_package/local_mock_http/README.md) | `HttpClient` / `package:http` 适配器 |
| 📡 [`local_mock_transport`](local_mock_package/local_mock_transport/README.md) | App、Relay、控制台之间的 WebSocket 通信协议 |
| 🤖 [`skills/local-mock-rules`](skills/local-mock-rules/SKILL.md) | 帮助 AI 助手生成规则文件的 Skill |

> [!WARNING]
> Relay 没有鉴权，能访问 Relay 地址的人都能看到请求内容并修改规则。请只在本地或内网中使用。
