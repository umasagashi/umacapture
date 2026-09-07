import 'package:flutter/material.dart';
import 'package:highlight/highlight.dart' show highlight, Node;

import '/src/gui/theme_extensions.dart';

/// A [TextEditingController] that renders its text as syntax-highlighted code.
///
/// Highlighting is purely presentational: it overrides [buildTextSpan] to
/// tokenize the current text with the pure-Dart `highlight` package (using
/// [language], one of the identifiers `highlight` registers, e.g. `'dart'` or
/// `'json'`) and colors each token via a brightness-aware theme. The
/// underlying editing model is an ordinary `TextField`, so native selection /
/// IME / undo behaviour is kept.
///
/// The theme palette ([CodeHighlightColors], in `theme_extensions.dart`) is
/// keyed by `highlight`'s node class names and was chosen for Dart. Other
/// languages emit their own subset of class names, which may or may not be
/// covered by that palette — an uncovered class simply renders unstyled, it
/// does not error.
/// The most `characters × spans` a field will colour before giving up on colour.
///
/// **The unit is a product, because the cost is.** Colouring is two steps and
/// only the second one is expensive: `highlight.parse` costs 31–73 ms over the
/// whole 60–260 KB range (so it is affordable to run *in order to decide*), and
/// laying the resulting `TextSpan` tree out inside a `TextField` costs
/// approximately `characters × spans`. Measured on a real installation's
/// `prediction.json` sliced to nine sizes, with the app's own font, first pump,
/// warm process (one run per row):
///
/// | chars   | spans  | product | pump   | ms per 10⁹ |
/// |---------|--------|---------|--------|------------|
/// |  41,637 |  7,084 | 2.95e8  |   314 ms |  1065 |
/// |  83,588 | 14,182 | 1.19e9  | 1,295 ms |  1092 |
/// | 146,300 | 24,808 | 3.63e9  | 3,513 ms |   968 |
/// | 182,149 | 30,877 | 5.62e9  | 5,903 ms |  1050 |
///
/// The rate is flat to ±8% across that 19× range, and it stays flat when the two
/// factors are moved independently (the same text cut into 1,000 / 8,000 /
/// 30,000 equal spans, at a quarter / half / all of its length). So neither
/// factor alone predicts: 262,144 B of `.log` is **one** span and pumps in
/// ~110 ms, while 260,609 B of JSON is 30,877 spans and pumps in 5,903 ms. A
/// byte or character threshold cannot tell those two apart; this one can, and it
/// also leaves a large JSON whose bulk is a few long string values coloured,
/// because such a file genuinely is cheap.
///
/// **The value is a third of a second, and it is measured rather than
/// extrapolated:** 2.95e8 is the largest product in the table whose measured
/// pump is under that, at 314 ms, so everything this budget permits costs at
/// most about what a configuration that was actually run costs. On the census
/// this tab was designed against that keeps every `record.json` (≤22,126 B, so
/// ≤4e7) coloured — the file the feature exists to read — and drops colour on
/// the `prediction.json` above ~60 KB, which is where the stall was found.
///
/// Nothing here is a claim about a particular machine's milliseconds. The
/// product is the invariant; the rate is what the product was calibrated with.
const int codeHighlightSpanCharBudget = 300000000;

/// What colouring [text] as [language] would cost, in the unit
/// [codeHighlightSpanCharBudget] is expressed in.
///
/// Runs the parse — the cheap half — so the caller can decide with the real span
/// count rather than a guess derived from the size.
int codeHighlightSpanCharCost(String text, String language) {
  final result = highlight.parse(text, language: language);
  return text.length * _countSpans(result.nodes ?? const []);
}

/// Whether [text] may be coloured as [language] within [budget].
bool codeHighlightFitsBudget(String text, String language, {int budget = codeHighlightSpanCharBudget}) {
  return codeHighlightSpanCharCost(text, language) <= budget;
}

/// How many `TextSpan`s [CodeHighlightController._spans] would build for [nodes].
///
/// Mirrors that method arm for arm — a node with a value becomes one span, a
/// node with children becomes one span plus its subtree — because a count taken
/// any other way would be measuring a tree the field does not build.
/// `code_highlight_field_test.dart` pins the two together against the rendered
/// tree, so the mirror cannot drift silently.
int _countSpans(List<Node> nodes) {
  var total = 0;
  for (final node in nodes) {
    if (node.value != null) {
      total += 1;
    } else if (node.children != null) {
      total += 1 + _countSpans(node.children!);
    }
  }
  return total;
}

class CodeHighlightController extends TextEditingController {
  final String language;

  CodeHighlightController({super.text, this.language = 'dart'});

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final theme = Theme.of(context).codeHighlight.styles;
    final result = highlight.parse(text, language: language);
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
