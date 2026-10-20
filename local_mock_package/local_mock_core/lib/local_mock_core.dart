/// HTTP-client-agnostic core: rules, matching, traffic capture, and outbound
/// app reporting. Adapters (local_mock_dio, local_mock_http) call
/// [LocalMock.match] and [LocalMock.beginTraffic].
library;

export 'src/local_mock.dart' show LocalMock;
export 'src/mock_rule.dart' show MockRule;
export 'src/protocol.dart' show LocalMockProtocol;
export 'src/traffic.dart' show TrafficEntry, TrafficRecorder, TrafficRecording;
