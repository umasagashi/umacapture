// Verifies the Progress value type, including the indeterminate flag used by
// batch operations (archive) that cannot report a per-step percentage.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/progress_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/utils.dart';

void main() {
  test('defaults to determinate', () {
    final progress = Progress(total: 5);
    expect(progress.indeterminate, isFalse);
    expect(progress.isEmpty, isFalse);
  });

  test('indeterminate marks a busy, percentage-less batch', () {
    // The archive flow publishes this: a non-empty total (so the indicator is
    // shown) but with the indeterminate flag so the UI spins instead of sitting
    // frozen at 0%.
    final progress = Progress(total: 5, indeterminate: true);
    expect(progress.indeterminate, isTrue);
    expect(progress.isEmpty, isFalse);
  });

  test('none is empty and determinate', () {
    expect(Progress.none.isEmpty, isTrue);
    expect(Progress.none.indeterminate, isFalse);
  });
}
