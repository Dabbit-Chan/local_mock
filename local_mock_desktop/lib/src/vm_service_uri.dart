/// Accepts the VM Service HTTP URL or its WebSocket URL, not a DevTools URL.
Uri normalizeVmServiceUri(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      !['http', 'https', 'ws', 'wss'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException(
      '请输入 VM Service 的 http(s) 或 ws(s) 地址，不是 DevTools 页面地址',
    );
  }
  final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  return uri.replace(
    scheme: switch (uri.scheme) {
      'http' => 'ws',
      'https' => 'wss',
      final scheme => scheme,
    },
    path: path.endsWith('/ws') ? path : '$path/ws',
  );
}
