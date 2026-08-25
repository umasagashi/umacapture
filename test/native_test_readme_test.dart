// THE NATIVE TEST INDEX IS COUNTED BY MACHINE, NOT MAINTAINED BY HOPE.
// Run: .fvm/flutter_sdk/bin/flutter test test/native_test_readme_test.dart
//
// `native/test/README.md` is the only description of what the C++ suite covers, and it is a
// hand-written table asserting facts about a directory -- the shape that goes stale silently. It
// had: 29 of the 56 test translation units were missing from it, including 7 of the 13 under
// `native/test/cv/`, so a reader auditing coverage would have concluded that things like the
// frame shaper, the crop calibrator and the video frame grabber had no unit tests at all.
//
// This suite is Dart only because Dart is where the repo's always-on test job lives: the native
// `ctest` run needs MSVC and OpenCV, while `flutter test` runs on every machine and in CI. It
// compiles nothing native -- it reads three files as text.
//
// NOTHING BELOW NAMES A TEST FILE. Every case derives its roster from the directory, so a new
// `native/test/**/test_*.cpp` fails here until it is described, and a deleted one fails until its
// row is removed. That is the whole point: a list that has to be edited by hand to stay true is
// the defect, not the fix.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _testRoot = 'native/test';
const _readmePath = '$_testRoot/README.md';
const _cmakePath = 'native/CMakeLists.txt';

/// Every C++ translation unit under `native/test/`, as a path relative to that directory.
List<String> _testSources() {
  final root = Directory(_testRoot);
  expect(root.existsSync(), isTrue, reason: '$_testRoot is missing -- this suite is looking at nothing');
  final found =
      root
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.replaceAll(r'\', '/'))
          .where((p) => p.endsWith('.cpp'))
          .map((p) => p.substring('$_testRoot/'.length))
          .toList()
        ..sort();
  // Vacuity guard: a glob that matched nothing, or a handful, would make every assertion below
  // pass while checking nothing. The suite was 56 files when this was written.
  expect(found.length, greaterThan(40), reason: 'the directory scan found only ${found.length} sources');
  return found;
}

/// Every `…/test_*.cpp` path the README mentions.
///
/// Matched as a path so a bare basename cannot stand in for one: two directories may hold files of
/// the same name, and the reverse direction below has to be able to point at a real file.
Set<String> _pathsMentionedIn(String text) {
  return RegExp(r'(?:[a-z0-9_]+/)?test_[a-z0-9_]+\.cpp').allMatches(text).map((m) => m.group(0)!).toSet();
}

void main() {
  test('every native test source is described in the native test README', () {
    final readme = File(_readmePath).readAsStringSync();
    expect(readme.length, greaterThan(2000), reason: '$_readmePath is too short to be the real file');

    final undescribed = _testSources().where((p) => !readme.contains(p)).toList();
    expect(
      undescribed,
      isEmpty,
      reason:
          '${undescribed.length} native test source(s) are not mentioned in $_readmePath. Add a line '
          'for each describing what it covers -- an index that omits a file is worse than no index, '
          'because it reads as a statement that the coverage does not exist.',
    );
  });

  test('the native test README describes no source that is not there', () {
    final readme = File(_readmePath).readAsStringSync();
    final mentioned = _pathsMentionedIn(readme);
    expect(mentioned.length, greaterThan(40), reason: 'only ${mentioned.length} paths parsed out of the README');

    final stale = mentioned.where((p) => !File('$_testRoot/$p').existsSync()).toList()..sort();
    expect(
      stale,
      isEmpty,
      reason:
          '$_readmePath describes ${stale.length} file(s) that no longer exist. A deleted test whose '
          'row survives is a claim of coverage the repository does not have.',
    );
  });

  test('every native test source is registered with a build target', () {
    // The README says the source list "is maintained by hand in both ../CMakeLists.txt and here --
    // keep the two in sync". This is that sentence, counted. A `.cpp` no target lists compiles
    // nowhere, so its cases never run and nothing says so.
    final cmake = File(_cmakePath).readAsStringSync();
    expect(cmake.contains('TEST_SOURCE_FILES'), isTrue, reason: '$_cmakePath does not look like the native build');

    final unregistered = _testSources().where((p) => !cmake.contains('test/$p')).toList();
    expect(
      unregistered,
      isEmpty,
      reason:
          '${unregistered.length} native test source(s) are in no target in $_cmakePath, so they are built '
          'by nothing and their cases never run.',
    );
  });
}
