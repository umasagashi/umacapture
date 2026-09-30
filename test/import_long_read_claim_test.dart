// The record import is a long *writer*, and this is the suite that says so.
//
//   .fvm/flutter_sdk/bin/flutter test test/import_long_read_claim_test.dart
//
// THE DEFECT THIS PINS. `CharaDetailImportButton._pickAndImport` resolved the
// storage layout once, then read and wrote one picked zip after another without
// announcing anything: `readAsBytes` (a multi-megabyte file on desktop, a blob
// fetch on web) and the gap between two zips are inside no acquisition at all,
// and `WebRecordPersistence.persistFiles` — the only thing that does acquire —
// declares `LongReadDeclaration.none` on the stated grounds that "the producer
// above owns the window". Nothing above owned it. A data-root relocation's own
// claim asks the registry whether anything holds the roots it is about to
// rename, and an import that holds nothing lets it through: the loop keeps
// writing the rest of the selection into the store that has just been renamed
// away, where the next startup does not look.
//
// WHAT IS ASSERTED, in the terms the app itself uses:
//  * the claim exists for the whole run, and the *relocation's own claim* —
//    `dataRootRelocationLongReadDeclaration`, the declaration the dialog hands
//    `migrate`, over `DataRootMigrationController.movedRoots` — is refused for
//    `LongReadKind.import` while it does and let through once it is gone;
//  * the claim comes off however the run ends: normally, with every zip
//    refused, from a toolbar that was disposed mid-run, and (never taken) from
//    a cancelled pick;
//  * the button itself is withheld while somebody else holds what the import
//    writes into, and comes back on its own when they let go.
//
// WHY THE SPINNER IS THE SAMPLING WINDOW. Nothing on disk marks the run: a
// record directory appears mid-transaction, before the publish is verified. The
// app-scoped importing flag is raised before the first read and cleared in the
// `finally`, so the frames in which it is up are exactly the frames in which a
// claim is owed. Each sample is taken from the container, which is what a
// storage surface would read.
//
// The flag goes up one line *before* `pathInfoLoader` is awaited, and the first
// zip is read one line *inside* the claim, which is what lets the sampling cases
// park the run on a `Completer` at each end and hold the spinner up in between:
// neither edge of the run is a transient to catch sight of. `runImportSampling`
// says what that repairs.
//
// WHAT THIS SUITE CANNOT REACH.
//  * The real web build. The web leg is exercised over `WebLikeFsBackend` on the
//    VM, which reproduces OPFS's *prohibition* on synchronous FS calls and
//    nothing else about a browser; the Web Locks half of the exclusion is not
//    modelled here at all.
//  * The relocation's copy, and its dialog. What is run is the relocation's
//    declaration around an action that does nothing, not `migrate`; that
//    `migrate` runs that declaration before it closes or copies anything is
//    `data_root_migration_long_read_gate_test.dart`'s case, and that the dialog
//    hands it this declaration is driven by neither suite.
//  * A long read a web worker performs under the same lock. The registry is the
//    Dart isolate's memory, as its own header says.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/data_root_migration.dart';
import 'package:umacapture/src/core/fs/fs_backend.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/chara_detail/import_button.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/file_picker.dart';
import 'support/localization.dart';
import 'support/riverpod.dart';
import 'support/settling.dart';
import 'support/web_like_fs_backend.dart';

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

/// The minimum `record.json` `WebRecordPersistence` accepts: it validates that
/// the payload names the record its directory does, and writes nothing at all
/// when it does not — which would make "no claim was seen" true for the wrong
/// reason.
Uint8List _recordJson(String id) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'metadata': {
        'record_id': {'self': id},
      },
    }),
  ),
);

/// How many frames `runImportSampling` samples while it is holding the run open.
///
/// More than one, because a claim that appeared for a single frame and went away
/// again would satisfy a sampler that only looked once; small, because every
/// further frame is spent inside a window the helper has already opened and is
/// keeping open, so nothing is being waited *for* here and a larger number would
/// only make the suite slower. It is not a budget the run has to finish inside —
/// that is exactly what this file used to get wrong.
const _sampledFrames = 3;

void main() {
  setUpAll(loadAppTranslations);

  late Directory tempRoot;
  late FakeFilePicker picker;
  late FsBackend originalBackend;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_import_claim');
    picker = installFakeFilePicker();
    originalBackend = fsBackend;
  });
  tearDown(() {
    fsBackend = originalBackend;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  PathInfo pathInfoFor(DirectoryPath root) => PathInfo(
    documentDir: root,
    supportDir: root,
    executableDir: root / 'exe',
    downloadDir: root / 'dl',
    dataRoot: root,
  );

  /// Writes a real zip file (the picker hands over paths, not bytes).
  String writeZip(String fileName, List<String> recordIds) {
    final archive = Archive();
    for (final id in recordIds) {
      final json = _recordJson(id);
      archive.addFile(ArchiveFile('chara_detail/active/$id/record.json', json.length, json));
    }
    final path = '${tempRoot.path}${Platform.pathSeparator}$fileName';
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    return path;
  }

  /// A zip `RecordZipService.import` rejects outright: one entry escapes the
  /// record tree, which is a `FormatException` before anything is written.
  String writeRejectedZip(String fileName) {
    final archive = Archive();
    final json = _recordJson('good');
    archive.addFile(ArchiveFile('chara_detail/active/good/record.json', json.length, json));
    archive.addFile(ArchiveFile('../escaped.json', json.length, json));
    final path = '${tempRoot.path}${Platform.pathSeparator}$fileName';
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    return path;
  }

  /// A container whose storage layout is parked on [layoutGate] until the test
  /// opens it, if one is given.
  ///
  /// **The start of an import is the test's to decide, not something to catch
  /// sight of.** `CharaDetailImportButton._pickAndImport` raises the app-scoped
  /// importing flag — the only thing that draws the spinner — *before* it awaits
  /// `pathInfoLoader`, so a loader parked here holds the spinner up until this
  /// gate is completed, and "the import has started" becomes an edge that can be
  /// awaited rather than a transient a poll has to land on. Without it the whole
  /// run is tens of milliseconds while one turn of [settleUntil] costs a real
  /// event-loop turn, so a contended runner steps over the spinner entirely and
  /// waits out the helper's whole 20 s bound on an import that finished long
  /// before. That is not hypothetical: CI hit it on two different cases of this
  /// file, and neither reproduces on an idle machine.
  ///
  /// This gate holds the run's *start* and nothing else, so on its own it moves
  /// the same race one line down — the claim is still taken and given back inside
  /// a window narrower than a poll. `runImportSampling` holds the other end.
  ProviderContainer containerFor(PathInfo info, {Future<void>? layoutGate}) => ProviderContainer(
    overrides: [
      pathInfoLoader.overrideWith((ref) async {
        if (layoutGate != null) {
          await layoutGate;
        }
        return info;
      }),
      moduleVersionLoader.overrideWith((ref) async => null),
    ],
  );

  /// As [containerFor], plus a resolved [pathInfoProvider].
  ///
  /// The surface cases put a claim on the registry by hand and then read the
  /// button, so the layout has to be there the moment the button asks; the
  /// asynchronous loader would otherwise decide the answer by whether it had
  /// settled. The button's own guard against the unresolved case (`claims`
  /// empty, `pathInfoProvider` never read) is exercised by every case in the
  /// group above, which pumps it before the loader has answered.
  ProviderContainer resolvedContainerFor(PathInfo info) => ProviderContainer(
    overrides: [
      pathInfoLoader.overrideWith((ref) async => info),
      pathInfoProvider.overrideWithValue(info),
      // The button asks the *layout* where the store is, so that it can answer during a store
      // outage; the store-prepared provider above is left in place for the run itself.
      pathLayoutProvider.overrideWithValue(info),
      moduleVersionLoader.overrideWith((ref) async => null),
    ],
  );

  Widget host(Widget body) => MaterialApp(
    theme: _theme(),
    home: Scaffold(body: body),
  );

  bool recordLanded(PathInfo info, String id) =>
      Directory('${info.charaDetailActiveDir.path}${Platform.pathSeparator}$id').existsSync();

  /// The relocation's own answer: which registered long reader, if any, its claim is refused for.
  ///
  /// Asked by running `dataRootRelocationLongReadDeclaration` — the declaration the relocation
  /// dialog hands `migrate` — over a real `DataRootMigrationController`, so the trees it asks about
  /// and the kinds it disregards are the ones a relocation uses. The guarded action does nothing, so
  /// a claim that is let through registers and is released within this call.
  Future<LongReadKind?> relocationRefusedBy(ProviderContainer container, PathInfo info) async {
    final declaration = dataRootRelocationLongReadDeclaration(
      container.read(containerRefProvider),
      DataRootMigrationController(source: info),
    );
    try {
      await declaration.runDeclared(() async {});
    } on LongReadNotStartedException catch (exception) {
      final heldBy = exception.heldBy;
      if (heldBy == null) {
        // Abandoned: the registry went away, which names no holder and answers nothing.
        rethrow;
      }
      return heldBy;
    }
    return null;
  }

  /// Taps the button, opens the run's two edges in turn, and samples the registry
  /// on the frames between them, answering what was seen: the claim count on
  /// every sampled frame, and what the relocation's own claim was refused for on
  /// the frames the run is parked.
  ///
  /// **Both edges belong to the test, and for one reason.** The whole run is over
  /// in a fraction of a second — a claim measured at ~80 ms with two zips and
  /// ~120 ms on the web leg, on one unloaded machine, so the number is an order
  /// of magnitude and not a bound — while every poll loop in this suite turns on
  /// a real event-loop delay. One turn on a contended runner is wider than the
  /// entire window, and the sampler steps over it. The previous shape held
  /// only the *start* edge on [layoutGate] and then went looking for the claim
  /// with a poll — which is the same race one line further on, and it failed on
  /// CI exactly there: `waited 20s for the import to announce its claim`
  /// alongside `Expected: Set:[1] / Actual: Set:[0]`, the empty sample list of a
  /// run that had finished before the first observation. Reproduced locally by
  /// widening that poll to 60 ms (two of the three cases below) and to 300 ms
  /// (all three).
  ///
  /// So the end edge is held too. [firstReadGate] is handed to the first file of
  /// the selection, which does not answer `readAsBytes` until this helper
  /// completes it — and `_pickAndImport` reads that file *inside*
  /// `LongReadRegistry.hold`, past the claim. The run therefore parks with the
  /// claim registered, the spinner up and nothing written, for as long as the
  /// sampling wants, and none of the assertions below depend on how fast anything
  /// ran. That is what makes [_sampledFrames] a legitimate fixed count rather
  /// than another guess about the host: it is spent inside a window this helper
  /// opened and has not yet closed, not aimed at one it hopes is still open.
  ///
  /// The start edge is latched on a landed toast as well: every run this helper drives ends in one, and a toast that has
  /// landed stays landed. That is a diagnosability net — a run that never raised
  /// the spinner reaches the claim wait and names it, instead of hanging here.
  ///
  /// The claim is *also* watched rather than only sampled. A frame sampler can
  /// only speak for the frames it took, and this helper's guaranteed frames are
  /// all in the first zip; a `hold` that released and re-took the claim between
  /// two zips would be invisible to it. `container.listen` cannot miss a
  /// transition, so the count sequence is asserted here, once, for every case
  /// that comes through: up to one claim, and back to none.
  ///
  /// **The relocation is asked only while the run is parked.** Asking runs its
  /// claim, and a claim that is let through registers: asked on the frames after
  /// [firstReadGate], where the import's own claim may already be gone while the
  /// spinner is still up, it would add transitions to the very count sequence
  /// asserted above. Nothing is lost by it: that sequence proves the import held
  /// one claim, unchanged, from its registration to its release, so the answer on
  /// the parked frames is the answer for the whole run.
  Future<({List<int> claimCounts, List<LongReadKind?> refusals})> runImportSampling(
    WidgetTester tester,
    ProviderContainer container,
    PathInfo info, {
    required Completer<void> layoutGate,
    required Completer<void> firstReadGate,
  }) async {
    final sampledCounts = <int>[];
    final refusals = <LongReadKind?>[];
    final claimCounts = <int>[];
    final toasts = <ToastData>[];
    final toastSubscription = container.listen<AsyncValue<ToastData>>(
      plainToastEventProvider,
      (_, current) => current.whenData(toasts.add),
    );
    addTearDown(toastSubscription.close);
    final registrySubscription = container.listen(
      longReadRegistryProvider,
      (_, current) => claimCounts.add(current.length),
    );
    addTearDown(registrySubscription.close);
    bool spinning() => find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
    void sample() => sampledCounts.add(container.read(longReadRegistryProvider).length);

    await tester.runAsync(() async {
      await tester.tap(find.byType(IconButton));
    });
    await settleUntil(tester, () => spinning() || toasts.isNotEmpty, describe: 'the import to raise its spinner');
    // Resumes `_pickAndImport` at its `pathInfoLoader` await; from there it
    // reaches `hold`, which registers the claim before its own first await, and
    // parks on the gated read one line inside the action.
    layoutGate.complete();
    await settleUntil(
      tester,
      () => container.read(longReadRegistryProvider).isNotEmpty,
      describe: 'the import to announce its claim',
    );
    for (var frame = 0; frame < _sampledFrames; frame++) {
      sample();
      refusals.add(await relocationRefusedBy(container, info));
      await tester.pump();
    }
    firstReadGate.complete();
    await settleUntil(tester, () {
      if (!spinning()) {
        return true;
      }
      sample();
      return false;
    }, describe: "the import to finish and its spinner to go out");
    expect(claimCounts, [
      1,
      0,
    ], reason: 'the import must take one claim and give it back once, not one per zip and not none');
    return (claimCounts: sampledCounts, refusals: refusals);
  }

  group('the claim', () {
    testWidgets('is held for the whole run, and the relocation\'s own claim is refused while it is', (tester) async {
      final info = pathInfoFor(DirectoryPath(tempRoot.path));
      final firstReadGate = Completer<void>();
      picker.answerWithPaths([
        writeZip('part1.zip', ['uuid-1']),
        writeZip('part2.zip', ['uuid-2']),
      ], firstReadGate: firstReadGate.future);
      final layoutGate = Completer<void>();
      final container = containerFor(info, layoutGate: layoutGate.future);
      await pumpWithContainer(tester, container, host(const CharaDetailImportButton()));

      final samples = await runImportSampling(
        tester,
        container,
        info,
        layoutGate: layoutGate,
        firstReadGate: firstReadGate,
      );

      // The window sampled above has to be a window in which records were being
      // written; otherwise every assertion below holds vacuously.
      expect(recordLanded(info, 'uuid-1'), isTrue);
      expect(recordLanded(info, 'uuid-2'), isTrue);
      expect(samples.claimCounts, isNotEmpty, reason: 'the run was never sampled with its spinner up');
      expect(
        samples.claimCounts.toSet(),
        {1},
        reason: 'the import must announce exactly one claim, for its whole length: ${samples.claimCounts}',
      );
      expect(
        samples.refusals.toSet(),
        {LongReadKind.import},
        reason: 'the relocation would have run while the import was still writing: ${samples.refusals}',
      );
      expect(
        container.read(longReadRegistryProvider),
        isEmpty,
        reason: 'a claim nobody releases withholds every delete over the store for the rest of the session',
      );
      expect(
        await relocationRefusedBy(container, info),
        isNull,
        reason: 'the relocation is still refused after the import that caused it has finished',
      );
    });

    testWidgets('the web leg announces the same claim over the same root', (tester) async {
      // The prohibition, not the browser: `WebLikeFsBackend` throws on every
      // synchronous FS call as OPFS does, so a claim that only held because the
      // desktop leg took some sync shortcut cannot pass here. See the backend's
      // own header for what it does not model.
      fsBackend = WebLikeFsBackend(originalBackend);
      final info = pathInfoFor(DirectoryPath(tempRoot.path));
      final firstReadGate = Completer<void>();
      picker.answerWithPaths([
        writeZip('web.zip', ['uuid-web']),
      ], firstReadGate: firstReadGate.future);
      final layoutGate = Completer<void>();
      final container = containerFor(info, layoutGate: layoutGate.future);
      await pumpWithContainer(tester, container, host(const CharaDetailImportButton()));

      final samples = await runImportSampling(
        tester,
        container,
        info,
        layoutGate: layoutGate,
        firstReadGate: firstReadGate,
      );

      expect(recordLanded(info, 'uuid-web'), isTrue);
      expect(samples.claimCounts, isNotEmpty, reason: 'the run was never sampled with its spinner up');
      expect(samples.claimCounts.toSet(), {1});
      expect(samples.refusals.toSet(), {LongReadKind.import});
      expect(container.read(longReadRegistryProvider), isEmpty);
    });

    testWidgets('a selection in which every zip is refused still gives the claim back', (tester) async {
      // The failure path this button actually has: the per-zip `catch` absorbs
      // the rejection so the loop can carry on, which means the claim's release
      // is `LongReadRegistry.hold`'s `finally` and not a line at the throw. A
      // release written by hand at the end of the loop would pass the case above
      // and fail here only if the throw escaped — so what this asserts is that
      // nothing is left held when the run produced no record at all.
      final info = pathInfoFor(DirectoryPath(tempRoot.path));
      final firstReadGate = Completer<void>();
      // The gate is on the *read*, which is above the rejection: a zip this
      // service throws on is thrown on after its bytes are in hand and before
      // anything is written, so a gate placed at the write would never be reached
      // by this case at all and it would keep racing while the two above stopped.
      picker.answerWithPaths([
        writeRejectedZip('bad1.zip'),
        writeRejectedZip('bad2.zip'),
      ], firstReadGate: firstReadGate.future);
      final layoutGate = Completer<void>();
      final container = containerFor(info, layoutGate: layoutGate.future);
      await pumpWithContainer(tester, container, host(const CharaDetailImportButton()));

      final samples = await runImportSampling(
        tester,
        container,
        info,
        layoutGate: layoutGate,
        firstReadGate: firstReadGate,
      );

      expect(samples.claimCounts, isNotEmpty, reason: 'the run was never sampled with its spinner up');
      expect(samples.claimCounts.toSet(), {1}, reason: 'a failing import holds the store too');
      expect(container.read(longReadRegistryProvider), isEmpty);
      expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNotNull);
    });

    testWidgets('a cancelled pick announces nothing at all', (tester) async {
      // The claim is taken after the dialog answers, so a selection the user
      // abandoned must not leave the store held while nothing runs.
      final info = pathInfoFor(DirectoryPath(tempRoot.path));
      picker.result = null;
      final container = containerFor(info);
      await pumpWithContainer(tester, container, host(const CharaDetailImportButton()));
      await tester.runAsync(() async {
        await tester.tap(find.byType(IconButton));
      });
      await settleUntil(
        tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
        describe: 'the cancelled pick to return',
      );
      expect(container.read(longReadRegistryProvider), isEmpty);
      expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNotNull);
    });

    testWidgets('a run whose toolbar was disposed mid-import still gives the claim back', (tester) async {
      // The third of the three ways a claim can be left behind (the others being
      // a throw and a cancel). The import outlives the widget that started it on
      // purpose — the records are on disk whoever is on screen — so the release
      // cannot be tied to the element.
      final info = pathInfoFor(DirectoryPath(tempRoot.path));
      picker.answerWithPaths([
        writeZip('part1.zip', ['uuid-1']),
      ]);
      final gate = Completer<void>();
      final container = containerFor(info, layoutGate: gate.future);
      await pumpWithContainer(tester, container, host(const CharaDetailImportButton()));
      await tester.runAsync(() async {
        await tester.tap(find.byType(IconButton));
        await tester.pump();
        // Same container, different child: the toolbar unmounts while the
        // app-scoped flag and the registry live on, as when the user navigates
        // away mid-import.
        await pumpWithContainer(tester, container, host(const SizedBox()));
        gate.complete();
        await pumpWithContainer(tester, container, host(const CharaDetailImportButton()));
        for (var i = 0; i < 4; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          await tester.pump();
        }
      });
      await settleUntil(
        tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
        describe: "the disposed run's import to finish",
      );
      expect(recordLanded(info, 'uuid-1'), isTrue, reason: 'the import ran past the dispose, or this proves nothing');
      expect(tester.takeException(), isNull);
      expect(
        container.read(longReadRegistryProvider),
        isEmpty,
        reason: 'the claim outlived the run, leaving every delete over the store withheld for the session',
      );
    });
  });

  group('the surface', () {
    testWidgets('the button is withheld while a long reader holds the store, and comes back when it lets go', (
      tester,
    ) async {
      final info = pathInfoFor(DirectoryPath(tempRoot.path));
      final container = resolvedContainerFor(info);
      await pumpWithContainer(tester, container, host(const CharaDetailImportButton()));
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNotNull,
        reason: 'nothing is holding anything yet; a button dead here would say nothing below',
      );

      // A bundle of the active store: a path *inside* what the import writes,
      // which is the containment the fold decides in the direction opposite to
      // the relocation's.
      final registry = container.read(longReadRegistryProvider.notifier);
      final token = registry.claimUntilReleased(kind: LongReadKind.zip, paths: [info.charaDetailActiveDir]);
      await tester.pump();
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
        reason: 'the import would have written into a folder being bundled out of the app',
      );

      registry.release(token);
      await tester.pump();
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNotNull,
        reason: 'the registry is watched, not read once: a control withheld for a finished job never comes back',
      );
    });

    testWidgets('a claim on something the import never writes leaves the button alone', (tester) async {
      // The discrimination half: without this, a button that was simply dead
      // whenever *anything* was claimed would pass the case above.
      final info = pathInfoFor(DirectoryPath(tempRoot.path));
      final container = resolvedContainerFor(info);
      await pumpWithContainer(tester, container, host(const CharaDetailImportButton()));
      container
          .read(longReadRegistryProvider.notifier)
          .claimUntilReleased(kind: LongReadKind.moduleInstall, paths: [info.modulesDir]);
      await tester.pump();
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNotNull,
        reason: 'a module install writes nowhere near active/; withholding the import for it is a false refusal',
      );
    });

    testWidgets('refuses a selection the picker was still holding when the claim arrived, and says why', (
      tester,
    ) async {
      // **The window a watched gate cannot see.** The button follows the
      // registry frame by frame, but the picker is a modal dialog and this
      // control's own comment says the user may leave it open for minutes; no
      // frame is built while it is up, so a claim taken between the tap and the
      // selection would be walked straight past by an import that was authorised
      // before it existed. The refusal is the run's own ask-and-claim at the
      // moment of writing, and it has to be said out loud — discarding the files
      // silently would leave the user watching a toolbar that ignored the zips
      // they just chose — and said as what it is: the import's generic failure
      // sentence would tell the user their zips were broken.
      final info = pathInfoFor(DirectoryPath(tempRoot.path));
      final container = resolvedContainerFor(info);
      final toasts = <ToastData>[];
      final subscription = container.listen<AsyncValue<ToastData>>(
        plainToastEventProvider,
        (_, current) => current.whenData(toasts.add),
      );
      addTearDown(subscription.close);

      // A real zip that would import cleanly, so "nothing landed" below cannot
      // pass because the selection was unusable to begin with.
      final picking = Completer<void>();
      picker.holdUntil = picking.future;
      picker.answerWithPaths([
        writeZip('part1.zip', ['uuid-1']),
      ]);

      await pumpWithContainer(tester, container, host(const CharaDetailImportButton()));
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNotNull,
        reason: 'the button was already withheld, so this case never opens the window it is about',
      );
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(picker.calls, hasLength(1), reason: 'the picker never opened');

      // The claim arrives with the picker still up, and the selection follows it
      // with no frame in between. A relocation, because that is the one whose
      // damage this window actually causes: the store root is resolved once,
      // before the first zip, so a rename granted here leaves the loop writing
      // into a directory the next startup does not look in.
      container
          .read(longReadRegistryProvider.notifier)
          .claimUntilReleased(kind: LongReadKind.relocate, paths: [DirectoryPath(tempRoot.path)]);
      picking.complete();
      await settleUntil(tester, () => toasts.isNotEmpty, describe: 'the import to answer the selection it was handed');

      expect(
        recordLanded(info, 'uuid-1'),
        isFalse,
        reason: 'the import wrote into a store a relocation had already claimed',
      );
      // The shipped sentence read out of `ja.json` as a literal, not `key.tr()`:
      // easy_localization renders an unresolved key AS the key, so comparing
      // against `tr()` would compare the toast with itself.
      expect(
        toasts.map((toast) => toast.description),
        [appSentenceAt(longReadBusyKey)],
        reason: 'the picked zips were dropped without the one long-read sentence, or with a failure beside it',
      );
      expect(
        container.read(longReadRegistryProvider).values.map((claim) => claim.kind),
        [LongReadKind.relocate],
        reason: 'the refused run left an import claim behind',
      );
      await tester.pump();
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: 'the refused run left the importing spinner up, and the button with it',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
