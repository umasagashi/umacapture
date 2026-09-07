// F4 (6th-pass review, MAJOR M-3): a group row's zip button used to be offered
// for a group whose root directory does not exist at all — `quarantine`,
// `temp` and `retired` are ordinary states when nothing has ever landed there
// (`directory_totals.dart` states the identical fact for the group's byte
// total: an absent root is an empty total, not an error). Pressing the button
// anyway sent `exportDirectoryAsZip` into a listing that throws
// (`PathNotFoundException` on Windows, `WebVfs`'s own not-found on the
// browser leg), which the outer `catch` turns into the generic
// `pages.storage.zip.failed` toast — a failure the user did nothing to cause.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_zip_group_absent_target_test.dart
//
// The fix asks the same question the delete survey already asks when it
// decides [StorageDeletePlan.absent] — `storageTargetIsPresent`, a named
// pass-through to [PathEntity.exists] — instead of a second, unrelated
// derivation of "is this here". This suite asserts the button side; the
// existing delete-side behaviour for an absent target (an empty, "isComplete"
// report, asserted in `storage_delete_test.dart`) is not re-asserted here.
//
// WHAT THIS SUITE DOES NOT REACH. The browser leg (`WebVfs`), which has no VM
// path; the exact Win32 exception a real `ZipFileEncoder.addDirectory` throws
// against a missing directory, which is `V1-c3-zip-picker.md`'s own probe and
// not repeated here — this suite only has to show the button never lets a
// press reach that call at all.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/file_download.dart';
import 'package:umacapture/src/core/storage/storage_delete.dart';
import 'package:umacapture/src/core/storage/zip_export.dart';
import 'package:umacapture/src/gui/storage_tree.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

late Directory _tempRoot;
late PathInfo _layout;
late List<String> _requestedNames;

DirectoryPath get _quarantineDir => _layout.charaDetailQuarantineDir;

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      pathLayoutLoader.overrideWith((ref) async => _layout),
      storageZipAvailableProvider.overrideWithValue(true),
      // Stands in for the OS save dialog, which no VM test may open. Recording
      // the requested name is what tells a press-while-disabled case apart
      // from a press that reached the runner: the assertion a finder alone
      // cannot make.
      storageSaveFileProvider.overrideWithValue(({
        required String dialogTitle,
        required String fileName,
        required Uint8List bytes,
      }) async {
        _requestedNames.add(fileName);
        return null;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

bool _iconEnabled(WidgetTester tester, Key key) => tester.widget<IconButton>(find.byKey(key)).onPressed != null;

/// Lets the real `dart:io` futures behind `PathEntity.exists()` resolve, which
/// a `testWidgets` body's fake clock does not advance on its own.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 20; round++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

Future<void> _pumpTree(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await pumpWithContainer(tester, container, const MaterialApp(home: Scaffold(body: StorageTreeView())));
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _requestedNames = [];
    _tempRoot = Directory.systemTemp.createTempSync('uma_zip_group_absent_target');
    _layout = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
    // Nothing is written under `documents/`, so `_quarantineDir` and every
    // other group root do not exist on disk at all — the ordinary state for a
    // fresh install, and the state `V1-c3-zip-picker.md`'s B-2 named.
  });

  tearDown(() {
    if (_tempRoot.existsSync()) {
      _tempRoot.deleteSync(recursive: true);
    }
  });

  test('the same fact: an absent target reads false through storageTargetIsPresent, '
      'the function the delete survey turns into StorageDeletePlan.absent', () async {
    expect(await storageTargetIsPresent(_quarantineDir), isFalse);
    File(_quarantineDir.filePath('leftover.bin').path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([1]);
    expect(await storageTargetIsPresent(_quarantineDir), isTrue);
  });

  testWidgets('a group whose root does not exist yet offers a zip button, but disabled', (tester) async {
    final container = _container();
    await _pumpTree(tester, container);

    final key = storageZipEntityKey(_quarantineDir);
    // The positive control first: the button is *offered* (the group declares
    // the operation), which is what tells this apart from the settings group's
    // `findsNothing`.
    expect(find.byKey(key), findsOneWidget);
    expect(_iconEnabled(tester, key), isFalse);

    // The assertion a finder cannot fake: a press on a disabled button never
    // reaches the save-dialog seam, so the zip runner never opened the folder
    // that is not there.
    await tester.tap(find.byKey(key), warnIfMissed: false);
    await _settle(tester);
    expect(_requestedNames, isEmpty, reason: 'a zip of an absent group directory reached the save dialog');
  });

  testWidgets('once something lands in the group, the same button turns live', (tester) async {
    final container = _container();
    await _pumpTree(tester, container);
    expect(_iconEnabled(tester, storageZipEntityKey(_quarantineDir)), isFalse);

    File(_quarantineDir.filePath('leftover.bin').path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([1]);
    // Driven through the view's own refresh — the one a delete and a re-entry
    // call — and not by invalidating the family element from here, which would
    // assert only that the provider re-reads when told to and would stay green
    // with the provider left out of `storageTabContentProviders`. Nothing
    // watches the filesystem on either platform (`directory_totals.dart` states
    // the same limit for the byte totals), so this refresh is the only thing
    // that ever asks again.
    reloadStorageTab(container.read(refBaseProvider));
    await _settle(tester);

    expect(_iconEnabled(tester, storageZipEntityKey(_quarantineDir)), isTrue);

    await tester.tap(find.byKey(storageZipEntityKey(_quarantineDir)));
    await _settle(tester);
    expect(_requestedNames, ['${_quarantineDir.name}.zip']);
  });

  testWidgets('a group whose root does exist keeps a live button, as before', (tester) async {
    File(_quarantineDir.filePath('leftover.bin').path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync([1]);
    final container = _container();
    await _pumpTree(tester, container);

    expect(_iconEnabled(tester, storageZipEntityKey(_quarantineDir)), isTrue);
  });
}
