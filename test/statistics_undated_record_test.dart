// A record whose trained date could not be read must not appear on a time axis.
//
// `trained_date` is OCR of the game screen and stays an empty string when the
// recognizer could not read it -- about 2% of real captured records. That empty
// string used to parse to a stand-in date in 1999, and the two time-axis
// statistics derive their extent from the oldest record they are given, so a
// single such record dragged the axis back a quarter of a century and squashed
// every real point into the last few pixels. The chart the user is looking at is
// what these tests assert on: the axis it is handed and the points on it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/gui/statistics.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';

import 'support/records.dart';

/// Enough theme for the chart bodies: they read `theme.chart.series` for the dot
/// colour and the text/colour scheme for the labels.
ThemeData _theme() => ThemeData(extensions: <ThemeExtension<dynamic>>[AppChartColors.standard()]);

/// Five player records spanning 2026/01 to 2026/06, plus one whose trained date
/// the recognizer could not read -- the 2.1% shape, an empty `trained_date`.
List<CharaDetailRecord> _recordsWithOneUndated() => [
  makeRecord(id: "a", card: 1, trainedDate: "2026/01/05", fans: 100, evaluationValue: 10000),
  makeRecord(id: "b", card: 2, trainedDate: "2026/02/10", fans: 200, evaluationValue: 12000),
  makeRecord(id: "c", card: 3, trainedDate: "2026/04/01", fans: 300, evaluationValue: 14000),
  makeRecord(id: "d", card: 4, trainedDate: "2026/05/15", fans: 400, evaluationValue: 16000),
  makeRecord(id: "e", card: 5, trainedDate: "2026/06/20", fans: 500, evaluationValue: 18000),
  makeRecord(id: "undated", card: 6, trainedDate: "", fans: 600, evaluationValue: 20000),
];

void main() {
  group("evaluation trend scatter", () {
    test("the axis spans the real records, not a quarter of a century", () {
      final chart = EvaluationScatterChartData(_recordsWithOneUndated()).build(_theme());
      final data = chart.data;

      // The records cover a little under six months, so the axis -- measured in
      // months from the oldest record -- has to stay in that neighbourhood. The
      // stand-in date put the oldest record in 1999 and made this span ~337.
      expect(data.maxX - data.minX, lessThan(8));

      // And the points have to sit inside it rather than piled against one edge.
      final xs = data.scatterSpots.map((spot) => spot.x).toList();
      expect(xs.reduce((a, b) => a < b ? a : b), lessThan(1));
      expect(xs.reduce((a, b) => a > b ? a : b), greaterThan(4));
    });

    test("plots one point per dated record and none for the undated one", () {
      final chart = EvaluationScatterChartData(_recordsWithOneUndated()).build(_theme());
      expect(chart.data.scatterSpots, hasLength(5));

      // The undated record carries the highest evaluation value in the fixture,
      // so a point for it would be visible on the Y axis too.
      final ys = chart.data.scatterSpots.map((spot) => spot.y);
      expect(ys.contains(20000.0), isFalse);
    });

    test("a library of nothing but undated records leaves the tile with no chart to draw", () {
      final chart = EvaluationScatterChartData([makeRecord(id: "x", card: 1, trainedDate: "")]);
      // What the tile checks before it calls build(), so it renders "-" instead
      // of throwing on an empty reduce.
      expect(chart.entries, isEmpty);
    });
  });

  group("monthly fans", () {
    test("the earliest navigable month is the oldest dated record's, not the undated one's", () {
      final dates = datedRecords(_recordsWithOneUndated()).map((entry) => entry.trainedDate);
      final oldest = dates.reduce((a, b) => a.isBefore(b) ? a : b);
      expect(DateTime(oldest.year, oldest.month), DateTime(2026, 1));
    });

    test("an undated record contributes no fans to any month", () {
      final withUndated = MonthlyFansChartData(_recordsWithOneUndated());
      final withoutUndated = MonthlyFansChartData(
        _recordsWithOneUndated().where((record) => record.trainedDate.isNotEmpty).toList(),
      );
      final start = DateTime(2026, 1);
      final end = DateTime(2026, 2).subtract(const Duration(microseconds: 1));
      final spots = withUndated.parse(start: start, end: end);
      expect(spots.map((spot) => spot.y).toList(), withoutUndated.parse(start: start, end: end).map((s) => s.y));
      // January holds exactly the one dated January record's fans.
      expect(spots.last.y, 100.0);
    });
  });

  // Contrast, kept to record what the pre-fix shape could and could not say: the
  // record model still answers "unknown" for an unreadable date, and the value
  // it used to answer instead is older than every real record -- which is why a
  // test written against a record count, or against "the chart drew something",
  // stayed green while the axis was unreadable.
  group("contrast: what an unreadable trained date used to answer", () {
    test("an empty trained_date is unknown, not a date", () {
      expect(makeRecord(id: "x", card: 1, trainedDate: "").trainedDateAsDateTimeOrNull, isNull);
      expect(makeRecord(id: "y", card: 1, trainedDate: "2026/03/04").trainedDateAsDateTimeOrNull, DateTime(2026, 3, 4));
    });

    test("the stand-in it used to answer precedes every real record", () {
      expect(DateTime(1999, 12, 31).isBefore(DateTime(2026, 1, 5)), isTrue);
    });
  });
}
