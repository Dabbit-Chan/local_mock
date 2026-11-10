# local_mock_client

The web console and relay service for local_mock. The console is written in Flutter Web: it lets you inspect devices, live requests and recordings, and edit rules. The relay is a separate process that serves the console page and forwards messages between the app and the console. The Dart relay runs alongside the console; the Go relay lives in `../local_mock_relay/go`.

<p>
  <a href="README.md">中文</a> ·
  <a href="README.en.md">English</a>
</p>

## How it works

- **Relay** (Dart version `tool/relay_host.dart`, Go version `../local_mock_relay/go`): serves the console page from `build/web`, accepting app connections on `/ws/app` and console connections on `/ws/console`. It caches each device's currently confirmed rules and most recent requests in memory; on reconnect, the rules reported by the app win.
- **App side**: `LocalMockAgent` maintains the `/ws/app` connection to the relay; `VmServiceBridge` is a second WebSocket inside the app that forwards relay commands to the VM Service extension and receives capture events.
- **Console**: always connects to the relay address that served the page — no extra configuration. Routing uses hash mode; recordings and rules are stored in the browser's localStorage, with rules kept separately per device ID.
- **Rule sync**: after a cold start the app has no rules, and the device page shows "App restarted, rules not pushed". Once you click "Sync to device" and it succeeds, saving, toggling, deleting and reordering rules all push automatically for the current app session. Ordinary network drops, relay restarts or browser refreshes do not turn auto-sync off for the same app session; a new app session requires syncing manually again. Rules saved in the browser are never overwritten by the app's empty rule set.

## Local setup

```bash
flutter pub get
flutter build web --no-web-resources-cdn
dart run tool/relay_host.dart 9090
```

You can also use the Go relay instead (it reads `build/web` relative to the current directory by default):

```bash
cd ../local_mock_relay/go
LOCAL_MOCK_WEB_DIR=../../local_mock_client/build/web go run . 9090
```

Then open <http://127.0.0.1:9090/> in a browser. The relay listens on `127.0.0.1` only. For access from a phone or another device, set `LOCAL_MOCK_HOST=0.0.0.0`, or expose the address through a tunnel (such as `cloudflared`). The Go relay also provides <http://127.0.0.1:9090/diag> for online connections and recent disconnect reasons.

> The relay has no authentication — use it only locally or on a trusted internal network.
