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
// above owns the window". Nothing above owned it. A data-root relocation asks
// `storageDeleteBlockedBy` over the roots it is about to rename, that question
// was answered `null` for the whole import, and the relocation therefore ran:
// the loop kept writing the rest of the selection into the store that had just
// been renamed away, where the next startup does not look.
//
// WHAT IS ASSERTED, in the terms the app itself uses:
//  * the claim exists for the whole run, and the *relocation's own question* —
//    `storageDeleteBlockedBy` over `DataRootMigrationController.movedRoots` —
//    refuses while it does;
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
// The flag goes up one line *before* `pathInfoLoader` is awaited, which is what
// lets the sampling cases park that loader on a `Completer` and hold the spinner
// up until they let go: the start of the run stops being a transient to catch
// sight of. `runImportSampling` says what that repairs.
//
// WHAT THIS SUITE CANNOT REACH.
//  * The real web build. The web leg is exercised over `WebLikeFsBackend` on the
//    VM, which reproduces OPFS's *prohibition* on synchronous FS calls and
//    nothing else about a browser; the Web Locks half of the exclusion is not
//    modelled here at all.
//  * The relocation actually running. What is checked is the predicate the
//    relocation dialog asks, not the dialog: driving `DataRootMigrationController.migrate`
//    would move real trees, and the registry grants nothing in any case — it
//    decides whether the button is offered.
//  * A second tab. The registry is one tab's memory, as its own header says.
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
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/chara_detail/import_button.dart';
import 'package:umacapture/src/gui/storage_tree.dart';
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

  /// Taps the button, releases [layoutGate] once the import is provably running,
  /// and samples the registry on every frame the spinner is up, answering what
  /// was seen. The samples are `(claim count, what the relocation's question
  /// answers)`.
  ///
  /// **Two awaited edges, and deliberately not one compound predicate.** This
  /// used to latch `started |= spinning` and return on `started && !spinning`,
  /// which asks one predicate of two different moments: a poll that never landed
  /// while the spinner was up left `started` false for ever, and the wait then
  /// expired naming a condition that had already happened. Raising the timeout
  /// cannot help — the run is shorter than the first poll interval — so the
  /// spinner is held up by [layoutGate] instead, and "it started" is awaited on
  /// its own before "it finished" is.
  ///
  /// The start edge is latched on a landed toast as well, the way
  /// `chara_detail_import_button_test.dart` and `import_refusal_surface_test.dart`
  /// latch theirs: every run this helper drives ends in one, and a toast that has
  /// landed stays landed. That is a diagnosability net rather than the fix — on
  /// its own it would only turn the 20 s wait into the empty `samples` list the
  /// callers already assert against, which is why the gate is there too.
  Future<List<(int, LongReadKind?)>> runImportSampling(
    WidgetTester tester,
    ProviderContainer container,
    PathInfo info, {
    required Completer<void> layoutGate,
  }) async {
    // The question the relocation dialog asks, built the way it builds it: over
    // the controller's own enumeration of the trees it is about to rename, so a
    // fourth tree added to the migration is asked about here without this suite
    // being edited.
    final movedRoots = DataRootMigrationController(source: info).movedRoots;
    final samples = <(int, LongReadKind?)>[];
    final toasts = <ToastData>[];
    final subscription = container.listen<AsyncValue<ToastData>>(
      plainToastEventProvider,
      (_, current) => current.whenData(toasts.add),
    );
    addTearDown(subscription.close);
    bool spinning() => find.byType(CircularProgressIndicator).evaluate().isNotEmpty;

    await tester.runAsync(() async {
      await tester.tap(find.byType(IconButton));
    });
    await settleUntil(tester, () => spinning() || toasts.isNotEmpty, describe: 'the import to raise its spinner');
    await tester.runAsync(() async {
      layoutGate.complete();
      // Completing the gate resumes `_pickAndImport` at its `pathInfoLoader`
      // await, and from there it reaches `LongReadRegistry.hold` — which
      // registers the claim before its own first await — without suspending, so
      // this drain lands past the claim rather than in front of it and the
      // samples below cannot open with a frame that owes one but has not taken
      // it yet. Waited for rather than spent as a fixed number of turns, and
      // abandoned the moment the spinner goes out so that a run which claimed
      // nothing fails on the empty sample list rather than here.
      await waitUntil(
        () => container.read(longReadRegistryProvider).isNotEmpty || !spinning(),
        describe: 'the import to announce its claim',
      );
    });
    await settleUntil(tester, () {
      if (!spinning()) {
        return true;
      }
      final claims = container.read(longReadRegistryProvider).values;
      samples.add((claims.length, storageDeleteBlockedBy(StorageDeletePathsRequest(movedRoots), claims)));
      return false;
    }, describe: "the import to finish and its spinner to go out");
    return samples;
  }

  group('the claim', () {
    testWidgets('is held for the whole run, and the relocation\'s own question refuses while it is', (tester) async {
      final info = pathInfoFor(DirectoryPath(tempRoot.path));
      picker.answerWithPaths([
        writeZip('part1.zip', ['uuid-1']),
        writeZip('part2.zip', ['uuid-2']),
      ]);
      final layoutGate = Completer<void>();
      final container = containerFor(info, layoutGate: layoutGate.future);
      await pumpWithContainer(tester, container, host(const CharaDetailImportButton()));

      final samples = await runImportSampling(tester, container, info, layoutGate: layoutGate);

      // The window sampled above has to be a window in which records were being
      // written; otherwise every assertion below holds vacuously.
      expect(recordLanded(info, 'uuid-1'), isTrue);
      expect(recordLanded(info, 'uuid-2'), isTrue);
      expect(samples, isNotEmpty, reason: 'the run was never sampled with its spinner up');
      expect(
        samples.map((sample) => sample.$1).toSet(),
        {1},
        reason: 'the import must announce exactly one claim, for its whole length: $samples',
      );
      expect(
        samples.map((sample) => sample.$2).toSet(),
        {LongReadKind.import},
        reason: 'the relocation would have been offered while the import was still writing: $samples',
      );
      expect(
        container.read(longReadRegistryProvider),
        isEmpty,
        reason: 'a claim nobody releases withholds every delete over the store for the rest of the session',
      );
    });

    testWidgets('the web leg announces the same claim over the same root', (tester) async {
      // The prohibition, not the browser: `WebLikeFsBackend` throws on every
      // synchronous FS call as OPFS does, so a claim that only held because the
      // desktop leg took some sync shortcut cannot pass here. See the backend's
      // own header for what it does not model.
      fsBackend = WebLikeFsBackend(originalBackend);
      final info = pathInfoFor(DirectoryPath(tempRoot.path));
      picker.answerWithPaths([
        writeZip('web.zip', ['uuid-web']),
      ]);
      final layoutGate = Completer<void>();
      final container = containerFor(info, layoutGate: layoutGate.future);
      await pumpWithContainer(tester, container, host(const CharaDetailImportButton()));

      final samples = await runImportSampling(tester, container, info, layoutGate: layoutGate);

      expect(recordLanded(info, 'uuid-web'), isTrue);
      expect(samples, isNotEmpty, reason: 'the run was never sampled with its spinner up');
      expect(samples.map((sample) => sample.$1).toSet(), {1});
      expect(samples.map((sample) => sample.$2).toSet(), {LongReadKind.import});
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
      picker.answerWithPaths([writeRejectedZip('bad1.zip'), writeRejectedZip('bad2.zip')]);
      final layoutGate = Completer<void>();
      final container = containerFor(info, layoutGate: layoutGate.future);
      await pumpWithContainer(tester, container, host(const CharaDetailImportButton()));

      final samples = await runImportSampling(tester, container, info, layoutGate: layoutGate);

      expect(samples, isNotEmpty, reason: 'the run was never sampled with its spinner up');
      expect(samples.map((sample) => sample.$1).toSet(), {1}, reason: 'a failing import holds the store too');
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
      // selection is walked straight past by an import that was authorised
      // before it existed. Nothing downstream catches it: the `hold` this run
      // takes grants nothing and refuses nothing, so arriving second at the
      // registry is not an error anybody reports. The refusal has to be a second
      // reading at the moment of writing, and it has to be said out loud —
      // discarding the files silently would leave the user watching a toolbar
      // that ignored the zips they just chose.
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
        contains(appSentenceAt(longReadBusyKey)),
        reason: 'the picked zips were dropped without telling the user why',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
