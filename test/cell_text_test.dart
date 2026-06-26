// Regression test for [CellText], the table cell text wrapper behind the
// auto-row-height toggle.
// Run: .fvm/flutter_sdk/bin/flutter test test/cell_text_test.dart
//
// When auto row height is off the cell must clamp to two lines and ellipsize
// (so a narrowed column truncates cleanly instead of clipping its third line);
// when on it must drop the line cap so the row can grow to show every line.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/preference/notifier.dart';

Future<Text> _pumpCellText(WidgetTester tester, {required bool expand}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // entryKey null keeps the notifier off Hive, so the test needs no storage.
        charaDetailAutoRowHeightProvider.overrideWith(() => BooleanNotifier(defaultValue: expand, entryKey: null)),
      ],
      child: const MaterialApp(home: Scaffold(body: CellText('long cell text'))),
    ),
  );
  return tester.widget<Text>(find.text('long cell text'));
}

void main() {
  testWidgets('clamps to two lines with ellipsis when auto height is off', (tester) async {
    final text = await _pumpCellText(tester, expand: false);
    expect(text.maxLines, 2);
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('drops the line cap when auto height is on', (tester) async {
    final text = await _pumpCellText(tester, expand: true);
    expect(text.maxLines, isNull);
    expect(text.overflow, isNull);
  });
}
