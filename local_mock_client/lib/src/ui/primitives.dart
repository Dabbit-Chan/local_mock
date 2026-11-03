import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// 1px separator in the rule colour; [strong] uses ink for structural lines.
class Hairline extends StatelessWidget {
  const Hairline({super.key, this.vertical = false, this.strong = false});

  final bool vertical;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final color = strong ? context.palette.ink : context.palette.rule;
    return vertical
        ? VerticalDivider(width: 1, thickness: 1, color: color)
        : Divider(height: 1, thickness: 1, color: color);
  }
}

/// The Local Mock mark on a 24-unit grid: an ink "L" frame missing its
/// corner, with the signal block standing in for it – the mock that answers
/// in place of the real server. Mirrors `web/favicon.svg`.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 18});

  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return CustomPaint(
      size: Size.square(size),
      painter: _BrandMarkPainter(ink: p.ink, signal: p.signal),
    );
  }
}

class _BrandMarkPainter extends CustomPainter {
  const _BrandMarkPainter({required this.ink, required this.signal});

  final Color ink;
  final Color signal;

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.shortestSide / 24;
    Rect r(double x, double y, double w, double h) =>
        Rect.fromLTWH(x * u, y * u, w * u, h * u);
    final inkPaint = Paint()..color = ink;
    canvas
      ..drawRect(r(0, 0, 7, 24), inkPaint)
      ..drawRect(r(0, 17, 24, 7), inkPaint)
      ..drawRect(r(11, 0, 13, 13), Paint()..color = signal);
  }

  @override
  bool shouldRepaint(_BrandMarkPainter old) =>
      old.ink != ink || old.signal != signal;
}

/// Small uppercase label used above fields and as list captions.
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: context.text.labelSmall!.copyWith(
      color: color ?? context.palette.muted,
    ),
  );
}

/// Numbered column heading: `01  规则  12`.
class SectionHeading extends StatelessWidget {
  const SectionHeading({
    super.key,
    required this.index,
    required this.title,
    this.count,
    this.trailing,
  });

  final String index;
  final String title;
  final String? count;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(index, style: mono(context, size: 12, color: p.signal)),
            const SizedBox(width: Space.m),
            Text(title, style: context.text.headlineSmall),
            if (count != null) ...[
              const SizedBox(width: Space.s),
              Text(
                count!,
                style: context.text.headlineSmall!.copyWith(color: p.faint),
              ),
            ],
            const Spacer(),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

enum TagTone { plain, inverse, signal, outline }

/// Compact rectangular label.
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.tone = TagTone.plain});

  final String text;
  final TagTone tone;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (bg, fg, border) = switch (tone) {
      TagTone.plain => (p.well, p.ink, null),
      TagTone.inverse => (p.ink, p.paper, null),
      TagTone.signal => (p.signal, p.onSignal, null),
      TagTone.outline => (Colors.transparent, p.muted, p.rule),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        border: border == null ? null : Border.all(color: border),
      ),
      child: Text(
        text,
        maxLines: 1,
        style: context.text.labelSmall!.copyWith(color: fg, letterSpacing: 0.4),
      ),
    );
  }
}

/// HTTP method in a fixed-width monospace column.
class MethodText extends StatelessWidget {
  const MethodText(this.method, {super.key, this.width = 56, this.size = 12});

  final String method;
  final double width;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Text(
      method.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.clip,
      style: mono(context, size: size, weight: FontWeight.w600),
    ),
  );
}

/// Status code coloured by class: 4xx/5xx and failures use the signal colour.
class StatusText extends StatelessWidget {
  const StatusText({super.key, this.code, this.size = 12});

  final int? code;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final value = code;
    final color = value == null || value >= 400
        ? p.signal
        : value >= 300
        ? p.muted
        : p.ink;
    return Text(
      value == null ? 'ERR' : '$value',
      style: mono(context, size: size, weight: FontWeight.w600, color: color),
    );
  }
}

/// Square status indicator: filled = on, outlined = off, signal = live.
class StatusSquare extends StatelessWidget {
  const StatusSquare({super.key, required this.on, this.signal = false});

  final bool on;
  final bool signal;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = signal ? p.signal : p.ink;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: on ? color : Colors.transparent,
        border: Border.all(color: on ? color : p.faint, width: 1.2),
      ),
    );
  }
}

/// Rectangular on/off switch.
class SquareToggle extends StatelessWidget {
  const SquareToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = onChanged != null;
    final frame = !enabled
        ? p.faint
        : value
        ? p.ink
        : p.muted;
    void toggle() => onChanged?.call(!value);
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: semanticLabel,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              toggle();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: enabled ? toggle : null,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 30,
              height: 16,
              padding: const EdgeInsets.all(2),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(
                color: value ? frame : Colors.transparent,
                border: Border.all(color: frame, width: 1.4),
              ),
              child: Container(
                width: 10,
                height: 10,
                color: value ? p.paper : frame.withValues(alpha: 0.55),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A list row with hover tint, a selection bar on the left edge and
/// keyboard activation.
class ListRow extends StatefulWidget {
  const ListRow({
    super.key,
    required this.child,
    this.onTap,
    this.selected = false,
    this.padding = const EdgeInsets.symmetric(
      horizontal: Space.gutter,
      vertical: Space.m,
    ),
    this.hoverActions,
    this.hoverInset = Space.m,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool selected;
  final EdgeInsetsGeometry padding;

  /// Shown on the right while hovered or selected.
  final Widget? hoverActions;

  /// Distance of [hoverActions] from the right edge.
  final double hoverInset;

  @override
  State<ListRow> createState() => _ListRowState();
}

class _ListRowState extends State<ListRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final background = widget.selected
        ? p.selected
        : _hover && widget.onTap != null
        ? p.hover
        : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: FocusableActionDetector(
        enabled: widget.onTap != null,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            color: background,
            child: Stack(
              children: [
                Padding(padding: widget.padding, child: widget.child),
                if (widget.selected)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: Container(width: 3, color: p.signal),
                  ),
                if (widget.hoverActions != null && (_hover || widget.selected))
                  Positioned(
                    right: widget.hoverInset,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.only(left: Space.s),
                        color: background == Colors.transparent
                            ? p.paper
                            : background,
                        child: widget.hoverActions,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Left-aligned, typographic empty state.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.body,
    this.action,
    this.mark,
  });

  final String title;
  final String? body;
  final Widget? action;

  /// Large glyph shown above the title, e.g. `—` or `00`.
  final String? mark;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.all(Space.gutter),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (mark != null)
                Text(
                  mark!,
                  style: context.text.displayMedium!.copyWith(color: p.rule),
                ),
              const SizedBox(height: Space.m),
              Text(title, style: context.text.titleLarge),
              if (body != null) ...[
                const SizedBox(height: Space.s),
                Text(
                  body!,
                  style: context.text.bodyMedium!.copyWith(color: p.muted),
                ),
              ],
              if (action != null) ...[const SizedBox(height: Space.l), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Inline banner across a column: signal for problems, ink for info.
class Notice extends StatelessWidget {
  const Notice({
    super.key,
    required this.message,
    this.signal = true,
    this.actions = const [],
    this.leading,
  });

  final String message;
  final bool signal;
  final List<Widget> actions;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bg = signal ? p.signal : p.ink;
    final fg = signal ? p.onSignal : p.paper;
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.gutter,
        vertical: Space.s,
      ),
      constraints: const BoxConstraints(minHeight: 44),
      child: DefaultTextStyle.merge(
        style: context.text.bodyMedium!.copyWith(color: fg),
        child: IconTheme.merge(
          data: IconThemeData(color: fg),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 10)],
              Expanded(child: Text(message)),
              for (final action in actions)
                TextButtonTheme(
                  data: TextButtonThemeData(
                    style: TextButton.styleFrom(
                      foregroundColor: fg,
                      shape: const RoundedRectangleBorder(),
                      textStyle: context.text.labelLarge!.copyWith(
                        decoration: TextDecoration.underline,
                        decorationColor: fg,
                      ),
                    ),
                  ),
                  child: action,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Field caption above an input.
class Labeled extends StatelessWidget {
  const Labeled({
    super.key,
    required this.label,
    required this.child,
    this.trailing,
    this.help,
  });

  final String label;
  final Widget child;
  final Widget? trailing;
  final String? help;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        height: 24,
        child: Row(children: [Eyebrow(label), const Spacer(), ?trailing]),
      ),
      const SizedBox(height: 2),
      child,
      if (help != null) ...[
        const SizedBox(height: 6),
        Text(help!, style: context.text.bodySmall),
      ],
    ],
  );
}

/// Label / value pair in a two-column grid.
class Fact extends StatelessWidget {
  const Fact(
    this.label,
    this.value, {
    super.key,
    this.monospace = true,
    this.color,
  });

  final String label;
  final String value;
  final bool monospace;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 112,
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Eyebrow(label),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: monospace
                ? mono(context, color: color)
                : context.text.bodyMedium!.copyWith(color: color),
          ),
        ),
      ],
    ),
  );
}

/// Small square icon button with tooltip.
class ToolButton extends StatelessWidget {
  const ToolButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(icon, size: 17, color: onPressed == null ? null : color),
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints.tightFor(width: 32, height: 32),
    padding: EdgeInsets.zero,
  );
}

/// Shows a one-line toast at the bottom of the page.
void toast(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 5),
        action: actionLabel == null
            ? null
            : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
      ),
    );
}

/// Two-button confirmation dialog. Returns true when confirmed.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      final p = context.palette;
      return AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Text(body),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: p.signal,
                    foregroundColor: p.onSignal,
                  )
                : null,
            autofocus: true,
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result == true;
}

/// Copies [text] and confirms with a toast.
Future<void> copyText(BuildContext context, String text, String what) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) toast(context, '已复制$what');
}
