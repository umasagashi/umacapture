// Regression test for [CellText], the table cell text wrapper behind the
// row-height mode setting.
// Run: .fvm/flutter_sdk/bin/flutter test test/cell_text_test.dart
//
// In wrap mode the cell must clamp to the minimum line count and ellipsize (so a
// narrowed column truncates cleanly instead of clipping its overflow line); in
// the auto modes it must drop the line cap so the row can grow to show every line.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/preference/notifier.dart';

Future<Text> _pumpCellText(WidgetTester tester, {required RowHeightMode mode, int minLines = 2}) async {
  await tester.pumpWidget(
    ProviderScope(
      // entryKey null keeps the notifiers off Hive, so the test needs no storage.
      overrides: [
        charaDetailRowHeightModeProvider.overrideWith(
          () => ExclusiveItemsNotifier<RowHeightMode>(values: RowHeightMode.values, defaultValue: mode, entryKey: null),
        ),
        charaDetailMinRowLinesProvider.overrideWith(
          () => IntNotifier(defaultValue: minLines, min: 1, max: 6, entryKey: null),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: CellText('long cell text'))),
    ),
  );
  return tester.widget<Text>(find.text('long cell text'));
}

void main() {
  testWidgets('clamps to the minimum lines with ellipsis in wrap mode', (tester) async {
    final text = await _pumpCellText(tester, mode: RowHeightMode.wrap, minLines: 3);
    expect(text.maxLines, 3);
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('drops the line cap in auto-per-row mode', (tester) async {
    final text = await _pumpCellText(tester, mode: RowHeightMode.autoPerRow);
    expect(text.maxLines, isNull);
    expect(text.overflow, isNull);
  });

  testWidgets('drops the line cap in auto-uniform mode', (tester) async {
    final text = await _pumpCellText(tester, mode: RowHeightMode.autoUniform);
    expect(text.maxLines, isNull);
    expect(text.overflow, isNull);
  });
}
