import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:local_mock_transport/local_mock_transport.dart';

import 'mock_registry.dart';
import 'mock_rule.dart';
import 'protocol.dart';
import 'traffic.dart';

/// Isolate-local entry point shared by all adapters.
///
/// Business apps normally use an adapter (local_mock_dio / local_mock_http)
/// instead of calling this directly. Custom adapters call [ensureInitialized]
/// once, [match] for every request, and [beginTraffic] to feed the capture
/// view shown by the desktop app.
abstract final class LocalMock {
  static final _registry = MockRegistry();
  static final _traffic = TrafficRecorder(
    maxEntries: 500,
    onEntry: (entry) {
      _agent?.report(entry.toJson());
    },
  );
  static LocalMockAgent? _agent;
  static Uri? _serverUri;

  /// Enabled in Debug and Profile; disabled in Release.
  static const enabled = !kReleaseMode;

  /// Starts an outbound relay connection. Returns immediately; unavailable
  /// servers are retried in the background and never block business requests.
  /// Use a unique, stable deviceId for each app installation/isolate.
  static bool connect({
    required String serverUrl,
    required String deviceId,
    String? deviceName,
  }) {
    if (!enabled) return false;
    if (deviceId.trim().isEmpty) {
      throw ArgumentError('deviceId must not be empty');
    }
    final uri = relayUri(serverUrl, 'app');
    disconnect();
    _serverUri = uri;
    _agent = LocalMockAgent(
      serverUrl: serverUrl,
      deviceId: deviceId,
      deviceName: deviceName ?? deviceId,
      snapshot: () => {..._registry.state, ..._trafficSnapshot(0)},
      onCommand: (method, args) {
        switch (method) {
          case 'replaceRules':
            _registry.replace(args['rules']);
          case 'clear':
            _registry.clear();
          case 'clearTraffic':
            _traffic.clear();
          case 'getState':
            break;
          default:
            throw FormatException('Unknown command: $method');
        }
        return _registry.state;
      },
    )..start();
    return true;
  }

  static bool get connected => _agent?.connected ?? false;

  /// Stops reporting; rules remain in memory until explicitly cleared.
  static void disconnect() {
    _agent?.stop();
    _agent = null;
    _serverUri = null;
  }

  static bool _isControlRequest(Uri uri) =>
      _serverUri != null &&
      uri.host == _serverUri!.host &&
      uri.port ==
          (_serverUri!.hasPort
              ? _serverUri!.port
              : (_serverUri!.scheme == 'wss' ? 443 : 80)) &&
      uri.path == _serverUri!.path;
  static bool _registered = false;

  /// Registers the VM Service extensions once per isolate.
  /// Returns false when disabled. VM extensions are only registered in Debug.
  static bool ensureInitialized() {
    if (!enabled) return false;
    if (!kDebugMode) return true;
    if (!_registered) {
      for (final method in [
        LocalMockProtocol.replaceRules,
        LocalMockProtocol.getState,
        LocalMockProtocol.clear,
        LocalMockProtocol.getTraffic,
        LocalMockProtocol.clearTraffic,
      ]) {
        developer.registerExtension(method, _handle);
      }
      _registered = true;
    }
    return true;
  }

  /// First enabled rule matching [method] and [uri], or null.
  /// Always null when disabled.
  static MockRule? match(String method, Uri uri) =>
      enabled && !_isControlRequest(uri) ? _registry.match(method, uri) : null;

  /// Starts recording one request for the capture view. Returns null outside
  /// enabled modes. Call [TrafficRecording.finish] or [TrafficRecording.fail] once it settles.
  static TrafficRecording? beginTraffic(String method, Uri uri) =>
      enabled && !_isControlRequest(uri) ? _traffic.begin(method, uri) : null;

  /// Replaces rules without the VM Service, for adapter tests.
  @visibleForTesting
  static void debugReplaceRules(List<dynamic> rules) =>
      _registry.replace(rules);

  /// Clears rules without the VM Service, for adapter tests.
  @visibleForTesting
  static void debugClear() => _registry.clear();

  /// Recorded traffic, oldest first, for adapter tests.
  @visibleForTesting
  static List<TrafficEntry> debugTrafficEntries() => [..._traffic.since(0)];

  /// Clears recorded traffic, for adapter tests.
  @visibleForTesting
  static void debugClearTraffic() => _traffic.clear();

  static Map<String, dynamic> _trafficSnapshot(int sinceRevision) => {
    'protocolVersion': LocalMockProtocol.version,
    'trafficRevision': _traffic.revision,
    'entries': [
      for (final entry in _traffic.since(sinceRevision)) entry.toJson(),
    ],
  };

  static Future<developer.ServiceExtensionResponse> _handle(
    String method,
    Map<String, String> parameters,
  ) async {
    try {
      switch (method) {
        case LocalMockProtocol.replaceRules:
          if (parameters['protocolVersion'] != '${LocalMockProtocol.version}') {
            throw const FormatException('incompatible protocolVersion');
          }
          final rules = parameters['rules'];
          if (rules == null) throw const FormatException('missing rules');
          _registry.replace(jsonDecode(rules));
        case LocalMockProtocol.clear:
          _registry.clear();
        case LocalMockProtocol.getTraffic:
          final since = int.tryParse(parameters['sinceRevision'] ?? '0');
          if (since == null || since < 0) {
            throw const FormatException(
              'sinceRevision must be a non-negative integer',
            );
          }
          return developer.ServiceExtensionResponse.result(
            jsonEncode(_trafficSnapshot(since)),
          );
        case LocalMockProtocol.clearTraffic:
          _traffic.clear();
          return developer.ServiceExtensionResponse.result(
            jsonEncode(_trafficSnapshot(0)),
          );
        case LocalMockProtocol.getState:
          break;
        default:
          throw FormatException('unknown method: $method');
      }
      return developer.ServiceExtensionResponse.result(
        jsonEncode(_registry.state),
      );
    } on FormatException catch (error) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.invalidParams,
        jsonEncode({'message': error.message}),
      );
    }
  }
}
