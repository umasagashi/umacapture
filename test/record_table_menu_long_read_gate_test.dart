// The long-read gate on the record table's row menu: the 再認識 entry.
//
//   .fvm/flutter_sdk/bin/flutter test test/record_table_menu_long_read_gate_test.dart
//
// WHAT THESE CASES ARE TRYING TO FALSIFY, in one sentence: *while a registered
// long reader holds a record's `active/<id>` folder, the record table's row menu
// still offers 再認識 as a live entry, so pressing it reaches
// `CharaDetailRecordRegenerationController.start` and is refused there with a
// `logger.i` line and nothing on screen.*
//
// WHY THIS FILE EXISTS AT ALL. Every other subscriber to the registry is held by
// a case somewhere: breaking `runModuleInstall`'s hold, the three settings tiles'
// `heldBy`, or the archive / re-recognition dialogs' claim reads each turns a
// named suite red. This one entry did not: replacing its `claims:` argument with
// `const <LongReadClaim>[]` left the whole suite green. It is the same defect the
// whole-store tile was fixed for — a control offered over a directory something
// else is rewriting, whose press is then swallowed — and the row menu was the one
// route to it that nothing watched.
//
// WHY IT IS MOUNTED RATHER THAN INSPECTED. The entry is built in `showPopup`,
// a method on a private `State` in `data_table_widget.dart`, from a
// `recordDeleteBlockedBy` call written inline. There is no seam to call, so the
// only assertion that can distinguish "withheld" from "offered" is made on the
// rendered menu: `flutter_context_menu`'s `MenuItem` gives a disabled entry an
// `InkWell` with a null `onTap`, which is the property a press actually meets.
// That is why the grid is mounted for real and the row is right-clicked for real.
//
// EVERY WITHHELD ASSERTION STANDS BESIDE A LIVE ONE. "Withheld while a long
// reader runs" and "withheld always" read identically from one case, and the
// second would ship an entry that never works, so each blocked case is paired
// with the same entry being live in the same mount — and with 削除, the neighbour
// entry this gate must *not* touch, being live in the same menu.
//
// THE SUBJECT IS CHECKED, NOT ONLY THE PRESENCE OF A CLAIM. A claim over a
// *different* record's folder must leave the entry alone. Without that case a
// gate that answered "is anything claimed at all" would pass here, and that gate
// would grey the entry for every row on the page whenever any zip ran.
//
// WHAT THIS SUITE DOES NOT REACH.
//  * Any sentence. `MenuItem` takes no tooltip, so the withheld entry says
//    nothing — a known gap `data_table_widget.dart` states at the entry, not one
//    this suite could assert away.
//  * The engine-side refusal in `CharaDetailRecordRegenerationController.start`;
//    that is `regeneration_long_read_gate_test.dart`'s.
//  * The web leg. `longReadRegistryProvider` is the shared model both platforms
//    report through, but browser storage semantics are outside a VM suite.
//  * The other entries' own gating (`selecting`, `importing`): those flags are
//    read in the same expression and would still have to be broken separately.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trina_grid/trina_grid.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/spec/base.dart';
import 'package:umacapture/src/chara_detail/spec/loader.dart';
import 'package:umacapture/src/chara_detail/spec/logic.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/zip_export.dart';
import 'package:umacapture/src/gui/chara_detail/data_table_widget.dart';

import 'support/hive.dart';
import 'support/localization.dart';
import 'support/records.dart';
import 'support/riverpod.dart';

late Directory _tempRoot;
late PathInfo _layout;

DirectoryPath get _activeDir => _layout.charaDetailActiveDir;

/// The two records the table is built with: the one whose menu is opened, and a
/// neighbour used to show that a claim elsewhere does not reach it.
final _record = makeRecord(id: 'held', card: 1);
final _other = makeRecord(id: 'other', card: 2);

/// Active storage that answers for both records and scans nothing.
///
/// The table is driven from [displayedRecordsProvider] and [currentGridProvider],
/// both overridden below, so the store only has to exist.
class _FakeRecordStorage extends CharaDetailRecordStorage {
  @override
  Future<List<CharaDetailRecord>> build() async => [_record, _other];

  @override
  CharaDetailRecord? getBy({required String id}) => id == _record.id ? _record : (id == _other.id ? _other : null);
}

/// One text column and one row per record, each carrying the user data
/// `_buildGrid` attaches — which is where `onRowSecondaryTap` reads both from.
///
/// The column's spec is a [LogicColumnSpec] because it is the one concrete spec
/// that needs no parser: the tap handler dereferences the column's spec without a
/// null check and reads only `cellAction`, so which spec it is does not matter,
/// only that there is one.
Grid _grid() {
  final column = TrinaColumn(title: 'id', field: 'id', type: TrinaColumnType.text(), width: 200)
    ..setUserData(LogicColumnSpec(id: 'id', title: 'id', logic: LogicMode.and));
  final rows = [
    for (final record in [_record, _other]) TrinaRow(cells: {'id': TrinaCell(value: record.id)})..setUserData(record),
  ];
  return Grid([column], rows, const {});
}

ProviderContainer _container() {
  return ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      charaDetailRecordStorageLoaderProvider.overrideWith(_FakeRecordStorage.new),
      // The real loader runs the archive geometry migration and awaits three
      // upstream loaders. None of that is what is under test, and all of it
      // would put a filesystem sweep inside a widget test's fake clock.
      charaDetailInitialDataLoader.overrideWith((ref) async => const <List<Object>>[]),
      // Built here rather than derived, so the grid does not depend on the
      // column-spec graph. `_CharaDetailDataTablePreCheckLayer` gates on both of
      // these being non-empty before it mounts the table at all.
      displayedRecordsProvider.overrideWithValue([_record, _other]),
      currentGridProvider.overrideWithValue(_grid()),
    ],
  );
}

/// Publishes a zip over [directory] through the notifier `exportDirectoryAsZip`
/// claims the registry slot with.
///
/// A zip and not a hand-made claim: it is the shortest real route into
/// `longReadRegistryProvider`, so these cases would also fail if the zip stopped
/// registering itself.
void _hold(ProviderContainer container, DirectoryPath directory) {
  expect(
    container.read(storageZipProgressProvider.notifier).begin(directory),
    isTrue,
    reason: 'the slot must have been free for the arrangement under test to mean anything',
  );
}

void _release(ProviderContainer container) => container.read(storageZipProgressProvider.notifier).finish();

/// Gives the grid and the menu a window they both fit in.
void _useARoomyWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpTable(WidgetTester tester, ProviderContainer container) async {
  _useARoomyWindow(tester);
  await pumpWithContainer(
    tester,
    container,
    MaterialApp(
      locale: appTestLocale,
      home: const Scaffold(body: CharaDetailDataTableLoaderLayer()),
    ),
  );
  await tester.pumpAndSettle();
}

/// Right-clicks the cell of [record]'s row and lets the menu route settle.
Future<void> _openRowMenu(WidgetTester tester, CharaDetailRecord record) async {
  final cell = find.text(record.id);
  expect(cell, findsOneWidget, reason: 'the row under test is not on screen, so no menu could be opened on it');
  final gesture = await tester.startGesture(tester.getCenter(cell), kind: PointerDeviceKind.mouse, buttons: 2);
  await gesture.up();
  await tester.pumpAndSettle();
}

/// Whether the menu entry labelled [label] accepts a press.
///
/// Read off the `InkWell` the entry is built from rather than off its colour: a
/// disabled `MenuItem` renders `onTap: null`, which is the property a press meets.
/// A colour comparison would keep passing for an entry that was greyed and still
/// live — the exact defect this suite exists for, seen from the other side.
bool _entryLive(WidgetTester tester, String label) {
  final finder = find.ancestor(of: find.text(label), matching: find.byType(InkWell));
  expect(finder, findsOneWidget, reason: 'the menu entry "$label" is not in the open menu');
  return tester.widget<InkWell>(finder).onTap != null;
}

String get _regenerateLabel => appSentenceAt('pages.chara_detail.context_menu.regenerate_record');

String get _deleteLabel => appSentenceAt('pages.chara_detail.context_menu.delete_record');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);
  useStorageBoxForTest();

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_record_table_menu_gate');
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

  testWidgets('positive control: with nothing claimed, the row menu offers 再認識', (tester) async {
    final container = _container();
    await _pumpTable(tester, container);
    await _openRowMenu(tester, _record);

    expect(_entryLive(tester, _regenerateLabel), isTrue);
    expect(_entryLive(tester, _deleteLabel), isTrue, reason: 'the neighbouring entry is the control for the mount');
  });

  testWidgets('a long reader holding the record\'s folder withholds 再認識, and only that entry', (tester) async {
    final container = _container();
    _hold(container, _activeDir / _record.id);
    await _pumpTable(tester, container);
    await _openRowMenu(tester, _record);

    expect(_entryLive(tester, _regenerateLabel), isFalse);
    // The gate is on re-recognition alone. Delete has a gate of its own, in the
    // dialog it opens (`record_delete_extraction_gate_test.dart`), so greying it
    // here as well would be a second, divergent copy of that decision.
    expect(_entryLive(tester, _deleteLabel), isTrue);
  });

  testWidgets('a claim on another record leaves this row\'s 再認識 alone', (tester) async {
    final container = _container();
    _hold(container, _activeDir / _other.id);
    await _pumpTable(tester, container);
    await _openRowMenu(tester, _record);

    expect(
      _entryLive(tester, _regenerateLabel),
      isTrue,
      reason: 'the entry is gated on a claim over this record, not on the registry being non-empty',
    );
  });

  testWidgets('a claim on the write transaction journal withholds 再認識 too', (tester) async {
    // No record's folder, and the half this entry used to miss: a batch started
    // here publishes every rewritten record through a slot under this directory on
    // web, and 「アプリの残骸」 offers a zip and a delete over it. The entry asks
    // `regenerateRecordLongReadPaths` — what the batch itself claims — so the
    // journal is in the question by construction.
    final container = _container();
    _hold(container, _layout.charaDetailWriteTransactionDir);
    await _pumpTable(tester, container);
    await _openRowMenu(tester, _record);

    expect(_entryLive(tester, _regenerateLabel), isFalse);
    expect(_entryLive(tester, _deleteLabel), isTrue, reason: 'the gate is still on re-recognition alone');
  });

  testWidgets('a claim on the archive journal next door leaves 再認識 alone', (tester) async {
    // The control that keeps the case above about the write journal rather than
    // about any sibling of `active/`: a re-recognition never writes the archive's
    // journal.
    final container = _container();
    _hold(container, _layout.charaDetailArchiveTransactionDir);
    await _pumpTable(tester, container);
    await _openRowMenu(tester, _record);

    expect(_entryLive(tester, _regenerateLabel), isTrue);
  });

  testWidgets('the entry comes back once the claim is released', (tester) async {
    final container = _container();
    _hold(container, _activeDir / _record.id);
    await _pumpTable(tester, container);
    await _openRowMenu(tester, _record);
    expect(_entryLive(tester, _regenerateLabel), isFalse);

    // Dismiss the menu, release, and open it again: the entry is built fresh on
    // every open (the menu reads the registry rather than watching it), so the
    // recovery is only observable through a second open.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    _release(container);
    await tester.pumpAndSettle();
    await _openRowMenu(tester, _record);

    expect(_entryLive(tester, _regenerateLabel), isTrue);
  });
}
