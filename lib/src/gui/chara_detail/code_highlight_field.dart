import 'package:flutter/material.dart';
import 'package:highlight/highlight.dart' show highlight, Node;

import '/src/gui/theme_extensions.dart';

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
    final theme = Theme.of(context).codeHighlight.styles;
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
