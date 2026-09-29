import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/item_cell.dart';
import 'package:umacapture/src/chara_detail/spec/item_cell_text.dart';

/// Fixed text extents, independent of any font: an item character is 10 wide and its line 20 tall with the
/// baseline at 15; a counter character is 8 wide and its line 17 tall with the baseline at 13.
class _FakeMeasurer implements ItemTextMeasurer {
  @override
  ItemTextExtent item(CellItem item, String text) => (width: text.length * 10.0, top: 0, bottom: 20, baseline: 15);

  @override
  ItemTextExtent counter(String text) => (width: text.length * 8.0, top: 0, bottom: 17, baseline: 13);
}

final _measurer = _FakeMeasurer();

List<CellItem> _items(List<String> texts) => [for (final t in texts) CellItem(t, ItemState.normal)];

List<Rect> _boxes(ItemBoxArrangement a) => [for (final (_, p) in a.items) p.box, if (a.counter case final c?) c.box];

void main() {
  const spacing = ItemBoxSpacing();

  group('T1 an item is never split across rows', () {
    test('an item that does not fit at the end of a row starts the next row whole', () {
      final items = _items(['aaa', 'bbb ccc', 'dd']);
      final a = arrangeItemBoxes(items, 3, _measurer, maxWidth: 100);

      expect(a.shown, 3);
      expect(a.counter, isNull);
      expect([for (final (item, p) in a.items) (item, p.text)], [for (final i in items) (i, i.text)]);
      final bbb = a.items[1].$2.box;
      expect(bbb.left, 0);
      expect(bbb.top, spacing.outerMargin + 20 + 2 * spacing.paddingVertical + spacing.rowGap);
      expect(bbb.width, 70 + 2 * spacing.paddingHorizontal);
      for (final box in _boxes(a)) {
        expect(box.right, lessThanOrEqualTo(100));
      }
      // 'dd' does not fit after 'bbb ccc' (77 + 4 + 27 > 100) either.
      expect(a.rows, 3);
    });
  });

  group('T2 padding does not change the gaps', () {
    for (final s in const [
      ItemBoxSpacing(),
      ItemBoxSpacing(paddingHorizontal: 10),
      ItemBoxSpacing(paddingVertical: 5),
      ItemBoxSpacing(paddingHorizontal: 10, paddingVertical: 5),
    ]) {
      test('padding ${s.paddingHorizontal} x ${s.paddingVertical}', () {
        final a = arrangeItemBoxes(
          _items(['aaa', 'bb', 'cccc', 'd', 'eeeee', 'ff', 'ggg']),
          9,
          _measurer,
          maxWidth: 130,
          spacing: s,
        );
        final items = [for (final (_, p) in a.items) p.box];
        expect(a.rows, greaterThan(1));
        final rowTops = {for (final b in items) b.top}.toList()..sort();
        for (final top in rowTops) {
          final row = items.where((b) => b.top == top).toList();
          for (var i = 1; i < row.length; i++) {
            expect(row[i].left - row[i - 1].right, closeTo(s.gap, 1e-9));
          }
        }
        for (var r = 1; r < rowTops.length; r++) {
          final prevBottom = items
              .where((b) => b.top == rowTops[r - 1])
              .map((b) => b.bottom)
              .reduce((x, y) => x > y ? x : y);
          expect(rowTops[r] - prevBottom, closeTo(s.rowGap, 1e-9));
        }
        final boxes = _boxes(a);
        for (var i = 0; i < boxes.length; i++) {
          for (var j = i + 1; j < boxes.length; j++) {
            expect(boxes[i].overlaps(boxes[j]), isFalse, reason: '${boxes[i]} overlaps ${boxes[j]}');
          }
        }
        final counter = a.counter!;
        final last = items.last;
        if (counter.box.left > 0) {
          expect(counter.box.left - last.right, closeTo(s.gap, 1e-9));
        }
      });
    }

    test('the gap goes before a box, not after it (two boxes of 20 with gap 4)', () {
      final a = arrangeItemBoxes(
        _items(['a', 'b']),
        2,
        _measurer,
        maxWidth: double.infinity,
        spacing: const ItemBoxSpacing(paddingHorizontal: 5, gap: 4),
      );
      expect([for (final (_, p) in a.items) p.box.left], [0, 24]);
      expect(a.size.width, 44);
    });
  });

  group('T4 fixed row height shows the most boxes that fit with the counter', () {
    // Each 'aaa' box is 37 wide and 22 tall; two fit on a row of 80. The counter '... k/6' is 56 wide and 17 tall.
    final six = _items(List.filled(6, 'aaa'));
    const row = 22.0;

    test('two rows: the counter falling to a third row is counted', () {
      final bound = 2 * row + 2 * itemBoxCellMarginVertical;
      final a = arrangeItemBoxes(six, 6, _measurer, maxWidth: 80, maxHeight: bound);
      expect(a.shown, 2);
      expect(a.counter!.text, '... 2/6');
      expect(a.size.height, lessThanOrEqualTo(bound));
      final more = arrangeItemBoxes(six.sublist(0, 3), 6, _measurer, maxWidth: 80);
      expect(more.size.height, greaterThan(bound));
    });

    test('three rows', () {
      // Six boxes would fill the three rows exactly; a seventh needs the counter, which then falls to a fourth.
      final seven = _items(List.filled(7, 'aaa'));
      final bound = 3 * row + itemBoxRowGap + 2 * itemBoxCellMarginVertical;
      final a = arrangeItemBoxes(seven, 7, _measurer, maxWidth: 80, maxHeight: bound);
      expect(a.shown, 4);
      expect(a.counter!.text, '... 4/7');
      expect(a.size.height, lessThanOrEqualTo(bound));
      final more = arrangeItemBoxes(seven.sublist(0, 5), 7, _measurer, maxWidth: 80);
      expect(more.size.height, greaterThan(bound));
    });

    test('everything fits: no counter', () {
      final a = arrangeItemBoxes(six, 6, _measurer, maxWidth: 80, maxHeight: 3 * row + 8 + 100);
      expect(a.shown, 6);
      expect(a.counter, isNull);
    });

    test('one row is shown even when it is taller than maxHeight', () {
      final a = arrangeItemBoxes(six, 6, _measurer, maxWidth: 120, maxHeight: 10);
      expect(a.shown, 1);
      expect(a.rows, 1);
      expect(a.counter!.text, '... 1/6');
      expect(a.counter!.box.left, 37 + 4);
    });

    test('several boxes on one row are all shown when that row is taller than maxHeight', () {
      // 'aaa', 'bb' and 'c' are 37 + 4 + 27 + 4 + 17 = 89 wide on one row of 22.
      final a = arrangeItemBoxes(_items(['aaa', 'bb', 'c']), 3, _measurer, maxWidth: 120, maxHeight: 10);
      expect(a.rows, 1);
      expect(a.shown, 3);
      expect(a.counter, isNull);
      expect(a.size.height, greaterThan(10));
    });
  });

  group('T6 the counter box', () {
    test('one unpadded box, gap after the last item, on the item baseline', () {
      final a = arrangeItemBoxes(_items(['aaa', 'bbb ccc', 'dd']), 5, _measurer, maxWidth: double.infinity);
      final counter = a.counter!;
      expect(counter.text, '... 3/5');
      expect(counter.box.width, 7 * 8);
      expect(counter.box.left - a.items.last.$2.box.right, spacing.gap);
      expect(counter.textOrigin.dy + 13, a.items.last.$2.textOrigin.dy + 15);
      expect(counter.box.top, greaterThanOrEqualTo(0));
      expect(counter.box.bottom, lessThanOrEqualTo(a.size.height));
    });

    test('no item but a total: the counter alone', () {
      final a = arrangeItemBoxes(const [], 3, _measurer, maxWidth: 200);
      expect(a.shown, 0);
      expect(a.counter!.text, '... 0/3');
      expect(a.counter!.box, Rect.fromLTWH(0, spacing.outerMargin, 56, 17));
      expect(a.size, Size(56, 17 + 2 * spacing.outerMargin));
    });

    test('nothing at all: no box', () {
      final a = arrangeItemBoxes(const [], 0, _measurer, maxWidth: 200);
      expect(a.items, isEmpty);
      expect(a.counter, isNull);
      expect(a.size, Size.zero);
    });
  });

  group('T7 an item too wide for the column is shortened inside its box', () {
    test('the longest prefix whose box fits', () {
      // 'ab...' is 50 + 7 = 57 wide, 'abc...' 67.
      final a = arrangeItemBoxes(_items(['abcdefghij']), 1, _measurer, maxWidth: 60);
      expect(a.items.single.$2.text, 'ab...');
      expect(a.items.single.$1.text, 'abcdefghij');
      expect(a.items.single.$2.box.right, lessThanOrEqualTo(60));
      expect(a.counter, isNull);
    });

    test('one row only: the first item is shortened to share it with the counter', () {
      final a = arrangeItemBoxes(_items(['abcdefghij', 'x']), 2, _measurer, maxWidth: 120, maxHeight: 10);
      expect(a.shown, 1);
      expect(a.items.single.$2.text, 'ab...');
      expect(a.counter!.text, '... 1/2');
      expect(a.rows, 1);
      expect(a.counter!.box.right, lessThanOrEqualTo(120));
    });
  });

  group('T8 an unbounded width lays every box on one row', () {
    test('width is the boxes plus the gaps between them, counter included', () {
      final a = arrangeItemBoxes(_items(['aaa', 'bbb ccc', 'dd']), 5, _measurer, maxWidth: double.infinity);
      expect(a.rows, 1);
      expect(a.size.width, (37 + 77 + 27) + 56 + 3 * spacing.gap);
      expect(a.size.height, 20 + 2 * spacing.paddingVertical + 2 * spacing.outerMargin);
    });
  });

  group('T9 a cell with boxes has itemBoxCellMarginVertical above and below its content (P7)', () {
    test('the first box starts down by the cell margin; the size includes both margins', () {
      final a = arrangeItemBoxes(_items(['aaa', 'bbb ccc', 'dd']), 3, _measurer, maxWidth: 100);
      expect(a.items.first.$2.box.top, spacing.outerMargin);
      const row = 20 + 2 * itemBoxPaddingVertical;
      expect(a.size.height, 3 * row + 2 * spacing.rowGap + 2 * spacing.outerMargin);
      expect(a.size.height - a.items.last.$2.box.bottom, spacing.outerMargin);
    });

    test('the counter alone is a box and gets the margin too', () {
      final a = arrangeItemBoxes(const [], 3, _measurer, maxWidth: 200);
      expect(a.counter!.box.top, spacing.outerMargin);
      expect(a.size.height, 17 + 2 * spacing.outerMargin);
    });

    test('no box: the size stays zero', () {
      expect(arrangeItemBoxes(const [], 0, _measurer, maxWidth: 200).size, Size.zero);
    });

    test('two table rows of the same height stacked: their boxes are twice the cell margin apart', () {
      // Pure function: a table row is exactly as tall as the arrangement's size when it is the tallest cell, so
      // the gap between the last box of the upper row and the first box of the lower one is size - bottom + top.
      final a = arrangeItemBoxes(_items(['aaa', 'bbb ccc']), 2, _measurer, maxWidth: 100);
      final upperLastBottom = a.items.last.$2.box.bottom;
      final lowerFirstTop = a.size.height + a.items.first.$2.box.top;
      expect(lowerFirstTop - upperLastBottom, 2 * itemBoxCellMarginVertical);
    });

    test('the cell margin does not move with rowGap (independent constants)', () {
      const wide = ItemBoxSpacing(rowGap: 20);
      final a = arrangeItemBoxes(_items(['aaa']), 1, _measurer, maxWidth: 100, spacing: wide);
      expect(a.items.first.$2.box.top, itemBoxCellMarginVertical);
      expect(a.size.height - a.items.first.$2.box.bottom, itemBoxCellMarginVertical);
    });

    test('itemBoxesMinHeight agrees with the arranged height of that many rows', () {
      final m = CellMeasurement(style: const TextStyle(fontSize: 14), textScaler: TextScaler.noScaling);
      final lines = 3;
      final extent = (width: 10.0, top: 0.0, bottom: m.preferredLineHeight, baseline: 0.0);
      final a = arrangeItemBoxes(_items(['a', 'b', 'c']), 3, _FixedMeasurer(extent), maxWidth: 15);
      expect(a.rows, lines);
      expect(itemBoxesMinHeight(lines, m), a.size.height);
    });
  });
}

class _FixedMeasurer implements ItemTextMeasurer {
  _FixedMeasurer(this.extent);

  final ItemTextExtent extent;

  @override
  ItemTextExtent item(CellItem item, String text) => extent;

  @override
  ItemTextExtent counter(String text) => extent;
}
