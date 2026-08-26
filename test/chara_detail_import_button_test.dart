// Tests for [CharaDetailImportButton], the record table's "import records from a zip" control.
//
// The defect this pins: the button called `FilePicker.pickFiles` without `allowMultiple`, which
// **defaults to true** in file_picker 12, and then imported `files.first` only. Every other zip the
// user selected in that dialog was dropped with no toast, no log line and no trace in the table --
// while the size limit this very feature enforces (`too_large`) tells the user to split an oversized
// export and import it in several pieces. So the selection the app asks for was the selection it
// silently discarded.
//
// The picker is faked at `FilePickerPlatform.instance` (see test/support/file_picker.dart): the real
// Windows backend would open a modal `GetOpenFileNameW` dialog and hang the suite.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/chara_detail_import_button_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/record_zip.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/chara_detail/import_button.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/file_picker.dart';
import 'support/localization.dart';
import 'support/riverpod.dart';
import 'support/settling.dart';

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

/// The sentence the app ships at [dottedKey], with each `{name}` filled from [args].
///
/// **Not `key.tr(namedArgs: …)`, and that is the whole point.** `.tr()` renders a key it cannot
/// resolve *as the key*, so `expect(toast.description, key.tr())` compares the app's output with
/// itself: it holds exactly as well when the entry has been renamed away and the user is being shown
/// a raw key instead of a sentence. Reading `ja.json` yields a Japanese literal, which a key can
/// never equal, so a deleted, renamed or mistyped key turns the comparison red (see
/// [appSentenceAt], which throws rather than returning null for the same reason).
///
/// The placeholders are checked in both directions -- a name with nothing to fill, and a sentence
/// still holding `{…}` once the fills are done -- because an unfilled placeholder is precisely the
/// defect the tautology used to hide: rendered and expected would carry the same raw `{count}`.
/// Derived from the sentence rather than from a list of names kept here, so a key that gains a
/// placeholder is caught without anyone remembering to add it.
String _sentence(String dottedKey, [Map<String, String> args = const {}]) {
  var text = appSentenceAt(dottedKey);
  args.forEach((name, value) {
    if (!text.contains('{$name}')) {
      throw StateError('"$dottedKey" has no {$name} placeholder for this test to fill');
    }
    text = text.replaceAll('{$name}', value);
  });
  final unfilled = RegExp(r'\{[a-zA-Z_][a-zA-Z0-9_]*\}').firstMatch(text);
  if (unfilled != null) {
    throw StateError('"$dottedKey" still holds ${unfilled[0]} after filling ${args.keys.toList()}');
  }
  return text;
}

void main() {
  setUpAll(loadAppTranslations);

  late Directory tempRoot;
  late FakeFilePicker picker;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_import_button');
    picker = installFakeFilePicker();
  });
  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  PathInfo pathInfoFor(DirectoryPath root) => PathInfo(
    documentDir: root,
    supportDir: root,
    executableDir: root / 'exe',
    downloadDir: root / 'dl',
    dataRoot: root,
  );

  /// Writes a real zip file (the picker hands over paths, not bytes) holding one record per id.
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

  /// Writes a zip the importer refuses outright: one of its entries escapes the record tree, which
  /// `RecordZipService.import` rejects with a `FormatException` before writing anything (see
  /// test/record_zip_import_test.dart). A zip that merely holds no records is *not* a failure --
  /// it imports zero records successfully -- so the refusal has to be a real one.
  String writeRejectedZip(String fileName) {
    final archive = Archive();
    final json = _recordJson('good');
    archive.addFile(ArchiveFile('chara_detail/active/good/record.json', json.length, json));
    final escaping = Uint8List.fromList(utf8.encode('escaped'));
    archive.addFile(ArchiveFile('chara_detail/active/../../evil.txt', escaping.length, escaping));
    final path = '${tempRoot.path}${Platform.pathSeparator}$fileName';
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    return path;
  }

  /// Writes a zip the importer refuses as too large, i.e. with a
  /// `RecordZipTooLargeException` rather than the plain `FormatException` [writeRejectedZip]
  /// provokes. The button imports with the production limits, so the fixture has to breach one of
  /// them for real: the entry-count cap is the only one a small file can breach (the byte caps are
  /// 20 MiB per entry and 1 GiB per zip), and it is checked before any entry is parsed or
  /// decompressed -- so these one-byte entries never have to hold anything a record parser would
  /// accept.
  String writeTooLargeZip(String fileName) {
    final archive = Archive();
    final content = Uint8List.fromList([0]);
    for (var i = 0; i <= RecordZipService.defaultMaxEntryCount; i++) {
      archive.addFile(ArchiveFile('chara_detail/active/uuid-$i/record.json', content.length, content));
    }
    final path = '${tempRoot.path}${Platform.pathSeparator}$fileName';
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    return path;
  }

  /// Writes a zip that imports successfully but carries no record: the desktop exporter's
  /// top-level `labels.json` side-car is skipped rather than rejected, so this is a zero-record
  /// success and not a failure.
  String writeRecordlessZip(String fileName) {
    final archive = Archive();
    final labels = Uint8List.fromList(utf8.encode('{}'));
    archive.addFile(ArchiveFile('labels.json', labels.length, labels));
    final path = '${tempRoot.path}${Platform.pathSeparator}$fileName';
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    return path;
  }

  /// Pumps the button, taps it, and returns the toasts it emitted.
  Future<List<ToastData>> tapImport(WidgetTester tester, DirectoryPath root) async {
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        // Skip the (network/version) module check so nothing reaches for the network.
        moduleVersionLoader.overrideWith((ref) async => null),
      ],
    );
    final toasts = <ToastData>[];
    final subscription = container.listen<AsyncValue<ToastData>>(
      plainToastEventProvider,
      (_, current) => current.whenData(toasts.add),
    );
    addTearDown(subscription.close);

    await pumpWithContainer(
      tester,
      container,
      MaterialApp(
        theme: _theme(),
        home: const Scaffold(body: CharaDetailImportButton()),
      ),
    );
    // Inside `runAsync`: the import reads and writes real files, and `dart:io` futures do not
    // complete in the fake-async zone a widget test otherwise runs in -- the import would simply
    // never finish and `pumpAndSettle` would time out on the button's own spinner.
    await tester.runAsync(() async {
      await tester.tap(find.byType(IconButton));
      // The four turns the old capped loop spent before it was allowed to look, kept as a window and
      // not shortened: the spinner is raised a turn or two after the tap, so "no spinner" only means
      // "finished" once it has had the chance to appear.
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await tester.pump();
      }
    });
    // The spinner is shown exactly while the import runs, so its absence is the button telling us it
    // is done. Polled on the shared helper rather than capped at 400 turns: the cap was a 2 s budget
    // over real file I/O that fell out *silently* on expiry, so a contended runner reached the
    // assertions below with a half-finished import and reported it as the assertion being false.
    await settleUntil(
      tester,
      () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      describe: "the import to finish and the toolbar's spinner to go out",
    );
    return toasts;
  }

  Directory activeDir(DirectoryPath root) => Directory(pathInfoFor(root).charaDetailActiveDir.path);

  testWidgets('imports every zip the user selected, not just the first', (tester) async {
    final root = DirectoryPath(tempRoot.path);
    picker.answerWithPaths([
      writeZip('part1.zip', ['uuid-1']),
      writeZip('part2.zip', ['uuid-2']),
    ]);

    final toasts = await tapImport(tester, root);

    // The whole point: the second zip is on disk too. Before the fix this directory did not exist.
    expect(Directory('${activeDir(root).path}${Platform.pathSeparator}uuid-1').existsSync(), isTrue);
    expect(
      Directory('${activeDir(root).path}${Platform.pathSeparator}uuid-2').existsSync(),
      isTrue,
      reason: 'the second selected zip was dropped',
    );
    expect(toasts, hasLength(1));
    expect(toasts.single.type, ToastType.success);
    expect(toasts.single.description, contains('2'), reason: 'the count covers both zips');
  });

  testWidgets('asks the dialog for a multi-selection and for no eagerly loaded bytes', (tester) async {
    final root = DirectoryPath(tempRoot.path);
    picker.answerWithPaths([
      writeZip('part1.zip', ['uuid-1']),
    ]);

    await tapImport(tester, root);

    expect(picker.calls, hasLength(1));
    expect(picker.calls.single.allowMultiple, isTrue, reason: 'the split this feature prescribes needs it');
    expect(
      picker.calls.single.withData,
      isFalse,
      reason: 'web would otherwise load every selected zip into memory at once',
    );
  });

  testWidgets('keeps importing after a zip it refuses, and says so', (tester) async {
    final root = DirectoryPath(tempRoot.path);
    // Two imported records against one refused zip, so the two numbers in the message differ: with
    // 1 and 1 the assertion below would still hold if either interpolation were dropped or if the
    // two were swapped.
    picker.answerWithPaths([
      writeRejectedZip('rejected.zip'),
      writeZip('part2.zip', ['uuid-2']),
      writeZip('part3.zip', ['uuid-3']),
    ]);

    final toasts = await tapImport(tester, root);

    expect(
      Directory('${activeDir(root).path}${Platform.pathSeparator}uuid-2').existsSync(),
      isTrue,
      reason: 'a zip that failed to decode aborted the rest of the selection',
    );
    expect(Directory('${activeDir(root).path}${Platform.pathSeparator}uuid-3').existsSync(), isTrue);
    // Not silence: one bad file out of several is neither a success nor a failure, and the user has
    // no way to tell which of the files they picked did not arrive unless the app says how many.
    expect(toasts, hasLength(1));
    expect(toasts.single.type, ToastType.warning);
    expect(toasts.single.description, _sentence("$tr_import.partial_failure", {'count': '2', 'failed': '1'}));
    // Spelled out as well as compared, so the message is pinned to carrying both numbers even if
    // the key's text is reworded: 2 records in, 1 zip refused.
    expect(toasts.single.description, contains('2'));
    expect(toasts.single.description, contains('1'));
  });

  testWidgets('reports a single failing zip exactly as it always has', (tester) async {
    final root = DirectoryPath(tempRoot.path);
    picker.answerWithPaths([writeRejectedZip('rejected.zip')]);

    final toasts = await tapImport(tester, root);

    expect(toasts, hasLength(1));
    expect(toasts.single.type, ToastType.error, reason: 'one zip, one failure: the old message stands');
    expect(toasts.single.description, _sentence("$tr_import.failure"));
  });

  testWidgets('reports a single successful zip exactly as it always has', (tester) async {
    final root = DirectoryPath(tempRoot.path);
    picker.answerWithPaths([
      writeZip('part1.zip', ['uuid-1']),
    ]);

    final toasts = await tapImport(tester, root);

    expect(toasts, hasLength(1));
    expect(toasts.single.type, ToastType.success);
    expect(toasts.single.description, _sentence("$tr_import.success", {'count': '1'}));
  });

  testWidgets('reports a single zip holding no record exactly as it always has', (tester) async {
    final root = DirectoryPath(tempRoot.path);
    picker.answerWithPaths([writeRecordlessZip('labels-only.zip')]);

    final toasts = await tapImport(tester, root);

    expect(toasts, hasLength(1));
    expect(toasts.single.type, ToastType.warning);
    expect(toasts.single.description, _sentence("$tr_import.empty"));
  });

  testWidgets('reports a single oversized zip exactly as it always has, split advice included', (tester) async {
    final root = DirectoryPath(tempRoot.path);
    picker.answerWithPaths([writeTooLargeZip('huge.zip')]);

    final toasts = await tapImport(tester, root);

    expect(toasts, hasLength(1));
    expect(toasts.single.type, ToastType.error);
    expect(toasts.single.description, _sentence("$tr_import.too_large"));
    // The advice this message exists to give, and the reason the multi-selection case below must
    // not reuse it. Asserted here so the literal the other test forbids is known to be present in
    // the message it is derived from, rather than being a string that matches nothing anywhere.
    expect(toasts.single.description, contains('分けて'));
  });

  testWidgets('says how many zips failed when a whole multi-selection fails', (tester) async {
    final root = DirectoryPath(tempRoot.path);
    picker.answerWithPaths([writeRejectedZip('rejected1.zip'), writeRejectedZip('rejected2.zip')]);

    final toasts = await tapImport(tester, root);

    expect(toasts, hasLength(1));
    expect(toasts.single.type, ToastType.error);
    expect(toasts.single.description, _sentence("$tr_import.all_failure", {'failed': '2'}));
    expect(toasts.single.description, contains('2'), reason: 'the user picked two zips and got neither');
    expect(
      toasts.single.description,
      isNot(_sentence("$tr_import.failure")),
      reason: 'the single-selection message says nothing about how many were refused',
    );
  });

  testWidgets('blames the size, not the user, when a whole multi-selection is oversized', (tester) async {
    final root = DirectoryPath(tempRoot.path);
    picker.answerWithPaths([writeTooLargeZip('huge1.zip'), writeTooLargeZip('huge2.zip')]);

    final toasts = await tapImport(tester, root);

    expect(toasts, hasLength(1));
    expect(toasts.single.type, ToastType.error);
    expect(toasts.single.description, _sentence("$tr_import.all_too_large", {'failed': '2'}));
    expect(toasts.single.description, contains('2'));
    // The point of the branch: the single-zip message tells the user to split the export and import
    // it in several pieces. Several pieces is what this user just handed over, so repeating the
    // advice answers a split with another split.
    expect(
      toasts.single.description,
      isNot(contains('分けて')),
      reason: 'the advice to split cannot be the answer to an already-split selection',
    );
    expect(
      toasts.single.description,
      isNot(_sentence("$tr_import.all_failure", {'failed': '2'})),
      reason: 'refused for size reads differently from refused for being unreadable',
    );
  });

  testWidgets('imports and reports a selection that arrives after the toolbar is gone', (tester) async {
    final root = DirectoryPath(tempRoot.path);
    picker.answerWithPaths([
      writeZip('part1.zip', ['uuid-1']),
    ]);
    // The modal dialog can stay up for as long as the user browses, so the toolbar behind it can be
    // disposed before the picker answers. The selection is still the user's: they chose a file and
    // are owed the import and its outcome whichever screen they are on when it lands. Giving up here
    // would discard the pick in silence -- no record, no toast, not even a log line -- which is the
    // one failure this control must never have.
    final gate = Completer<void>();
    picker.holdUntil = gate.future;
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
      ],
    );
    final toasts = <ToastData>[];
    final subscription = container.listen<AsyncValue<ToastData>>(
      plainToastEventProvider,
      (_, current) => current.whenData(toasts.add),
    );
    addTearDown(subscription.close);
    Widget host(Widget body) => MaterialApp(
      theme: _theme(),
      home: Scaffold(body: body),
    );

    // Set inside the run below and asserted after it, so a run that never starts fails on its own
    // assertion instead of being reported as a stray exception by `takeException`.
    var started = false;

    await pumpWithContainer(tester, container, host(const CharaDetailImportButton()));
    await tester.runAsync(() async {
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      // Disposed while the dialog is still up: the picker has been called but has not answered.
      await pumpWithContainer(tester, container, host(const SizedBox()));
      gate.complete();
      // A fresh toolbar over the same container, so the app-scoped spinner flag is observable again.
      // The old element stays unmounted; this one only reports what the running import does to the
      // flag.
      await pumpWithContainer(tester, container, host(const CharaDetailImportButton()));
    });
    // Two phases in one predicate, because the spinner is raised *after* the picker answers: the
    // import has to start at all (a run that never starts is the defect) and then finish. Reading the
    // record directory instead would be wrong -- it appears mid-transaction, before the publish is
    // verified.
    // Sampled before each wait (which is where `settleUntil` looks too), and latched on the toast as
    // well as the spinner. The spinner is a transient -- raised when the picker answers, dropped in
    // the import's `finally`, ~50 ms apart for a one-record zip -- so a poll that waited before its
    // first look could arrive after it had gone out again and conclude the import never ran. That
    // window does not widen on a slow machine (it is `dart:io` completion time, off the main isolate)
    // while the poll's turnaround does, so a contended runner samples it less often, not more. A
    // toast that has landed stays landed, so unlike the spinner it cannot be sampled away.
    // This is the case that actually failed on CI, as `Expected: true / Actual: <false>` from the
    // `started` assertion below: the old loop was a 2 s cap that expired in silence, so "we ran out
    // of time" and "the import never started" were the same red. Now the former names itself.
    await settleUntil(tester, () {
      final spinning = find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      started |= spinning || toasts.isNotEmpty;
      return started && !spinning;
    }, describe: 'the selection held back by the dialog to start an import and for that import to finish');

    expect(tester.takeException(), isNull);
    expect(started, isTrue, reason: 'the import never started: the selection was dropped');
    expect(
      Directory('${activeDir(root).path}${Platform.pathSeparator}uuid-1').existsSync(),
      isTrue,
      reason: 'the zip the user picked was never imported',
    );
    // And the user is told, on whatever screen they moved to. Silence here is the app quietly
    // deciding the pick did not count.
    expect(toasts, hasLength(1));
    expect(toasts.single.type, ToastType.success);
    expect(toasts.single.description, _sentence("$tr_import.success", {'count': '1'}));
  });

  testWidgets('reports and refreshes even when the toolbar is disposed mid-import', (tester) async {
    final root = DirectoryPath(tempRoot.path);
    picker.answerWithPaths([
      writeZip('part1.zip', ['uuid-1']),
    ]);
    // Holds the import at its first await inside the button -- after the spinner is raised, before
    // any zip is read -- so the widget is disposed at a point every later step has to survive. What
    // the import produces does not belong to this widget: the records land on disk and the record
    // stores go stale regardless, so the completion toast and the store refresh are owed to the user
    // whether or not the toolbar that started the import is still on screen. Skipping them left the
    // imported records out of the table for the rest of the session -- they only appeared after an
    // app restart -- with nothing said to explain it.
    final gate = Completer<void>();
    // The two stores the button invalidates, replaced by fakes that count their builds: an
    // invalidate with a live listener is followed by a rebuild, so the count is the observation.
    // The real stores would scan the record tree (and pull each other in), which is not what is
    // under test here.
    var activeBuilds = 0;
    var archiveBuilds = 0;
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async {
          await gate.future;
          return pathInfoFor(root);
        }),
        moduleVersionLoader.overrideWith((ref) async => null),
        charaDetailRecordStorageLoaderProvider.overrideWith(() => _CountingRecordStorage(() => activeBuilds++)),
        charaDetailArchiveStorageLoaderProvider.overrideWith(() => _CountingArchiveStorage(() => archiveBuilds++)),
      ],
    );
    final toasts = <ToastData>[];
    final subscription = container.listen<AsyncValue<ToastData>>(
      plainToastEventProvider,
      (_, current) => current.whenData(toasts.add),
    );
    addTearDown(subscription.close);
    // Listened, not merely overridden: riverpod drops an invalidated provider with no listeners
    // instead of rebuilding it, and then the counter could never move. These stand in for the
    // record table the user navigated away from and comes back to.
    final activeSubscription = container.listen(charaDetailRecordStorageLoaderProvider, (_, _) {});
    final archiveSubscription = container.listen(charaDetailArchiveStorageLoaderProvider, (_, _) {});
    addTearDown(activeSubscription.close);
    addTearDown(archiveSubscription.close);
    expect(activeBuilds, 1, reason: 'listening builds each store once, which is what the import adds to');
    expect(archiveBuilds, 1);
    Widget host(Widget body) => MaterialApp(
      theme: _theme(),
      home: Scaffold(body: body),
    );

    await pumpWithContainer(tester, container, host(const CharaDetailImportButton()));
    await tester.runAsync(() async {
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      // Same container, different child: the button unmounts while the container -- and the
      // app-scoped providers holding its spinner flag and the record stores -- lives on, as when the
      // user navigates away mid-import.
      await pumpWithContainer(tester, container, host(const SizedBox()));
      gate.complete();
      // A fresh toolbar, watching the same app-scoped flag. The running import holds the *old*
      // element's context, which stays unmounted, so this new instance only reports whether the
      // disposed run cleared the flag -- and its spinner going out is the one signal that the whole
      // import (record write included) has finished, which no file on disk gives us: the record
      // directory appears mid-transaction, before the publish is verified.
      await pumpWithContainer(tester, container, host(const CharaDetailImportButton()));
      // The window the old capped loop kept in front of its first look, unshortened: the fresh
      // toolbar has to have had the chance to show the flag before its absence means anything.
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await tester.pump();
      }
    });
    await settleUntil(
      tester,
      () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      describe: "the disposed run's import to finish and clear the app-scoped spinner flag",
    );
    // The spinner going out means the invalidates have been issued; the rebuilds they schedule land
    // a turn later. An arrival, not an absence -- the assertions below say the count *moved* -- so it
    // is polled rather than given a fixed turn, and a host too busy to deliver the rebuild now says
    // so instead of surfacing as `Expected: 2 / Actual: 1`.
    await settleUntil(
      tester,
      () => activeBuilds >= 2 && archiveBuilds >= 2,
      describe: 'the two invalidated record stores to rebuild',
    );

    expect(
      Directory('${activeDir(root).path}${Platform.pathSeparator}uuid-1').existsSync(),
      isTrue,
      reason: 'the import ran past the dispose; otherwise this test proves nothing about what follows it',
    );
    expect(tester.takeException(), isNull);
    // The import succeeded, so the user is told so -- through the app-wide toast stream, which no
    // widget owns. Silence here is the app writing a record the user is never told about.
    expect(toasts, hasLength(1), reason: 'an import that finished is reported whoever is on screen');
    expect(toasts.single.type, ToastType.success);
    expect(toasts.single.description, _sentence("$tr_import.success", {'count': '1'}));
    // And the stores were rescanned, so the record is in the table when the user returns. Without
    // this the import is invisible until the app restarts.
    expect(activeBuilds, 2, reason: 'the active store was not invalidated after the dispose');
    expect(archiveBuilds, 2, reason: 'the archive store was not invalidated after the dispose');
    // The spinner flag lives in the container, not in the widget, so a `finally` skipped along with
    // the rest of the method would leave the button spinning and disabled for the rest of the
    // session -- on a toolbar the user comes back to.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNotNull);
  });

  testWidgets('leaves the stores alone when not one record was imported', (tester) async {
    final root = DirectoryPath(tempRoot.path);
    // Every zip is refused, so nothing was written and the stores already hold what they would hold
    // after a rescan. The button's `committed` guard says exactly that, and it used to be implied by
    // control flow rather than stated -- so this pins it: a rescan here is a full record-tree scan
    // the user pays for to arrive back at the same list, and on a store whose last scan failed it
    // restarts an outage nobody asked to retry.
    picker.answerWithPaths([writeRejectedZip('rejected1.zip'), writeRejectedZip('rejected2.zip')]);
    var activeBuilds = 0;
    var archiveBuilds = 0;
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
        charaDetailRecordStorageLoaderProvider.overrideWith(() => _CountingRecordStorage(() => activeBuilds++)),
        charaDetailArchiveStorageLoaderProvider.overrideWith(() => _CountingArchiveStorage(() => archiveBuilds++)),
      ],
    );
    final toasts = <ToastData>[];
    final subscription = container.listen<AsyncValue<ToastData>>(
      plainToastEventProvider,
      (_, current) => current.whenData(toasts.add),
    );
    addTearDown(subscription.close);
    final activeSubscription = container.listen(charaDetailRecordStorageLoaderProvider, (_, _) {});
    final archiveSubscription = container.listen(charaDetailArchiveStorageLoaderProvider, (_, _) {});
    addTearDown(activeSubscription.close);
    addTearDown(archiveSubscription.close);
    expect(activeBuilds, 1, reason: 'listening builds each store once; an invalidate would make it two');
    expect(archiveBuilds, 1);

    await pumpWithContainer(
      tester,
      container,
      MaterialApp(
        theme: _theme(),
        home: const Scaffold(body: CharaDetailImportButton()),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byType(IconButton));
      // The pre-look window, kept as it was.
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await tester.pump();
      }
    });
    await settleUntil(
      tester,
      () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      describe: 'the import of two refused zips to finish and its spinner to go out',
    );
    // Turns the rebuild an invalidate schedules would have landed in. Without them this assertion
    // would pass on timing rather than on the guard.
    //
    // Deliberately still a window and not `settleUntil`: the assertions below say the stores were
    // **not** rescanned, and an absence has no arrival to poll for -- see the header of
    // test/support/settling.dart. Polling would either return on the first look (testing nothing) or
    // need a condition that can never become true. A slow host only makes this negative weaker here,
    // never falsely red, which is the trade that comment prescribes.
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }

    expect(activeBuilds, 1, reason: 'the active store was rescanned for an import that wrote nothing');
    expect(archiveBuilds, 1, reason: 'the archive store was rescanned for an import that wrote nothing');
    // Not silence, though: the user picked two zips and got neither, which is the failure message's
    // whole job. "Nothing to refresh" must not become "nothing to say".
    expect(toasts, hasLength(1));
    expect(toasts.single.type, ToastType.error);
    expect(toasts.single.description, _sentence("$tr_import.all_failure", {'failed': '2'}));
  });

  testWidgets('says nothing when the dialog was cancelled', (tester) async {
    final root = DirectoryPath(tempRoot.path);
    picker.result = null;

    final toasts = await tapImport(tester, root);

    expect(toasts, isEmpty);
    expect(activeDir(root).existsSync(), isFalse);
  });
}

/// A stand-in for the active record store whose only observable behaviour is that it was built.
///
/// The provider's notifier type is part of its type, so an override has to be a
/// [CharaDetailRecordStorage]; `build()` is replaced outright, so none of the real store's scanning,
/// archive kick-off or capture listener runs. The counter lives in the test rather than in the
/// notifier because riverpod calls this factory afresh on every rebuild.
class _CountingRecordStorage extends CharaDetailRecordStorage {
  _CountingRecordStorage(this.onBuild);

  final void Function() onBuild;

  @override
  Future<List<CharaDetailRecord>> build() async {
    onBuild();
    return const [];
  }
}

/// [_CountingRecordStorage]'s counterpart for the archive store.
class _CountingArchiveStorage extends CharaDetailArchiveStorage {
  _CountingArchiveStorage(this.onBuild);

  final void Function() onBuild;

  @override
  Future<List<CharaDetailRecord>> build() async {
    onBuild();
    return const [];
  }
}

Uint8List _recordJson(String id) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'metadata': {
        'record_id': {'self': id},
      },
    }),
  ),
);
