import 'package:flutter/material.dart';

/// Swiss International Style tokens.
///
/// One neutral ink on paper, a single signal red, hairline rules and zero
/// radius. Red is reserved for things that are *live* or need attention:
/// recording, mocked responses, errors and the brand mark.
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.paper,
    required this.well,
    required this.ink,
    required this.muted,
    required this.faint,
    required this.rule,
    required this.hover,
    required this.selected,
    required this.signal,
    required this.onSignal,
    required this.string,
  });

  /// Page background.
  final Color paper;

  /// Recessed areas: code editors, inputs.
  final Color well;
  final Color ink;
  final Color muted;
  final Color faint;

  /// Hairline separators.
  final Color rule;
  final Color hover;
  final Color selected;

  /// The single accent colour.
  final Color signal;
  final Color onSignal;

  /// JSON string literals – the only second hue, used inside code only.
  final Color string;

  static const light = Palette(
    paper: Color(0xFFFFFFFF),
    well: Color(0xFFF4F4F1),
    ink: Color(0xFF111111),
    muted: Color(0xFF6B6B66),
    faint: Color(0xFFA8A8A2),
    rule: Color(0xFFDDDDD8),
    hover: Color(0xFFF4F4F1),
    selected: Color(0xFFEAEAE5),
    signal: Color(0xFFE2231A),
    onSignal: Color(0xFFFFFFFF),
    string: Color(0xFF1F4E9C),
  );

  static const dark = Palette(
    paper: Color(0xFF111111),
    well: Color(0xFF1A1A19),
    ink: Color(0xFFF0F0EC),
    muted: Color(0xFF9A9A94),
    faint: Color(0xFF5E5E5A),
    rule: Color(0xFF2B2B29),
    hover: Color(0xFF1C1C1B),
    selected: Color(0xFF262624),
    signal: Color(0xFFFF4B32),
    onSignal: Color(0xFF111111),
    string: Color(0xFF8DB2F0),
  );

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(Palette? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return Palette(
      paper: mix(paper, other.paper),
      well: mix(well, other.well),
      ink: mix(ink, other.ink),
      muted: mix(muted, other.muted),
      faint: mix(faint, other.faint),
      rule: mix(rule, other.rule),
      hover: mix(hover, other.hover),
      selected: mix(selected, other.selected),
      signal: mix(signal, other.signal),
      onSignal: mix(onSignal, other.onSignal),
      string: mix(string, other.string),
    );
  }
}

const sansFamily = 'Inter';
const monoFamily = 'JetBrainsMono';

/// Fallbacks for CJK glyphs and for platforms where the bundled fonts are
/// unavailable (unit tests).
const _sansFallback = [
  'PingFang SC',
  'Hiragino Sans GB',
  'Microsoft YaHei',
  'Noto Sans SC',
  'Helvetica Neue',
  'Arial',
];
const monoFallback = ['SF Mono', 'Menlo', 'Consolas', 'PingFang SC'];

/// Grid unit. All spacing is a multiple of 4; layout gutters are 24.
abstract final class Space {
  static const xs = 4.0;
  static const s = 8.0;
  static const m = 12.0;
  static const l = 16.0;
  static const xl = 24.0;
  static const xxl = 40.0;
  static const gutter = 24.0;
  static const topBar = 56.0;
}

extension ThemeX on BuildContext {
  Palette get palette => Theme.of(this).extension<Palette>()!;
  TextTheme get text => Theme.of(this).textTheme;
}

TextStyle mono(
  BuildContext context, {
  double size = 12.5,
  FontWeight weight = FontWeight.w400,
  Color? color,
}) => TextStyle(
  fontFamily: monoFamily,
  fontFamilyFallback: monoFallback,
  fontSize: size,
  fontWeight: weight,
  height: 1.45,
  color: color ?? context.palette.ink,
);

ThemeData buildTheme(Brightness brightness) {
  final p = brightness == Brightness.light ? Palette.light : Palette.dark;
  const square = RoundedRectangleBorder();
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.ink,
    onPrimary: p.paper,
    secondary: p.ink,
    onSecondary: p.paper,
    tertiary: p.signal,
    onTertiary: p.onSignal,
    error: p.signal,
    onError: p.onSignal,
    surface: p.paper,
    onSurface: p.ink,
    onSurfaceVariant: p.muted,
    surfaceContainerLowest: p.paper,
    surfaceContainerLow: p.paper,
    surfaceContainer: p.paper,
    surfaceContainerHigh: p.well,
    surfaceContainerHighest: p.well,
    outline: p.ink,
    outlineVariant: p.rule,
    inverseSurface: p.ink,
    onInverseSurface: p.paper,
    shadow: Colors.transparent,
  );

  TextStyle t(
    double size,
    FontWeight weight, {
    double height = 1.4,
    double spacing = 0,
    Color? color,
  }) => TextStyle(
    fontFamily: sansFamily,
    fontFamilyFallback: _sansFallback,
    fontSize: size,
    fontWeight: weight,
    height: height,
    letterSpacing: spacing,
    color: color ?? p.ink,
  );

  final text = TextTheme(
    displayLarge: t(72, FontWeight.w700, height: 1.0, spacing: -2.6),
    displayMedium: t(48, FontWeight.w700, height: 1.05, spacing: -1.6),
    headlineMedium: t(28, FontWeight.w700, height: 1.15, spacing: -0.7),
    headlineSmall: t(22, FontWeight.w700, height: 1.2, spacing: -0.4),
    titleLarge: t(18, FontWeight.w700, height: 1.3, spacing: -0.2),
    titleMedium: t(15, FontWeight.w600, height: 1.35),
    titleSmall: t(13.5, FontWeight.w600, height: 1.35),
    bodyLarge: t(15, FontWeight.w400, height: 1.5),
    bodyMedium: t(13.5, FontWeight.w400, height: 1.5),
    bodySmall: t(12, FontWeight.w400, height: 1.45, color: p.muted),
    labelLarge: t(13, FontWeight.w600, height: 1.2, spacing: 0.1),
    labelMedium: t(12, FontWeight.w500, height: 1.2),
    labelSmall: t(10.5, FontWeight.w700, height: 1.2, spacing: 1.4),
  );

  ButtonStyle base(Color fg, Color? bg, {BorderSide? side}) => ButtonStyle(
    shape: const WidgetStatePropertyAll(square),
    elevation: const WidgetStatePropertyAll(0),
    splashFactory: NoSplash.splashFactory,
    minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
    textStyle: WidgetStatePropertyAll(text.labelLarge),
    visualDensity: VisualDensity.standard,
    foregroundColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.disabled) ? p.faint : fg,
    ),
    backgroundColor: WidgetStateProperty.resolveWith((s) {
      if (bg == null) return Colors.transparent;
      return s.contains(WidgetState.disabled) ? p.rule : bg;
    }),
    side: side == null
        ? null
        : WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled)
                ? BorderSide(color: p.rule)
                : side,
          ),
    overlayColor: WidgetStateProperty.resolveWith((s) {
      if (s.contains(WidgetState.pressed)) {
        return (bg == null ? p.ink : p.paper).withValues(alpha: 0.16);
      }
      if (s.contains(WidgetState.hovered) || s.contains(WidgetState.focused)) {
        return (bg == null ? p.ink : p.paper).withValues(alpha: 0.08);
      }
      return null;
    }),
  );

  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.zero,
    borderSide: BorderSide(color: p.rule),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    extensions: [p],
    fontFamily: sansFamily,
    fontFamilyFallback: _sansFallback,
    textTheme: text,
    scaffoldBackgroundColor: p.paper,
    canvasColor: p.paper,
    dividerColor: p.rule,
    splashFactory: NoSplash.splashFactory,
    hoverColor: p.hover,
    focusColor: p.selected,
    highlightColor: Colors.transparent,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.signal,
      selectionColor: p.signal.withValues(alpha: 0.22),
      selectionHandleColor: p.signal,
    ),
    dividerTheme: DividerThemeData(color: p.rule, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(style: base(p.paper, p.ink)),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: base(p.ink, null, side: BorderSide(color: p.ink)),
    ),
    textButtonTheme: TextButtonThemeData(style: base(p.ink, null)),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll(square),
        splashFactory: NoSplash.splashFactory,
        iconSize: const WidgetStatePropertyAll(18),
        minimumSize: const WidgetStatePropertyAll(Size(32, 32)),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? p.faint : p.ink,
        ),
        overlayColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.hovered)
              ? p.ink.withValues(alpha: 0.08)
              : null,
        ),
      ),
    ),
    iconTheme: IconThemeData(color: p.ink, size: 18),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: p.well,
      hoverColor: Colors.transparent,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      hintStyle: text.bodyMedium!.copyWith(color: p.faint),
      errorStyle: text.bodySmall!.copyWith(color: p.signal),
      border: inputBorder,
      enabledBorder: inputBorder,
      disabledBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: p.rule.withValues(alpha: 0.5)),
      ),
      focusedBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: p.ink, width: 1.5),
      ),
      errorBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: p.signal),
      ),
      focusedErrorBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: p.signal, width: 1.5),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(side: BorderSide(color: p.ink)),
      titleTextStyle: text.headlineSmall,
      contentTextStyle: text.bodyMedium,
      barrierColor: p.paper.withValues(alpha: 0.72),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.ink,
      contentTextStyle: text.bodyMedium!.copyWith(color: p.paper),
      actionTextColor: p.paper,
      behavior: SnackBarBehavior.floating,
      width: 520,
      elevation: 0,
      shape: square,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: p.ink),
      textStyle: text.labelMedium!.copyWith(color: p.paper),
      waitDuration: const Duration(milliseconds: 400),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(side: BorderSide(color: p.ink)),
      textStyle: text.bodyMedium,
      labelTextStyle: WidgetStatePropertyAll(text.bodyMedium),
      menuPadding: EdgeInsets.zero,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(p.paper),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(0),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(side: BorderSide(color: p.ink)),
        ),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll(square),
        splashFactory: NoSplash.splashFactory,
        minimumSize: const WidgetStatePropertyAll(Size(220, 40)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14),
        ),
        textStyle: WidgetStatePropertyAll(text.bodyMedium),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? p.faint : p.ink,
        ),
        overlayColor: WidgetStatePropertyAll(p.hover),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      radius: Radius.zero,
      thickness: const WidgetStatePropertyAll(6),
      thumbColor: WidgetStatePropertyAll(p.ink.withValues(alpha: 0.28)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.ink,
      linearTrackColor: p.rule,
      linearMinHeight: 2,
    ),
  );
}
