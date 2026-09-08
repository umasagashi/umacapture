// Widget tests for the delete confirmation dialogs' async confirm path.
//
// The delete became asynchronous, which opened a window in which the dialog can be closed (its scrim is
// dismissible) while the delete is still running. Everything the post-await steps touch must therefore be
// prepared before the await, and the dismissal must be scoped to this dialog's own token.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/delete_record_dialog_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/gui/chara_detail/delete_record_dialog.dart';
import 'package:umacapture/src/gui/common.dart';

import 'support/localization.dart';
import 'support/records.dart';

/// Record storage whose deletes complete when the test says so.
///
/// Deletes behave the way the real store behaves once the record lock has been
/// acquired: the ids this store still holds are erased and reported as
/// succeeded, and an id it no longer holds is reported as *failed* — the rule in
/// `_deleteAllAsyncUnlocked` ("not in memory means this store cannot say the
/// record is gone") that turns a repeated delete of an already-deleted record
/// into a "deletion failed" toast. Calls settle in the order they arrived,
/// because the lock serialises them rather than refusing the second one.
class _FakeRecordStorage extends CharaDetailRecordStorage {
  final deleteAllCalls = <Set<String>>[];

  /// What each settled delete reported back, in settle order.
  final reported = <RecordDeleteResult>[];

  final Set<String> _held = {'a', 'b'};
  final List<Completer<void>> _gates = [];

  bool get hasPendingDelete => _gates.any((e) => !e.isCompleted);

  @override
  Future<List<CharaDetailRecord>> build() async => const [];

  @override
  CharaDetailRecord? getBy({required String id}) {
    return _held.contains(id) ? makeRecord(id: id, card: 1) : null;
  }

  @override
  Future<RecordDeleteResult> deleteAsync(String id) => deleteAllAsync([id]);

  @override
  Future<RecordDeleteResult> deleteAllAsync(Iterable<String> ids) {
    final idSet = ids.toSet();
    deleteAllCalls.add(idSet);
    final gate = Completer<void>();
    _gates.add(gate);
    return gate.future.then((_) => _erase(idSet));
  }

  /// Lets the oldest unsettled delete run to completion.
  void settle() => _gates.firstWhere((e) => !e.isCompleted).complete();

  /// Fails the oldest unsettled delete outright (e.g. the lock was unavailable).
  void settleWithError(Object error) =>
      _gates.firstWhere((e) => !e.isCompleted).completeError(error, StackTrace.current);

  RecordDeleteResult _erase(Set<String> ids) {
    final succeeded = <String>{};
    final failed = <String>{};
    for (final id in ids) {
      (_held.remove(id) ? succeeded : failed).add(id);
    }
    final result = RecordDeleteResult(succeeded: Set.unmodifiable(succeeded), failed: Set.unmodifiable(failed));
    reported.add(result);
    return result;
  }
}

/// Settles every delete the fake is already holding, one per pumped frame.
///
/// Capped by turns rather than by seconds, because this loop advances only the fake clock:
/// `tester.pump()` never hands control back to the real event loop, so neither `package:test`'s 30s
/// nor the binding's 10-minute timeout ever gets a turn to fire, and a loop that spins here spins
/// until the process is killed with no reason printed.
///
/// The cap is the number of deletes issued *before* the loop started, which is not a guess:
/// [_FakeRecordStorage.settle] completes exactly one gate per turn and one gate exists per
/// `deleteAllAsync` call, so that many turns always suffice. Needing more means the confirm is
/// issuing fresh deletes as the old ones settle -- the very failure these cases are about, so it
/// has to be reported rather than waited out.
Future<void> _settlePendingDeletes(WidgetTester tester, _FakeRecordStorage storage) async {
  final issued = storage.deleteAllCalls.length;
  for (var turns = 0; storage.hasPendingDelete; turns++) {
    if (turns >= issued) {
      fail(
        'the store still held an unsettled delete after $turns turns, one per delete issued; '
        'confirming is issuing new deletes as the old ones settle',
      );
    }
    storage.settle();
    await tester.pump();
  }
}

class _ShowButton extends ConsumerWidget {
  const _ShowButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: () => BulkDeleteRecordDialog.show(ref.base, recordIds: const ['a', 'b'], source: RecordSource.active),
      child: const Text('show delete dialog'),
    );
  }
}

class _ShowSingleButton extends ConsumerWidget {
  const _ShowSingleButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: () => DeleteRecordDialog.show(ref.base, recordId: 'a'),
      child: const Text('show single delete dialog'),
    );
  }
}

Future<({ProviderContainer container, _FakeRecordStorage storage})> _pump(WidgetTester tester) async {
  final storage = _FakeRecordStorage();
  final container = ProviderContainer(overrides: [charaDetailRecordStorageLoaderProvider.overrideWith(() => storage)]);
  addTearDown(container.dispose);
  container.read(selectionModeProvider.notifier).set(SelectionPurpose.delete);
  container.read(selectedRecordIdsProvider.notifier).set({'a', 'b'});
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: DialogLayer(child: const Scaffold(body: _ShowButton())),
      ),
    ),
  );
  await tester.tap(find.text('show delete dialog'));
  await tester.pump();
  expect(find.byType(BulkDeleteRecordDialog), findsOneWidget);
  // Destructive confirmations require a long press; a plain tap is a no-op.
  await tester.longPress(find.widgetWithIcon(FilledButton, Symbols.delete_rounded));
  await tester.pump();
  expect(storage.deleteAllCalls, [
    {'a', 'b'},
  ]);
  return (container: container, storage: storage);
}

/// Opens the bulk confirmation without answering it.
///
/// The part of [_pump] that precedes the long press, so the positive control can
/// tap the same barrier coordinate with no delete under way.
Future<ProviderContainer> _pumpUnconfirmed(WidgetTester tester) async {
  final storage = _FakeRecordStorage();
  final container = ProviderContainer(overrides: [charaDetailRecordStorageLoaderProvider.overrideWith(() => storage)]);
  addTearDown(container.dispose);
  container.read(selectionModeProvider.notifier).set(SelectionPurpose.delete);
  container.read(selectedRecordIdsProvider.notifier).set({'a', 'b'});
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: DialogLayer(child: const Scaffold(body: _ShowButton())),
      ),
    ),
  );
  await tester.tap(find.text('show delete dialog'));
  await tester.pump();
  expect(find.byType(BulkDeleteRecordDialog), findsOneWidget);
  return container;
}

/// Opens the single-record confirmation and answers it, leaving the delete held.
Future<({ProviderContainer container, _FakeRecordStorage storage})> _pumpSingle(WidgetTester tester) async {
  final storage = _FakeRecordStorage();
  final temp = DirectoryPath(Directory.systemTemp.path);
  final container = ProviderContainer(
    overrides: [
      charaDetailRecordStorageLoaderProvider.overrideWith(() => storage),
      pathInfoProvider.overrideWithValue(
        PathInfo(documentDir: temp, supportDir: temp, executableDir: temp, downloadDir: temp),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: DialogLayer(child: const Scaffold(body: _ShowSingleButton())),
      ),
    ),
  );
  await tester.tap(find.text('show single delete dialog'));
  await tester.pump();
  expect(find.byType(DeleteRecordDialog), findsOneWidget);
  await tester.longPress(find.widgetWithIcon(FilledButton, Symbols.delete_rounded));
  await tester.pump();
  expect(storage.deleteAllCalls, [
    {'a'},
  ]);
  return (container: container, storage: storage);
}

/// The confirmation's cancel button, scoped to [dialog].
///
/// `find.byType(OutlinedButton)` would match nothing: `OutlinedButton.icon`
/// returns a private subclass and `byType` compares `runtimeType` exactly, so a
/// "cancel is disabled" assertion written that way would pass with the button
/// live on screen.
Finder _cancelButton(Finder dialog) {
  return find.descendant(of: dialog, matching: find.byWidgetPredicate((widget) => widget is OutlinedButton));
}

/// The title bar's × for [dialog]. Scoped by dialog rather than by tooltip
/// because the bulk dialog gives its × and its cancel the same tooltip, and this
/// is the only [IconButton] either confirmation builds.
Finder _closeButton(Finder dialog) => find.descendant(of: dialog, matching: find.byType(IconButton));

/// Lets the held delete finish and asserts it did, without reporting a failure.
///
/// The second half of every exit test: shutting a door must not also stop the
/// delete behind it, and a dialog that survived the exit while silently dropping
/// its delete would satisfy the first assertion alone.
Future<void> _expectHeldDeleteFinished(WidgetTester tester, _FakeRecordStorage storage, Finder dialog) async {
  storage.settle();
  await tester.pump();
  await _settlePendingDeletes(tester, storage);
  expect(storage.reported.where((e) => !e.isSuccess), isEmpty, reason: 'a delete that ran was reported as a failure');
  expect(dialog, findsNothing, reason: 'the confirmation outlived its delete');
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  testWidgets('leaves selection mode as soon as the delete starts', (tester) async {
    final h = await _pump(tester);

    // Not after the delete settles: the dialog can be gone by then, and the checked rows are on their way
    // out either way.
    expect(h.container.read(selectionModeProvider), isNull);
    expect(h.container.read(selectedRecordIdsProvider), isEmpty);

    h.storage.settle();
    await tester.pump();
    expect(find.byType(BulkDeleteRecordDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('survives the dialog being closed while the delete runs', (tester) async {
    final h = await _pump(tester);

    // The scrim is dismissible, so a bulk delete on OPFS is easily long enough for the user to close the
    // dialog mid-flight. Touching a WidgetRef after that throws a StateError into the unawaited future.
    h.container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();
    expect(find.byType(BulkDeleteRecordDialog), findsNothing);

    h.storage.settle();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failing delete neither throws nor leaves the dialog open', (tester) async {
    final h = await _pump(tester);

    h.storage.settleWithError(StateError('lock unavailable'));
    await tester.pump();
    expect(find.byType(BulkDeleteRecordDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a second confirm does not report the finished delete as a failure', (tester) async {
    final h = await _pump(tester);

    // The record lock makes the first delete wait instead of refusing the second caller, and nothing on
    // screen says the delete is running, so pressing again is the natural response to the silence. A second
    // run reaching the store after the first one finished finds every id already gone and reports the whole
    // batch as failed - an error toast for a delete that succeeded.
    await tester.longPress(find.widgetWithIcon(FilledButton, Symbols.delete_rounded));
    await tester.pump();

    h.storage.settle();
    await tester.pump();
    await _settlePendingDeletes(tester, h.storage);
    // What the user is told, then why: no batch reported a failure, because only one delete was ever issued.
    expect(h.storage.reported.where((e) => !e.isSuccess), isEmpty);
    expect(h.storage.deleteAllCalls, [
      {'a', 'b'},
    ]);
    expect(find.byType(BulkDeleteRecordDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('withdraws the confirm and shows progress while the delete runs', (tester) async {
    final h = await _pump(tester);

    // Withdrawing the confirm on its own would be a refusal that states no reason - the defect the running
    // indicator answers. Both come from the same flag, so neither can appear without the other.
    final confirm = tester.widget<FilledButton>(find.widgetWithIcon(FilledButton, Symbols.delete_rounded));
    expect(confirm.onPressed, isNull);
    expect(confirm.onLongPress, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    h.storage.settle();
    await tester.pump();
    expect(find.byType(BulkDeleteRecordDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the single-record dialog withdraws its confirm too', (tester) async {
    // The context-menu dialog reaches the same store through deleteAsync, so it carries the same defect and
    // needs its own cover: neither class can be fixed by the other one being fixed.
    final storage = _FakeRecordStorage();
    final temp = DirectoryPath(Directory.systemTemp.path);
    final container = ProviderContainer(
      overrides: [
        charaDetailRecordStorageLoaderProvider.overrideWith(() => storage),
        pathInfoProvider.overrideWithValue(
          PathInfo(documentDir: temp, supportDir: temp, executableDir: temp, downloadDir: temp),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DialogLayer(child: const Scaffold(body: _ShowSingleButton())),
        ),
      ),
    );
    await tester.tap(find.text('show single delete dialog'));
    await tester.pump();
    expect(find.byType(DeleteRecordDialog), findsOneWidget);

    await tester.longPress(find.widgetWithIcon(FilledButton, Symbols.delete_rounded));
    await tester.pump();
    final confirm = tester.widget<FilledButton>(find.widgetWithIcon(FilledButton, Symbols.delete_rounded));
    expect(confirm.onPressed, isNull);
    expect(confirm.onLongPress, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.longPress(find.widgetWithIcon(FilledButton, Symbols.delete_rounded));
    await tester.pump();
    storage.settle();
    await tester.pump();
    await _settlePendingDeletes(tester, storage);
    expect(storage.reported.where((e) => !e.isSuccess), isEmpty);
    expect(storage.deleteAllCalls, [
      {'a'},
    ]);
  });

  testWidgets('leaves a dialog opened meanwhile alone', (tester) async {
    final h = await _pump(tester);

    // An ordinary `show` replaces whatever is up, so this replaces the delete confirmation (only the
    // storage view asks to stack, with `over: true`). The pending delete must not take the unrelated
    // dialog down with it when it finally settles.
    h.container
        .read(dialogBuilderProvider.notifier)
        .show(
          (_) => const CardDialog(
            key: Key('other-dialog'),
            dialogTitle: 'other dialog',
            usePageView: false,
            content: SizedBox(width: 100, height: 100),
          ),
        );
    await tester.pump();
    expect(find.byKey(const Key('other-dialog')), findsOneWidget);

    h.storage.settle();
    await tester.pump();
    expect(find.byKey(const Key('other-dialog')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // **A confirmation has three exits, and the withdrawn confirm is not one of
  // them.** The group above pins that a second press cannot be made through the
  // confirm button. It says nothing about the barrier, the title bar's x and
  // cancel, each of which unmounts the dialog outright -- and `_deleting` goes
  // with the widget, so the rows are listed again with their delete entries live
  // and the same records can be sent to the store a second time. The store's
  // cross-tab lock makes that second call *wait* rather than refusing it, so it
  // arrives after the first delete erased the records, finds every id missing and
  // reports the whole batch as failed: an error toast for a delete that worked.
  //
  // One test per exit and per dialog, so a guard put back for one door and not
  // the others cannot hide behind a neighbour.
  //
  // **The positive control for the barrier tests.** Those tap a bare coordinate
  // and assert nothing happened, which is what a tap that *missed* the barrier
  // looks like too. This states that the same coordinate does reach a live
  // barrier, so "nothing happened" there is a refusal and not a miss.
  testWidgets('the same barrier tap does close the confirmation before the delete starts', (tester) async {
    await _pumpUnconfirmed(tester);

    await tester.tapAt(const Offset(4, 4));
    await tester.pump();

    expect(
      find.byType(BulkDeleteRecordDialog),
      findsNothing,
      reason: 'the tap the barrier tests rely on does not reach the barrier at all',
    );
  });

  testWidgets('the barrier does not close the bulk confirmation mid-delete', (tester) async {
    final h = await _pump(tester);

    await tester.tapAt(const Offset(4, 4));
    await tester.pump();

    expect(
      find.byType(BulkDeleteRecordDialog),
      findsOneWidget,
      reason: 'a tap on the barrier closed the confirmation while its delete was running',
    );
    await _expectHeldDeleteFinished(tester, h.storage, find.byType(BulkDeleteRecordDialog));
  });

  testWidgets('the close button does not close the bulk confirmation mid-delete', (tester) async {
    final h = await _pump(tester);
    final close = _closeButton(find.byType(BulkDeleteRecordDialog));

    expect(tester.widget<IconButton>(close).onPressed, isNull, reason: 'the title bar x is live while the delete runs');
    await tester.tap(close, warnIfMissed: false);
    await tester.pump();

    expect(
      find.byType(BulkDeleteRecordDialog),
      findsOneWidget,
      reason: 'the title bar x closed the confirmation while its delete was running',
    );
    await _expectHeldDeleteFinished(tester, h.storage, find.byType(BulkDeleteRecordDialog));
  });

  testWidgets('the cancel button does not close the bulk confirmation mid-delete', (tester) async {
    final h = await _pump(tester);
    final cancel = _cancelButton(find.byType(BulkDeleteRecordDialog));

    expect(tester.widget<ButtonStyleButton>(cancel).enabled, isFalse, reason: 'cancel is live while the delete runs');
    await tester.tap(cancel, warnIfMissed: false);
    await tester.pump();

    expect(
      find.byType(BulkDeleteRecordDialog),
      findsOneWidget,
      reason: 'cancel closed the confirmation while its delete was running',
    );
    await _expectHeldDeleteFinished(tester, h.storage, find.byType(BulkDeleteRecordDialog));
  });

  // The same three claims on the single-record dialog, which reaches the same
  // store through `deleteAsync` and carries its own copy of every exit: neither
  // class can be fixed by the other one being fixed.
  testWidgets('the barrier does not close the single confirmation mid-delete', (tester) async {
    final h = await _pumpSingle(tester);

    await tester.tapAt(const Offset(4, 4));
    await tester.pump();

    expect(
      find.byType(DeleteRecordDialog),
      findsOneWidget,
      reason: 'a tap on the barrier closed the confirmation while its delete was running',
    );
    await _expectHeldDeleteFinished(tester, h.storage, find.byType(DeleteRecordDialog));
  });

  testWidgets('the close button does not close the single confirmation mid-delete', (tester) async {
    final h = await _pumpSingle(tester);
    final close = _closeButton(find.byType(DeleteRecordDialog));

    expect(tester.widget<IconButton>(close).onPressed, isNull, reason: 'the title bar x is live while the delete runs');
    await tester.tap(close, warnIfMissed: false);
    await tester.pump();

    expect(
      find.byType(DeleteRecordDialog),
      findsOneWidget,
      reason: 'the title bar x closed the confirmation while its delete was running',
    );
    await _expectHeldDeleteFinished(tester, h.storage, find.byType(DeleteRecordDialog));
  });

  testWidgets('the cancel button does not close the single confirmation mid-delete', (tester) async {
    final h = await _pumpSingle(tester);
    final cancel = _cancelButton(find.byType(DeleteRecordDialog));

    expect(tester.widget<ButtonStyleButton>(cancel).enabled, isFalse, reason: 'cancel is live while the delete runs');
    await tester.tap(cancel, warnIfMissed: false);
    await tester.pump();

    expect(
      find.byType(DeleteRecordDialog),
      findsOneWidget,
      reason: 'cancel closed the confirmation while its delete was running',
    );
    await _expectHeldDeleteFinished(tester, h.storage, find.byType(DeleteRecordDialog));
  });
}
