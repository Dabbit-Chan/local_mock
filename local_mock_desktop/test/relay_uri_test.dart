import 'package:flutter_test/flutter_test.dart';
import 'package:local_mock_transport/local_mock_transport.dart';

void main() {
  test('service URLs work for local development, TLS and path prefixes', () {
    expect(
      relayUri('http://127.0.0.1:9090', 'app').toString(),
      'ws://127.0.0.1:9090/ws/app',
    );
    expect(
      relayUri('https://mock.example.com/', 'console').toString(),
      'wss://mock.example.com/ws/console',
    );
    expect(
      relayUri('wss://mock.example.com/tools/ws/app', 'console').toString(),
      'wss://mock.example.com/tools/ws/console',
    );
    expect(
      relayUri('https://mock.example.com/tools/', 'app').toString(),
      'wss://mock.example.com/tools/ws/app',
    );
  });

  test('invalid service URLs fail before attempting a socket connection', () {
    for (final address in [
      '',
      'localhost:9090',
      'ftp://host',
      'https://',
      'https://user:password@host',
      'https://host/#fragment',
    ]) {
      expect(() => relayUri(address, 'app'), throwsFormatException);
    }
  });
}
