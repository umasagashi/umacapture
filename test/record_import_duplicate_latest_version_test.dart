// A multi-zip import weighs each record against the latest version of every record id the import
// has seen: a record the selection replaced is judged by its new contents, not by what the store
// loaded before the import or what an earlier zip of the selection carried.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/record_import_duplicate_latest_version_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/chara_detail/import_button.dart';
import 'package:umacapture/src/gui/theme_extensions.dart';
import 'package:umacapture/src/gui/toast.dart';

import 'support/file_picker.dart';
import 'support/localization.dart';
import 'support/records.dart';
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

void main() {
  setUpAll(loadAppTranslations);
  // The duplicate check decodes each `record.json` into a [CharaDetailRecord]; without the mappers
  // every decode throws and is swallowed, so the check would answer "not a duplicate" for
  // everything and the tests below would pass on a wire that was never connected.
  setUpAll(initializeMappers);

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

  /// Writes a real zip holding [records] verbatim (the picker hands over paths, not bytes).
  String writeRecordZip(String fileName, List<CharaDetailRecord> records) {
    final archive = Archive();
    for (final record in records) {
      final json = Uint8List.fromList(utf8.encode(jsonEncode(record.toMap())));
      archive.addFile(ArchiveFile('chara_detail/active/${record.id}/record.json', json.length, json));
    }
    final path = '${tempRoot.path}${Platform.pathSeparator}$fileName';
    File(path).writeAsBytesSync(ZipEncoder().encode(archive));
    return path;
  }

  /// Pumps the button, taps it, and returns the toasts it emitted.
  Future<List<ToastData>> tapImport(
    WidgetTester tester,
    DirectoryPath root, {
    List<Override> extraOverrides = const [],
    Future<void> Function(ProviderContainer container)? prepare,
  }) async {
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => pathInfoFor(root)),
        // Skip the (network/version) module check so nothing reaches for the network.
        moduleVersionLoader.overrideWith((ref) async => null),
        ...extraOverrides,
      ],
    );
    // Runs before the button is pumped, for the cases that need the record store actually built:
    // the button asks `ProviderContainer.exists` and takes silence for "no store to ask".
    if (prepare != null) {
      await prepare(container);
    }
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
    });
    // Latched on "it started" first: the spinner is raised only once the picker has answered, so
    // "no spinner" is also true before the import begins. Latched on the toast as well, because a
    // slow poll can step over the spinner entirely while a landed toast stays landed.
    var started = false;
    await settleUntil(tester, () {
      final spinning = find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      started |= spinning || toasts.isNotEmpty;
      return started && !spinning;
    }, describe: "the import to start and then to finish, with the toolbar's spinner gone out");
    return toasts;
  }

  Directory activeDir(DirectoryPath root) => Directory(pathInfoFor(root).charaDetailActiveDir.path);

  bool has(DirectoryPath root, String id) =>
      Directory('${activeDir(root).path}${Platform.pathSeparator}$id').existsSync();
  CharaDetailRecord storedAt(DirectoryPath root, String id) => CharaDetailRecordMapper.fromJson(
    File('${activeDir(root).path}${Platform.pathSeparator}$id${Platform.pathSeparator}record.json').readAsStringSync(),
  );

  // Two charas sharing a card, told apart by their factors: every `x(...)` is the same chara as
  // every other `x(...)`, and never the same chara as a `y(...)`.
  CharaDetailRecord x(String id) => makeRecord(id: id, card: 300, self: const [Factor(9, 2)]);
  CharaDetailRecord y(String id) => makeRecord(id: id, card: 300, self: const [Factor(8, 1)]);

  test('the two fixtures are different charas, and each is the same chara under another id', () {
    expect(x('A').isSameChara(y('A')), isFalse);
    expect(x('A').isSameChara(x('B')), isTrue);
  });

  Future<List<ToastData>> importOverStoredX(WidgetTester tester, DirectoryPath root) => tapImport(
    tester,
    root,
    extraOverrides: [
      charaDetailRecordStorageLoaderProvider.overrideWith(() => _StockedRecordStorage([x('A')])),
      charaDetailArchiveStorageLoaderProvider.overrideWith(_EmptyArchiveStorage.new),
    ],
    prepare: (container) async {
      addTearDown(container.listen(charaDetailRecordStorageLoaderProvider, (_, _) {}).close);
      await container.read(charaDetailRecordStorageLoaderProvider.future);
    },
  );

  group('an earlier zip of the same selection replaced a record', () {
    testWidgets('a copy of the replaced version is not a duplicate', (tester) async {
      final root = DirectoryPath(tempRoot.path);
      picker.answerWithPaths([
        writeRecordZip('z1.zip', [x('A')]),
        writeRecordZip('z2.zip', [y('A')]),
        writeRecordZip('z3.zip', [x('B')]),
      ]);
      await tapImport(tester, root);
      expect(storedAt(root, 'A').isSameChara(y('A')), isTrue);
      expect(has(root, 'B'), isTrue, reason: 'A no longer holds X once z2 replaced it');
    });

    testWidgets('without the replacement, the copy is still refused', (tester) async {
      final root = DirectoryPath(tempRoot.path);
      picker.answerWithPaths([
        writeRecordZip('z1.zip', [x('A')]),
        writeRecordZip('z3.zip', [x('B')]),
      ]);
      await tapImport(tester, root);
      expect(storedAt(root, 'A').isSameChara(x('A')), isTrue);
      expect(has(root, 'B'), isFalse);
    });
  });

  group('the import replaced a record the store had already loaded', () {
    testWidgets('a copy of the replaced version is not a duplicate', (tester) async {
      final root = DirectoryPath(tempRoot.path);
      picker.answerWithPaths([
        writeRecordZip('z2.zip', [y('A')]),
        writeRecordZip('z3.zip', [x('B')]),
      ]);
      await importOverStoredX(tester, root);
      expect(storedAt(root, 'A').isSameChara(y('A')), isTrue);
      expect(has(root, 'B'), isTrue, reason: 'A no longer holds X once z2 replaced it');
    });

    testWidgets('without the replacement, the copy is still refused', (tester) async {
      final root = DirectoryPath(tempRoot.path);
      picker.answerWithPaths([
        writeRecordZip('z3.zip', [x('B')]),
      ]);
      await importOverStoredX(tester, root);
      expect(has(root, 'B'), isFalse);
    });
  });
}

/// A stand-in active record store that already holds [stocked]. `build()` is replaced outright, so
/// none of the real store's scanning or capture wiring runs.
class _StockedRecordStorage extends CharaDetailRecordStorage {
  _StockedRecordStorage(this.stocked);

  final List<CharaDetailRecord> stocked;

  @override
  Future<List<CharaDetailRecord>> build() async => stocked;
}

/// An archive store that holds nothing and scans nothing.
class _EmptyArchiveStorage extends CharaDetailArchiveStorage {
  @override
  Future<List<CharaDetailRecord>> build() async => const [];
}
