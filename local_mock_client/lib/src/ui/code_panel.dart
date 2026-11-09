import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/json.dart';

import '../format.dart';
import 'primitives.dart';
import 'theme.dart';

/// Validates editor text; returns an error message or null.
typedef TextValidator = String? Function(String text);

/// Accepts empty text or any JSON value.
String? validateJson(String text) {
  if (text.trim().isEmpty) return null;
  try {
    jsonDecode(text);
    return null;
  } on FormatException catch (error) {
    return _jsonError(text, error);
  }
}

/// Accepts empty text or a JSON object.
String? validateJsonObject(String text) {
  if (text.trim().isEmpty) return null;
  try {
    if (jsonDecode(text) is! Map) return '需要 JSON 对象，例如 {"key": "value"}';
    return null;
  } on FormatException catch (error) {
    return _jsonError(text, error);
  }
}

String _jsonError(String text, FormatException error) {
  final offset = error.offset;
  if (offset == null || offset > text.length) return 'JSON 格式错误';
  final before = text.substring(0, offset);
  final line = '\n'.allMatches(before).length + 1;
  final column = offset - before.lastIndexOf('\n');
  return 'JSON 格式错误：第 $line 行第 $column 列';
}

/// Syntax colours for JSON in the current palette. Keys carry weight,
/// values carry colour; punctuation recedes.
Map<String, TextStyle> _jsonTheme(Palette p) => {
  'root': TextStyle(color: p.ink, backgroundColor: p.well),
  'attr': TextStyle(color: p.ink, fontWeight: FontWeight.w600),
  'string': TextStyle(color: p.string),
  'number': TextStyle(color: p.signal),
  'literal': TextStyle(color: p.signal, fontWeight: FontWeight.w600),
  'punctuation': TextStyle(color: p.muted),
  'comment': TextStyle(color: p.faint),
};

/// A labelled code area built on re_editor: JSON highlighting, line numbers,
/// folding, find (⌘/Ctrl F), a context menu, validation and formatting.
class CodePanel extends StatefulWidget {
  const CodePanel({
    super.key,
    required this.controller,
    this.label,
    this.readOnly = false,
    this.validator,
    this.hint,
    this.onSave,
    this.onChanged,
    this.trailing,
    this.finalAction,
    this.formatAction = true,
    this.wordWrap = false,
    this.showGutter = true,
    this.editorKey,
  });

  final CodeLineEditingController controller;
  final String? label;
  final bool readOnly;
  final TextValidator? validator;
  final String? hint;

  /// ⌘/Ctrl S inside the editor.
  final VoidCallback? onSave;
  final VoidCallback? onChanged;

  /// Extra widgets in the header, left of the built-in actions.
  final Widget? trailing;

  /// Optional action placed at the far right, after search and copy.
  final Widget? finalAction;
  final bool formatAction;
  final bool wordWrap;
  final bool showGutter;

  /// Key placed on the underlying [CodeEditor] (used by tests).
  final Key? editorKey;

  @override
  State<CodePanel> createState() => _CodePanelState();
}

class _CodePanelState extends State<CodePanel> {
  late final _find = CodeFindController(widget.controller);
  Timer? _debounce;
  String? _error;
  late String _lastText = widget.controller.text;

  /// Flips whenever the platform reports new fonts (on the web: CJK
  /// fallback glyphs downloaded on demand).
  bool _fontsFlip = false;

  void _fontsChanged() {
    if (mounted) setState(() => _fontsFlip = !_fontsFlip);
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_textChanged);
    PaintingBinding.instance.systemFonts.addListener(_fontsChanged);
    _error = widget.validator?.call(_lastText);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_textChanged);
    PaintingBinding.instance.systemFonts.removeListener(_fontsChanged);
    _find.dispose();
    super.dispose();
  }

  void _textChanged() {
    final text = widget.controller.text;
    if (text == _lastText) return;
    _lastText = text;
    widget.onChanged?.call();
    if (widget.validator == null) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final error = widget.validator!(widget.controller.text);
      if (error != _error) setState(() => _error = error);
    });
  }

  void _format() {
    final text = widget.controller.text;
    if (text.trim().isEmpty) return;
    try {
      widget.controller.text = prettyJson(jsonDecode(text));
    } on FormatException catch (error) {
      setState(() => _error = _jsonError(text, error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final header =
        widget.label == null &&
            widget.trailing == null &&
            widget.finalAction == null
        ? null
        : SizedBox(
            height: 32,
            child: Row(
              children: [
                if (widget.label != null) Eyebrow(widget.label!),
                if (_error != null) ...[
                  const SizedBox(width: Space.m),
                  Flexible(
                    child: Text(
                      _error!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodySmall!.copyWith(color: p.signal),
                    ),
                  ),
                ],
                const Spacer(),
                ?widget.trailing,
                if (widget.formatAction && !widget.readOnly)
                  ToolButton(
                    icon: Icons.format_align_left,
                    tooltip: '格式化 JSON',
                    onPressed: _format,
                  ),
                ToolButton(
                  icon: Icons.search,
                  tooltip: '查找（⌘/Ctrl F）',
                  onPressed: _find.findMode,
                ),
                ToolButton(
                  icon: Icons.copy_outlined,
                  tooltip: '复制全部',
                  onPressed: () =>
                      copyText(context, widget.controller.text, '内容'),
                ),
                ?widget.finalAction,
              ],
            ),
          );

    final editor = CodeEditor(
      key: widget.editorKey,
      controller: widget.controller,
      findController: _find,
      readOnly: widget.readOnly,
      wordWrap: widget.wordWrap,
      hint: widget.hint,
      padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
      border: Border.all(
        color: _error != null ? p.signal : p.rule,
        width: _error != null ? 1.2 : 1,
      ),
      style: CodeEditorStyle(
        fontFamily: monoFamily,
        // re_editor caches laid-out lines and never re-lays them out when
        // fallback fonts arrive, leaving tofu for CJK text. A different
        // (equivalent) fallback list is a layout change that clears it.
        fontFamilyFallback: [...monoFallback, if (_fontsFlip) monoFamily],
        fontSize: 12.5,
        fontHeight: 1.55,
        textColor: p.ink,
        hintTextColor: p.faint,
        backgroundColor: p.well,
        selectionColor: p.signal.withValues(alpha: 0.22),
        highlightColor: p.signal.withValues(alpha: 0.30),
        cursorColor: p.signal,
        cursorLineColor: widget.readOnly ? null : p.ink.withValues(alpha: 0.04),
        chunkIndicatorColor: p.muted,
        codeTheme: CodeHighlightTheme(
          languages: {'json': CodeHighlightThemeMode(mode: langJson)},
          theme: _jsonTheme(p),
        ),
      ),
      indicatorBuilder: widget.showGutter
          ? (context, editing, chunks, notifier) => Row(
              children: [
                DefaultCodeLineNumber(
                  controller: editing,
                  notifier: notifier,
                  textStyle: mono(context, size: 11.5, color: p.faint),
                  focusedTextStyle: mono(context, size: 11.5, color: p.ink),
                ),
                DefaultCodeChunkIndicator(
                  width: 18,
                  controller: chunks,
                  notifier: notifier,
                ),
              ],
            )
          : null,
      findBuilder: (context, controller, readOnly) =>
          _FindBar(controller: controller, readOnly: readOnly),
      toolbarController: const _ContextMenu(),
      shortcutOverrideActions: {
        if (widget.onSave != null)
          CodeShortcutSaveIntent: CallbackAction<CodeShortcutSaveIntent>(
            onInvoke: (_) {
              widget.onSave!();
              return null;
            },
          ),
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?header,
        Expanded(child: editor),
      ],
    );
  }
}

/// Right-click menu for the editor.
class _ContextMenu implements SelectionToolbarController {
  const _ContextMenu();

  @override
  void hide(BuildContext context) {}

  @override
  void show({
    required BuildContext context,
    required CodeLineEditingController controller,
    required TextSelectionToolbarAnchors anchors,
    Rect? renderRect,
    required LayerLink layerLink,
    required ValueNotifier<bool> visibility,
  }) {
    final editable =
        !(context.findAncestorWidgetOfExactType<CodeEditor>()?.readOnly ??
            false);
    PopupMenuItem<void> item(String label, String keys, VoidCallback onTap) =>
        PopupMenuItem<void>(
          height: 36,
          onTap: onTap,
          child: SizedBox(
            width: 168,
            child: Row(
              children: [
                Expanded(child: Text(label)),
                Text(
                  keys,
                  style: mono(context, size: 11, color: context.palette.muted),
                ),
              ],
            ),
          ),
        );
    unawaited(
      showMenu<void>(
        context: context,
        position: RelativeRect.fromSize(
          anchors.primaryAnchor & const Size(1, 1),
          MediaQuery.sizeOf(context),
        ),
        items: [
          if (editable) item('剪切', '⌘X', controller.cut),
          item('复制', '⌘C', controller.copy),
          if (editable) item('粘贴', '⌘V', controller.paste),
          item('全选', '⌘A', controller.selectAll),
        ],
      ),
    );
  }
}

/// Find / replace strip shown above the editor.
class _FindBar extends StatelessWidget implements PreferredSizeWidget {
  const _FindBar({required this.controller, required this.readOnly});

  final CodeFindController controller;
  final bool readOnly;

  static const _row = 40.0;

  @override
  Size get preferredSize {
    final value = controller.value;
    if (value == null) return Size.zero;
    return Size(
      double.infinity,
      // Rows plus the 1px bottom border.
      (value.replaceMode && !readOnly ? _row * 2 : _row) + 1,
    );
  }

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    if (value == null) return const SizedBox.shrink();
    final p = context.palette;
    final result = value.result;
    final count = result == null || result.matches.isEmpty
        ? '无结果'
        : '${result.index + 1} / ${result.matches.length}';

    Widget field(TextEditingController text, FocusNode focus, String hint) =>
        SizedBox(
          width: 240,
          height: 28,
          child: TextField(
            controller: text,
            focusNode: focus,
            style: mono(context, size: 12),
            decoration: InputDecoration(
              hintText: hint,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 6,
              ),
            ),
          ),
        );

    Widget toggle(String label, bool on, VoidCallback onTap, String tip) =>
        Tooltip(
          message: tip,
          child: InkWell(
            onTap: onTap,
            child: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              color: on ? p.ink : Colors.transparent,
              child: Text(
                label,
                style: mono(context, size: 11, color: on ? p.paper : p.muted),
              ),
            ),
          ),
        );

    // CodeEditor stacks this widget unpositioned on top of the text and only
    // shifts the text down by [preferredSize]; anything taller would cover it.
    return Container(
      key: const Key('code-find-bar'),
      height: preferredSize.height,
      decoration: BoxDecoration(
        color: p.paper,
        border: Border(bottom: BorderSide(color: p.rule)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: _row,
            child: Row(
              children: [
                field(
                  controller.findInputController,
                  controller.findInputFocusNode,
                  '查找',
                ),
                const SizedBox(width: 4),
                toggle(
                  'Aa',
                  value.option.caseSensitive,
                  controller.toggleCaseSensitive,
                  '区分大小写',
                ),
                toggle(
                  '.*',
                  value.option.regex,
                  controller.toggleRegex,
                  '正则表达式',
                ),
                const SizedBox(width: 8),
                Text(count, style: context.text.bodySmall),
                const Spacer(),
                ToolButton(
                  icon: Icons.arrow_upward,
                  tooltip: '上一个',
                  onPressed: result == null ? null : controller.previousMatch,
                ),
                ToolButton(
                  icon: Icons.arrow_downward,
                  tooltip: '下一个',
                  onPressed: result == null ? null : controller.nextMatch,
                ),
                ToolButton(
                  icon: Icons.close,
                  tooltip: '关闭（Esc）',
                  onPressed: controller.close,
                ),
              ],
            ),
          ),
          if (value.replaceMode && !readOnly)
            SizedBox(
              height: _row,
              child: Row(
                children: [
                  field(
                    controller.replaceInputController,
                    controller.replaceInputFocusNode,
                    '替换为',
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: result == null ? null : controller.replaceMatch,
                    child: const Text('替换'),
                  ),
                  TextButton(
                    onPressed: result == null
                        ? null
                        : controller.replaceAllMatches,
                    child: const Text('全部替换'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Convenience for read-only display of a captured body.
CodeLineEditingController readOnlyCode(String? text) =>
    CodeLineEditingController.fromText(prettyBody(text));

/// Keyboard shortcut descriptor shown in tooltips.
String get saveShortcut =>
    defaultTargetPlatform == TargetPlatform.macOS ? '⌘S' : 'Ctrl+S';
