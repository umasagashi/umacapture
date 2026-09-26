// The store's canonical path-segment rule (`isSafeRecordId`, lib/src/core/fs/record_id_safety.dart), held to the
// table `web/worker.js` is held to, so the store and the worker that writes into it cannot disagree about a
// segment.
// Run: .fvm/flutter_sdk/bin/flutter test test/worker_refusal_scope_path_guard_test.dart
//
// THE DEFECT THIS PINS. The worker's `updateRecord` handler writes and deletes MEMFS paths built out of the
// record id and the file paths in the message. A `..` segment in either would walk out of the storage root and
// over a file the recognizer reads. The worker refuses such a segment by its own rule (`isSafePathSegment`),
// which has to be the store's rule: a segment one side accepts and the other refuses is a divergence between
// the store and the code that writes into it.
//
// HOW THE TWO SIDES ARE HELD TOGETHER. Neither side reads the other's source. `test/fixtures/
// safe_path_segment_cases.json` lists the segments that must be accepted and the ones that must be refused;
// this file asserts the store's verdict on every entry, and `tool/test_web_video_import.mjs` asserts the
// worker's by delivering an `updateRecord` to the real `web/worker.js` and watching what it stages and what
// it refuses. Neither side can prove anything about a segment the table does not list.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/record_id_safety.dart';

/// The shared table, as `accepted` and `refused` segment lists.
({List<String> accepted, List<String> refused}) readCases() {
  final table =
      jsonDecode(File('test/fixtures/safe_path_segment_cases.json').readAsStringSync()) as Map<String, dynamic>;
  List<String> listOf(String key) => [for (final entry in table[key] as List<dynamic>) entry as String];
  return (accepted: listOf('accepted'), refused: listOf('refused'));
}

void main() {
  final cases = readCases();

  group('the store s path-segment rule, against the table the worker is held to', () {
    test('lists both verdicts, and no segment under both', () {
      // An empty side would make its loop below pass without asserting anything.
      expect(cases.accepted, isNotEmpty);
      expect(cases.refused, isNotEmpty);
      expect(cases.accepted.toSet().intersection(cases.refused.toSet()), isEmpty);
      // The two dot segments are the ones the character class alone cannot refuse.
      expect(cases.refused, containsAll(<String>['.', '..']));
    });

    test('accepts every segment the table accepts', () {
      for (final segment in cases.accepted) {
        expect(isSafeRecordId(segment), isTrue, reason: 'the store refuses "$segment", which the worker stages');
      }
    });

    test('refuses every segment the table refuses', () {
      for (final segment in cases.refused) {
        expect(isSafeRecordId(segment), isFalse, reason: 'the store accepts "$segment", which the worker refuses');
      }
    });
  });
}
