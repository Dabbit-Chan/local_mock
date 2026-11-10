# local_mock_core

The core package of local_mock, independent of any specific HTTP client. It owns rules, request records and the relay connection; the adapters plug Dio, `HttpClient` and other clients into it.

<a href="README.md">中文</a> · <a href="README.en.md">English</a>

## What's inside

- **Rule model**: parsing, validation and matching of rules, supporting full replacement, field patches, parameter conditions and recording groups.
- **Rule table**: each isolate keeps one ordered rule list in memory.
- **Request records and recording**: buffers recent requests, and can turn a sequence of requests into a recording file.
- **Connection entry point**: `LocalMock.connect` starts `LocalMockAgent` (which connects to the relay's `/ws/app`) and creates `VmServiceBridge` (which connects to the local VM Service, establishing the connection on first use). The relay forwards console commands to the agent, and the bridge hands them to the `ext.local_mock.*` extension for execution; capture events travel the other way.

## How it works

- Rules are matched in list order and only the first match is used. The request method and path must match exactly; host and parameter conditions are optional.
- Rules inside the app live only in memory and are empty after a cold start. The console stores rules per device in the browser; once the user clicks "Sync to device", changes made during the current app session are pushed automatically.
- **Two channels**: the relay channel carries data across devices; the VM Service channel stays on the local machine, executing rule commands and collecting capture events inside the app isolate.
- **Capture path**: the adapter calls `LocalMock.beginTraffic`; once the request is recorded, an event is posted via `developer.postEvent`, and `VmServiceBridge` hands it to `LocalMockAgent`, which reports it to the relay.
