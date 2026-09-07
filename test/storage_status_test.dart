// The storage view's rule that a glyph never stands alone (stage 7), as a check
// the machine performs over the sources rather than one screen at a time.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_status_test.dart
//
// WHY A SOURCE SCAN AND NOT A WIDGET TEST. A widget test can assert that *this*
// surface says something while it waits, and two of them do
// (`storage_file_preview_view_test.dart`, `settings_box_preview_view_test.dart`).
// What neither can assert is that the next surface will: the previous attempt at
// this rule was a comment on a private helper in `storage_tree.dart` claiming
// that building the pair in one place "keeps a later status from being added as
// a bare icon again", and two bare `CircularProgressIndicator`s were added in
// another file regardless. This counts the occurrences itself, so a third one
// fails here on the day it is written instead of on the day someone looks.
//
// WHAT IT DOES NOT REACH. It is a text scan: it sees a constructor call, not
// what is rendered beside it, so a surface that routes through
// `storageStatusSpinner` and then draws it with no message still passes here.
// That half is what the two widget tests above are for. It also says nothing
// about the wording itself — `storage_wording_test.dart` owns that.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The one file allowed to construct the view's progress glyph.
const _owner = 'lib/src/gui/storage_status.dart';

/// Not part of the view, despite the name: `storage_settings.dart` is the
/// *Settings* page's storage section and predates this work, so a rule about
/// this view's surfaces would be quietly taking over another screen's.
const _outsideTheTab = 'lib/src/gui/storage_settings.dart';

/// Every `CircularProgressIndicator(` in [source] that is constructed without a
/// `value:`, i.e. every *indeterminate* one.
///
/// A determinate ring is a different thing and is deliberately not covered: it
/// stands in for a control the user just pressed (`storageZipProgressKey`
/// replaces the zip button while the zip runs) and reports a fraction, where an
/// indeterminate one is the whole of what a surface has to say about being busy.
int indeterminateSpinnersIn(String source) {
  const call = 'CircularProgressIndicator(';
  var found = 0;
  for (var at = source.indexOf(call); at >= 0; at = source.indexOf(call, at + call.length)) {
    final window = source.substring(at, (at + 240).clamp(0, source.length));
    if (!window.contains('value:')) {
      found += 1;
    }
  }
  return found;
}

Iterable<File> _tabSources() sync* {
  for (final directory in ['lib/src/gui', 'lib/src/core/storage']) {
    for (final entity in Directory(directory).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      final path = entity.path.replaceAll(r'\', '/');
      if (path == _outsideTheTab) {
        continue;
      }
      if (path.contains('/storage_') || path.contains('/core/storage/')) {
        yield entity;
      }
    }
  }
}

void main() {
  test('the detector sees an indeterminate spinner and ignores a determinate one', () {
    // The negative control the assertion below rests on: green there means "no
    // file builds its own spinner", and without this it could equally mean the
    // scanner never matches anything.
    expect(indeterminateSpinnersIn('const Center(child: CircularProgressIndicator())'), 1);
    expect(indeterminateSpinnersIn('CircularProgressIndicator(strokeWidth: 2, value: running.fraction)'), 0);
    expect(indeterminateSpinnersIn('nothing here'), 0);
  });

  test('only storage_status.dart builds the view a progress glyph', () {
    final offenders = <String>[];
    var ownerCount = 0;
    for (final file in _tabSources()) {
      final path = file.path.replaceAll(r'\', '/');
      final found = indeterminateSpinnersIn(file.readAsStringSync());
      if (path.endsWith(_owner)) {
        ownerCount = found;
      } else if (found > 0) {
        offenders.add('$path ($found)');
      }
    }
    // The owner still has one. Without this the assertion below would also pass
    // if `storageStatusSpinner` had been deleted and every wait had gone silent.
    expect(ownerCount, 1, reason: 'the shared spinner is gone, so the check below proves nothing');
    expect(
      offenders,
      isEmpty,
      reason: 'a storage-view surface builds its own spinner; use storageStatusSpinner so it carries a sentence',
    );
  });
}
