import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate' as dart_isolate;

import 'package:vm_service/vm_service.dart';

import 'protocol.dart';

// Construct control sockets outside the app's HttpOverrides so VM Service
// traffic cannot be mocked, captured or recursively reported by our adapter.
class _ControlOverrides extends HttpOverrides {}

/// Connects to the VM Service inside this device over a local WebSocket. This
/// is the app-local control channel; it never connects to the Relay. The
/// separate outbound Relay connection carries commands/results, so neither
/// testers nor Relay need a Flutter SDK, USB connection, inbound device port or
/// VM Service credentials.
class VmServiceBridge {
  VmServiceBridge({required this.onTraffic, required this.onDisconnected});

  final void Function(Map<String, dynamic>) onTraffic;
  final void Function() onDisconnected;
  VmService? _service;
  Future<VmService>? _connecting;
  StreamSubscription<Event>? _events;
  HttpClient? _client;
  WebSocket? _socket;
  String? _isolateId;
  bool _closed = false;

  Future<VmService> _connect() {
    if (_closed) throw StateError('VM Service bridge 已关闭');
    final connecting = _connecting;
    if (connecting != null) return connecting;
    final service = _service;
    if (service != null) return Future.value(service);
    return _connecting ??= _open().whenComplete(() => _connecting = null);
  }

  Future<VmService> _open() async {
    var info = await developer.Service.getInfo();
    if (info.serverUri == null) {
      info = await developer.Service.controlWebServer(
        enable: true,
        silenceOutput: true,
      );
    }
    final uri = info.serverWebSocketUri;
    final isolateId = developer.Service.getIsolateId(
      dart_isolate.Isolate.current,
    );
    if (uri == null || isolateId == null) {
      throw StateError(
        'VM Service 不可用，请使用启用 VM Service 的原生 Debug / Profile 构建',
      );
    }
    final client = _ControlOverrides().createHttpClient(null)
      ..connectionTimeout = const Duration(seconds: 4);
    _client = client;
    WebSocket socket;
    try {
      socket = await WebSocket.connect(uri.toString(), customClient: client);
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
    if (_closed) {
      await socket.close();
      client.close(force: true);
      throw StateError('VM Service bridge 已关闭');
    }
    _socket = socket;
    var ready = false;
    final messages = StreamController<String>();
    final done = Completer<void>();
    final subscription = socket.listen(
      (dynamic message) => messages.add(message as String),
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
    );
    final service = VmService(
      messages.stream,
      socket.add,
      streamClosed: done.future,
      disposeHandler: () async {
        await subscription.cancel();
        await socket.close();
        client.close(force: true);
        unawaited(messages.close());
      },
    );
    _service = service;
    _isolateId = isolateId;
    unawaited(
      service.onDone.then((_) {
        if (_service == service) {
          _service = null;
          _isolateId = null;
          unawaited(_events?.cancel());
          _events = null;
          if (!_closed && ready) onDisconnected();
        }
      }),
    );
    try {
      // Readiness means a real service extension call succeeded, not merely
      // that the local WebSocket connected.
      await _call(service, LocalMockProtocol.getState);
      _events = service.onExtensionEvent.listen((event) {
        if (_closed ||
            _service != service ||
            event.isolate?.id != isolateId ||
            event.extensionKind != LocalMockProtocol.trafficEvent) {
          return;
        }
        final entry = event.extensionData?.data['entry'];
        if (entry is Map) onTraffic(Map<String, dynamic>.from(entry));
      });
      await service.streamListen(EventStreams.kExtension);
      ready = true;
      return service;
    } catch (_) {
      await service.dispose();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _call(
    VmService service,
    String method, [
    Map<String, String> args = const {},
  ]) async {
    final response = await service
        .callServiceExtension(method, isolateId: _isolateId, args: args)
        .timeout(const Duration(seconds: 5));
    final result = response.json!;
    if (result['protocolVersion'] != LocalMockProtocol.version) {
      throw StateError('local_mock VM Service 协议版本不兼容');
    }
    return result;
  }

  Future<Map<String, dynamic>> command(
    String method,
    Map<String, dynamic> args,
  ) async {
    final service = await _connect();
    switch (method) {
      case 'replaceRules':
        return _call(service, LocalMockProtocol.replaceRules, {
          'protocolVersion': '${LocalMockProtocol.version}',
          'rules': jsonEncode(args['rules']),
        });
      case 'clear':
        return _call(service, LocalMockProtocol.clear);
      case 'clearTraffic':
        await _call(service, LocalMockProtocol.clearTraffic);
        return _call(service, LocalMockProtocol.getState);
      case 'getState':
        // Snapshot and reconnect backfill also go through VM Service.
        final state = await _call(service, LocalMockProtocol.getState);
        final traffic = await _call(service, LocalMockProtocol.getTraffic, {
          'sinceRevision': '0',
        });
        return {...state, ...traffic};
      default:
        throw FormatException('Unknown command: $method');
    }
  }

  Future<void> close() async {
    _closed = true;
    await _events?.cancel();
    _events = null;
    await _service?.dispose();
    await _socket?.close();
    _client?.close(force: true);
    _service = null;
  }
}
