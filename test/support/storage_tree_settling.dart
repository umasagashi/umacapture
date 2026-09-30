// WAITING FOR STORAGE-TREE ROWS.
//
// A storage row that is still being read shows an indeterminate progress glyph
// (`storageStatusSpinner`), and a group whose total is still being walked shows the word
// 「計算中…」 in place of a size. These helpers wait until neither is on screen, on the
// condition, through `settleUntil`.
//
// Not `pumpAndSettle`: a listing is a `dart:io` future that completes on the real event loop, which
// only `runAsync` reaches, and a spinning indicator schedules a frame on every tick, so
// `pumpAndSettle` would not return while one is on screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'localization.dart';
import 'settling.dart';

/// True while a storage row is still being read or totalled: an indeterminate
/// `CircularProgressIndicator` (`value == null`) or the "calculating" word is on screen.
///
/// A determinate indicator is a task's own progress -- the zip bar -- and not a row being read,
/// so it does not count.
bool storageRowsPending() {
  final spinning = find
      .byWidgetPredicate((widget) => widget is CircularProgressIndicator && widget.value == null)
      .evaluate()
      .isNotEmpty;
  return spinning || find.text(appSentenceAt('pages.storage.status.calculating')).evaluate().isNotEmpty;
}

/// Lets one round of real time and one frame pass, then waits until no storage row is pending.
///
/// The first round is part of the contract: right after a tap or a `pumpWidget` the tree has not
/// rebuilt yet, so no spinner is showing and [storageRowsPending] is already false -- checking it
/// first would return before the read had even started.
Future<void> settleStorageRows(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
  await tester.pump();
  await settleUntil(tester, () => !storageRowsPending(), describe: 'the storage rows to finish loading and totalling');
}
