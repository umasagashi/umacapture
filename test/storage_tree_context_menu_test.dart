// The storage view's row context menu and its "open the containing folder"
// entry.
//
// **One gate, one test — deliberately, and the list is the test names, not this
// comment.** The feature is a stack of independent gates, and a single test that
// opened the menu and pressed something would go green again if any one of them
// were reintroduced. So this header describes the *shape* rather than
// enumerating: an earlier version of it counted ("four separate claims") and was
// stale by the next round. Read `flutter test --plain-name` output, or the
// `testWidgets` descriptions below, for what is actually claimed.
//
// The gates each test is written against, as kinds:
//
//  * **entrances** — a secondary press and a long press reach one builder, and
//    each entrance is claimed apart from the other, so removing either is not
//    mistaken for removing the menu;
//  * **capability** — the "open the folder" entry exists only where the platform
//    has a file manager (`CurrentPlatform.canRevealInFileManager()`), reachable
//    from the VM through `TargetPlatformVariant`;
//  * **target** — what a file row launches is the containing folder and never the
//    file, asserted on the URL the shell channel receives;
//  * **failure** — a shell that refuses says so, as an error toast;
//  * **exclusion** — the withholding that applies while a capture or a video
//    import is writing into the group, claimed once per gated entry rather
//    than once for the menu, since the entries read it independently. Asserted
//    with the activity beginning *under an open menu*: a row it is already in
//    force on opens no menu at all, and that half is claimed here too and in
//    `storage_row_menu_gate_test.dart`;
//  * **liveness** — an entry's refusal is re-read while the menu is up, so a long
//    reader that begins after it opened withholds the entry and releasing gives
//    it back, without the menu being reopened;
//  * **independence from the preview** — a file the preview declines to render is
//    still one the menu can save.
//
// Negative controls: a group row's menu is narrower than an entry row's — no
// copy and no "open the folder", because a group can resolve to more than one
// root — and the entries a row does not offer are absent rather than
// present-and-dead.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/storage_tree_context_menu_test.dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_context_menu/flutter_context_menu.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/clipboard_alt.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/file_download.dart';
import 'package:umacapture/src/core/storage/file_preview.dart';
import 'package:umacapture/src/core/storage/file_preview_source.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/storage/zip_export.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/storage_tree.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

late Directory _root;
late PathInfo _info;

/// The names `storageSaveFileProvider` was asked to write, which is what "the
/// save entry ran" means without a native file dialog.
late List<String> _saved;

/// The arrangement every test but one runs in.
///
/// A `TargetPlatformVariant` rather than an assignment in `setUp`, because
/// `testWidgets` verifies at the end of each body that no foundation debug
/// variable is still set; the variant is what sets and restores it around the
/// body instead.
final _desktop = TargetPlatformVariant.only(TargetPlatform.windows);

/// A platform with no OS file manager, which is what
/// `CurrentPlatform.canRevealInFileManager()` answers false for. The VM reports
/// `kIsWeb == false`, so this is the reachable half of that gate — and
/// `PathEntity.launch()` cannot tell a browser from a phone.
final _withoutFileManager = TargetPlatformVariant.only(TargetPlatform.android);

/// The label of a menu entry, read out of `ja.json` so the assertion is about
/// the shipped sentence rather than about whatever the code happens to say.
String _label(String key) => appSentenceAt('pages.storage.actions.$key');

void _write(String relative, int bytes) {
  final file = File('${_root.path}${Platform.pathSeparator}$relative');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(List<int>.filled(bytes, 0x61));
}

/// [zipped] collects the folders the zip export was actually started on, which is
/// what "the export ran" means without writing an archive: the runner is the last
/// thing `exportDirectoryAsZip` reaches, so a press that gets that far got past
/// every gate.
/// The notifier the last [_container] handed to `videoImportListenableProvider`.
///
/// Exposed so a test can start an activity blocker **while the menu is already
/// open**, which is the only ordering that reaches an entry's own gate now that a
/// blocked row opens no menu at all. An import is a `CaptureActivity` exactly as
/// a capture is (`storage_delete_capture_gate_test` asserts the two resolve
/// alike), and it is the half this suite can turn on mid-test: the capture half
/// is a value override, fixed for the life of the container.
late ValueNotifier<VideoImportState> _importNotifier;

ProviderContainer _container({bool clipboard = true, bool capturing = false, List<String>? zipped}) {
  _importNotifier = ValueNotifier(VideoImportState.idle);
  return ProviderContainer(
    overrides: [
      if (zipped != null) ...[
        storageZipAvailableProvider.overrideWithValue(true),
        storageZipPreflightProvider.overrideWithValue((ref, directory) async => null),
        storageZipRunnerProvider.overrideWithValue((ref, directory, report, guard) async {
          zipped.add(directory.path);
          return StorageZipDelivery.cancelled;
        }),
      ],
      pathLayoutLoader.overrideWith((ref) async => _info),
      // "Absent" and "disabled" are two of the answers this suite has to tell
      // apart, so the capability is pinned rather than left to the host.
      clipboardFileReferenceSupportProvider.overrideWithValue(clipboard),
      // Overridden *below* `captureActivityProvider`, so the resolution under
      // test is the shipped one.
      capturingStateProvider.overrideWithValue(capturing),
      videoImportListenableProvider.overrideWithValue(_importNotifier),
      // Stands in for the OS save dialog, which no VM test may open.
      storageSaveFileProvider.overrideWithValue(({
        required String dialogTitle,
        required String fileName,
        required Uint8List bytes,
      }) async {
        _saved.add(fileName);
        return null;
      }),
    ],
  );
}

Future<void> _pumpTree(WidgetTester tester, ProviderContainer container) {
  tester.view.physicalSize = const Size(1000, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  return pumpWithContainer(tester, container, const MaterialApp(home: Scaffold(body: StorageTreeView())));
}

/// Lets the real event loop run, which a `testWidgets` body's fake clock does not.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 40; round++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

/// Presses [target] with the secondary button and lets the menu route settle.
Future<void> _secondaryPress(WidgetTester tester, Finder target) async {
  final gesture = await tester.startGesture(tester.getCenter(target), buttons: kSecondaryButton);
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  const shellChannel = MethodChannel('plugins.flutter.io/url_launcher');
  late List<MethodCall> shellCalls;
  late bool shellResult;

  setUp(() {
    _root = Directory.systemTemp.createTempSync('storage_tree_menu_test');
    final base = DirectoryPath(_root.path);
    _info = PathInfo(
      documentDir: base / 'documents' / 'umacapture',
      supportDir: base / 'support',
      executableDir: base / 'executable',
      downloadDir: base / 'downloads',
    );
    _write('documents/umacapture/storage/chara_detail/active/rec1/record.json', 100);
    _saved = <String>[];
    shellCalls = <MethodCall>[];
    shellResult = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(shellChannel, (
      call,
    ) async {
      shellCalls.add(call);
      return shellResult;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(shellChannel, null);
    _root.deleteSync(recursive: true);
  });

  /// Opens the active-records group and returns nothing; the row `rec1` is then
  /// on screen as a directory row and `record.json` under it as a file row.
  Future<void> openToTheFile(WidgetTester tester, ProviderContainer container) async {
    await _pumpTree(tester, container);
    await _settle(tester);
    final expansion = container.read(storageTreeExpansionProvider.notifier);
    expansion.toggle((group: StorageGroupId.activeRecords, path: null));
    await _settle(tester);
    expansion.toggle((group: StorageGroupId.activeRecords, path: (_info.charaDetailActiveDir / 'rec1').path));
    await _settle(tester);
    expect(find.text('record.json'), findsOneWidget);
  }

  testWidgets('a secondary press on a directory row opens a menu of that row s actions', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);

    // The package's menu widget is not exported, so the menu is observed by its
    // own entries: none of these labels is on the tree itself (the row's buttons
    // carry them as tooltips, which render no `Text` until they are shown).
    expect(find.text(_label('copy_directory')), findsNothing);
    await _secondaryPress(tester, find.text('rec1'));

    expect(find.text(_label('copy_directory')), findsOneWidget);
    expect(find.text(_label('delete')), findsOneWidget);
    expect(find.text(_label('open_in_explorer')), findsOneWidget);
    // A folder's menu is not a file's: the two file actions are not on it.
    expect(find.text(_label('copy_file')), findsNothing);
    expect(find.text(_label('download_file')), findsNothing);
  }, variant: _desktop);

  testWidgets('a file row s menu carries the two actions that were only on its preview', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);

    await _secondaryPress(tester, find.text('record.json'));

    expect(find.text(_label('delete')), findsOneWidget);
    expect(find.text(_label('copy_file')), findsOneWidget);
    expect(find.text(_label('download_file')), findsOneWidget);
    expect(find.text(_label('open_in_explorer')), findsOneWidget);
    // Negative control for the same menu: a file offers no folder copy and no
    // zip, so those entries are absent rather than dead.
    expect(find.text(_label('copy_directory')), findsNothing);
    expect(find.text(_label('zip_directory')), findsNothing);
  }, variant: _desktop);

  // **A group row has a menu now, and it is narrower than an entry row's.** This
  // case used to claim the opposite — that a group row had none at all — and the
  // reason it gave has survived the change: a group can resolve to more than one
  // root, so "copy this" and "open this folder" still have no single path to
  // name. The zip and the delete were never in that position, so they are what
  // the row's menu carries.
  //
  // Paired with the two tests above, which show the missing labels *do* appear
  // for an entry row, so the absences below cannot pass by the labels being
  // unfindable in principle.
  testWidgets('a group row s menu carries the bundle and the removal alone', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);

    await _secondaryPress(tester, find.text(appSentenceAt('pages.storage.group.active_records.label')));

    expect(find.text(_label('zip_directory')), findsOneWidget);
    expect(find.text(_label('delete')), findsOneWidget);
    expect(find.text(_label('open_in_explorer')), findsNothing);
    expect(find.text(_label('copy_directory')), findsNothing);
    // The two file actions are not on it either: a group is not a file.
    expect(find.text(_label('copy_file')), findsNothing);
    expect(find.text(_label('download_file')), findsNothing);
  }, variant: _desktop);

  testWidgets('the open-the-folder entry is absent where the platform has no file manager', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);

    await _secondaryPress(tester, find.text('record.json'));

    // The menu is still there — only the one entry that needs a file manager is
    // gone — so this cannot pass by the menu having failed to open.
    expect(find.text(_label('download_file')), findsOneWidget);
    expect(find.text(_label('open_in_explorer')), findsNothing);
  }, variant: _withoutFileManager);

  testWidgets('a file row opens the folder that contains it, never the file', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);

    await _secondaryPress(tester, find.text('record.json'));
    await tester.tap(find.text(_label('open_in_explorer')));
    await _settle(tester);

    expect(shellCalls, hasLength(1));
    expect(shellCalls.single.method, 'launch');
    final url = Uri.parse((shellCalls.single.arguments as Map)['url'] as String);
    final opened = DirectoryPath(url.toFilePath()).path;
    expect(opened, (_info.charaDetailActiveDir / 'rec1').path);
    // The claim is specifically that the *file* was not handed to the shell.
    expect(opened, isNot(contains('record.json')));
  }, variant: _desktop);

  testWidgets('a directory row opens that directory itself', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);

    await _secondaryPress(tester, find.text('rec1'));
    await tester.tap(find.text(_label('open_in_explorer')));
    await _settle(tester);

    expect(shellCalls, hasLength(1));
    final url = Uri.parse((shellCalls.single.arguments as Map)['url'] as String);
    expect(DirectoryPath(url.toFilePath()).path, (_info.charaDetailActiveDir / 'rec1').path);
  }, variant: _desktop);

  testWidgets('a shell that refuses is reported, not swallowed', (tester) async {
    final container = _container();
    final toasts = <ToastData>[];
    final subscription = container.listen(plainToastEventProvider, (_, next) => next.whenData(toasts.add));
    addTearDown(subscription.close);
    shellResult = false;
    await openToTheFile(tester, container);

    await _secondaryPress(tester, find.text('record.json'));
    await tester.tap(find.text(_label('open_in_explorer')));
    await _settle(tester);

    expect(shellCalls, hasLength(1));
    expect(toasts, hasLength(1));
    expect(toasts.single.type, ToastType.error);
    expect(toasts.single.description, appSentenceAt('pages.storage.reveal.failed'));
  }, variant: _desktop);

  // The blocker is asserted by *behaviour*, not by the entry's colour: a menu
  // entry is a model and not a widget, so `enabled` is not readable from the
  // tree, and matching the greyed style would keep passing if `enabled` were
  // hard-wired true while the style stayed. The save entry is the one chosen for
  // it because its effect is observable without a native dialog and without the
  // app-level dialog host `showStorageDeleteConfirmation` needs.
  testWidgets('the save entry runs when nothing is running', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);

    await _secondaryPress(tester, find.text('record.json'));
    await tester.tap(find.text(_label('download_file')));
    await _settle(tester);

    expect(_saved, ['record.json']);
  }, variant: _desktop);

  // **These three used to run with the activity already in force when the menu
  // was opened.** A row a capture or an import is writing into now opens no menu
  // at all — the row's ⋮ and both of its gestures are shut, which
  // `storage_row_menu_gate_test.dart` claims — so the state they were written
  // against, a listed entry that refuses the press, is only reachable when the
  // activity begins *after* the menu is up. That ordering is what the entries'
  // per-frame reading is for, and it is the one the app really produces: an
  // import can begin from a picker the user left standing.
  testWidgets('an activity that begins while the menu is open withholds the save entry', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);

    await _secondaryPress(tester, find.text('record.json'));
    expect(_entryEnabled(tester, _label('download_file')), isTrue, reason: 'the entry has to start live');

    _importNotifier.value = const VideoImportState(phase: VideoImportPhase.importing);
    await _settle(tester);

    expect(_entryEnabled(tester, _label('download_file')), isFalse);
    await tester.tap(find.text(_label('download_file')));
    await _settle(tester);

    // Withheld while the import writes, not withdrawn. The entry is still listed — the press
    // simply does nothing — so this is not the "entry is missing" state.
    expect(find.text(_label('download_file')), findsOneWidget);
    expect(_saved, isEmpty);
  }, variant: _desktop);

  testWidgets('an activity that begins while the menu is open does not withhold the folder entry', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);

    await _secondaryPress(tester, find.text('record.json'));
    _importNotifier.value = const VideoImportState(phase: VideoImportPhase.importing);
    await _settle(tester);

    // Reading a path out to the file manager writes nothing and copies nothing,
    // so it is not one of the actions the per-group exclusion covers. The save
    // entry beside it *is* withheld in this very frame, so this is not a test in
    // which the blocker failed to arrive.
    expect(_entryEnabled(tester, _label('download_file')), isFalse);
    expect(_entryEnabled(tester, _label('open_in_explorer')), isTrue);
    await tester.tap(find.text(_label('open_in_explorer')));
    await _settle(tester);

    expect(shellCalls, hasLength(1));
  }, variant: _desktop);

  // The other side of the same change: with the activity already running there
  // is no menu to grey, because the entrance is what closed. Asserted here as
  // well as in the gate suite, because this file is where the reader looks for
  // "what does a capture do to this menu" and the answer moved.
  testWidgets('a capture already running opens no menu at all, rather than a menu of dead entries', (tester) async {
    final container = _container(capturing: true);
    await openToTheFile(tester, container);

    await _secondaryPress(tester, find.text('record.json'));

    expect(find.text(_label('download_file')), findsNothing);
    // `open_in_explorer` is the entry nothing ever withholds, so it is the one
    // that tells "the menu did not open" from "the menu opened with everything
    // greyed".
    expect(find.text(_label('open_in_explorer')), findsNothing);
    expect(_saved, isEmpty);
  }, variant: _desktop);

  // The claim `storage_file_preview_view_test` used to carry on the preview's own
  // download button: a file this view will not *render* is still one the user may
  // want to pull out — arguably the case where getting it out matters most. The
  // menu is now a second host for that action, and nothing about the menu reads
  // the preview's verdict, so the claim has to be restated here or it is nowhere.
  testWidgets('a file the preview refuses is still one the menu can save', (tester) async {
    // Over `imagePreviewByteLimit`, which is the bound `resolveFilePreview`
    // declines an image at. Written in the body rather than the fixture: it is
    // 16 MB, and only this test needs it.
    _write('documents/umacapture/storage/chara_detail/active/rec1/huge.png', imagePreviewByteLimit + 1);
    final container = _container();
    await _pumpTree(tester, container);
    await _settle(tester);

    // The refusal is asserted, not assumed. Without this the test would still be
    // green against a bound that had been raised past the fixture, and would then
    // be making its claim about an ordinary renderable image.
    final verdict = await tester.runAsync(
      () => resolveFilePreview(
        name: 'huge.png',
        source: FsBackendPreviewSource((_info.charaDetailActiveDir / 'rec1').filePath('huge.png').path),
      ),
    );
    expect(verdict, isA<OversizeImageFilePreview>());

    final expansion = container.read(storageTreeExpansionProvider.notifier);
    expansion.toggle((group: StorageGroupId.activeRecords, path: null));
    await _settle(tester);
    expansion.toggle((group: StorageGroupId.activeRecords, path: (_info.charaDetailActiveDir / 'rec1').path));
    await _settle(tester);

    await _secondaryPress(tester, find.text('huge.png'));
    expect(find.text(_label('download_file')), findsOneWidget);
    await tester.tap(find.text(_label('download_file')));
    await _settle(tester);

    expect(_saved, ['huge.png']);
  }, variant: _desktop);

  // The copy entry's own gate, asserted apart from the save entry's. The two read
  // the same expression today and sit in the same list, so a single test that
  // happened to cover both would stop covering either the moment they diverged.
  //
  // Observed on the entry's rendered disabled styling rather than by pressing it:
  // a press would reach `ClipboardAlt.pasteEntity`, which on this host writes a
  // file reference into the *user's real clipboard*, and this machine is shared.
  // The positive control below is what stops "always the disabled colour" from
  // passing.
  testWidgets('the copy entry is live when nothing is running', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);

    await _secondaryPress(tester, find.text('record.json'));

    expect(_entryEnabled(tester, _label('copy_file')), isTrue);
    expect(_entryLooksDisabled(tester, _label('copy_file')), isFalse);
  }, variant: _desktop);

  // The single-flight read is `holdsKind`, not the zip's progress projection
  // (`_EntryTile._showRowMenu`'s `zipRunning`): the projection is only defined
  // for a claim with exactly one hold, and `begin` never produces any other
  // shape, so a claim registered directly with none yet is the one arrangement
  // that tells the two readings apart. If the entry read the projection instead,
  // it would see `null` (no single hold to report) and offer a second zip while
  // one is already claimed.
  testWidgets('the zip entry is withheld by a zip claim even before it holds a path', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);

    container.read(longReadRegistryProvider.notifier).claimUntilReleased(kind: LongReadKind.zip, paths: const []);

    await _secondaryPress(tester, find.text('rec1'));

    expect(
      _entryEnabled(tester, _label('zip_directory')),
      isFalse,
      reason: 'a zip claim is live even though it holds no path yet, so the menu must not offer a second one',
    );
  }, variant: _desktop);

  // The gate that has to survive the menu being *already open*.
  //
  // Nothing the user does starts these claims: a module install runs from the
  // desktop auto-update and from the web bootstrap on every load, and it holds
  // the `modules` group, which carries no filesystem lock underneath. So an
  // entry that read the registry once, when the menu opened, hands out a folder
  // that is being rewritten and nothing downstream stops it. The three entries
  // are claimed one at a time because they are three independent readings, and a
  // single case would stop covering two of them the moment one diverged.
  //
  // The negative controls are the claim-first cases already above and beside
  // these: without them "always disabled" would pass every positive here.
  LongReadToken claimRecordDir(ProviderContainer container) {
    return container
        .read(longReadRegistryProvider.notifier)
        .claimUntilReleased(kind: LongReadKind.scan, paths: [_info.charaDetailActiveDir / 'rec1']);
  }

  testWidgets('a claim that begins while the menu is open withholds the save entry', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);
    await _secondaryPress(tester, find.text('record.json'));
    expect(_entryEnabled(tester, _label('download_file')), isTrue, reason: 'the entry has to start live');

    claimRecordDir(container);
    await _settle(tester);

    expect(_entryEnabled(tester, _label('download_file')), isFalse);
    expect(_entryLooksDisabled(tester, _label('download_file')), isTrue);
    await tester.tap(find.text(_label('download_file')));
    await _settle(tester);
    expect(_saved, isEmpty, reason: 'the press reached the save with a long reader holding the folder');
  }, variant: _desktop);

  // The claim-first ordering, whose answer changed. It used to open the menu and
  // find the save entry listed and inert; the entrance is now shut before the
  // menu can be asked for, so what it asserts is that no menu appears — the
  // difference between "listed and refused" and "not offered", which is exactly
  // what the case above it is the other half of.
  testWidgets('a claim registered before the menu is asked for opens no menu', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);

    claimRecordDir(container);
    await _settle(tester);
    await _secondaryPress(tester, find.text('record.json'));

    expect(find.text(_label('download_file')), findsNothing);
    expect(find.text(_label('open_in_explorer')), findsNothing);
    expect(_saved, isEmpty);
  }, variant: _desktop);

  testWidgets('a claim that begins while the menu is open withholds the zip entry', (tester) async {
    final zipped = <String>[];
    final container = _container(zipped: zipped);
    await openToTheFile(tester, container);
    await _secondaryPress(tester, find.text('rec1'));
    expect(_entryEnabled(tester, _label('zip_directory')), isTrue, reason: 'the entry has to start live');

    claimRecordDir(container);
    await _settle(tester);

    expect(_entryEnabled(tester, _label('zip_directory')), isFalse);
    expect(_entryLooksDisabled(tester, _label('zip_directory')), isTrue);
    await tester.tap(find.text(_label('zip_directory')));
    await _settle(tester);
    expect(zipped, isEmpty, reason: 'the export started over a folder a long reader is holding');
  }, variant: _desktop);

  // The zip entry with nothing claimed, so the case above is not green merely
  // because this arrangement can never start an export.
  testWidgets('the zip entry runs when nothing is running', (tester) async {
    final zipped = <String>[];
    final container = _container(zipped: zipped);
    await openToTheFile(tester, container);

    await _secondaryPress(tester, find.text('rec1'));
    await tester.tap(find.text(_label('zip_directory')));
    await _settle(tester);

    expect(zipped, [(_info.charaDetailActiveDir / 'rec1').path]);
  }, variant: _desktop);

  // Read rather than pressed, for the reason the two copy cases above give: a
  // press writes into the user's real clipboard on a shared machine.
  testWidgets('a claim that begins while the menu is open withholds the copy entry', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);
    await _secondaryPress(tester, find.text('record.json'));
    expect(_entryEnabled(tester, _label('copy_file')), isTrue, reason: 'the entry has to start live');

    claimRecordDir(container);
    await _settle(tester);

    expect(_entryEnabled(tester, _label('copy_file')), isFalse);
    expect(_entryLooksDisabled(tester, _label('copy_file')), isTrue);
  }, variant: _desktop);

  // Releasing gives the entries back without the menu being reopened, which is
  // the other half of "the reading is live": an entry that merely latched the
  // first refusal it saw would pass every case above.
  testWidgets('releasing the claim gives the open menu its entries back', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);
    await _secondaryPress(tester, find.text('record.json'));

    final token = claimRecordDir(container);
    await _settle(tester);
    expect(_entryEnabled(tester, _label('download_file')), isFalse);

    container.read(longReadRegistryProvider.notifier).release(token);
    await _settle(tester);

    expect(_entryEnabled(tester, _label('download_file')), isTrue);
    expect(_entryLooksDisabled(tester, _label('download_file')), isFalse);
    await tester.tap(find.text(_label('download_file')));
    await _settle(tester);
    expect(_saved, ['record.json']);
  }, variant: _desktop);

  // The copy entry's own activity gate, asserted apart from the save entry's for
  // the reason the two long-read cases above are: they read the same expression
  // today and sit in the same list, so one case covering both would stop covering
  // either the moment they diverged. Reordered like its neighbours — the activity
  // begins under an open menu, since a row it is already in force on opens none.
  testWidgets('an activity that begins while the menu is open withholds the copy entry', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);

    await _secondaryPress(tester, find.text('record.json'));
    expect(_entryEnabled(tester, _label('copy_file')), isTrue, reason: 'the entry has to start live');

    _importNotifier.value = const VideoImportState(phase: VideoImportPhase.importing);
    await _settle(tester);

    expect(_entryEnabled(tester, _label('copy_file')), isFalse);
    expect(_entryLooksDisabled(tester, _label('copy_file')), isTrue);
    // Still listed, not withdrawn — the same shape the save entry keeps while an
    // import is writing.
    expect(find.text(_label('copy_file')), findsOneWidget);
  }, variant: _desktop);

  // The second entrance. Asserted apart from the secondary press throughout: if
  // one test covered both, the two entrances would not be separately claimed, and
  // removing either would look like removing the menu.
  testWidgets('a long press opens the same menu a secondary press does', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);

    expect(find.text(_label('open_in_explorer')), findsNothing);
    await tester.longPress(find.text('record.json'));
    await tester.pump(const Duration(milliseconds: 200));

    // The same four entries the secondary press produces, since both go through
    // one builder.
    expect(find.text(_label('delete')), findsOneWidget);
    expect(find.text(_label('copy_file')), findsOneWidget);
    expect(find.text(_label('download_file')), findsOneWidget);
    expect(find.text(_label('open_in_explorer')), findsOneWidget);
  }, variant: _desktop);

  testWidgets('a long press does not also count as a tap on the row', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);
    final opened = container.read(storageTreeExpansionProvider);

    // A directory row, whose tap toggles the node: the state is what says whether
    // the press leaked through as a tap. Checked on the row that has an
    // observable tap, not on the file row, whose preview needs a dialog host.
    await tester.longPress(find.text('rec1'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text(_label('open_in_explorer')), findsOneWidget);
    expect(container.read(storageTreeExpansionProvider), opened);
  }, variant: _desktop);

  // The group row's second entrance, claimed apart from its secondary press for
  // the reason an entry row's two are. This case used to claim that a long press
  // on a group row opened nothing, which was the other half of "a group row has
  // no menu"; a group row has one now, and it is reached the same three ways an
  // entry row's is.
  testWidgets('a long press on a group row opens the same menu', (tester) async {
    final container = _container();
    await openToTheFile(tester, container);

    await tester.longPress(find.text(appSentenceAt('pages.storage.group.active_records.label')));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text(_label('delete')), findsOneWidget);
    expect(find.text(_label('zip_directory')), findsOneWidget);
    // Still narrower than an entry row's, from this entrance as from the other.
    expect(find.text(_label('open_in_explorer')), findsNothing);
  }, variant: _desktop);
}

/// The open menu's entry labelled [label], as the model the menu was built from.
///
/// A menu entry is not itself a widget, but the package wraps each one in a
/// `MenuEntryWidget` that holds it in a public `entry` field. That wrapper is not
/// exported from the package's umbrella library, so it is matched by the name its
/// runtime type reports and read dynamically; `ContextMenuItem` — the type that
/// declares `enabled` — *is* exported, so the value that comes back is checked
/// statically and nothing about `enabled` is read through `dynamic`.
///
/// The label is read through `dynamic` because the entry type is private to
/// `storage_tree.dart`; it is a plain `String` there, since the entry decides its
/// own colours from the availability it re-reads on every frame rather than from
/// a `Text` fixed when the menu opened.
///
/// This is what lets [_entryEnabled] assert the entry's own `enabled`, and not
/// merely the colour it is drawn in. The two are separate claims: a regression
/// that greyed the label while leaving the entry pressable would pass a
/// colour-only assertion, and pressing the copy entry to find out is not
/// available here — it writes into the user's real clipboard, on a machine the
/// user is using.
ContextMenuItem _menuEntry(WidgetTester tester, String label) {
  final matches = tester.allWidgets
      .where((widget) => widget.runtimeType.toString().startsWith('MenuEntryWidget'))
      .map((widget) => (widget as dynamic).entry)
      .whereType<ContextMenuItem>()
      .where((item) => (item as dynamic).label == label)
      .toList();
  expect(matches, hasLength(1), reason: 'expected exactly one menu entry labelled "$label"');
  return matches.single;
}

/// Whether the menu entry labelled [label] will act when it is selected.
bool _entryEnabled(WidgetTester tester, String label) => _menuEntry(tester, label).enabled;

/// Whether the menu entry labelled [label] is *drawn* in the disabled colour.
///
/// Kept alongside [_entryEnabled] rather than replaced by it: one is what the
/// entry does, the other is what the user sees, and a regression can break either
/// without the other. Compared against the same `theme.disabledColor` the entry
/// itself reads, taken from the entry's own context, so a theme change cannot turn
/// this into a comparison with a constant.
bool _entryLooksDisabled(WidgetTester tester, String label) {
  final finder = find.text(label);
  expect(finder, findsOneWidget, reason: 'expected exactly one menu entry labelled "$label"');
  final theme = Theme.of(tester.element(finder));
  return tester.widget<Text>(finder).style?.color == theme.disabledColor;
}
