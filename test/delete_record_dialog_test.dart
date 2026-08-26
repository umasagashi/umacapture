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
    while (h.storage.hasPendingDelete) {
      h.storage.settle();
      await tester.pump();
    }
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
    while (storage.hasPendingDelete) {
      storage.settle();
      await tester.pump();
    }
    expect(storage.reported.where((e) => !e.isSuccess), isEmpty);
    expect(storage.deleteAllCalls, [
      {'a'},
    ]);
  });

  testWidgets('leaves a dialog opened meanwhile alone', (tester) async {
    final h = await _pump(tester);

    // Only one dialog exists at a time, so this replaces the delete confirmation. The pending delete must
    // not take the unrelated dialog down with it when it finally settles.
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
}
