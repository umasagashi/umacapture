// Tests that a record the ZIP importer *refused* reaches the user, with its reason.
//
// The defect this pins: the write transaction learned to refuse a record whose id already lives
// under `archive/` (one id belongs to one store, so re-importing a zip exported from the archive
// view would otherwise put the same trainee in both). The refusal was logged and put in a failure
// map -- and then dropped on the floor by `RecordImportResult`, which carried only "which ids were
// written". A mixed zip therefore lost one record with no toast, no count and no reason: the user
// saw "N records imported" for a zip that held N+1.
//
// "Says how many failed" is not enough here. "Already in the archive" needs the opposite advice
// from every other import failure -- nothing at all, the record is already owned -- so the reason,
// not just the count, has to survive to the toast.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/import_refusal_surface_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/record_zip.dart';
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

/// The shipped sentence for [key] with `{count}` filled in, read out of `ja.json` **as a literal**.
///
/// Not `key.tr(namedArgs: …)`: `.tr()` renders an unresolvable key AS the key, so comparing the
/// toast against it would pass whether or not the key exists -- key equals key. Reading the file
/// gives a Japanese literal, so a deleted, renamed or mistyped key turns every assertion below red.
/// [appSentenceAt] itself throws when the path is missing, which is the key-absence detector.
String _sentence(String key, int count) => appSentenceAt(key).replaceAll('{count}', '$count');

void main() {
  setUpAll(loadAppTranslations);

  late Directory tempRoot;
  late FakeFilePicker picker;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_import_refusal');
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

  /// Puts [id] in the archive store, which is what makes the publish into `active/` refuse.
  ///
  /// A real directory, because the guard probes the filesystem (`_otherStoreHolding`); nothing is
  /// stubbed on the way, so this exercises the shipped refusal rather than a fake of it.
  void archiveRecord(DirectoryPath root, String id) {
    final dir = Directory(pathInfoFor(root).charaDetailArchiveDir.path)..createSync(recursive: true);
    Directory('${dir.path}${Platform.pathSeparator}$id').createSync();
    File(
      '${dir.path}${Platform.pathSeparator}$id${Platform.pathSeparator}record.json',
    ).writeAsBytesSync(_recordJson(id));
  }

  Uint8List zipBytes(List<String> recordIds) {
    final archive = Archive();
    for (final id in recordIds) {
      final json = _recordJson(id);
      archive.addFile(ArchiveFile('chara_detail/active/$id/record.json', json.length, json));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  String writeZip(String fileName, List<String> recordIds) {
    final path = '${tempRoot.path}${Platform.pathSeparator}$fileName';
    File(path).writeAsBytesSync(zipBytes(recordIds));
    return path;
  }

  Future<List<ToastData>> tapImport(WidgetTester tester, DirectoryPath root) async {
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

    await pumpWithContainer(
      tester,
      container,
      MaterialApp(
        theme: _theme(),
        home: const Scaffold(body: CharaDetailImportButton()),
      ),
    );
    // A pick that yields nothing takes the one path with no import to wait for: `_pickAndImport`
    // returns on `result == null || result.files.isEmpty` *before* it raises the spinner, so neither
    // spinner nor toast ever appears and the latch further down could only expire. Read from the
    // answer the test loaded rather than from a list of the cases that cancel, so a new cancelling
    // case needs no entry here. Kept in step with the same branch in
    // test/chara_detail_import_button_test.dart, which is where the cancelling cases live.
    final answer = picker.result;
    final cancelling = answer == null || answer.files.isEmpty;
    // Held shut across the tap, so the wait below has something that has genuinely not happened yet.
    // `FakeFilePicker.pickFiles` records the call *before* awaiting `holdUntil`, so
    // `picker.calls.isNotEmpty` is already true the moment `tester.tap` returns: a latch on it turns
    // its loop over zero times and advances the clock by nothing (measured: 0 turns). What is a real
    // arrival is the picker having *answered*, and holding the dialog is what makes it one.
    final dialog = cancelling ? Completer<void>() : null;
    if (dialog != null) {
      expect(picker.holdUntil, isNull, reason: 'a cancelling case that holds the dialog itself would be overwritten');
      picker.holdUntil = dialog.future;
    }
    // Inside `runAsync`: the import reads and writes real files, and `dart:io` futures do not
    // complete in the fake-async zone a widget test otherwise runs in.
    await tester.runAsync(() async {
      await tester.tap(find.byType(IconButton));
    });
    if (dialog != null) {
      var answered = false;
      // Registered after the widget's own `await holdUntil`, and a future runs its callbacks in
      // registration order, so this one lands once `pickFiles` has resumed and returned.
      unawaited(dialog.future.whenComplete(() => answered = true));
      dialog.complete();
      await settleUntil(tester, () => answered, describe: 'the file picker to answer the tap with no selection');
      // What this returns to are absences, and per test/support/settling.dart an absence has no
      // arrival to poll for, so its window has to stay a window. The latch above does not stand in
      // for one: it clears a single turn (~1 ms) after the pick, and a stand-in that emitted a toast
      // 5 ms later went unseen with the latch alone and was seen with these four turns.
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump();
      }
      return toasts;
    }
    // Two phases in one predicate, because the spinner is raised only once the picker has answered:
    // "no spinner" is also true *before* the import starts, so a predicate that only asks for its
    // absence returns the moment it is first sampled and the assertions below run against an import
    // that has not begun. Latching "it started" first is what makes the absence mean "finished".
    //
    // This replaces a fixed window of four turns of 5 ms spent before the poll was allowed to look,
    // which was exactly the guess about the host's spare CPU these helpers exist to remove: the
    // spinner-to-toast transient is ~50 ms for a one-record zip, so 20 ms only ever covered the tap-
    // to-picker gap on an idle machine. The latch needs no window and none is kept.
    //
    // Latched on the toast as well as the spinner: the spinner is a transient that a slow poll can
    // step over entirely, while a toast that has landed stays landed. Polled on the shared helper
    // rather than capped at 400 turns: the cap was a 2 s budget over real file I/O that fell out
    // *silently* on expiry, so a contended runner reached the assertions with a half-finished import
    // and reported it as the assertion being false.
    var started = false;
    await settleUntil(tester, () {
      final spinning = find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      started |= spinning || toasts.isNotEmpty;
      return started && !spinning;
    }, describe: "the import to start and then to finish, with the toolbar's spinner gone out");
    return toasts;
  }

  Directory activeDir(DirectoryPath root) => Directory(pathInfoFor(root).charaDetailActiveDir.path);

  group('RecordZipService.import', () {
    test('reports the archived record it refused, by id and by reason', () async {
      final root = DirectoryPath(tempRoot.path);
      archiveRecord(root, 'uuid-archived');

      final result = await RecordZipService.import(
        zipBytes(['uuid-archived', 'uuid-new']),
        pathInfoFor(root).storageDir,
      );

      // The half that already worked: the record that was free to land, landed.
      expect(result.recordIds, {'uuid-new'});
      // The half that was thrown away: which record did not, and why. Asserted as a map and not as
      // a count, because a count cannot tell "you already own this" from "this was lost".
      expect(result.refusals, {'uuid-archived': RecordImportRefusal.alreadyArchived});
      expect(
        Directory('${activeDir(root).path}${Platform.pathSeparator}uuid-archived').existsSync(),
        isFalse,
        reason: 'the archived copy must stay the only copy; otherwise there is nothing to report',
      );
    });

    test('reports no refusal when every record was written', () async {
      final root = DirectoryPath(tempRoot.path);

      final result = await RecordZipService.import(zipBytes(['uuid-1', 'uuid-2']), pathInfoFor(root).storageDir);

      // Negative control for the assertions above: a clean import must not manufacture a refusal,
      // or the toast below would appear on every ordinary import.
      expect(result.recordIds, {'uuid-1', 'uuid-2'});
      expect(result.refusals, isEmpty);
    });
  });

  group('the toolbar button', () {
    testWidgets('says a record was refused because it is already archived, and that nothing is owed', (tester) async {
      final root = DirectoryPath(tempRoot.path);
      archiveRecord(root, 'uuid-archived');
      picker.answerWithPaths([
        writeZip('mixed.zip', ['uuid-archived', 'uuid-new']),
      ]);

      final toasts = await tapImport(tester, root);

      // Two lines, because two different things happened and either alone would be a lie: one
      // record arrived, one was refused. Before the fix the refused one was invisible and the
      // success toast said "1 imported" for a zip holding two records.
      expect(toasts, hasLength(2));
      expect(toasts.first.type, ToastType.success);
      final refusal = toasts.last;
      expect(refusal.type, ToastType.warning);
      expect(
        refusal.description,
        _sentence('pages.chara_detail.import.refused.already_archived', 1),
        reason: 'the reason has to be the sentence about the archive, not a generic failure count',
      );
      // Spelled out as well as compared, so the assertion still pins the *content* if the sentence
      // is reworded: it has to name the archive and say the user need do nothing.
      expect(refusal.description, contains('アーカイブ'));
      expect(refusal.description, contains('必要ありません'));
      expect(
        refusal.description,
        isNot(contains('pages.chara_detail')),
        reason: 'easy_localization renders an unresolvable key as the key itself',
      );
    });

    testWidgets('does not claim the zip held no record when every record was refused', (tester) async {
      final root = DirectoryPath(tempRoot.path);
      archiveRecord(root, 'uuid-a');
      archiveRecord(root, 'uuid-b');
      picker.answerWithPaths([
        writeZip('all-archived.zip', ['uuid-a', 'uuid-b']),
      ]);

      final toasts = await tapImport(tester, root);

      expect(toasts, hasLength(1));
      expect(toasts.single.type, ToastType.warning);
      expect(
        toasts.single.description,
        _sentence('pages.chara_detail.import.refused.already_archived', 2),
        reason: 'two records were refused, so the count is 2 and the reason is still the archive',
      );
      // The wrong answer this branch replaced: "no importable record was found" is false -- two
      // were found, both were refused -- and it explains nothing.
      expect(toasts.single.description, isNot(appSentenceAt('pages.chara_detail.import.empty')));
      expect(toasts.single.description, contains('2'));
    });

    testWidgets('adds nothing to an import in which every record landed', (tester) async {
      final root = DirectoryPath(tempRoot.path);
      picker.answerWithPaths([
        writeZip('clean.zip', ['uuid-1', 'uuid-2']),
      ]);

      final toasts = await tapImport(tester, root);

      // The negative control. A refusal toast on an import with no refusal would train the user to
      // ignore the one case this whole change exists to show them.
      expect(toasts, hasLength(1));
      expect(toasts.single.type, ToastType.success);
      expect(toasts.single.description, _sentence('pages.chara_detail.import.success', 2));
    });
  });

  group('the refusal vocabulary', () {
    test('every reason has a sentence in the shipped translations', () {
      // The machine walks the enum, so a member added later is covered without this test being
      // touched -- and `appSentenceAt` throws on a key `ja.json` does not define, which is what
      // makes "I added the enum value and forgot the string" a red test rather than a toast that
      // shows `pages.chara_detail.import.refused.…` to the user.
      for (final refusal in RecordImportRefusal.values) {
        final key = importRefusalKey(refusal);
        final sentence = appSentenceAt(key);
        expect(sentence, isNot(equals(key)));
        expect(sentence, contains('{count}'), reason: '$key must be able to say how many');
      }
    });

    test('groups a mixed set of refusals into one line per reason, each with its own count', () {
      final toasts = importRefusalToasts({
        'a': RecordImportRefusal.alreadyArchived,
        'b': RecordImportRefusal.notStored,
        'c': RecordImportRefusal.notStored,
      });

      // Two reasons, so two lines -- a single "3 records failed" would put the record the user
      // already owns and the two they lost under one verdict and one (wrong) piece of advice.
      expect(toasts, hasLength(2));
      expect(toasts[0].type, ToastType.warning);
      expect(toasts[0].description, _sentence('pages.chara_detail.import.refused.already_archived', 1));
      expect(toasts[1].type, ToastType.error);
      expect(toasts[1].description, _sentence('pages.chara_detail.import.refused.not_stored', 2));
    });

    test('says nothing when nothing was refused', () {
      expect(importRefusalToasts(const {}), isEmpty);
    });
  });
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
