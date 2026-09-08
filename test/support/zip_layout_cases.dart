// The cases for `planStorageZipLayout`, written once and run by both suites.
//
// Shared as a function rather than duplicated because the reason this code was
// moved into `zip_bundle.dart` at all is that it must be checkable from the VM
// *and* from `dart test --platform chrome`: two copies that could drift would
// re-open the gap by a different route. `storage_zip_web_export_test.dart` calls
// this on the VM and `storage_zip_export_web_test.dart` calls it in a browser,
// so a difference between `dart2js`'s list semantics and the VM's would show up
// as one suite red and the other green.
//
// `package:test` rather than `flutter_test`: this file has to compile under
// `dart2js`, which cannot build `dart:ui`. `flutter_test` re-exports these same
// `group` / `test` / `expect`, so a VM suite that imports `flutter_test` runs
// these cases unchanged.
// ignore: depend_on_referenced_packages
import 'package:test/test.dart';
import 'package:umacapture/src/core/storage/zip_bundle.dart';

/// Registers every `planStorageZipLayout` case in the calling suite.
void runStorageZipLayoutCases() {
  group('the archive layout of one folder', () {
    test('paths come back relative to the bundled folder, in the order given', () {
      // The index pairing is not decoration: the web runner still holds the
      // `FilePath`s it has to read bytes from, and pairs them with this list by
      // position. A layout that sorted or de-duplicated would put every file's
      // bytes under a different file's name -- an archive that opens fine and is
      // wrong.
      final layout = planStorageZipLayout(
        rootSegmentCount: 3,
        fileSegments: [
          ['C:', 'store', 'rec1', 'b.bin'],
          ['C:', 'store', 'rec1', 'nested', 'a.bin'],
        ],
        directorySegments: const [],
      );

      expect(layout.fileSegments, [
        ['b.bin'],
        ['nested', 'a.bin'],
      ]);
      expect(layout.emptyDirectorySegments, isEmpty);
    });

    test('a folder that holds no file keeps an entry, and one that does holds none', () {
      // Both halves in one case on purpose. The suppression alone is satisfied by
      // a function that returns nothing, and the retention alone by one that
      // returns everything; only together do they describe the rule.
      final layout = planStorageZipLayout(
        rootSegmentCount: 1,
        fileSegments: [
          ['root', 'full', 'x.bin'],
        ],
        directorySegments: [
          ['root', 'full'],
          ['root', 'empty'],
        ],
      );

      expect(layout.emptyDirectorySegments, [
        ['empty'],
      ]);
    });

    test('a file deep in a folder suppresses every folder above it, not just its own', () {
      final layout = planStorageZipLayout(
        rootSegmentCount: 1,
        fileSegments: [
          ['root', 'a', 'b', 'c', 'x.bin'],
        ],
        directorySegments: [
          ['root', 'a'],
          ['root', 'a', 'b'],
          ['root', 'a', 'b', 'c'],
        ],
      );

      expect(layout.emptyDirectorySegments, isEmpty);
    });

    test('an empty folder nested in another empty folder keeps both entries', () {
      // A zip reader creates the parents of an entry it is given, so `a` would
      // come back either way; it is listed anyway because the walk found it and
      // dropping it would make "which folders existed" depend on how deep they
      // were.
      final layout = planStorageZipLayout(
        rootSegmentCount: 1,
        fileSegments: const [],
        directorySegments: [
          ['root', 'a'],
          ['root', 'a', 'b'],
        ],
      );

      expect(layout.emptyDirectorySegments, [
        ['a'],
        ['a', 'b'],
      ]);
    });

    test('containment is by segment, so a folder whose name is a prefix of a sibling survives', () {
      // The failure this excludes is an ancestor test written on the joined path:
      // `root/foo` is a string prefix of `root/foobar/x.bin`, so `foo` would be
      // taken for its parent and silently dropped from the archive.
      final layout = planStorageZipLayout(
        rootSegmentCount: 1,
        fileSegments: [
          ['root', 'foobar', 'x.bin'],
        ],
        directorySegments: [
          ['root', 'foo'],
        ],
      );

      expect(layout.emptyDirectorySegments, [
        ['foo'],
      ]);
    });

    test('an empty folder produces an empty layout rather than an error', () {
      final layout = planStorageZipLayout(rootSegmentCount: 4, fileSegments: const [], directorySegments: const []);

      expect(layout.fileSegments, isEmpty);
      expect(layout.emptyDirectorySegments, isEmpty);
    });
  });
}
