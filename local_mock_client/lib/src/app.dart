import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'capture_session_store.dart';
import 'format.dart';
import 'mock_connection.dart';
import 'pages/device_page.dart';
import 'pages/home_page.dart';
import 'pages/recording_page.dart';
import 'preferences.dart';
import 'recording_library.dart';
import 'rule_book.dart';
import 'rule_file_transfer.dart';
import 'ui/primitives.dart';
import 'ui/theme.dart';

/// Light / dark / follow-system, remembered in the browser.
class ThemeController extends ValueNotifier<ThemeMode> {
  ThemeController([this._prefs = const Preferences()])
    : super(_decode(_prefs.read(_key)));

  final Preferences _prefs;
  static const _key = 'local_mock.theme';

  static ThemeMode _decode(String? value) => ThemeMode.values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => ThemeMode.system,
  );

  void cycle() {
    value = switch (value) {
      ThemeMode.system => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
    };
    _prefs.write(_key, value.name);
  }
}

/// Page-lifetime services shared by every route.
class AppServices {
  AppServices({
    required this.connection,
    required this.ruleFiles,
    required CaptureSessionStore store,
    ThemeController? theme,
  }) : rules = RuleBook(connection),
       library = RecordingLibrary(connection: connection, store: store),
       theme = theme ?? ThemeController();

  final MockConnection connection;
  final RuleBook rules;
  final RecordingLibrary library;
  final ThemeController theme;
  final RuleFileTransfer ruleFiles;

  void dispose() {
    rules.dispose();
    library.dispose();
    theme.dispose();
  }
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});

  final AppServices services;

  static AppServices of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.services;

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services;
}

abstract final class Routes {
  static const home = '/';
  static String device(String id) => '/devices/${Uri.encodeComponent(id)}';
  static String recording(String id) =>
      '/recordings/${Uri.encodeComponent(id)}';
}

class LocalMockApp extends StatefulWidget {
  const LocalMockApp({
    super.key,
    this.connection,
    this.ruleFiles = const RuleFileTransfer(),
    this.store = const CaptureSessionStore(),
    this.initialLocation = Routes.home,
    this.themeMode,
  });

  /// Injected relay client (tests). Not disposed and never auto-connected.
  final MockConnection? connection;
  final RuleFileTransfer ruleFiles;
  final CaptureSessionStore store;
  final String initialLocation;

  /// Fixed theme (tests); null uses the persisted preference.
  final ThemeMode? themeMode;

  @override
  State<LocalMockApp> createState() => _LocalMockAppState();
}

class _LocalMockAppState extends State<LocalMockApp> {
  late final MockConnection _connection = widget.connection ?? MockConnection();
  late final AppServices _services = AppServices(
    connection: _connection,
    ruleFiles: widget.ruleFiles,
    store: widget.store,
  );
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<Object>? _savedSub;

  late final GoRouter _router = GoRouter(
    initialLocation: widget.initialLocation,
    routes: [
      GoRoute(
        path: '/',
        pageBuilder: (context, state) =>
            const NoTransitionPage(child: HomePage()),
      ),
      GoRoute(
        path: '/devices/:deviceId',
        pageBuilder: (context, state) {
          final id = state.pathParameters['deviceId']!;
          return NoTransitionPage(
            key: ValueKey('device-$id'),
            child: DevicePage(key: ValueKey(id), deviceId: id),
          );
        },
      ),
      GoRoute(
        path: '/recordings/:recordingId',
        pageBuilder: (context, state) {
          final id = state.pathParameters['recordingId']!;
          return NoTransitionPage(
            key: ValueKey('recording-$id'),
            child: RecordingPage(key: ValueKey(id), recordingId: id),
          );
        },
      ),
    ],
    errorPageBuilder: (context, state) =>
        const NoTransitionPage(child: NotFoundPage()),
  );

  @override
  void initState() {
    super.initState();
    unawaited(_services.library.load());
    _savedSub = _services.library.saved.listen((session) {
      final messenger = _messenger.currentState;
      if (messenger == null) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              '录制「${session.name}」已保存，共 ${session.entries.length} 条请求',
            ),
            action: SnackBarAction(
              label: '查看',
              onPressed: () => _router.go(Routes.recording(session.id)),
            ),
          ),
        );
    });
    // The console is served by the relay itself, so the page origin is the
    // relay address. Connect immediately and keep reconnecting.
    if (kIsWeb && widget.connection == null) {
      unawaited(
        _connection
            .connect(pageOrigin(), autoReconnect: true)
            .catchError((_) {}),
      );
    }
  }

  @override
  void dispose() {
    unawaited(_savedSub?.cancel());
    _router.dispose();
    _services.dispose();
    if (widget.connection == null) _connection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppScope(
    services: _services,
    child: ValueListenableBuilder<ThemeMode>(
      valueListenable: _services.theme,
      builder: (context, mode, _) => MaterialApp.router(
        title: 'Local Mock',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: _messenger,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: widget.themeMode ?? mode,
        routerConfig: _router,
      ),
    ),
  );
}

/// One breadcrumb segment in the top bar.
class Crumb {
  const Crumb(this.label, {this.location, this.mono = false});

  final String label;
  final String? location;
  final bool mono;
}

/// Page frame: top bar with brand, breadcrumbs, live status and theme
/// switch; the body fills the rest of the window.
class AppFrame extends StatelessWidget {
  const AppFrame({
    super.key,
    required this.crumbs,
    required this.body,
    this.status,
  });

  final List<Crumb> crumbs;
  final Widget body;

  /// Page-specific status shown before the global indicators.
  final Widget? status;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final services = AppScope.of(context);
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: Space.topBar,
            child: Row(
              children: [
                const SizedBox(width: Space.gutter),
                _Brand(onTap: () => context.go(Routes.home)),
                for (final crumb in crumbs) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Space.m),
                    child: Text(
                      '/',
                      style: context.text.titleMedium!.copyWith(color: p.faint),
                    ),
                  ),
                  _CrumbLink(crumb),
                ],
                const Spacer(),
                if (status != null) ...[status!, const SizedBox(width: 20)],
                _RecordingIndicator(services: services),
                _RelayIndicator(connection: services.connection),
                const SizedBox(width: Space.s),
                _ThemeSwitch(controller: services.theme),
                const SizedBox(width: Space.m),
              ],
            ),
          ),
          const Hairline(strong: true),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Row(
          children: [
            Container(width: 14, height: 14, color: p.signal),
            const SizedBox(width: 10),
            Text(
              'Local Mock',
              style: context.text.titleMedium!.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CrumbLink extends StatelessWidget {
  const _CrumbLink(this.crumb);

  final Crumb crumb;

  @override
  Widget build(BuildContext context) {
    final style = crumb.mono
        ? mono(context, size: 13.5, weight: FontWeight.w600)
        : context.text.titleMedium!;
    final label = Text(
      crumb.label,
      overflow: TextOverflow.ellipsis,
      style: crumb.location == null
          ? style
          : style.copyWith(color: context.palette.muted),
    );
    if (crumb.location == null) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: label,
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => context.go(crumb.location!),
        child: label,
      ),
    );
  }
}

class _RelayIndicator extends StatelessWidget {
  const _RelayIndicator({required this.connection});

  final MockConnection connection;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: connection,
    builder: (context, _) {
      final connected = connection.connected;
      return Tooltip(
        message: connected ? 'Relay ${pageOrigin()} 已连接' : connection.status,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.s),
          child: Row(
            children: [
              StatusSquare(on: connected, signal: !connected),
              const SizedBox(width: 8),
              Text(
                connected ? 'Relay 在线' : 'Relay 未连接',
                style: context.text.labelMedium!.copyWith(
                  color: connected
                      ? context.palette.muted
                      : context.palette.signal,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _RecordingIndicator extends StatelessWidget {
  const _RecordingIndicator({required this.services});

  final AppServices services;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: services.connection,
    builder: (context, _) {
      final connection = services.connection;
      if (!connection.recording) return const SizedBox.shrink();
      final p = context.palette;
      final device = connection.selectedId;
      return Padding(
        padding: const EdgeInsets.only(right: Space.m),
        child: Material(
          color: p.signal,
          child: InkWell(
            onTap: device == null
                ? null
                : () => context.go(Routes.device(device)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                '● 录制中  ${connection.recordingName} · ${connection.recordedCount}',
                style: context.text.labelMedium!.copyWith(
                  color: p.onSignal,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _ThemeSwitch extends StatelessWidget {
  const _ThemeSwitch({required this.controller});

  final ThemeController controller;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
    valueListenable: controller,
    builder: (context, mode, _) {
      final (icon, label) = switch (mode) {
        ThemeMode.system => (Icons.brightness_auto_outlined, '跟随系统'),
        ThemeMode.light => (Icons.light_mode_outlined, '浅色'),
        ThemeMode.dark => (Icons.dark_mode_outlined, '深色'),
      };
      return ToolButton(
        icon: icon,
        tooltip: '外观：$label（点击切换）',
        onPressed: controller.cycle,
      );
    },
  );
}

class NotFoundPage extends StatelessWidget {
  const NotFoundPage({super.key});

  @override
  Widget build(BuildContext context) => AppFrame(
    crumbs: const [Crumb('404')],
    body: EmptyState(
      mark: '404',
      title: '没有这个页面',
      body: '地址可能已失效。设备调试页和录制页的地址都可以收藏，但对应的设备或录制需要仍然存在。',
      action: FilledButton(
        onPressed: () => context.go(Routes.home),
        child: const Text('返回设备列表'),
      ),
    ),
  );
}
