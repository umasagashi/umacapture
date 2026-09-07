// The extraction gate on the record list's delete: while a record's folder is
// being bundled into a zip, that record may not be deleted from 殿堂入り管理
// either.
//
//   .fvm/flutter_sdk/bin/flutter test test/record_delete_extraction_gate_test.dart
//
// WHY THIS SURFACE NEEDS THE GATE TOO. The storage view already withholds the
// delete of a folder it is bundling, but the zip lives in an app-wide provider
// and `StorageManagerDialog` can be closed while one runs. A user who met the
// withheld button there could therefore leave the view, open the record list,
// and delete the same record — through `RecordStorage.deleteAsync`, which takes
// the very same per-record lock the zip's reader holds. Measured on real data,
// that delete waits for the lock correctly and then fails *after* it: Windows
// had not closed the archive's handles yet, so 90 of 2,662 files met
// ERROR_SHARING_VIOLATION and the app reported
// 「2662 件中 2559 件を削除しました。残りは使用中のため削除できませんでした。」 The
// record is quarantined and recovered on the next load, so this is not data
// loss; it is a destructive operation that silently does not finish, and on this
// surface nothing on screen said why.
//
// WHERE THE REFUSAL SITS, AND WHY IT IS NOT WHERE THE STORAGE VIEW PUT ITS OWN.
// The storage view gates its row button and its menu entry. Here both entrances
// — the row context menu and the selection scrim — open one of the two dialogs
// below, so the dialog is the single point every record delete passes through;
// see `recordDeleteAwaitsExtraction`. The cases below therefore assert the
// dialogs, which is also what makes the refusal reachable from a suite at all:
// the context-menu entry is built inside a private `State` of the grid widget
// and cannot be opened without mounting the whole table.
//
// EVERY REFUSAL STANDS BESIDE ITS OWN CONTROL. "Withheld while a zip runs" and
// "withheld always" are the same observation seen once, and the second would
// ship a delete that never works. So every blocked assertion is made in the same
// test as the same confirm being live — for a record nobody is bundling, or for
// the same record once the zip has ended.
//
// WHAT THIS SUITE DOES NOT REACH.
//  * The sharing violation itself. That needs a real `ZipFileEncoder` over a
//    real folder on Windows and a delete timed into the handle-release window;
//    the gate exists so that timing is unreachable, and asserting the OS error
//    would be asserting the defect rather than its absence.
//  * The two entrances. The row context menu lives in a private `State` of
//    `data_table_widget.dart` and the scrim's confirm button is private too;
//    neither is gated, deliberately, because both open a dialog that is.
//  * The web zip leg. `storageZipProgressProvider` is the shared progress model
//    both legs report through and this gate reads only that, but the browser's
//    copy semantics are outside a VM suite.
//  * The confirm's hover/pressed overlay and its semantics: a change that greyed
//    the icon while leaving the button announcing itself as enabled would still
//    pass here.
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
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/storage/zip_export.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/gui/chara_detail/common.dart';
import 'package:umacapture/src/gui/chara_detail/delete_record_dialog.dart';
import 'package:umacapture/src/gui/common.dart';

import 'support/localization.dart';
import 'support/records.dart';
import 'support/riverpod.dart';

late Directory _tempRoot;
late PathInfo _layout;

DirectoryPath get _activeDir => _layout.charaDetailActiveDir;

DirectoryPath get _archiveDir => _layout.charaDetailArchiveDir;

/// A zip in flight over [directory], as the dialogs read one.
StorageZipState _bundling(DirectoryPath directory) => (directoryPath: directory.path, fraction: 0.25);

/// Record storage that holds ids and deletes them without a lock.
///
/// The lock is not what these cases are about: the measured defect happens
/// *after* the lock is granted, which is why the refusal has to come before the
/// delete is started at all. What this fake has to report faithfully is
/// therefore only whether a delete was issued.
///
/// Written once and mixed into both stores rather than copied: the archive cases
/// exist to tell the two apart, so the two fakes have to be alike in everything
/// *except* which store they are, or a difference in the fakes could pass for the
/// difference under test.
mixin _FakeRecordStore on CharaDetailRecordMutator {
  final deleteAllCalls = <Set<String>>[];

  final Set<String> _held = {'a', 'b'};

  @override
  CharaDetailRecord? getBy({required String id}) => _held.contains(id) ? makeRecord(id: id, card: 1) : null;

  @override
  Future<RecordDeleteResult> deleteAsync(String id) => deleteAllAsync([id]);

  @override
  Future<RecordDeleteResult> deleteAllAsync(Iterable<String> ids) async {
    final idSet = ids.toSet();
    deleteAllCalls.add(idSet);
    _held.removeAll(idSet);
    return RecordDeleteResult(succeeded: Set.unmodifiable(idSet), failed: const {});
  }
}

class _FakeRecordStorage extends CharaDetailRecordStorage with _FakeRecordStore {
  @override
  Future<List<CharaDetailRecord>> build() async => const [];
}

/// The same fake behind the *other* store, so a dialog opened with
/// [RecordSource.archive] can be watched reaching the store its source names.
class _FakeArchiveStorage extends CharaDetailArchiveStorage with _FakeRecordStore {
  @override
  Future<List<CharaDetailRecord>> build() async => const [];
}

/// [archive] is supplied only by the cases that open an archived record: leaving
/// the real notifier in place elsewhere keeps those cases honest about which
/// store they touched, since a stray archive read would then fail rather than be
/// served by a fake nobody asserted on.
ProviderContainer _container(_FakeRecordStorage storage, {_FakeArchiveStorage? archive}) {
  return ProviderContainer(
    overrides: [
      charaDetailRecordStorageLoaderProvider.overrideWith(() => storage),
      if (archive != null) charaDetailArchiveStorageLoaderProvider.overrideWith(() => archive),
      pathInfoProvider.overrideWithValue(_layout),
      // The bulk confirmation asks the *layout* where the store is, so that it can answer during a
      // store outage; the store-prepared provider above is left in place for the delete itself.
      pathLayoutProvider.overrideWithValue(_layout),
    ],
  );
}

class _ShowSingle extends ConsumerWidget {
  final RecordSource source;

  const _ShowSingle({this.source = RecordSource.active});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: () => DeleteRecordDialog.show(ref.base, recordId: 'a', source: source),
      child: const Text('open'),
    );
  }
}

class _ShowBulk extends ConsumerWidget {
  final RecordSource source;

  const _ShowBulk({this.source = RecordSource.active});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: () => BulkDeleteRecordDialog.show(ref.base, recordIds: const ['a', 'b'], source: source),
      child: const Text('open'),
    );
  }
}

Future<void> _open(WidgetTester tester, ProviderContainer container, Widget launcher) async {
  await pumpWithContainer(
    tester,
    container,
    MaterialApp(
      home: DialogLayer(child: Scaffold(body: launcher)),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
}

Finder get _confirm => find.widgetWithIcon(FilledButton, Symbols.delete_rounded);

bool _confirmLive(WidgetTester tester) {
  final button = tester.widget<FilledButton>(_confirm);
  // Destructive confirms answer a long press and keep a no-op `onPressed`, so
  // "live" is the long press. Both are asserted: `enabled: false` nulls the pair,
  // and reading only one of them would pass for a button that still fires.
  return button.onLongPress != null && button.onPressed != null;
}

/// The colour the confirm's icon actually paints with.
///
/// Read off the `RichText` the `Icon` builds rather than off `Icon.color`: the
/// disabled foreground is resolved by the button's `ButtonStyle`, where the
/// widget's own colour is not, so asserting the field would fail for a correct
/// implementation and pass for one that moved no pixel.
Color _paintedConfirmIconColour(WidgetTester tester) {
  final icon = find.descendant(of: _confirm, matching: find.byIcon(Symbols.delete_rounded));
  final text = tester.widget<RichText>(find.descendant(of: icon, matching: find.byType(RichText)));
  final colour = text.text.style?.color;
  expect(colour, isNotNull, reason: 'the confirm icon painted with no colour at all');
  return colour!;
}

/// Publishes [state] as the one zip in flight, through the same notifier
/// `exportDirectoryAsZip` claims the slot with.
void _beginExtraction(ProviderContainer container, DirectoryPath directory) {
  expect(
    container.read(storageZipProgressProvider.notifier).begin(directory),
    isTrue,
    reason: 'the slot must have been free for the arrangement under test to mean anything',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_record_delete_gate');
    _layout = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
  });

  tearDown(() {
    if (_tempRoot.existsSync()) {
      _tempRoot.deleteSync(recursive: true);
    }
  });

  group('the rule itself', () {
    bool awaits(List<String> ids, StorageZipState? extraction, {RecordSource source = RecordSource.active}) {
      return recordDeleteAwaitsExtraction(pathInfo: _layout, source: source, recordIds: ids, extraction: extraction);
    }

    test('the bundled record is withheld and a sibling is not', () {
      final extraction = _bundling(_activeDir / 'a');
      expect(awaits(['a'], extraction), isTrue);
      // `ab` is the case a string `startsWith` gets wrong: it shares a prefix
      // with `a` and is a different record with a different lock.
      expect(awaits(['b'], extraction), isFalse);
      expect(awaits(['ab'], extraction), isFalse);
    });

    test('bundling the store root withholds every record under it', () {
      // The root is what the group row's zip names, and the delete of a record
      // inside it opens handles the reader is holding.
      final extraction = _bundling(_activeDir);
      expect(awaits(['a'], extraction), isTrue);
      expect(awaits(['b'], extraction), isTrue);
    });

    test('the source is part of the answer, not only the id', () {
      // Active and archived records can carry the same id in two folders, and a
      // gate that compared ids rather than paths would refuse both.
      final extraction = _bundling(_archiveDir / 'a');
      expect(awaits(['a'], extraction, source: RecordSource.archive), isTrue);
      expect(awaits(['a'], extraction), isFalse);
    });

    test('a bulk delete is withheld when any one of its records is covered', () {
      final extraction = _bundling(_activeDir / 'b');
      expect(awaits(['a', 'b'], extraction), isTrue);
      // The control for "any": a selection that misses the bundled record keeps
      // its delete, so this is not a gate that refuses every batch.
      expect(awaits(['a', 'c'], extraction), isFalse);
    });

    test('nothing is withheld while no zip runs, and an empty selection never is', () {
      for (final ids in [
        ['a'],
        ['a', 'b'],
      ]) {
        expect(awaits(ids, null), isFalse, reason: ids.join(','));
      }
      // "This deletes nothing" is not a state a zip can cover, and
      // `StorageDeletePathsRequest` is documented as never empty.
      expect(awaits(const [], _bundling(_activeDir)), isFalse);
    });

    test('the refusal is the one shipped sentence, and it still carries the reason', () {
      final sentence = longReadBusyMessage();
      // Read as a literal: `.tr()` renders a missing key as the key, so a message
      // built the same way would compare equal to itself.
      expect(sentence, appSentenceAt('app.long_read_busy'));
      expect(sentence, isNot(contains('{')));
      // ONE sentence where there were three. Until the merge this case asserted
      // the opposite — that the single dialog, the bulk dialog and the storage
      // tree each had a key of its own and that no two of the three strings were
      // equal — because each named its own subject and its own verb. Eight such
      // sentences were merged into `app.long_read_busy` so that a newly withheld
      // surface costs no translation entry at all, and the sharing is the
      // requirement now rather than the separation.
      //
      // What is pinned in their place is the half that survives the merge: the
      // sentence still says *why*. Without 「使用中」 the user meets a dead confirm
      // and is told nothing about what waiting would achieve. That the two
      // dialogs actually render this string is asserted further down this file.
      expect(sentence, contains('使用中'));
      // Nothing was pressed — the confirm is inert before the first tap — so a
      // past tense or a retry would describe an attempt that never happened.
      expect(sentence, isNot(contains('できませんでした')));
      expect(sentence, isNot(contains('もう一度')));
      // And no registered long reader has a stop, so telling the user to stop one
      // is an instruction nobody can follow.
      expect(sentence, isNot(contains('止めて')));
    });
  });

  group('the single-record confirmation', () {
    testWidgets('the confirm is withheld while the record is bundled, and comes back when the zip ends', (
      tester,
    ) async {
      final storage = _FakeRecordStorage();
      final container = _container(storage);
      await _open(tester, container, const _ShowSingle());
      expect(find.byType(DeleteRecordDialog), findsOneWidget);

      // The control that separates this gate from "the dialog is broken".
      expect(_confirmLive(tester), isTrue);

      _beginExtraction(container, _activeDir / 'a');
      await tester.pump();
      expect(_confirmLive(tester), isFalse);

      // The assertion a finder cannot fake: press it and read what the store was
      // asked to do.
      await tester.longPress(_confirm);
      await tester.pump();
      expect(storage.deleteAllCalls, isEmpty, reason: 'a delete started over a running zip');

      container.read(storageZipProgressProvider.notifier).finish();
      await tester.pump();

      // Withheld for the length of the extraction, not for the length of the
      // session.
      expect(_confirmLive(tester), isTrue);
      await tester.longPress(_confirm);
      await tester.pump();
      expect(storage.deleteAllCalls, [
        {'a'},
      ]);
    });

    testWidgets('a record nobody is bundling keeps its delete', (tester) async {
      final storage = _FakeRecordStorage();
      final container = _container(storage);
      await _open(tester, container, const _ShowSingle());

      // A zip of a *different* record. If this withheld the confirm the gate
      // would be "any zip stops every delete", which the row-level control above
      // could not tell apart.
      _beginExtraction(container, _activeDir / 'b');
      await tester.pump();

      expect(_confirmLive(tester), isTrue);
      await tester.longPress(_confirm);
      await tester.pump();
      expect(storage.deleteAllCalls, [
        {'a'},
      ]);
    });

    testWidgets('an archived record is answered about the archive folder, not the active one', (tester) async {
      // The dialog is opened from two places and carries the source it was
      // opened with; every other widget case here happens to be `active`, so
      // without this one the gate could be asked about `active/<id>` whatever the
      // dialog is showing and the suite would not notice. Both directions are
      // asserted below, so neither a hard-coded `active` nor a hard-coded
      // `archive` survives.
      final storage = _FakeRecordStorage();
      final archive = _FakeArchiveStorage();
      final container = _container(storage, archive: archive);
      await _open(tester, container, const _ShowSingle(source: RecordSource.archive));
      expect(find.byType(DeleteRecordDialog), findsOneWidget);
      expect(_confirmLive(tester), isTrue);

      // What this record's delete opens is `archive/a`, so that is the folder a
      // zip has to be reading for it to wait.
      _beginExtraction(container, _archiveDir / 'a');
      await tester.pump();
      expect(_confirmLive(tester), isFalse);
      await tester.longPress(_confirm);
      await tester.pump();
      expect(archive.deleteAllCalls, isEmpty, reason: 'a delete started over a zip of the archived record');

      container.read(storageZipProgressProvider.notifier).finish();
      await tester.pump();

      // The control that keeps this about the source rather than about "any
      // zip": the same id under `active/` is a different folder holding a
      // different record, and bundling it is none of this delete's business.
      _beginExtraction(container, _activeDir / 'a');
      await tester.pump();
      expect(_confirmLive(tester), isTrue);
      await tester.longPress(_confirm);
      await tester.pump();

      // Deleted from the archive store, which is the same store the gate was
      // asked about — the two readings of `source` are checked against each
      // other rather than each against itself.
      expect(archive.deleteAllCalls, [
        {'a'},
      ]);
      expect(storage.deleteAllCalls, isEmpty);
    });

    testWidgets('the dialog says why in its body, and the way out stays open', (tester) async {
      final storage = _FakeRecordStorage();
      final container = _container(storage);
      await _open(tester, container, const _ShowSingle());

      // Before: the caution that answers "shall I?".
      expect(find.byType(WarningCard), findsOneWidget);
      expect(find.text(longReadBusyMessage()), findsNothing);

      _beginExtraction(container, _activeDir / 'a');
      await tester.pump();

      // The reason is on screen as text, not only in a tooltip: this dialog has
      // already taken the whole surface to ask a question that cannot be
      // answered yet, and a hover is not something a touch user has.
      expect(find.text(longReadBusyMessage()), findsOneWidget);
      expect(find.byType(WarningCard), findsNothing);

      // Leaving is the remedy the sentence asks for, so both exits stay live.
      // A refusal that also shut the way out would be a dialog the user is
      // locked inside for the length of someone else's zip.
      expect(
        tester.widget<OutlinedButton>(find.widgetWithIcon(OutlinedButton, Symbols.cancel_rounded)).onPressed,
        isNotNull,
      );
      expect(container.read(dialogBuilderProvider), isNotNull);
      await tester.tap(find.widgetWithIcon(OutlinedButton, Symbols.cancel_rounded));
      await tester.pump();
      expect(container.read(dialogBuilderProvider), isNull);
    });
  });

  group('the bulk confirmation', () {
    testWidgets('one bundled record in the selection withholds the whole batch, and it comes back', (tester) async {
      final storage = _FakeRecordStorage();
      final container = _container(storage);
      container.read(selectionModeProvider.notifier).set(SelectionPurpose.delete);
      container.read(selectedRecordIdsProvider.notifier).set({'a', 'b'});
      await _open(tester, container, const _ShowBulk());
      expect(find.byType(BulkDeleteRecordDialog), findsOneWidget);

      expect(_confirmLive(tester), isTrue);

      // Only `b` is bundled; the batch names both. A gate that asked about the
      // first id would let this through.
      _beginExtraction(container, _activeDir / 'b');
      await tester.pump();
      expect(_confirmLive(tester), isFalse);
      expect(find.text(longReadBusyMessage()), findsOneWidget);

      await tester.longPress(_confirm);
      await tester.pump();
      expect(storage.deleteAllCalls, isEmpty, reason: 'a bulk delete started over a running zip');

      container.read(storageZipProgressProvider.notifier).finish();
      await tester.pump();
      expect(_confirmLive(tester), isTrue);
      await tester.longPress(_confirm);
      await tester.pump();
      expect(storage.deleteAllCalls, [
        {'a', 'b'},
      ]);
    });

    testWidgets('a selection none of whose records is bundled still deletes', (tester) async {
      final storage = _FakeRecordStorage();
      final container = _container(storage);
      container.read(selectionModeProvider.notifier).set(SelectionPurpose.delete);
      container.read(selectedRecordIdsProvider.notifier).set({'a', 'b'});
      await _open(tester, container, const _ShowBulk());

      _beginExtraction(container, _activeDir / 'c');
      await tester.pump();

      expect(_confirmLive(tester), isTrue);
      await tester.longPress(_confirm);
      await tester.pump();
      expect(storage.deleteAllCalls, [
        {'a', 'b'},
      ]);
    });

    testWidgets('an archived selection is answered about the archive folder, not the active one', (tester) async {
      // The single dialog's counterpart: the bulk dialog reads its source twice
      // as well (the store it deletes from, and the folders the gate is asked
      // about), and the two readings have to name the same store.
      final storage = _FakeRecordStorage();
      final archive = _FakeArchiveStorage();
      final container = _container(storage, archive: archive);
      container.read(selectionModeProvider.notifier).set(SelectionPurpose.delete);
      container.read(selectedRecordIdsProvider.notifier).set({'a', 'b'});
      await _open(tester, container, const _ShowBulk(source: RecordSource.archive));
      expect(find.byType(BulkDeleteRecordDialog), findsOneWidget);
      expect(_confirmLive(tester), isTrue);

      _beginExtraction(container, _archiveDir / 'b');
      await tester.pump();
      expect(_confirmLive(tester), isFalse);
      expect(find.text(longReadBusyMessage()), findsOneWidget);
      await tester.longPress(_confirm);
      await tester.pump();
      expect(archive.deleteAllCalls, isEmpty, reason: 'a bulk delete started over a zip of an archived record');

      container.read(storageZipProgressProvider.notifier).finish();
      await tester.pump();

      // The control: the same ids under `active/`, which this selection does not
      // name.
      _beginExtraction(container, _activeDir / 'b');
      await tester.pump();
      expect(_confirmLive(tester), isTrue);
      await tester.longPress(_confirm);
      await tester.pump();
      expect(archive.deleteAllCalls, [
        {'a', 'b'},
      ]);
      expect(storage.deleteAllCalls, isEmpty);
    });

    testWidgets('the way out stays open while the batch is withheld', (tester) async {
      final storage = _FakeRecordStorage();
      final container = _container(storage);
      container.read(selectionModeProvider.notifier).set(SelectionPurpose.delete);
      container.read(selectedRecordIdsProvider.notifier).set({'a', 'b'});
      await _open(tester, container, const _ShowBulk());

      _beginExtraction(container, _activeDir / 'a');
      await tester.pump();
      expect(_confirmLive(tester), isFalse);

      // Waiting or leaving is the entire remedy the refusal offers, so both
      // exits this dialog owns stay live — `leaveEnabled` shuts the × and cancel
      // together and is answered by the running delete alone. Narrowing it by
      // the extraction as well would lock the user inside a dialog they cannot
      // act on for the length of someone else's zip. The single dialog's
      // counterpart of this case is above; the two dialogs shut their exits
      // through different parameters, so one assertion cannot cover both.
      expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Symbols.close_rounded)).onPressed, isNotNull);
      expect(
        tester.widget<OutlinedButton>(find.widgetWithIcon(OutlinedButton, Symbols.cancel_rounded)).onPressed,
        isNotNull,
      );
      expect(container.read(dialogBuilderProvider), isNotNull);
      await tester.tap(find.widgetWithIcon(OutlinedButton, Symbols.cancel_rounded));
      await tester.pump();
      expect(container.read(dialogBuilderProvider), isNull);
    });
  });

  group('the withheld confirm looks withheld', () {
    // The refusal is invisible unless the button also *reads* as refused. The
    // confirm carries a `FilledButton.styleFrom(foregroundColor: onError)`, and
    // that style names no disabled colour, so the greying is the framework's
    // value-level fallback rather than anything this dialog states. What is
    // pinned is therefore the outcome, so that a `disabledForegroundColor`, an
    // `Icon(color:)`, or a switch to an always-coloured icon added later cannot
    // quietly flatten it — `common.dart`'s dialog × shipped with exactly that
    // defect, painting at full strength while refusing every press.
    testWidgets('the gated confirm paints differently from the live one', (tester) async {
      final storage = _FakeRecordStorage();
      final container = _container(storage);
      await _open(tester, container, const _ShowSingle());

      // The control for the comparison, read while the button is live: it wears
      // the role a destructive confirm is required to carry, so the difference
      // below is about the refusal and not about a dialog that lost its colour.
      final scheme = Theme.of(tester.element(_confirm)).colorScheme;
      final live = _paintedConfirmIconColour(tester);
      expect(live.toARGB32(), scheme.onError.toARGB32());

      _beginExtraction(container, _activeDir / 'a');
      // Time has to pass. `ButtonStyleButton` hands its foreground down through
      // an `AnimatedTheme`, so the frame the button goes dead in still paints the
      // live colour, and zero-duration pumps — however many — read the old one.
      // A fixed duration rather than `pumpAndSettle`, because an extraction in
      // flight can be drawing a progress ring, which never settles.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(_confirmLive(tester), isFalse);

      // Compared at the 8 bits per channel the surface actually has, which is the
      // strict direction for an inequality: at full precision two colours landing
      // on the same byte would count as different, so a flattened disabled state
      // could pass over a difference no screen can show.
      expect(
        _paintedConfirmIconColour(tester).toARGB32(),
        isNot(live.toARGB32()),
        reason: 'the withheld confirm paints exactly as the live one, so nothing says it is refused',
      );
    });

    testWidgets('the gated bulk confirm paints differently from the live one', (tester) async {
      // The same outcome pinned for the other dialog. Both confirms are built by
      // `ConfirmActionRow` today, so no defect reachable now can redden this case
      // alone — what it buys is that the bulk dialog's appearance is stated
      // rather than inherited, so a later `BulkConfirmDialog` that styles its own
      // confirm (or stops using the shared row) cannot flatten the refusal on the
      // surface where a whole selection is at stake while the single dialog's
      // case still passes. Until then it is a second reading of a shared value,
      // which is what the finding that asked for it observed.
      final storage = _FakeRecordStorage();
      final container = _container(storage);
      container.read(selectionModeProvider.notifier).set(SelectionPurpose.delete);
      container.read(selectedRecordIdsProvider.notifier).set({'a', 'b'});
      await _open(tester, container, const _ShowBulk());

      final scheme = Theme.of(tester.element(_confirm)).colorScheme;
      final live = _paintedConfirmIconColour(tester);
      expect(live.toARGB32(), scheme.onError.toARGB32());

      _beginExtraction(container, _activeDir / 'b');
      // Time has to pass, for the reason given in the single dialog's case
      // above: the frame the button dies in still paints the live colour.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(_confirmLive(tester), isFalse);

      expect(
        _paintedConfirmIconColour(tester).toARGB32(),
        isNot(live.toARGB32()),
        reason: 'the withheld bulk confirm paints exactly as the live one, so nothing says it is refused',
      );
    });
  });

  group('the gate is released by the zip itself, however the zip ends', () {
    // The failure mode a gate like this creates is the opposite of the one it
    // fixes: a delete button that never comes back. The release is
    // `exportDirectoryAsZip`'s `finally`, so it is exercised here through that
    // function rather than through `StorageZipProgress.finish`, which every other
    // case in this file calls directly and which would therefore assert only that
    // the dialog reads the provider.
    testWidgets('a run that throws leaves the confirm live again', (tester) async {
      final storage = _FakeRecordStorage();
      // The runner is held open rather than throwing at once, so the refusal is
      // observed *in force* before the throw. A runner that threw immediately
      // would complete the whole export in the microtasks the first pump drains,
      // and the case could then no longer tell "released by the finally" from
      // "never engaged".
      final held = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          charaDetailRecordStorageLoaderProvider.overrideWith(() => storage),
          pathInfoProvider.overrideWithValue(_layout),
          storageZipPreflightProvider.overrideWithValue((ref, directory) async => null),
          storageZipRunnerProvider.overrideWithValue((ref, directory, onProgress, guard) async {
            await held.future;
            throw StateError('the encoder died');
          }),
        ],
      );
      await _open(tester, container, const _ShowSingle());
      expect(_confirmLive(tester), isTrue);

      final record = _activeDir / 'a';
      final export = exportDirectoryAsZip(
        container.read(refBaseProvider),
        record,
        group: storageGroupOf(StorageGroupId.activeRecords),
        silent: true,
      );
      await tester.pump();
      expect(_confirmLive(tester), isFalse, reason: 'the running zip did not reach this dialog at all');

      held.complete();
      expect(await tester.runAsync(() => export), StorageZipOutcome.failed);
      await tester.pump();
      expect(_confirmLive(tester), isTrue, reason: 'a zip that threw left the record undeletable for the session');

      await tester.longPress(_confirm);
      await tester.pump();
      expect(storage.deleteAllCalls, [
        {'a'},
      ]);
    });

    test('the slot the dialogs read is free again after a throwing run', () async {
      final container = ProviderContainer(
        overrides: [
          pathInfoProvider.overrideWithValue(_layout),
          storageZipPreflightProvider.overrideWithValue((ref, directory) async => null),
          storageZipRunnerProvider.overrideWithValue((ref, directory, onProgress, guard) async {
            throw StateError('the encoder died');
          }),
        ],
      );
      addTearDown(container.dispose);
      final outcome = await exportDirectoryAsZip(
        container.read(refBaseProvider),
        _activeDir / 'a',
        group: storageGroupOf(StorageGroupId.activeRecords),
        silent: true,
      );
      expect(outcome, StorageZipOutcome.failed);
      expect(container.read(storageZipProgressProvider), isNull);
      expect(
        recordDeleteAwaitsExtraction(
          pathInfo: _layout,
          source: RecordSource.active,
          recordIds: const ['a'],
          extraction: container.read(storageZipProgressProvider),
        ),
        isFalse,
      );
    });
  });
}
