{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}},
  },
  config: {
    // Glyphs missing from every bundled font (rare CJK, emoji, other
    // scripts) are downloaded by the engine from this base URL. The default,
    // fonts.gstatic.com, is unreachable in many networks in mainland China;
    // fonts.gstatic.cn is Google's official China mirror with the same paths
    // and CORS headers. Alternative: https://gstatic.loli.net/s/
    fontFallbackBaseUrl: 'https://fonts.gstatic.cn/s/',
  },
});
