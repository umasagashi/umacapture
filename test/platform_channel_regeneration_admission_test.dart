// How many records' input bytes a regeneration batch may hold in main-thread memory at once.
// Run: .fvm/flutter_sdk/bin/flutter test test/platform_channel_regeneration_admission_test.dart
//
// The batch fires `updateRecord` for every obsoleted record in one unawaited loop, and the OPFS
// lock each one takes is per record, so they all proceed together. On web each one reads the
// record's seven input files — the stitched tab PNGs dominate, megabytes apiece — before it
// reaches the worker's own gate, which admits one at a time. So the reads all happened and then
// waited, and a large library could put its whole input set on the main thread at once.
//
// The fix admits one regeneration at a time *around the read*, so the resident set is one
// record's inputs no matter how wide the fan-out. This asserts the bound directly: what the
// admission guarantees is that no two bodies overlap.
//
// NOT covered here, and it cannot be: that `PlatformChannel.updateRecord` wraps its whole body —
// the file reads included — in this admission. `platform_channel_web.dart` imports
// `dart:js_interop` and no VM test can compile it, and the browser suite CI runs does not include
// this slice. The number of records at which a browser actually gives up is likewise unmeasured;
// the bound is asserted, the threshold it used to be measured against is not.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/platform_channel_web_ops.dart';

void main() {
  group('record regeneration admission', () {
    test('never lets two regenerations be resident at once', () async {
      var live = 0;
      var peak = 0;
      final gates = <Completer<void>>[];

      Future<void> regenerate() async {
        live += 1;
        peak = live > peak ? live : peak;
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        live -= 1;
      }

      // The fan-out shape the batch has: submitted in one synchronous loop, none awaited.
      final all = [for (var i = 0; i < 5; i++) admitRecordRegeneration(regenerate)];

      // Release them one by one, in the order they were admitted. Each release lets exactly one
      // more in, so a run that admitted several would show up as a peak above one.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
        expect(gates.length, i + 1, reason: 'exactly one more body may have started');
        gates[i].complete();
      }
      await Future.wait(all);

      expect(peak, 1, reason: 'the resident set is one record, whatever the fan-out is');
      expect(live, 0);
    });

    test('a failed regeneration does not wedge the ones behind it', () async {
      final ran = <String>[];
      final failed = admitRecordRegeneration(() async {
        ran.add('a');
        throw StateError('the worker refused this record');
      });
      final after = admitRecordRegeneration(() async => ran.add('b'));

      await expectLater(failed, throwsA(isA<StateError>()));
      await after;

      // Excludes an admission built on a tail that is only advanced on success: one record whose
      // regeneration throws would then strand every record queued behind it, which is worse than
      // the unbounded reads this replaced.
      expect(ran, ['a', 'b']);
    });

    test('the result of the admitted body is the caller\'s result', () async {
      // Positive control for the two tests above: the admission has to be transparent, or a
      // caller could not tell a committed regeneration from a skipped one.
      expect(await admitRecordRegeneration(() async => true), isTrue);
      expect(await admitRecordRegeneration(() async => false), isFalse);
    });
  });
}
