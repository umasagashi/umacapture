// Reading colour off a rendered `CodeHighlightController` field.
//
// Shared because the storage view drops colour on a text too costly to lay out,
// and the two surfaces that reach that field -- the file preview and the
// settings-store dialog -- each need to assert the drop and its control. A
// second copy of the walk would be a second chance to walk the tree wrong.
//
// **Why not `controller.language`.** That is the *input* to the decision, echoed
// back: it says what the field was asked to parse as, not what the reader ends
// up seeing. A palette that stopped resolving, or a `_spans` that stopped
// applying the style it looked up, would leave the grammar reading `json` on a
// field rendered in one flat colour. `buildTextSpan` is where the decision
// becomes pixels, so that is where this looks.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/gui/chara_detail/code_highlight_field.dart';

/// How many spans the field keyed [fieldKey] renders with a colour of their own.
///
/// Zero means the text is one uniform colour on screen -- which is what
/// "colouring was given up on" looks like to the person reading it.
int colouredSpanCount(WidgetTester tester, Key fieldKey) {
  final finder = find.byKey(fieldKey);
  final controller = tester.widget<TextField>(finder).controller! as CodeHighlightController;
  final root = controller.buildTextSpan(context: tester.element(finder), style: null, withComposing: false);
  var coloured = 0;
  void walk(InlineSpan span) {
    if (span is! TextSpan) {
      return;
    }
    if (span.style?.color != null) {
      coloured += 1;
    }
    span.children?.forEach(walk);
  }

  walk(root);
  return coloured;
}
