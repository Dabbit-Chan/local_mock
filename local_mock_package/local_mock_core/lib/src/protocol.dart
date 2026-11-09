/// VM Service extension names and wire version used inside the app.
abstract final class LocalMockProtocol {
  /// v2: adds traffic capture (`getTraffic` / `clearTraffic`).
  static const version = 2;
  static const replaceRules = 'ext.local_mock.replaceRules';
  static const getState = 'ext.local_mock.getState';
  static const clear = 'ext.local_mock.clear';
  static const getTraffic = 'ext.local_mock.getTraffic';
  static const clearTraffic = 'ext.local_mock.clearTraffic';
  static const trafficEvent = 'local_mock.traffic';
}
