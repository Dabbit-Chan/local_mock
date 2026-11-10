# local_mock_transport

The WebSocket communication layer shared by the app, the relay and the web console. It is pure Dart and does not depend on Flutter. Both `local_mock_core` and the web console use it directly; business apps do not need to. The Go relay implements the same protocol on its own.

<a href="README.md">中文</a> · <a href="README.en.md">English</a>

## How it works

- **Message model**: every message is JSON text, and is either a request, a reply or an event. Requests carry an `id` that maps them to their reply, with a timeout.
- **Two endpoints**: the app's `LocalMockAgent` connects to `/ws/app` and the console connects to `/ws/console`; each connection begins with a handshake that checks the protocol version.
- **Command forwarding**: commands from the console (read state, replace rules, clear, and so on) are forwarded by the relay to the target app, and the app's reply travels back the same way.
- **Reconnect**: the app reconnects automatically after a drop, resending its buffered requests and de-duplicating with an increasing sequence number; a changed session ID means the app has restarted.

`VmServiceBridge` inside the app talks to the local VM Service over a separate WebSocket channel. It is not part of this protocol and does not go through the relay.

The protocol itself has no authentication; whether traffic is encrypted depends on whether `wss` is used.
