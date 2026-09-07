// The long-read gate on the record page's three remaining destructive /
// extracting confirmations: export, archive and re-recognition.
//
//   .fvm/flutter_sdk/bin/flutter test test/record_action_extraction_gate_test.dart
//
// WHAT THESE CASES ARE TRYING TO FALSIFY, in one sentence: *while a registered
// long reader holds a record's folder, one of these three dialogs still offers
// its confirm, or offers it with nothing on screen saying why it cannot be
// pressed.*
//
// WHY THESE THREE AND NOT THE DELETE DIALOGS. `record_delete_extraction_gate_test.dart`
// covers the delete pair, which was the first surface to subscribe. These three
// are the rest of the same round: each acts on the same `active/<id>` directory a
// zip may be bundling or an archive move may be renaming away, and each was
// found by reading the tree rather than by any check — the scan in
// `long_read_registry_test.dart` is anchored on `storageActionBlockerOf`, which
// none of the three calls, so all three are outside its field of view.
//
// EVERY REFUSAL STANDS BESIDE ITS OWN CONTROL. "Withheld while a long reader
// runs" and "withheld always" are the same observation seen once, and the second
// would ship a button that never works. So every blocked assertion is made in
// the same case as the same confirm being live for a record nobody is holding.
//
// THE WAY OUT STAYS OPEN. Waiting is the only remedy a registered long reader
// offers (`storageDeleteExtractionBusyMessage` says why there is no "stop it"),
// so cancel is asserted live in the same breath as the confirm being shut: a
// refusal that also trapped the user in the dialog would be a worse defect than
// the one being fixed.
//
// WHAT THIS SUITE DOES NOT REACH.
//  * The record table's own re-recognition entry. It is built inside a private
//    `State` of `data_table_widget.dart` and cannot be opened without mounting
//    the whole grid — the same boundary the delete suite records. Its engine-side
//    half is covered by `regeneration_long_read_gate_test.dart`, and it can show
//    no sentence at all (`MenuItem` takes no tooltip).
//  * `RegenerateAllRecordsTile`, which is gated on its own blocker enum and has
//    no sentence for this refusal.
//  * The web legs of the zip and the archive move: `longReadRegistryProvider` is
//    the shared model both report through and these dialogs read only that, but
//    browser storage semantics are outside a VM suite.
//  * The confirm's hover/pressed overlay: a change that greyed the icon while
//    leaving the button announcing itself as enabled would still pass here.
import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/storage/zip_export.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/chara_detail/archive_record_dialog.dart';
import 'package:umacapture/src/gui/chara_detail/common.dart';
import 'package:umacapture/src/gui/chara_detail/export_button.dart';
import 'package:umacapture/src/gui/chara_detail/regenerate_record_dialog.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';

import 'support/localization.dart';
import 'support/records.dart';
import 'support/riverpod.dart';

late Directory _tempRoot;
late PathInfo _layout;

DirectoryPath get _activeDir => _layout.charaDetailActiveDir;

/// The archive store root — where an archive of a record *lands*, and the path
/// the geometry repair and a zip of 殿堂入り each claim whole.
DirectoryPath get _archiveDir => _layout.charaDetailArchiveDir;

/// The archive transaction journal: neither end of the move, written for its
/// whole length by the web leg, and claimed on both.
DirectoryPath get _journalDir => _layout.charaDetailArchiveTransactionDir;

/// The **write** transaction journal, which is a different directory from
/// [_journalDir] and is the one a re-recognition publishes through on web.
///
/// Named separately rather than reached through
/// `charaDetailTransactionJournalDirs`, so a case that means the write journal
/// cannot pass by holding the archive one.
DirectoryPath get _writeJournalDir => _layout.charaDetailWriteTransactionDir;

/// Record storage that answers `getBy` for the two ids these dialogs are opened
/// with, and does nothing else.
///
/// None of the three confirms is pressed here — what is under test is whether it
/// may be — so the store only has to exist and hold the records.
class _FakeRecordStorage extends CharaDetailRecordStorage {
  @override
  Future<List<CharaDetailRecord>> build() async => const [];

  @override
  CharaDetailRecord? getBy({required String id}) => const {'a', 'b'}.contains(id) ? makeRecord(id: id, card: 1) : null;
}

/// [zipRunner] replaces the platform zip, for the one case that drives
/// `exportDirectoryAsZip` itself rather than claiming the slot through [_hold];
/// the preflight goes with it because the platform one would be asked first and
/// answers about a folder that is not there.
ProviderContainer _container({StorageZipRunner? zipRunner}) {
  return ProviderContainer(
    overrides: [
      charaDetailRecordStorageLoaderProvider.overrideWith(_FakeRecordStorage.new),
      pathInfoProvider.overrideWithValue(_layout),
      // The export and archive confirmations ask the *layout* where the store is, so that they can
      // answer during a store outage; the store-prepared provider above is left in place for the
      // runs themselves.
      pathLayoutProvider.overrideWithValue(_layout),
      if (zipRunner != null) ...[
        storageZipRunnerProvider.overrideWithValue(zipRunner),
        storageZipPreflightProvider.overrideWithValue((ref, directory) async => null),
      ],
    ],
  );
}

/// Publishes a zip over [directory] through the same notifier
/// `exportDirectoryAsZip` claims the registry slot with.
///
/// A zip and not a hand-made claim: it is the shortest real path into
/// `longReadRegistryProvider`, and going through it means these cases would also
/// fail if the zip stopped registering itself.
void _hold(ProviderContainer container, DirectoryPath directory) {
  expect(
    container.read(storageZipProgressProvider.notifier).begin(directory),
    isTrue,
    reason: 'the slot must have been free for the arrangement under test to mean anything',
  );
}

void _release(ProviderContainer container) => container.read(storageZipProgressProvider.notifier).finish();

final _refProvider = Provider<RefBase>((ref) => ref.base);

/// A module install that has started and not finished, through the same seam
/// every install route goes through.
///
/// Not a hand-made claim, for [_hold]'s reason: these cases would also have to
/// fail if `runModuleInstall` stopped registering. The action is a future nobody
/// completes until [_releaseModules], which is what an extraction still running
/// looks like from a widget's point of view.
Completer<void>? _moduleInstall;

void _holdModules(ProviderContainer container) {
  final completer = Completer<void>();
  _moduleInstall = completer;
  // Either contention would do — nothing is holding `modules/` when this runs, so
  // the two behave alike; `defer` is the automatic routes', which is the one that
  // can be in flight without anybody having pressed anything.
  runModuleInstall(
    container.read(_refProvider),
    _layout.modulesDir,
    () => completer.future,
    contention: LongReadContention.defer,
  ).ignore();
}

void _releaseModules() {
  _moduleInstall?.complete();
  _moduleInstall = null;
}

class _Launcher extends ConsumerWidget {
  final void Function(RefBase ref) open;

  const _Launcher(this.open);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(onPressed: () => open(ref.base), child: const Text('open'));
  }
}

/// Gives the test a window these dialogs fit in.
///
/// The default 800×600 surface is smaller than the export dialog's own
/// `maxHeight` once the refusal card is in it, so without this the card would
/// overflow here and nowhere else — a failure about the test's window rather than
/// about the code. Sized once for every case so the two archive dialogs, which do
/// fit, are laid out under the same conditions as the one that does not.
void _useARoomyWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _open(WidgetTester tester, ProviderContainer container, void Function(RefBase ref) open) async {
  _useARoomyWindow(tester);
  await pumpWithContainer(
    tester,
    container,
    MaterialApp(
      home: DialogLayer(child: Scaffold(body: _Launcher(open))),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
}

Finder _confirmWith(IconData icon) => find.widgetWithIcon(FilledButton, icon);

/// Whether the confirm accepts input at all.
///
/// Both callbacks are read: a destructive confirm keeps a no-op `onPressed` while
/// it is offered and answers the long press, so reading either one alone would
/// pass for a button that still fires.
bool _confirmLive(WidgetTester tester, IconData icon, {required bool destructive}) {
  final button = tester.widget<FilledButton>(_confirmWith(icon));
  return destructive
      ? button.onPressed != null && button.onLongPress != null
      : button.onPressed != null && button.onLongPress == null;
}

bool _cancelLive(WidgetTester tester) {
  return tester.widget<OutlinedButton>(find.widgetWithIcon(OutlinedButton, Symbols.cancel_rounded)).onPressed != null;
}

/// Chooses the image disposition both archive dialogs require before they offer
/// their confirm at all, so the archive cases can tell "withheld by the long
/// reader" from "withheld until a radio is picked".
Future<void> _pickArchiveOption(WidgetTester tester) async {
  await tester.tap(find.byType(RadioListTile<ArchiveImageOption>).first);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_record_action_gate');
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

  // **This group used to be called "the three sentences".** Export, archive and
  // regeneration each had a key of its own, each named its own action
  // (エクスポート / アーカイブ / 再認識), and the two cases here asserted that no two
  // of the three strings were equal. All three were merged into
  // `app.long_read_busy` along with the five other per-surface refusals, so that a
  // newly withheld control costs no translation entry at all — the verb was the
  // price, and `longReadBusyMessage`'s doc records it.
  //
  // What is left to assert about the sentence is what did *not* change: it says
  // the state, it says why, and it promises nothing that never happened. That the
  // three dialogs each actually render it is asserted by the `find.text` cases
  // further down — three surfaces, one string, checked at the pixel rather than at
  // the key.
  group('the one sentence', () {
    test('it is a shipped key, and the three dialogs share it on purpose', () {
      final sentence = longReadBusyMessage();
      // Read as a literal out of `ja.json`: `.tr()` renders a missing key as the
      // key, so a message compared against another `.tr()` of the same key would
      // compare equal to itself whether or not the key exists.
      expect(sentence, appSentenceAt('app.long_read_busy'));
      expect(sentence, isNot(contains('{')), reason: 'an unfilled placeholder would be shown verbatim');
      // Filed outside `pages.` because the fact is no longer any one screen's. A
      // key that drifted back under a page namespace would be the first step back
      // towards one sentence per surface.
      expect(longReadBusyKey, startsWith('app.'));
    });

    test('it says the state rather than a failed attempt', () {
      // Not a full-text comparison: pinning the whole sentence would freeze the
      // wording against every edit, including the ones this project makes on
      // purpose. What must survive an edit is that the reader is told *why*, which
      // is the half of the old pair that the merge kept.
      final sentence = longReadBusyMessage();
      expect(sentence, contains('使用中'), reason: 'the reason is what makes waiting the obvious response');
      // The user has not pressed anything: the confirm is withheld before the
      // first press, so a past tense or a "try again" would describe an attempt
      // that never happened. `longReadBusyMessage` states the rule.
      expect(sentence, isNot(contains('もう一度')));
      expect(sentence, isNot(contains('できませんでした')));
      // No registered long reader has a stop, so telling the user to stop one
      // is worse than saying nothing.
      expect(sentence, isNot(contains('止めて')));
    });
  });

  group('the export confirmation', () {
    testWidgets('the confirm is withheld while a selected record is held, and the reason is on screen', (tester) async {
      final container = _container();
      await _open(tester, container, (ref) => ExportRecordDialog.show(ref, recordIds: const ['a', 'b']));
      expect(find.byType(ExportRecordDialog), findsOneWidget);

      // The control that separates this gate from "the dialog is broken".
      expect(_confirmLive(tester, Symbols.download_rounded, destructive: false), isTrue);
      expect(find.text(longReadBusyMessage()), findsNothing);

      _hold(container, _activeDir / 'b');
      await tester.pump();
      expect(_confirmLive(tester, Symbols.download_rounded, destructive: false), isFalse);
      // Body text, not only the confirm's tooltip: a tooltip needs a hover.
      expect(find.text(longReadBusyMessage()), findsOneWidget);
      // Waiting is the remedy, so the way out stays open for exactly the window
      // the confirm is shut.
      expect(_cancelLive(tester), isTrue);

      _release(container);
      await tester.pump();
      expect(_confirmLive(tester, Symbols.download_rounded, destructive: false), isTrue);
      expect(find.text(longReadBusyMessage()), findsNothing);
    });

    testWidgets('a module install withholds it too, because the desktop zip packs modules/labels.json', (tester) async {
      final container = _container();
      await _open(tester, container, (ref) => ExportRecordDialog.show(ref, recordIds: const ['a']));
      expect(_confirmLive(tester, Symbols.download_rounded, destructive: false), isTrue);

      // Nothing here names a record: the install is rewriting `modules/`, which
      // this dialog would not have asked about before the export's held paths
      // and the question it puts to the registry became one derivation.
      _holdModules(container);
      await tester.pump();
      expect(_confirmLive(tester, Symbols.download_rounded, destructive: false), isFalse);
      expect(find.text(longReadBusyMessage()), findsOneWidget);
      expect(_cancelLive(tester), isTrue);

      _releaseModules();
      await tester.pump();
      expect(_confirmLive(tester, Symbols.download_rounded, destructive: false), isTrue);
      expect(find.text(longReadBusyMessage()), findsNothing);
    });

    testWidgets('a zip over a record outside the selection leaves the export alone', (tester) async {
      final container = _container();
      await _open(tester, container, (ref) => ExportRecordDialog.show(ref, recordIds: const ['a']));

      _hold(container, _activeDir / 'b');
      await tester.pump();
      expect(_confirmLive(tester, Symbols.download_rounded, destructive: false), isTrue);
      expect(find.text(longReadBusyMessage()), findsNothing);
    });
  });

  group('the archive confirmations', () {
    testWidgets('the single dialog withholds its confirm and keeps its caution', (tester) async {
      final container = _container();
      await _open(tester, container, (ref) => ArchiveRecordDialog.show(ref, recordId: 'a'));
      expect(find.byType(ArchiveRecordDialog), findsOneWidget);
      await _pickArchiveOption(tester);

      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isTrue);

      _hold(container, _activeDir / 'a');
      await tester.pump();
      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isFalse);
      expect(find.text(longReadBusyMessage()), findsOneWidget);
      expect(_cancelLive(tester), isTrue);
      // In place of the caution rather than beside it, as the delete dialogs do:
      // 「一度アーカイブすると元には戻せません」 answers 「shall I?」, and that is not
      // the question in front of the user while the confirm is withheld.
      expect(find.byType(WarningCard), findsNothing);

      _release(container);
      await tester.pump();
      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isTrue);
    });

    testWidgets('the bulk dialog is withheld when any one of its records is held', (tester) async {
      final container = _container();
      await _open(tester, container, (ref) => BulkArchiveRecordDialog.show(ref, recordIds: const ['a', 'b']));
      await _pickArchiveOption(tester);
      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isTrue);

      _hold(container, _activeDir / 'b');
      await tester.pump();
      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isFalse);
      expect(find.text(longReadBusyMessage()), findsOneWidget);
      expect(_cancelLive(tester), isTrue);
    });

    testWidgets('a hold outside the bulk selection leaves it alone', (tester) async {
      final container = _container();
      await _open(tester, container, (ref) => BulkArchiveRecordDialog.show(ref, recordIds: const ['a']));
      await _pickArchiveOption(tester);

      _hold(container, _activeDir / 'b');
      await tester.pump();
      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isTrue);
      expect(find.text(longReadBusyMessage()), findsNothing);
    });

    // THE OTHER TWO ENDS OF THE MOVE. An archive empties `active/<id>` into
    // `archive/<id>` and, on web, stages it through the transaction journal — and
    // it claims all three, so a confirmation that asked only about the active
    // folder was asking a different question from the one the operation answers.
    // The reachable arrangement is a hold on the *archive store root*: the
    // geometry repair claims exactly that root at startup, and a zip of 殿堂入り
    // claims it for as long as the bundle takes. Neither names any `archive/<id>`,
    // and neither has to — holds are matched by containment and the destination
    // folder of a record being archived now does not exist yet.
    testWidgets('the single dialog is withheld while the archive store root is held', (tester) async {
      final container = _container();
      await _open(tester, container, (ref) => ArchiveRecordDialog.show(ref, recordId: 'a'));
      await _pickArchiveOption(tester);
      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isTrue);

      _hold(container, _archiveDir);
      await tester.pump();
      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isFalse);
      expect(find.text(longReadBusyMessage()), findsOneWidget);
      expect(_cancelLive(tester), isTrue);

      _release(container);
      await tester.pump();
      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isTrue);
    });

    testWidgets('the bulk dialog is withheld while the archive store root is held', (tester) async {
      final container = _container();
      await _open(tester, container, (ref) => BulkArchiveRecordDialog.show(ref, recordIds: const ['a', 'b']));
      await _pickArchiveOption(tester);
      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isTrue);

      _hold(container, _archiveDir);
      await tester.pump();
      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isFalse);
      expect(find.text(longReadBusyMessage()), findsOneWidget);
      expect(_cancelLive(tester), isTrue);
    });

    testWidgets('the single dialog is withheld while the transaction journal is held', (tester) async {
      final container = _container();
      await _open(tester, container, (ref) => ArchiveRecordDialog.show(ref, recordId: 'a'));
      await _pickArchiveOption(tester);
      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isTrue);

      // Neither end of the move, and claimed on both platforms although only the
      // web leg writes it: `archiveRecordLongReadPaths` says why the set is built
      // above the platform seam.
      _hold(container, _journalDir);
      await tester.pump();
      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isFalse);
      expect(find.text(longReadBusyMessage()), findsOneWidget);
      expect(_cancelLive(tester), isTrue);
    });

    testWidgets('the bulk dialog is withheld while the transaction journal is held', (tester) async {
      final container = _container();
      await _open(tester, container, (ref) => BulkArchiveRecordDialog.show(ref, recordIds: const ['a', 'b']));
      await _pickArchiveOption(tester);
      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isTrue);

      _hold(container, _journalDir);
      await tester.pump();
      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isFalse);
      expect(find.text(longReadBusyMessage()), findsOneWidget);
      expect(_cancelLive(tester), isTrue);
    });

    // WHAT MAKES THE ARRANGEMENT ABOVE REACHABLE. 殿堂入り's zip is started from
    // the storage dialog, and the question was whether closing that dialog ends
    // it — if it did, the only way to meet a hold on the archive root would be the
    // startup repair, which runs while the record page has nothing on it.
    //
    // It does not end it, and this case is what fixes that as a fact rather than a
    // reading: `exportDirectoryAsZip` is handed a container-scoped `RefBase` and
    // releases the claim in its own `finally`, so the widget that started it is
    // not part of the arrangement. The zip is driven here through the real
    // function rather than through [_hold] for exactly that reason — what is under
    // test is the ownership of the claim, which [_hold] would bypass.
    testWidgets('the zip that withholds it outlives the storage dialog that started it', (tester) async {
      final delivery = Completer<StorageZipDelivery>();
      final container = _container(zipRunner: (ref, directory, onProgress, guard) => delivery.future);
      // Stands in for the storage dialog: it starts the zip and is then gone,
      // while the container — the app — stays.
      final storageDialogOpen = ValueNotifier<bool>(true);
      addTearDown(storageDialogOpen.dispose);
      _useARoomyWindow(tester);
      await pumpWithContainer(
        tester,
        container,
        MaterialApp(
          home: DialogLayer(
            child: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: storageDialogOpen,
                builder: (context, open, _) => open
                    ? _Launcher(
                        (ref) => exportDirectoryAsZip(
                          ref,
                          _archiveDir,
                          group: storageGroupOf(StorageGroupId.archivedRecords),
                          silent: true,
                        ).ignore(),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();

      storageDialogOpen.value = false;
      await tester.pump();
      expect(find.text('open'), findsNothing, reason: 'the dialog that started the zip has to be gone');

      ArchiveRecordDialog.show(container.read(_refProvider), recordId: 'a');
      await tester.pump();
      await _pickArchiveOption(tester);
      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isFalse);
      expect(find.text(longReadBusyMessage()), findsOneWidget);

      // And it is the zip's own end, not the dialog's, that gives the confirm
      // back — the other half of the same fact.
      delivery.complete(StorageZipDelivery.cancelled);
      await tester.pump();
      await tester.pump();
      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isTrue);
      expect(find.text(longReadBusyMessage()), findsNothing);
    });

    testWidgets('the long reader is not what withholds an archive with no image option picked', (tester) async {
      // The two reasons the archive confirm can be down have to stay tellable
      // apart: without this, "greyed because no radio was chosen" would satisfy
      // every assertion above.
      final container = _container();
      await _open(tester, container, (ref) => ArchiveRecordDialog.show(ref, recordId: 'a'));

      expect(_confirmLive(tester, Symbols.archive_rounded, destructive: true), isFalse);
      expect(find.text(longReadBusyMessage()), findsNothing);
    });
  });

  group('the re-recognition confirmation', () {
    testWidgets('the confirm is withheld while the record is held, and comes back when the hold ends', (tester) async {
      final container = _container();
      await _open(tester, container, (ref) => RegenerateRecordDialog.show(ref, recordId: 'a'));
      expect(find.byType(RegenerateRecordDialog), findsOneWidget);

      expect(_confirmLive(tester, Symbols.refresh_rounded, destructive: true), isTrue);
      expect(find.text(longReadBusyMessage()), findsNothing);

      _hold(container, _activeDir / 'a');
      await tester.pump();
      expect(_confirmLive(tester, Symbols.refresh_rounded, destructive: true), isFalse);
      expect(find.text(longReadBusyMessage()), findsOneWidget);
      // This dialog's cancel is a plain button of its own rather than a
      // `ConfirmActionRow`, so it is asserted here as well as there.
      expect(_cancelLive(tester), isTrue);

      _release(container);
      await tester.pump();
      expect(_confirmLive(tester, Symbols.refresh_rounded, destructive: true), isTrue);
    });

    testWidgets('a hold on another record leaves this one alone', (tester) async {
      final container = _container();
      await _open(tester, container, (ref) => RegenerateRecordDialog.show(ref, recordId: 'a'));

      _hold(container, _activeDir / 'b');
      await tester.pump();
      expect(_confirmLive(tester, Symbols.refresh_rounded, destructive: true), isTrue);
      expect(find.text(longReadBusyMessage()), findsNothing);
    });

    testWidgets('it is withheld while the write transaction journal is held', (tester) async {
      // Not a record directory at all, and the half this confirm used to miss: a
      // re-recognition on web publishes every rewritten record through
      // `WebRecordWriteTransaction`, whose slots live here, and 「アプリの残骸」
      // offers a delete and a zip over exactly this directory. Held on both
      // platforms although only web writes it — `regenerateRecordLongReadPaths`
      // says why the set is built above the platform seam.
      final container = _container();
      await _open(tester, container, (ref) => RegenerateRecordDialog.show(ref, recordId: 'a'));
      expect(_confirmLive(tester, Symbols.refresh_rounded, destructive: true), isTrue);

      _hold(container, _writeJournalDir);
      await tester.pump();
      expect(_confirmLive(tester, Symbols.refresh_rounded, destructive: true), isFalse);
      expect(find.text(longReadBusyMessage()), findsOneWidget);
      expect(_cancelLive(tester), isTrue);

      _release(container);
      await tester.pump();
      expect(_confirmLive(tester, Symbols.refresh_rounded, destructive: true), isTrue);
    });

    testWidgets('the archive journal next door is not what withholds it', (tester) async {
      // The control that keeps the case above about the write journal rather than
      // about any directory beside `active/`: the archive's own journal is a
      // sibling of the same parent, and a re-recognition never writes it.
      final container = _container();
      await _open(tester, container, (ref) => RegenerateRecordDialog.show(ref, recordId: 'a'));

      _hold(container, _journalDir);
      await tester.pump();
      expect(_confirmLive(tester, Symbols.refresh_rounded, destructive: true), isTrue);
      expect(find.text(longReadBusyMessage()), findsNothing);
    });

    testWidgets('the refusal it already had for a video import is still the one it names', (tester) async {
      // Two independent exclusions on one button. The import's sentence names the
      // import, and it has to keep winning while both hold: the import is
      // something the user started and can stop, and a long reader is not.
      final container = _container();
      final imports = ValueNotifier<VideoImportState>(
        const VideoImportState(phase: VideoImportPhase.importing, fileName: 'clip.mkv'),
      );
      addTearDown(imports.dispose);
      _useARoomyWindow(tester);
      await pumpWithContainer(
        tester,
        container,
        MaterialApp(
          home: DialogLayer(
            child: Scaffold(
              body: RegenerateRecordDialog(recordId: 'a', debugImportState: imports),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(_confirmLive(tester, Symbols.refresh_rounded, destructive: true), isFalse);
      final blocked = tester.widget<Disabled>(find.byType(Disabled));
      expect(blocked.tooltip, "pages.capture.video_import.blocks_regeneration".tr());
      expect(find.text(longReadBusyMessage()), findsNothing);

      // And once the import ends with a long reader still on the folder, the
      // other sentence takes over rather than the button coming back.
      _hold(container, _activeDir / 'a');
      imports.value = VideoImportState.idle;
      await tester.pump();
      expect(_confirmLive(tester, Symbols.refresh_rounded, destructive: true), isFalse);
      expect(tester.widget<Disabled>(find.byType(Disabled)).tooltip, longReadBusyMessage());
      expect(find.text(longReadBusyMessage()), findsOneWidget);
    });
  });
}
