// The rule `web/worker.js` uses to decide which path segments it may create in MEMFS, and whether it is the
// same rule as the store's canon on the Dart side (`isSafeRecordId`, lib/src/core/fs/record_id_safety.dart).
// Run: .fvm/flutter_sdk/bin/flutter test test/worker_refusal_scope_path_guard_test.dart
//
// THE DEFECT THIS PINS. `handleUpdateRecord` validated its `recordId` structurally and said why — the handler
// ends in an unconditional `fsRemoveRecursive` of `active/<recordId>` — while the file paths in the same
// message, which are what actually drive the `FS.mkdir` / `FS.writeFile`, were split and used unchecked. A
// `..` segment survives `filter(Boolean)`, so `../../modules/version_info.json` walked out of the storage
// root and over a file the recognizer reads. Not a vulnerability: the only producer is Dart's own record
// store and a dedicated worker has no cross-origin message surface, so there is no attacker. It is the
// guard's own stated reasoning ("the guard, rather than the caller, is what makes the delete safe to read")
// not being applied to the write in the same handler.
//
// WHAT THIS TEST CAN AND CANNOT PROVE. `web/worker.js` is JavaScript: nothing in `flutter test` can load or
// execute it, so no Dart test can observe the guard refusing anything. The falsification available here is
// therefore about the RULE, not about the code path — this reads the file as text, lifts the character class
// out of it, and checks that the class decides every case the way `isSafeRecordId` decides it, so the two
// cannot drift apart unnoticed. It would still pass an implementation that declared the right class and never
// consulted it; the call sites are asserted structurally below for exactly that reason, and even that is a
// weaker statement than execution. The worker's own Node harnesses (`tool/test_web_*.mjs`) are what execute
// the file, and they exercise the well-formed paths only.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/record_id_safety.dart';

void main() {
  final source = File('web/worker.js').readAsStringSync();

  group('the worker s storage-path rule', () {
    test('is the same character class as the store s canonical record-id rule', () {
      final declaration = RegExp(r'const SAFE_PATH_SEGMENT_PATTERN = /(.+)/;').firstMatch(source);
      expect(declaration, isNotNull, reason: 'web/worker.js no longer declares a single path-segment class');
      final classSource = declaration?.group(1) ?? '';
      final workerRule = RegExp(classSource);

      // Every case the canon distinguishes, plus the two the class alone cannot: `.` and `..` are spelled
      // entirely with characters the class allows, which is why both predicates name them separately.
      const cases = <String>[
        '3f2b0c9a-1d4e-4a77-9d13-2b6a5c0e77aa',
        'record.json',
        'record_1700000000.json',
        'trainee.jpg',
        'chara_detail',
        'active',
        'a-b_c.d',
        '',
        '.',
        '..',
        '../..',
        'a/b',
        r'a\b',
        'a b',
        'ら',
        'C:',
      ];
      for (final candidate in cases) {
        final workerAccepts = candidate != '.' && candidate != '..' && workerRule.hasMatch(candidate);
        expect(
          workerAccepts,
          isSafeRecordId(candidate),
          reason: 'the worker and the store disagree about "$candidate"',
        );
      }
    });

    test('names the two dot segments the class cannot exclude', () {
      // Read off the worker's own predicate rather than assumed by the loop above: if these two comparisons
      // are ever dropped, the loop's `candidate != '.'` would still be re-stating a rule the worker no
      // longer holds, and the equivalence it reports would be about this test rather than about the worker.
      final predicate = RegExp(r'function isSafePathSegment\(segment\) \{(.+?)\n\}', dotAll: true).firstMatch(source);
      expect(predicate, isNotNull, reason: 'web/worker.js no longer states the rule in one predicate');
      final body = predicate?.group(1) ?? '';
      expect(body, contains("segment !== '.'"));
      expect(body, contains("segment !== '..'"));
      expect(body, contains('SAFE_PATH_SEGMENT_PATTERN.test(segment)'));
    });

    test('is applied to every segment the storage writer creates, and to the id the handler deletes by', () {
      final writer = RegExp(
        r'function writeStorageFile\(relPath, bytes\) \{(.+?)\n\}',
        dotAll: true,
      ).firstMatch(source)?.group(1);
      expect(writer, isNotNull, reason: 'web/worker.js no longer has a single storage writer');
      expect(
        writer,
        contains('isSafePathSegment(name)'),
        reason: 'the file name is written unchecked; a `..` name is the traversal on its own',
      );
      expect(
        writer,
        contains('isSafePathSegment(p)'),
        reason: 'the parent segments are mkdir-ed unchecked, which is where `..` walks out of the root',
      );
      expect(
        source,
        contains('if (!isSafePathSegment(recordId)) {'),
        reason: 'the sibling guard no longer shares the rule, so the delete and the write can disagree again',
      );
    });
  });
}
