// Regression test for the datetime range filter upper bound.
// Run: .fvm/flutter_sdk/bin/flutter test test/datetime_range_filter_test.dart
//
// The calendar hands the predicate bounds at midnight, but a record's captured
// value carries a time of day. A naive `value <= max` therefore excludes any
// record captured after midnight on the selected end day. The filter must
// compare on calendar day so the whole end day is inclusive.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/spec/datetime.dart';

void main() {
  test('includes a same-day record captured after the midnight end bound', () {
    final predicate = IsInRangeDateTimePredicate(min: DateTime(2026, 6, 1), max: DateTime(2026, 6, 12));
    expect(predicate.apply(DateTime(2026, 6, 12, 14, 30)), isTrue);
    expect(predicate.apply(DateTime(2026, 6, 12, 23, 59, 59)), isTrue);
  });

  test('excludes records outside the day range', () {
    final predicate = IsInRangeDateTimePredicate(min: DateTime(2026, 6, 1), max: DateTime(2026, 6, 12));
    expect(predicate.apply(DateTime(2026, 5, 31, 23, 59)), isFalse);
    expect(predicate.apply(DateTime(2026, 6, 13, 0, 0)), isFalse);
  });

  test('includes the start day regardless of time of day', () {
    final predicate = IsInRangeDateTimePredicate(min: DateTime(2026, 6, 1));
    expect(predicate.apply(DateTime(2026, 6, 1, 8, 0)), isTrue);
    expect(predicate.apply(DateTime(2026, 5, 31, 8, 0)), isFalse);
  });

  test('open bounds match everything', () {
    final predicate = IsInRangeDateTimePredicate();
    expect(predicate.apply(DateTime(2000, 1, 1)), isTrue);
    expect(predicate.apply(DateTime(2099, 12, 31, 23, 59)), isTrue);
  });
}
