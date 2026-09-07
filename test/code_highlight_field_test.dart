// Verifies the syntax-highlighting controller tokenizes and renders without
// disturbing the editing model, for its Dart default and for the `json`
// language the storage-view file preview is expected to pass explicitly.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/code_highlight_field_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:highlight/highlight.dart' show highlight;
import 'package:umacapture/src/gui/chara_detail/code_highlight_field.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

const _source =
    'bool filter(CharaRecord r) {\n'
    '  // keep fast horses\n'
    '  return r.status.speed >= 1000 && r.skills.any((s) => s.name.contains("スピード"));\n'
    '}';

void main() {
  test('highlight tokenizes Dart into class-tagged nodes', () {
    final nodes = highlight.parse(_source, language: 'dart').nodes ?? const [];
    final classes = <String>{};
    void walk(List nodes) {
      for (final n in nodes) {
        if (n.className != null) classes.add(n.className as String);
        if (n.children != null) walk(n.children as List);
      }
    }

    walk(nodes);
    expect(classes, contains('keyword')); // bool / return
    expect(classes, contains('comment'));
    expect(classes, contains('string'));
  });

  testWidgets('CodeHighlightController renders highlighted text in a TextField', (tester) async {
    final controller = CodeHighlightController(text: _source);
    late BuildContext capturedContext;

    await tester.pumpWidget(
      MaterialApp(
        // Register the same code-highlight tokens the app installs in
        // app_widget.dart; CodeHighlightController.buildTextSpan reads them via
        // Theme.of(context).codeHighlight, which asserts the extension is present.
        theme: ThemeData(
          brightness: Brightness.dark,
          extensions: <ThemeExtension<dynamic>>[CodeHighlightColors.dark()],
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              capturedContext = context;
              return TextField(controller: controller, maxLines: null);
            },
          ),
        ),
      ),
    );

    // The editing model is untouched.
    expect(controller.text, _source);

    // buildTextSpan produces a multi-token colored span (not one flat run).
    final span = controller.buildTextSpan(context: capturedContext, style: null, withComposing: false);
    expect(span.children, isNotNull);
    expect(span.children!.length, greaterThan(1));
    final colored = span.children!.whereType<TextSpan>().where((s) => s.style?.color != null);
    expect(colored, isNotEmpty);
  });

  testWidgets('CodeHighlightController(language: "json") colors JSON with 2+ distinct styles', (tester) async {
    const source = '{"name": "example", "count": 42, "enabled": true}';
    final controller = CodeHighlightController(text: source, language: 'json');
    late BuildContext capturedContext;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          extensions: <ThemeExtension<dynamic>>[CodeHighlightColors.dark()],
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              capturedContext = context;
              return TextField(controller: controller, maxLines: null);
            },
          ),
        ),
      ),
    );

    final span = controller.buildTextSpan(context: capturedContext, style: null, withComposing: false);

    // Collect (text, style) for every span that actually carries text, walking
    // the FULL tree (not just leaves): highlight nests a classed node one level
    // ("attr" -> its plain-text leaf holds the actual string, e.g. `"name"`), so
    // the style sits on the container while the text sits on its child. Record
    // the nearest enclosing non-null style for each piece of text.
    final byText = <String, TextStyle?>{};
    void walk(InlineSpan s, TextStyle? inherited) {
      if (s is! TextSpan) return;
      final style = s.style ?? inherited;
      if (s.text != null) byText[s.text!] = style;
      s.children?.forEach((c) => walk(c, style));
    }

    walk(span, null);

    // 1) Genuinely colored: the JSON "string"/"number"/"literal" classes are
    // covered by the Dart-authored palette, so at least 2 distinct colors show
    // up (the completion condition this test exists for).
    final distinctColoredStyles = byText.values.where((s) => s?.color != null).toSet();
    expect(distinctColoredStyles.length, greaterThanOrEqualTo(2));

    // 2) Actually parsed as JSON, not silently as some other language: a JSON
    // object key ("attr" class) and a same-shaped quoted VALUE ("string" class,
    // "example") must render in DIFFERENT colors, so a reader can tell a key
    // from a value at a glance. Under the JSON grammar these are genuinely
    // different classes; under most other grammars (e.g. "dart", which has no
    // "attr" concept) both quoted tokens would just be generic strings and
    // would match. So this also pins that [language] actually reaches
    // `highlight.parse` and is not hardcoded to something else.
    final keyColor = byText['"name"']?.color;
    final valueColor = byText['"example"']?.color;
    expect(keyColor, isNotNull, reason: 'a JSON object key ("attr") is styled (CodeHighlightColors.attr)');
    expect(valueColor, isNotNull, reason: 'a JSON string value ("string") is styled');
    expect(keyColor, isNot(equals(valueColor)), reason: 'a key must read differently from a value');
  });

  testWidgets('the cost estimate counts the spans the field actually builds', (tester) async {
    // [codeHighlightSpanCharCost] counts a tree it does not build, so the count
    // and the builder are two descriptions of one shape and can drift apart. The
    // budget would then be enforced against a number that means nothing. Pinned
    // against the rendered tree rather than against a transcribed figure, so a
    // change to `_spans` fails here instead of quietly moving the threshold.
    const source = '{"name": "example", "count": 42, "nested": {"a": [1, 2, "b"], "ok": null}}';
    final controller = CodeHighlightController(text: source, language: 'json');
    late BuildContext capturedContext;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: <ThemeExtension<dynamic>>[CodeHighlightColors.light()]),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              capturedContext = context;
              return TextField(controller: controller, maxLines: null);
            },
          ),
        ),
      ),
    );

    final root = controller.buildTextSpan(context: capturedContext, style: null, withComposing: false);
    var built = 0;
    void count(List<InlineSpan>? children) {
      for (final child in children ?? const <InlineSpan>[]) {
        built += 1;
        count(child is TextSpan ? child.children : null);
      }
    }

    // The root span is the controller's own wrapper, not one `_spans` produced,
    // so the walk starts at its children.
    count(root.children);
    expect(built, greaterThan(10), reason: 'a flat or empty tree would make the comparison below vacuous');
    expect(codeHighlightSpanCharCost(source, 'json'), source.length * built);

    // And the trivial arm, which is what the budget lets through unconditionally:
    // no grammar, one span, cost equal to the length.
    expect(codeHighlightSpanCharCost(source, 'plaintext'), source.length);
  });

  test('the budget is decided by both factors, not by either one alone', () {
    // The property the unit was chosen for. Without this, a threshold on size
    // alone would pass every other test in this file while refusing colour to a
    // long file that is cheap and granting it to a short file that is not.
    final dense = '[${List<String>.filled(4000, '1').join(',')}]';
    final sparse = '{"a": "${'x' * dense.length}"}';

    expect(sparse.length, greaterThan(dense.length), reason: 'the cheap one is the longer one');
    expect(codeHighlightSpanCharCost(sparse, 'json'), lessThan(codeHighlightSpanCharCost(dense, 'json')));
    expect(codeHighlightFitsBudget(sparse, 'json', budget: 400000), isTrue);
    expect(codeHighlightFitsBudget(dense, 'json', budget: 400000), isFalse);
  });
}
