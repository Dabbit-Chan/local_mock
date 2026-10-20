import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:local_mock_transport/local_mock_transport.dart';
import 'package:mime/mime.dart';

class _Device {
  _Device(this.id, this.name, this.session, this.socket);
  final String id;
  String name;
  String session;
  WebSocket? socket;
  List<dynamic> rules = [];
  final traffic = <Map<String, dynamic>>[];
  bool busy = false;
  bool ready = false;
  int epoch = 0;
  Map<String, dynamic> get json => {
    'id': id,
    'name': name,
    'sessionId': session,
    'online': socket != null && ready,
  };
}

/// In-memory relay. Each app has its own acknowledged rules and bounded
/// traffic history. Disconnecting a console does not change app rules.
class LocalMockRelay {
  LocalMockRelay({Directory? webDirectory})
    : webDirectory = webDirectory ?? Directory('build/web');

  final Directory webDirectory;
  HttpServer? _server;
  final _sockets = <WebSocket>{};
  final _consoles = <WebSocket>{};
  final _devices = <String, _Device>{};
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  int _counter = 0;
  int get port => _server!.port;

  Future<void> start({String host = '127.0.0.1', int port = 9090}) async {
    _server = await HttpServer.bind(host, port);
    _server!.listen((request) async {
      if (!['/ws/app', '/ws/console'].contains(request.uri.path)) {
        await _serveWeb(request);
        return;
      }
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      socket.pingInterval = const Duration(seconds: 20);
      _sockets.add(socket);
      var initialized = false;
      _Device? device;
      final isApp = request.uri.path == '/ws/app';
      final deadline = Timer(const Duration(seconds: 8), () {
        if (!initialized) {
          unawaited(socket.close(1008, 'Handshake timeout'));
        }
      });
      socket.listen(
        (raw) async {
          Map<String, dynamic>? message;
          try {
            message = jsonDecode(raw as String) as Map<String, dynamic>;
            if (!initialized) {
              final args = message['args'] as Map;
              if (message['method'] != 'hello' ||
                  args['protocolVersion'] != relayProtocolVersion) {
                throw StateError('协议版本不兼容');
              }
              if (isApp) {
                final id = args['deviceId'];
                final name = args['deviceName'];
                final session = args['sessionId'];
                if (id is! String ||
                    id.isEmpty ||
                    name is! String ||
                    session is! String ||
                    session.isEmpty) {
                  throw const FormatException('Invalid device identity');
                }
                final previous = _devices[id];
                if (previous?.socket != null && previous!.session != session) {
                  throw StateError('设备 ID 已被另一个 App 使用，请设置唯一 deviceId');
                }
                if (previous?.socket != null) {
                  unawaited(previous!.socket!.close(1000, 'Reconnected'));
                }
                device = previous ?? _Device(id, name, session, socket);
                final changedSession = device!.session != session;
                device!
                  ..name = name
                  ..session = session
                  ..socket = socket
                  ..ready = false;
                if (changedSession) {
                  device!.traffic.clear();
                  device!.epoch++;
                }
                if (previous == null) {
                  device!.rules = List.of(
                    (args['state'] as Map)['rules'] as List,
                  );
                }
                _devices[id] = device!;
                initialized = true;
                deadline.cancel();
                _send(socket, {
                  'id': message['id'],
                  'result': <String, dynamic>{},
                });
                if (previous != null) {
                  // Restore only rules acknowledged by an app, never a failed edit.
                  await _forward(device!, 'replaceRules', {
                    'rules': device!.rules,
                  });
                }
                if (device!.socket != socket) return;
                device!.ready = true;
                _broadcastDevices();
              } else {
                initialized = true;
                deadline.cancel();
                _consoles.add(socket);
                _send(socket, {
                  'id': message['id'],
                  'result': {
                    'devices': _devices.values.map((d) => d.json).toList(),
                  },
                });
                _broadcastDevices();
              }
              return;
            }
            if (isApp) {
              if (device!.socket != socket) return;
              final id = message['id'];
              if (id != null) {
                final pending = _pending.remove('${device!.id}:$id');
                if (pending != null) {
                  if (message['error'] != null) {
                    pending.completeError(StateError('${message['error']}'));
                  } else {
                    pending.complete(
                      Map<String, dynamic>.from(message['result'] as Map),
                    );
                  }
                }
              } else if (['traffic', 'snapshot'].contains(message['event'])) {
                _appendTraffic(
                  device!,
                  (message['entries'] as List).cast<Map<String, dynamic>>(),
                );
              }
            } else {
              final result = await _consoleRequest(message);
              _send(socket, {'id': message['id'], 'result': result});
            }
          } catch (error) {
            _send(socket, {'id': message?['id'], 'error': '$error'});
            if (!initialized || (isApp && device?.ready != true)) {
              unawaited(socket.close(1008, 'Protocol error'));
            }
          }
        },
        onError: (Object _) {},
        onDone: () {
          deadline.cancel();
          _sockets.remove(socket);
          _consoles.remove(socket);
          if (device?.socket == socket) {
            device!.socket = null;
            device!.ready = false;
            for (final key
                in _pending.keys
                    .where((k) => k.startsWith('${device!.id}:'))
                    .toList()) {
              _pending.remove(key)!.completeError(StateError('设备已离线'));
            }
            _broadcastDevices();
          }
        },
      );
    });
  }

  Future<Map<String, dynamic>> _consoleRequest(
    Map<String, dynamic> message,
  ) async {
    if (message['method'] != 'command') throw StateError('Unknown method');
    final args = message['args'] as Map;
    final device = _devices[args['deviceId']];
    if (device == null || device.socket == null || !device.ready) {
      throw StateError('设备已离线');
    }
    final method = args['method'] as String;
    if (![
      'getState',
      'replaceRules',
      'clear',
      'clearTraffic',
    ].contains(method)) {
      throw StateError('Unknown command');
    }
    await _forward(
      device,
      method,
      Map<String, dynamic>.from(args['args'] as Map? ?? {}),
    );
    if (method == 'clearTraffic') {
      device.traffic.clear();
      device.epoch++;
    }
    final snapshot = _snapshot(device);
    for (final console in _consoles) {
      _send(console, {'event': 'state', 'deviceId': device.id, ...snapshot});
    }
    return snapshot;
  }

  Future<Map<String, dynamic>> _forward(
    _Device device,
    String method,
    Map<String, dynamic> args,
  ) async {
    if (device.busy) throw StateError('设备正在同步，请稍后重试');
    device.busy = true;
    final socket = device.socket!;
    final id = 'relay-${++_counter}';
    final key = '${device.id}:$id';
    final pending = Completer<Map<String, dynamic>>();
    _pending[key] = pending;
    try {
      _send(socket, {'id': id, 'method': method, 'args': args});
      final state = await pending.future.timeout(const Duration(seconds: 7));
      if (device.socket != socket) throw StateError('设备连接已变化');
      if (state['rules'] is! List) {
        throw const FormatException('Invalid app state');
      }
      device.rules = List.of(state['rules'] as List);
      return state;
    } finally {
      _pending.remove(key);
      device.busy = false;
    }
  }

  Map<String, dynamic> _snapshot(_Device device) => {
    'rules': device.rules,
    'entries': device.traffic,
    'sessionId': device.session,
    'epoch': device.epoch,
  };

  void _appendTraffic(_Device device, List<Map<String, dynamic>> entries) {
    final last = device.traffic.isEmpty
        ? 0
        : device.traffic.last['revision'] as int;
    final fresh = entries
        .where((e) => e['revision'] is int && (e['revision'] as int) > last)
        .toList();
    if (fresh.isEmpty) return;
    device.traffic.addAll(fresh);
    if (device.traffic.length > 500) {
      device.traffic.removeRange(0, device.traffic.length - 500);
    }
    for (final console in _consoles) {
      _send(console, {
        'event': 'traffic',
        'deviceId': device.id,
        'sessionId': device.session,
        'epoch': device.epoch,
        'entries': fresh,
      });
    }
  }

  void _broadcastDevices() {
    for (final console in _consoles) {
      _send(console, {
        'event': 'devices',
        'devices': _devices.values.map((d) => d.json).toList(),
      });
    }
  }

  void _send(WebSocket socket, Map<String, dynamic> message) {
    try {
      if (socket.readyState == WebSocket.open) socket.add(jsonEncode(message));
    } on StateError {
      // The sink may have closed before readyState changes.
    }
  }

  Future<void> _serveWeb(HttpRequest request) async {
    final response = request.response;
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }
    final root = await webDirectory.absolute.resolveSymbolicLinks();
    final name = request.uri.path == '/'
        ? 'index.html'
        : request.uri.path.substring(1);
    final file = File.fromUri(Directory(root).uri.resolve(name));
    try {
      final resolved = await file.resolveSymbolicLinks();
      if (!resolved.startsWith('$root${Platform.pathSeparator}') ||
          (await FileStat.stat(resolved)).type != FileSystemEntityType.file) {
        response.statusCode = HttpStatus.notFound;
      } else {
        response.headers.contentType = ContentType.parse(
          lookupMimeType(resolved) ?? 'application/octet-stream',
        );
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        if (request.method == 'GET') {
          await response.addStream(File(resolved).openRead());
        }
      }
    } on FileSystemException {
      response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }

  Future<void> close() async {
    for (final socket in _sockets.toList()) {
      await socket.close();
    }
    await _server?.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  final port = args.isEmpty ? 9090 : int.tryParse(args.single);
  if (port == null || port < 1 || port > 65535) {
    stderr.writeln('Usage: dart run tool/relay_host.dart [port]');
    exitCode = 64;
    return;
  }
  final relay = LocalMockRelay();
  if (!await relay.webDirectory.exists()) {
    stderr.writeln('Web files not found. Run flutter build web first.');
    exitCode = 66;
    return;
  }
  try {
    await relay.start(port: port);
  } on SocketException catch (error) {
    if ([48, 98, 10048].contains(error.osError?.errorCode)) {
      stderr.writeln(
        'Port $port is already in use. Stop the process or choose another port.',
      );
      exitCode = 98;
      return;
    }
    rethrow;
  }
  stdout.writeln('Local Mock: http://127.0.0.1:$port');
  ProcessSignal.sigint.watch().listen((_) async {
    await relay.close();
    exit(0);
  });
}
