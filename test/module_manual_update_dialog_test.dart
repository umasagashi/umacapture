// Widget tests for [ModuleManualUpdateDialog]'s install path, which is async and
// therefore closable while it runs.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/module_manual_update_dialog_test.dart
//
// The byte route is the one driven here, because it is the one with an await
// *between* reading `ref` and using it: `installModuleFromZipBytes(ref.base,
// await readBytes())` evaluates `ref.base` first, suspends on the read, and only
// then hands the wrapper on -- so the `ref.read(pathInfoLoader.future)` inside
// happens on whatever the widget's ref has become by then. The picker is the
// entry point rather than the drop zone because the drop zone only exists where
// `CurrentPlatform.supportsFileDrop()` is true (web or desktop), while the byte
// route is taken where `hasWindowFrame()` is false -- two conditions the VM
// cannot hold at once. A picked file with a null path takes the byte route on
// any platform, which is exactly what a browser pick is.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/utils.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/common.dart';
import 'package:umacapture/src/gui/dashboard.dart';
import 'package:umacapture/src/gui/module_update_dialog.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/file_picker.dart';
import 'support/localization.dart';
import 'support/web_like_fs_backend.dart';

Uint8List _bytes(String content) => Uint8List.fromList(utf8.encode(content));

Uint8List _moduleZip() {
  final archive = Archive();
  final entries = {
    'modules/version_info.json': _bytes('{"recognizer_version": "2026-08-04T00:00:00+0900"}'),
    'modules/recognizer.json': _bytes('{"module_path": "skill/prediction.onnx"}'),
    'modules/skill/prediction.onnx': _bytes('onnx-payload'),
  };
  entries.forEach((name, content) => archive.addFile(ArchiveFile(name, content.length, content)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// Records what the extraction wrote instead of writing it.
///
/// **Not a temporary directory, because a widget test cannot wait for one.** The
/// install runs in the binding's fake-async zone, where `pump` advances only the
/// fake clock: a dart:io future never completes under it, and `runAsync` -- which
/// does give the real loop a turn -- does not let the fake zone run the
/// continuations waiting on it. Measured: the pair, alternated, still left the
/// dialog on its spinner until the ten-minute test timeout. A backend that
/// answers from memory completes on a microtask, which is exactly what `pump`
/// flushes. Only `createDir` and `writeBytes` are reached from here; everything
/// else keeps [WebLikeFsBackend]'s behaviour.
class _RecordingFsBackend extends WebLikeFsBackend {
  _RecordingFsBackend(super.inner);

  /// Every path written, in order.
  final written = <String>[];

  @override
  Future<void> createDir(String path, {bool recursive = false}) async {}

  @override
  Future<void> writeBytes(String path, List<int> bytes) async => written.add(path);

  @override
  Future<bool> exists(String path) async => written.contains(path);
}

/// A record store that does nothing, so the success path's `checkRecordVersion()`
/// does not reach the real one (which would walk the filesystem).
class _InertRecordStorage extends CharaDetailRecordStorage {
  @override
  Future<List<CharaDetailRecord>> build() async => const [];

  @override
  Future<void> checkRecordVersion({bool includeCurrentVersion = false}) async {}
}

class _ShowButton extends ConsumerWidget {
  const _ShowButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton(
      onPressed: () => ModuleManualUpdateDialog.show(ref.base),
      child: const Text('show module update dialog'),
    );
  }
}

/// A manual install stopped between the bytes being read and the install being
/// handed them, with the dialog still up.
typedef _HeldInstall = ({StreamController<List<int>> archive, ProviderContainer container, _RecordingFsBackend fs});

/// The root the overridden [pathInfoLoader] reports. Never touched: every write
/// under it is answered by [_RecordingFsBackend].
final _fakeRoot = DirectoryPath('/umacapture-test');

/// The layout every test in this file installs, spelt once so the gate tests ask
/// about the same `modules/` the install writes to.
final _layout = PathInfo(
  documentDir: _fakeRoot,
  supportDir: _fakeRoot,
  executableDir: _fakeRoot,
  downloadDir: _fakeRoot,
);

/// A theme carrying the extensions the dashboard card reads
/// ([AppSemanticColors.noticeContainer] for its title).
ThemeData _theme() {
  final base = FlexThemeData.light(scheme: FlexScheme.blue, useMaterial3: true);
  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[
      AppSemanticColors.light(base.colorScheme),
      AppChartColors.standard(),
      CodeHighlightColors.light(),
    ],
  );
}

late _RecordingFsBackend _fs;
late FsBackend _originalBackend;

/// The manual-update dialog is a three-step procedure and does not scroll, so
/// the default 800x600 test surface puts its pick button off screen and every
/// tap on it warns and misses.
void _sizeView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// The dialog title bar's close (×) button, reached through *this* dialog's
/// tooltip so it cannot match some other × on screen.
Finder _closeButton() {
  return find.descendant(
    of: find.byTooltip(appSentenceAt('pages.settings.module_update.dialog.close_button')),
    matching: find.byType(IconButton),
  );
}

/// Opens the dialog, picks a path-less archive and leaves the install suspended
/// on the archive stream it returns.
Future<_HeldInstall> _startHeldInstall(WidgetTester tester) async {
  _sizeView(tester);
  final container = ProviderContainer(
    overrides: [
      pathInfoLoader.overrideWith((ref) async => _layout),
      moduleVersionLoader.overrideWith((ref) async => null),
      charaDetailRecordStorageLoaderProvider.overrideWith(_InertRecordStorage.new),
    ],
  );
  addTearDown(container.dispose);

  final picker = installFakeFilePicker();
  final archive = StreamController<List<int>>();
  addTearDown(() {
    if (!archive.isClosed) archive.close();
  });
  picker.answerWith([
    // path: null is what a browser pick reports, and what sends the install down
    // the byte route on every platform.
    PlatformFile(name: 'modules.zip', size: 0, readStream: archive.stream),
  ]);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: DialogLayer(child: const Scaffold(body: _ShowButton())),
      ),
    ),
  );
  await tester.tap(find.text('show module update dialog'));
  await tester.pump();
  expect(find.byType(ModuleManualUpdateDialog), findsOneWidget);

  await tester.tap(find.text(appSentenceAt('pages.settings.module_update.dialog.pick_button.label')));
  await tester.pump();
  // The install is under way and waiting on the stream: the progress row is up
  // and the pick button has been withdrawn.
  expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'the install was not held open');
  archive.add(_moduleZip());
  return (archive: archive, container: container, fs: _fs);
}

/// Closes the archive stream and lets the install run to completion.
///
/// Two frames: one for the install's own `setState`, one for the dismiss it
/// publishes to the dialog controller. Nothing real is awaited -- see
/// [_RecordingFsBackend] for why the extraction must not touch a disk here.
///
/// The second frame also elapses the 300ms `sendModuleVersionCheckToast` defers
/// its toast by. Left pending, that timer outlives the tree and the binding
/// fails the test on it -- so the wait is the outcome being reported, not a
/// settling fudge.
Future<void> _releaseInstall(WidgetTester tester, _HeldInstall held) async {
  await held.archive.close();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Releases [held] and asserts the install ran, landed and closed the dialog.
///
/// The second half of every exit test: shutting a door must not also drop the
/// install behind it, and a dialog that survived the exit while quietly losing
/// its install would satisfy the first assertion alone.
Future<void> _expectHeldInstallFinished(WidgetTester tester, _HeldInstall held) async {
  await _releaseInstall(tester, held);
  _expectArchiveLanded(held);
  expect(find.byType(ModuleManualUpdateDialog), findsNothing, reason: 'the dialog outlived its install');
  expect(tester.takeException(), isNull);
}

/// Both halves of the archive reached the store.
///
/// The recognizer payload as well as the top-level JSON, because the install
/// commits the ONNX marker last: a run that stopped part-way would have written
/// one and not the other.
void _expectArchiveLanded(_HeldInstall held, {String why = 'the archive the user handed over was never installed'}) {
  expect(held.fs.written.where((path) => path.endsWith('recognizer.json')), hasLength(1), reason: why);
  expect(held.fs.written.where((path) => path.endsWith('prediction.onnx')), hasLength(1), reason: why);
}

/// Which of the two entries opened the dialog under test.
///
/// The gate is asserted through both of them because the defect was that the
/// answer lived at one entry: the settings tile asked the registry, the dashboard
/// card asked nothing, and the dialog they share asked nothing either.
enum _Entry {
  /// Opened the way [ModuleManualUpdateTile] opens it — `CardDialog.show` on the
  /// container's ref. The tile itself is not mounted: its own gate is
  /// `module_manual_update_tile_test.dart`'s subject, and mounting it here would
  /// make this file green on *that* gate.
  showCall,

  /// Opened by tapping [ModuleUpdaterGroup], the dashboard's module-updater card,
  /// which carries no gate of its own.
  dashboardCard,
}

/// A dialog standing open with [held] claimed, and the token that holds it.
typedef _GatedDialog = ({ProviderContainer container, LongReadToken? token});

/// Opens the dialog with a long read in force over [held] and nothing installing.
Future<_GatedDialog> _pumpGatedDialog(
  WidgetTester tester, {
  List<PathEntity> held = const [],
  LongReadKind kind = LongReadKind.moduleInstall,
  bool withLayout = true,
  _Entry from = _Entry.showCall,
}) async {
  _sizeView(tester);
  final container = ProviderContainer(
    overrides: [
      pathInfoLoader.overrideWith((ref) async => _layout),
      if (withLayout) pathInfoProvider.overrideWithValue(_layout),
      // The dialog asks the *layout* where `modules/` is, so that it can answer during a store
      // outage; the store-prepared provider above is left in place for the install itself.
      if (withLayout) pathLayoutProvider.overrideWithValue(_layout),
      moduleVersionLoader.overrideWith((ref) async => null),
      charaDetailRecordStorageLoaderProvider.overrideWith(_InertRecordStorage.new),
    ],
  );
  addTearDown(container.dispose);
  // `moduleInstall` by default, because that is the claim the automatic update
  // takes: `runModuleInstall` registers `modulesDir` for the length of the
  // extraction, and it is the one the entry tile is already withheld for.
  final token = held.isEmpty
      ? null
      : container.read(longReadRegistryProvider.notifier).claimUntilReleased(kind: kind, paths: held);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: _theme(),
        home: DialogLayer(
          child: Scaffold(
            body: switch (from) {
              _Entry.showCall => const _ShowButton(),
              _Entry.dashboardCard => const ModuleUpdaterGroup(),
            },
          ),
        ),
      ),
    ),
  );
  await tester.tap(switch (from) {
    _Entry.showCall => find.text('show module update dialog'),
    _Entry.dashboardCard => find.text(appSentenceAt('pages.dashboard.module_updater.subtitle')),
  });
  await tester.pump();
  expect(find.byType(ModuleManualUpdateDialog), findsOneWidget, reason: 'the dialog never opened');
  return (container: container, token: token);
}

/// The dialog's own gate, scoped to the dialog so no other [Disabled] on screen
/// can answer for it.
Finder _gate() => find.descendant(of: find.byType(ModuleManualUpdateDialog), matching: find.byType(Disabled));

/// The gate's answer, read off the [Disabled] rather than the [IgnorePointer] it
/// builds, because the subtree nests IgnorePointers of its own.
bool _isInert(WidgetTester tester) => tester.widget<Disabled>(_gate()).disabled;

/// The "select the archive" button, which is the way in that exists on every
/// platform (the drop zone needs `CurrentPlatform.supportsFileDrop()`).
Finder _pickButton() =>
    find.widgetWithText(FilledButton, appSentenceAt('pages.settings.module_update.dialog.pick_button.label'));

/// Every tooltip message currently rendered — what the user could actually
/// hover, rather than what was passed as a parameter.
List<String> _tooltipsShown(WidgetTester tester) => [
  for (final tooltip in tester.widgetList<Tooltip>(find.byType(Tooltip))) tooltip.message ?? '',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _originalBackend = fsBackend;
    _fs = _RecordingFsBackend(_originalBackend);
    fsBackend = _fs;
  });
  tearDown(() => fsBackend = _originalBackend);

  // **The positive control for the barrier test below.** That one taps a bare
  // coordinate and asserts nothing happened, which is what a tap that *missed*
  // the barrier looks like too. This states that the same coordinate does reach
  // a live barrier, so "nothing happened" there is a refusal and not a miss.
  testWidgets('the same barrier tap does close the dialog before an install starts', (tester) async {
    _sizeView(tester);
    final container = ProviderContainer(overrides: [moduleVersionLoader.overrideWith((ref) async => null)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DialogLayer(child: const Scaffold(body: _ShowButton())),
        ),
      ),
    );
    await tester.tap(find.text('show module update dialog'));
    await tester.pump();
    expect(find.byType(ModuleManualUpdateDialog), findsOneWidget);

    await tester.tapAt(const Offset(4, 4));
    await tester.pump();

    expect(
      find.byType(ModuleManualUpdateDialog),
      findsNothing,
      reason: 'the tap the barrier test relies on does not reach the barrier at all',
    );
  });

  testWidgets('the barrier does not close the dialog mid-install', (tester) async {
    final held = await _startHeldInstall(tester);

    await tester.tapAt(const Offset(4, 4));
    await tester.pump();

    expect(
      find.byType(ModuleManualUpdateDialog),
      findsOneWidget,
      reason: 'a tap on the barrier closed the dialog while its install was running',
    );
    await _expectHeldInstallFinished(tester, held);
  });

  testWidgets('the close button does not close the dialog mid-install', (tester) async {
    final held = await _startHeldInstall(tester);

    expect(
      tester.widget<IconButton>(_closeButton()).onPressed,
      isNull,
      reason: 'the title bar × is still live while the install runs',
    );
    await tester.tap(_closeButton(), warnIfMissed: false);
    await tester.pump();

    expect(
      find.byType(ModuleManualUpdateDialog),
      findsOneWidget,
      reason: 'the title bar × closed the dialog while its install was running',
    );
    await _expectHeldInstallFinished(tester, held);
  });

  testWidgets('a claim that lands while the archive is being read refuses the install rather than parking it', (
    tester,
  ) async {
    // **The window after the second check, and the state it used to leave the app
    // in.** `_install` reads the registry once the picker answers and refuses
    // there; the byte route then reads the whole archive into memory, which on a
    // real pick is an ONNX module and not a few hundred bytes. A claim arriving in
    // *that* window walked past both readings, and the install parked in
    // `holdWhenFree` — with the × already disabled, the barrier already swallowing
    // taps and no cancel button in this dialog, so there was no way to end it from
    // the screen and every other surface was behind the same barrier. The wait
    // then lasted for the holder's job, which is a whole-store re-recognition or a
    // video import: minutes, with the app inert.
    //
    // The two claims that reach this window need no press at all — the automatic
    // update takes `moduleInstall` once its download lands, and the version check
    // that follows a module change starts a `regeneration` batch — so the dialog's
    // own reading being "a moment ago" is the ordinary case and not a race to win.
    final held = await _startHeldInstall(tester);
    final toasts = <ToastData>[];
    final subscription = held.container.listen<AsyncValue<ToastData>>(
      plainToastEventProvider,
      (_, current) => current.whenData(toasts.add),
    );
    addTearDown(subscription.close);

    held.container
        .read(longReadRegistryProvider.notifier)
        .claimUntilReleased(kind: LongReadKind.regeneration, paths: [_layout.modulesDir]);
    await _releaseInstall(tester, held);

    expect(held.fs.written, isEmpty, reason: 'the archive was extracted over what a long reader had open');
    expect(
      toasts.map((toast) => toast.description),
      contains(appSentenceAt(longReadBusyKey)),
      reason: 'the install ended without telling the user why, which is what a silent park looks like from here',
    );
    expect(
      find.byType(ModuleManualUpdateDialog),
      findsOneWidget,
      reason: 'a refusal is a state the user can act on: the dialog stays so the archive can be handed over again',
    );
    expect(
      tester.widget<IconButton>(_closeButton()).onPressed,
      isNotNull,
      reason:
          'the dialog kept its exits shut after the install ended, which is the whole of the harm — a modal with no '
          '×, no barrier and no cancel, waiting on somebody else\'s batch',
    );
    expect(tester.takeException(), isNull);
  });

  // **And the install survives being closed by something that is not an exit.**
  //
  // Shutting the doors is not the whole answer: the dialog can still be unmounted
  // by anything that clears the stack, and none of that asks this widget's
  // permission. So the install must not be reading providers through a `ref` that
  // dies with the dialog -- `installModuleFromZipBytes` reads `pathInfoLoader`
  // *after* the byte await, catches the resulting `StateError` in its own guard,
  // and reports the manual update as failed with nothing installed.
  testWidgets('an install finishes and lands after the dialog is closed from elsewhere', (tester) async {
    final held = await _startHeldInstall(tester);

    held.container.read(dialogBuilderProvider.notifier).dismiss();
    await tester.pump();
    expect(find.byType(ModuleManualUpdateDialog), findsNothing, reason: 'the dismiss did not take');

    await _releaseInstall(tester, held);
    _expectArchiveLanded(held, why: 'closing the dialog mid-install silently threw the install away');
    expect(tester.takeException(), isNull);
  });

  // **THE OTHER DIRECTION, WHICH THE ENTRY ANSWERED AND THE DIALOG DID NOT.**
  //
  // `runModuleInstall` claims `modules/` for the length of an extraction, and
  // `ModuleManualUpdateTile` refuses to open this dialog while such a claim
  // stands. That gate runs once, when the entry is tapped — but the automatic
  // update downloads *outside* its claim and registers only when the zip has
  // landed, so the ordinary case is that the entry was live when it was pressed
  // and the claim arrives while the dialog is open. Measured before this gate
  // existed: with a `moduleInstall` claim over `modulesDir` standing, a picked
  // archive was extracted straight over it and `prediction.onnx` was written.
  // There is a second entry too — the dashboard's module-updater card — which has
  // no gate of its own at all, so the answer has to live here.
  group('a registered long reader on modules/', () {
    testWidgets('withholds both ways in, and says why', (tester) async {
      await _pumpGatedDialog(tester, held: [_layout.modulesDir]);

      expect(_isInert(tester), isTrue, reason: 'an archive applied here would overwrite what that reader has open');
      // The shipped sentence read out of `ja.json` as a literal, NOT `key.tr()`:
      // easy_localization renders an unresolved key AS the key, so
      // `contains(key.tr())` would compare the tooltip with itself and stay green
      // with the entry deleted.
      final sentence = appSentenceAt(longReadBusyKey);
      expect(tester.widget<Disabled>(_gate()).tooltip, sentence);
      expect(_tooltipsShown(tester), contains(sentence), reason: 'a Disabled wraps a Tooltip only when given one');
      expect(sentence, isNot(contains('app.')));
      // And the button announces itself, rather than only being unreachable.
      expect(tester.widget<FilledButton>(_pickButton()).onPressed, isNull);
    });

    testWidgets('and the archive comes back when the claim is released', (tester) async {
      // **This is what makes the gate a `watch` and not a first-build `read`.** A
      // module install takes seconds; a dialog left inert for the rest of its life
      // because the registry happened to be busy when it opened would be its own
      // defect, and a one-shot read passes the case above.
      final gated = await _pumpGatedDialog(tester, held: [_layout.modulesDir]);
      expect(_isInert(tester), isTrue, reason: 'the claim was not in force to begin with');

      gated.container.read(longReadRegistryProvider.notifier).release(gated.token!);
      await tester.pump();

      expect(_isInert(tester), isFalse, reason: 'the dialog stayed inert after the long reader let modules/ go');
      expect(tester.widget<Disabled>(_gate()).tooltip, isNull);
      expect(tester.widget<FilledButton>(_pickButton()).onPressed, isNotNull);
    });

    testWidgets('holds the dialog opened from the dashboard card as well', (tester) async {
      // The second entry, which has no gate of its own: the card is shown for as
      // long as `moduleUpdateFailedProvider` stands, which spans the whole of the
      // re-download and re-extraction that a delete of `modules/` sets off. Gating
      // the entries one at a time is what left it open; this asserts that the
      // answer covers an entry that never asked.
      await _pumpGatedDialog(tester, held: [_layout.modulesDir], from: _Entry.dashboardCard);

      expect(_isInert(tester), isTrue, reason: 'the dashboard card walked past the gate the settings tile respects');
      expect(tester.widget<Disabled>(_gate()).tooltip, appSentenceAt(longReadBusyKey));
    });

    testWidgets('a long read somewhere else in the data root leaves the archive alone', (tester) async {
      // The negative control. Without it every case above would also pass on a
      // dialog that went inert for any claim at all -- a different, and wrong,
      // rule that looks identical from here.
      await _pumpGatedDialog(tester, held: [_layout.charaDetailActiveDir], kind: LongReadKind.export);

      expect(_isInert(tester), isFalse);
      expect(tester.widget<Disabled>(_gate()).tooltip, isNull);
      expect(tester.widget<FilledButton>(_pickButton()).onPressed, isNotNull);
    });

    testWidgets('a claim on one file inside modules/ holds it too, which is the export s shape', (tester) async {
      // `recordExportLongReadPaths` claims `modules/labels.json` and not the
      // directory, so a rule that compared paths for equality would leave the
      // dialog live for the one collision that has actually shipped.
      await _pumpGatedDialog(tester, held: [_layout.modulesDir.filePath('labels.json')], kind: LongReadKind.export);

      expect(_isInert(tester), isTrue);
    });

    testWidgets('refuses the archive a picker opened before the claim comes back with', (tester) async {
      // **The window a watched gate cannot see.** The controls follow the
      // registry frame by frame, but the native picker is modal: between the tap
      // that opens it and the archive it answers with there is no frame at all,
      // so a claim taken in that window is walked straight past by an install
      // that was authorised seconds earlier. The refusal therefore has to be a
      // second reading of the registry at the moment of writing, and it has to
      // say so — dropping the pick silently would leave the user watching a
      // dialog that ignored the file they just chose.
      _sizeView(tester);
      final container = ProviderContainer(
        overrides: [
          pathInfoLoader.overrideWith((ref) async => _layout),
          pathInfoProvider.overrideWithValue(_layout),
          pathLayoutProvider.overrideWithValue(_layout),
          moduleVersionLoader.overrideWith((ref) async => null),
          charaDetailRecordStorageLoaderProvider.overrideWith(_InertRecordStorage.new),
        ],
      );
      addTearDown(container.dispose);
      final toasts = <ToastData>[];
      final subscription = container.listen<AsyncValue<ToastData>>(
        plainToastEventProvider,
        (_, current) => current.whenData(toasts.add),
      );
      addTearDown(subscription.close);

      // A complete archive, buffered and closed before the pick is answered, so
      // that an install which does start has everything it needs to land: the
      // assertion below is "nothing was written", and it must not be able to pass
      // merely because the bytes were still on their way. `close()` is not
      // awaited: its future completes when the stream has been *consumed*, so on
      // a controller nobody has subscribed to yet it never does.
      final archive = StreamController<List<int>>();
      addTearDown(() {
        if (!archive.isClosed) archive.close();
      });
      archive.add(_moduleZip());
      unawaited(archive.close());
      final picker = installFakeFilePicker();
      final picking = Completer<void>();
      picker.holdUntil = picking.future;
      picker.answerWith([PlatformFile(name: 'modules.zip', size: 0, readStream: archive.stream)]);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: _theme(),
            home: DialogLayer(child: const Scaffold(body: _ShowButton())),
          ),
        ),
      );
      await tester.tap(find.text('show module update dialog'));
      await tester.pump();
      expect(
        tester.widget<FilledButton>(_pickButton()).onPressed,
        isNotNull,
        reason: 'the pick was already withheld, so this test never opens the window it is about',
      );
      await tester.tap(_pickButton());
      await tester.pump();
      expect(picker.calls, hasLength(1), reason: 'the picker never opened');

      // The claim arrives with the picker still up, and the archive follows it
      // with no frame in between.
      container
          .read(longReadRegistryProvider.notifier)
          .claimUntilReleased(kind: LongReadKind.moduleInstall, paths: [_layout.modulesDir]);
      picking.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(_fs.written, isEmpty, reason: 'the archive was extracted over what a long reader had open');
      expect(
        toasts.map((toast) => toast.description),
        contains(appSentenceAt(longReadBusyKey)),
        reason: 'the picked archive was dropped without telling the user why',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty registry never asks where modules/ is', (tester) async {
      // The guard on the new branch. `pathInfoProvider` is `pathInfoLoader.value!`
      // and throws until the data root has resolved; this dialog never depended on
      // it before, and one that threw on open would be a worse defect than the one
      // being fixed. The four tests above this group mount it with no
      // `pathInfoProvider` override at all, so the read would throw there if it
      // happened -- this states the same thing where it can be seen.
      await _pumpGatedDialog(tester, withLayout: false);

      expect(_isInert(tester), isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('the blocker table', () {
    test('every reason has a sentence, and none of them is a raw key', () {
      // The table is exhaustive by construction (a `switch` expression over a
      // closed enum), so what is left to check is that each arm names a key that
      // resolves. easy_localization renders a missing key as itself, which is the
      // one failure the compiler cannot see.
      for (final blocker in ManualModuleInstallBlocker.values) {
        final key = manualModuleInstallBlockerKey(blocker);
        expect(appSentenceAt(key), isNotEmpty, reason: '$blocker has no shipped sentence');
        expect(appSentenceAt(key), isNot(contains('{')), reason: '$blocker leaves a placeholder unfilled');
      }
    });

    test('the long-read arm is the app s one sentence and not a copy of it', () {
      // A second literal spelling of the key would resolve to itself if it were
      // mistyped.
      expect(manualModuleInstallBlockerKey(ManualModuleInstallBlocker.longRead), longReadBusyKey);
      expect(appSentenceAt(longReadBusyKey), longReadBusyMessage());
    });

    test('our own install outranks the claim it takes itself', () {
      // `runModuleInstall` claims `modules/` while it extracts, so during this
      // dialog's own install both reasons are true at once -- and there the
      // long reader's sentence would answer "why?" with "another process" about
      // the user's own install, right beside its progress row.
      expect(resolveManualModuleInstallBlocker(installing: false, heldBy: null), isNull);
      expect(
        resolveManualModuleInstallBlocker(installing: false, heldBy: LongReadKind.zip),
        ManualModuleInstallBlocker.longRead,
      );
      expect(resolveManualModuleInstallBlocker(installing: true, heldBy: null), ManualModuleInstallBlocker.installing);
      expect(
        resolveManualModuleInstallBlocker(installing: true, heldBy: LongReadKind.moduleInstall),
        ManualModuleInstallBlocker.installing,
        reason: 'precedence must not depend on which of the two was asked about first',
      );
    });
  });
}
