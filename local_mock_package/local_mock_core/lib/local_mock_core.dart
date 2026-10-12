/// HTTP-client-agnostic core: rules, matching, and VM Service extensions.
/// Adapters (local_mock_dio, local_mock_http) call [LocalMock.match].
library;

export 'src/local_mock.dart' show LocalMock;
export 'src/mock_rule.dart' show MockRule;
export 'src/protocol.dart' show LocalMockProtocol;
