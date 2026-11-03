// TEMPORARY scratch device for UI screenshots. Not part of the change.
import 'dart:convert';
import 'package:local_mock_transport/local_mock_transport.dart';

void main(List<String> args) {
  var rules = <dynamic>[];
  var rev = 0;
  final now = DateTime.now().millisecondsSinceEpoch;
  Map<String, dynamic> e(String m, String uri, {String? req, String? res}) {
    final u = Uri.parse(uri);
    return {'revision': ++rev, 'startedAt': now - (10 - rev) * 5000, 'durationMs': 80, 'mocked': false,
      'method': m, 'uri': uri, 'host': u.host, 'path': u.path, 'requestBody': ?req, 'statusCode': 200,
      'contentType': 'application/json', 'responseBody': ?res};
  }
  final home = jsonEncode({'code': 0, 'data': {'siteBaseInfo': {'title': '周末徒步', 'city': '杭州'},
    'sitePhotoAlbumList': [for (var i = 0; i < 4; i++) {'id': 1000 + i, 'name': '相册 $i', 'count': i * 12}]}});
  final traffic = [
    e('GET', 'https://api.example.com/api/site/home?siteId=88&lang=zh', res: home),
    e('POST', 'https://api.example.com/api/order/create?channel=app', req: jsonEncode({'sku': 'A1', 'count': 2, 'address': {'city': '杭州', 'zip': '310000'}}), res: jsonEncode({'code': 0, 'data': {'orderId': 'O-1'}})),
  ];
  LocalMockAgent(serverUrl: 'http://127.0.0.1:9191', deviceId: 'pixel-8-qa', deviceName: 'Pixel 8 · QA',
    snapshot: () => {'rules': rules, 'entries': traffic, 'supportsRecordingMocks': true},
    onCommand: (method, a) {
      if (method == 'replaceRules') rules = List.of(a['rules'] as List);
      return {'rules': rules, 'supportsRecordingMocks': true};
    }).start();
}
