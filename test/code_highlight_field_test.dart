// Verifies the Dart syntax-highlighting controller tokenizes and renders
// without disturbing the editing model.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/code_highlight_field_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:highlight/highlight.dart' show highlight;
import 'package:umacapture/src/gui/chara_detail/code_highlight_field.dart';

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

  testWidgets('DartHighlightController renders highlighted text in a TextField', (tester) async {
    final controller = DartHighlightController(text: _source);
    late BuildContext capturedContext;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
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
}
