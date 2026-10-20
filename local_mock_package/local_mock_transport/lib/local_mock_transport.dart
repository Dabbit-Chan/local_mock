import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Separate from the legacy VM Service protocol.
const relayProtocolVersion = 1;

Uri relayUri(String address, String role) {
  final uri = Uri.parse(address.trim());
  if (!['http', 'https', 'ws', 'wss'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('请输入有效的 HTTP(S) / WS(S) 服务地址');
  }
  final path = uri.path.replaceFirst(RegExp(r'/(ws/(app|console))?/?$'), '');
  return Uri(
    scheme: ['https', 'wss'].contains(uri.scheme) ? 'wss' : 'ws',
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: '$path/ws/$role',
  );
}

/// JSON messages, request acknowledgements, deadlines and late-result cleanup.
class RelayPeer {
  RelayPeer._(this._channel, this.onEvent, this.onRequest) {
    _subscription = _channel.stream.listen(
      _receive,
      onError: (Object error) => _finish(error),
      onDone: () => _finish(StateError('连接已断开')),
    );
  }

  static Future<RelayPeer> connect(
    Uri uri, {
    required Map<String, dynamic> hello,
    void Function(Map<String, dynamic>)? onEvent,
    FutureOr<Map<String, dynamic>> Function(Map<String, dynamic>)? onRequest,
  }) async {
    final channel = WebSocketChannel.connect(uri);
    try {
      await channel.ready.timeout(const Duration(seconds: 8));
    } catch (_) {
      unawaited(channel.sink.close());
      rethrow;
    }
    final peer = RelayPeer._(channel, onEvent, onRequest);
    try {
      peer.helloResult = await peer.request('hello', {
        ...hello,
        'protocolVersion': relayProtocolVersion,
      });
      return peer;
    } catch (_) {
      peer.close();
      rethrow;
    }
  }

  late final Map<String, dynamic> helloResult;
  final WebSocketChannel _channel;
  final void Function(Map<String, dynamic>)? onEvent;
  final FutureOr<Map<String, dynamic>> Function(Map<String, dynamic>)?
  onRequest;
  late final StreamSubscription<dynamic> _subscription;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _done = Completer<void>();
  int _counter = 0;
  bool _closed = false;
  Future<void> get done => _done.future;

  void send(Map<String, dynamic> message) {
    if (_closed) throw StateError('连接已断开');
    _channel.sink.add(jsonEncode(message));
  }

  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    final id = '${++_counter}';
    final result = Completer<Map<String, dynamic>>();
    _pending[id] = result;
    try {
      send({'id': id, 'method': method, 'args': args});
      return await result.future.timeout(const Duration(seconds: 8));
    } finally {
      _pending.remove(id);
    }
  }

  void _receive(dynamic raw) async {
    Map<String, dynamic>? message;
    try {
      message = jsonDecode(raw as String) as Map<String, dynamic>;
      if (message.containsKey('method')) {
        final handler = onRequest;
        if (handler == null) throw StateError('Unsupported request');
        final result = await handler(message);
        if (!_closed) send({'id': message['id'], 'result': result});
      } else if (message.containsKey('id')) {
        final pending = _pending.remove(message['id']);
        if (pending == null) return;
        if (message['error'] != null) {
          pending.completeError(StateError('${message['error']}'));
        } else {
          pending.complete(Map<String, dynamic>.from(message['result'] as Map));
        }
      } else {
        onEvent?.call(message);
      }
    } catch (error) {
      if (!_closed && message?['method'] != null) {
        send({'id': message!['id'], 'error': '$error'});
      }
      // A malformed remote event must not crash the host application.
    }
  }

  void _finish(Object error) {
    if (_closed) return;
    _closed = true;
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
    _done.complete();
  }

  void close() {
    _finish(StateError('连接已断开'));
    unawaited(_subscription.cancel());
    unawaited(_channel.sink.close());
  }
}

/// App-initiated connection with automatic reconnect. A session ID identifies
/// one live app/isolate, while deviceId can remain stable across app restarts.
class LocalMockAgent {
  LocalMockAgent({
    required this.serverUrl,
    required this.deviceId,
    required this.deviceName,
    required this.onCommand,
    required this.snapshot,
    this.reconnectDelay = const Duration(seconds: 2),
  });

  final String serverUrl;
  final String deviceId;
  final String deviceName;
  final FutureOr<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  onCommand;
  final Map<String, dynamic> Function() snapshot;
  final Duration reconnectDelay;
  final String sessionId = '${DateTime.now().microsecondsSinceEpoch}';
  RelayPeer? _peer;
  Timer? _retry;
  bool _stopped = true;
  int _generation = 0;
  bool get connected => _peer != null;

  void start() {
    if (!_stopped) return;
    // Validate synchronously so configuration errors are visible to callers.
    relayUri(serverUrl, 'app');
    _stopped = false;
    unawaited(_connect(++_generation));
  }

  Future<void> _connect(int generation) async {
    try {
      final peer = await RelayPeer.connect(
        relayUri(serverUrl, 'app'),
        hello: {
          'deviceId': deviceId,
          'deviceName': deviceName,
          'sessionId': sessionId,
          'state': snapshot(),
        },
        onRequest: (message) => onCommand(
          message['method'] as String,
          Map<String, dynamic>.from(message['args'] as Map),
        ),
      );
      if (_stopped || generation != _generation) {
        peer.close();
        return;
      }
      _peer = peer;
      // Backfill the bounded buffer, including requests made during handshake.
      peer.send({'event': 'snapshot', ...snapshot()});
      await peer.done;
      if (identical(_peer, peer)) _peer = null;
    } catch (_) {
      // Backend availability must never prevent business app startup.
    }
    if (!_stopped && generation == _generation) {
      _retry = Timer(reconnectDelay, () => unawaited(_connect(generation)));
    }
  }

  void report(Map<String, dynamic> entry) {
    try {
      _peer?.send({
        'event': 'traffic',
        'entries': [entry],
      });
    } catch (_) {
      // Reporting failures must never fail a business request.
    }
  }

  void stop() {
    _stopped = true;
    _generation++;
    _retry?.cancel();
    _peer?.close();
    _peer = null;
  }
}
