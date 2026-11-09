/// Native-only, HTTP-client-agnostic core: rules, matching, traffic capture,
/// and the VM Service relay bridge. Adapters (local_mock_dio,
/// local_mock_http) call [LocalMock.match] and [LocalMock.beginTraffic].
library;

export 'src/local_mock.dart' show LocalMock;
export 'src/mock_rule.dart' show MockRule;
export 'src/protocol.dart' show LocalMockProtocol;
export 'src/traffic.dart' show TrafficEntry, TrafficRecorder, TrafficRecording;
export 'src/traffic_session.dart' show TrafficSession;
export 'src/recorded_request.dart' show RecordedRequest;
export 'src/recording_mock.dart' show recordingMockFromSession;
