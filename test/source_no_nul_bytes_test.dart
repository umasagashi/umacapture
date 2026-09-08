import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every tracked `.dart` path, straight from git.
///
/// The set is enumerated by the machine, not listed here. A hand-written list of
/// directories is how this class of check gets escaped: the offending file lived
/// under `test/`, and the one existing tree-walking test in this suite starts at
/// `Directory('lib')`, so a `lib`-shaped scan would have declared the repository
/// clean while the byte was still there. `git ls-files` also keeps the walk away
/// from `.fvm/`, `build/` and `.dart_tool/`, which a filesystem walk from the
/// repository root would drag in.
List<String> _trackedDartFiles() {
  final result = Process.runSync('git', ['ls-files', '-z', '--', '*.dart']);
  // Fail closed. "git could not answer" and "the answer is nothing" must not
  // collapse into the same silent pass -- that collapse is the reason this file
  // exists in the first place.
  if (result.exitCode != 0) {
    fail('Could not list the tracked Dart files (git exit ${result.exitCode}): ${result.stderr}');
  }
  return (result.stdout as String).split('\u0000').where((p) => p.isNotEmpty).toList();
}

void main() {
  test('no tracked Dart source carries a raw NUL byte', () {
    final files = _trackedDartFiles();

    // A scan that reached nothing passes every byte assertion below, so the size
    // and shape of the corpus are asserted before its contents are. Named
    // landmarks rather than a count: a threshold has to be hand-revised every
    // time the tree grows, and the revision is exactly when nobody looks.
    expect(files, isNotEmpty, reason: 'the tracked-Dart scan found no files at all');
    expect(files, contains('lib/main.dart'));
    expect(files.where((p) => p.startsWith('test/')), isNotEmpty, reason: 'the scan never reached test/');
    expect(files.where((p) => !p.endsWith('.dart')), isEmpty, reason: 'the pathspec let in a non-Dart file');

    // A raw NUL makes grep treat the whole file as binary and skip it silently,
    // so a source file carrying one drops out of every text search over the
    // repository without saying so. Write the escape (`'\\u0000'`) instead; it is
    // the same value.
    final offenders = <String>[];
    for (final path in files) {
      final bytes = File(path).readAsBytesSync();
      final offsets = <int>[];
      for (var i = 0; i < bytes.length; i++) {
        if (bytes[i] == 0) offsets.add(i);
      }
      if (offsets.isNotEmpty) {
        offenders.add('$path (${offsets.length} at ${offsets.take(5).join(', ')})');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These tracked Dart sources contain raw NUL bytes, which makes grep skip them '
          "as binary. Write the escape '\\u0000' instead:\n  ${offenders.join('\n  ')}",
    );
  });
}
