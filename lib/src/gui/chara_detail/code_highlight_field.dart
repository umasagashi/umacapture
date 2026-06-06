import 'package:flutter/material.dart';
import 'package:highlight/highlight.dart' show highlight, Node;

/// A [TextEditingController] that renders its text as syntax-highlighted Dart.
///
/// Highlighting is purely presentational: it overrides [buildTextSpan] to
/// tokenize the current text with the pure-Dart `highlight` package and colors
/// each token via a brightness-aware theme. The underlying editing model is an
/// ordinary `TextField`, so native selection / IME / undo behaviour is kept.
class DartHighlightController extends TextEditingController {
  DartHighlightController({super.text});

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final theme = Theme.of(context).brightness == Brightness.dark ? _darkTheme : _lightTheme;
    final result = highlight.parse(text, language: 'dart');
    return TextSpan(style: style, children: _spans(result.nodes ?? const [], theme));
  }

  List<InlineSpan> _spans(List<Node> nodes, Map<String, TextStyle> theme) {
    final spans = <InlineSpan>[];
    for (final node in nodes) {
      final style = node.className == null ? null : theme[node.className!];
      if (node.value != null) {
        spans.add(TextSpan(text: node.value, style: style));
      } else if (node.children != null) {
        spans.add(TextSpan(style: style, children: _spans(node.children!, theme)));
      }
    }
    return spans;
  }
}

// Token colors keyed by the `highlight` node class names emitted for Dart.
// Palettes follow VS Code's default light/dark themes for familiarity.

const Map<String, TextStyle> _lightTheme = {
  'comment': TextStyle(color: Color(0xFF008000), fontStyle: FontStyle.italic),
  'quote': TextStyle(color: Color(0xFF008000)),
  'keyword': TextStyle(color: Color(0xFF0000FF)),
  'literal': TextStyle(color: Color(0xFF0000FF)),
  'built_in': TextStyle(color: Color(0xFF267F99)),
  'type': TextStyle(color: Color(0xFF267F99)),
  'class': TextStyle(color: Color(0xFF267F99)),
  'title': TextStyle(color: Color(0xFF795E26)),
  'function': TextStyle(color: Color(0xFF795E26)),
  'string': TextStyle(color: Color(0xFFA31515)),
  'number': TextStyle(color: Color(0xFF098658)),
  'meta': TextStyle(color: Color(0xFFAF00DB)),
  'symbol': TextStyle(color: Color(0xFFAF00DB)),
  'subst': TextStyle(color: Color(0xFF001080)),
  'variable': TextStyle(color: Color(0xFF001080)),
  'params': TextStyle(color: Color(0xFF001080)),
};

const Map<String, TextStyle> _darkTheme = {
  'comment': TextStyle(color: Color(0xFF6A9955), fontStyle: FontStyle.italic),
  'quote': TextStyle(color: Color(0xFF6A9955)),
  'keyword': TextStyle(color: Color(0xFF569CD6)),
  'literal': TextStyle(color: Color(0xFF569CD6)),
  'built_in': TextStyle(color: Color(0xFF4EC9B0)),
  'type': TextStyle(color: Color(0xFF4EC9B0)),
  'class': TextStyle(color: Color(0xFF4EC9B0)),
  'title': TextStyle(color: Color(0xFFDCDCAA)),
  'function': TextStyle(color: Color(0xFFDCDCAA)),
  'string': TextStyle(color: Color(0xFFCE9178)),
  'number': TextStyle(color: Color(0xFFB5CEA8)),
  'meta': TextStyle(color: Color(0xFFC586C0)),
  'symbol': TextStyle(color: Color(0xFFC586C0)),
  'subst': TextStyle(color: Color(0xFF9CDCFE)),
  'variable': TextStyle(color: Color(0xFF9CDCFE)),
  'params': TextStyle(color: Color(0xFF9CDCFE)),
};
