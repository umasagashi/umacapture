// What the storage delete confirmation says once the delete is **already
// running** — and what it says before that, which is a different sentence.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_delete_in_flight_refusal_test.dart
//
// WHY THIS IS NOT `storage_long_read_extract_gate_test.dart`. That suite asks
// whether a registered long reader stops a delete from *starting*, and every
// claim in it is live before the confirm is pressed. This one asks the opposite
// half: a claim that lands **after** the long press, while the run it would have
// refused is under way. The two are the same registry read seen at two moments,
// and the confirmation used to answer them identically — the acknowledgement
// checkbox gave way to the running indicator, and the refusal card did not — so
// a claim arriving mid-run drew 「実行できません」 over a delete that then went on
// to finish and report success.
//
// THE REACHABLE INPUT IS NOT A USER GESTURE. `_confirm` shuts the barrier, the ×
// and cancel for the whole run, so nothing the user can touch starts a long read
// from here. `runModuleInstall` does: its download deliberately holds no claim
// and takes one only when it begins writing into `modules/`, so an automatic
// update that lands mid-delete is a claim with no gesture behind it.
//
// EVERY ASSERTION HAS ITS CONTROL. "No card while the delete runs" and "no card
// ever" are one observation seen once, and the second would ship the refusal
// that four other suites depend on as dead code. So the identical claim over the
// identical path is made *before* the long press in the control below, where it
// must produce the card and a dead confirm.
//
// WHAT THIS SUITE DOES NOT REACH. It does not run a real `runModuleInstall`: the
// claim is registered directly, which is what the dialog can observe in any case
// (it reads the registry and not the installer). It does not reach the web leg's
// own delete executor — the widget under test is shared, and neither `_deleting`
// nor the refusal has a platform branch.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_delete_request.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/video_import_ops.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';

import 'support/localization.dart';
import 'support/riverpod.dart';

late Directory _tempRoot;
late PathInfo _layout;

/// The group the claim below overlaps, and the file the delete removes.
DirectoryPath get _tempDir => _layout.tempDir;

FilePath _seed() {
  final path = _tempDir.filePath('scratch.bin');
  final file = File(path.path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('x');
  return path;
}

/// Nothing else going on: no capture, no video import.
ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      pathLayoutLoader.overrideWith((ref) async => _layout),
      capturingStateProvider.overrideWithValue(false),
      videoImportListenableProvider.overrideWithValue(ValueNotifier(VideoImportState.idle)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// The claim an automatic module install would land, as the registry sees it.
///
/// `claimUntilReleased` and not `hold`, because it has to outlive the call that
/// registers it. The kind is immaterial and the path is not:
/// `storageDeleteBlockedBy` compares the held paths against the delete's targets,
/// so this claim refuses this delete because it names the directory the file is
/// in.
void _claimTempDir(ProviderContainer container) {
  container.read(longReadRegistryProvider.notifier).claimUntilReleased(kind: LongReadKind.archive, paths: [_tempDir]);
}

Finder _confirmButton() {
  return find.descendant(
    of: find.byKey(storageDeleteConfirmRowKey),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton && widget is! OutlinedButton),
  );
}

/// Lets the real event loop run, which a `testWidgets` body's fake clock does not.
Future<void> _settle(WidgetTester tester) async {
  for (var round = 0; round < 20; round++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

Future<void> _pumpDialog(WidgetTester tester, ProviderContainer container, FilePath file) {
  return pumpWithContainer(
    tester,
    container,
    MaterialApp(
      home: Scaffold(
        body: StorageDeleteConfirmDialog(
          group: storageGroupOf(StorageGroupId.temp),
          request: StorageDeletePathsRequest([file]),
          subject: 'scratch.bin',
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_storage_delete_in_flight');
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

  testWidgets('a claim that lands mid-delete says nothing, and the delete finishes', (tester) async {
    final file = _seed();
    final container = _container();
    await _pumpDialog(tester, container, file);

    await tester.longPress(_confirmButton());
    await tester.pump();
    // The run is genuinely in flight and not already over: the indicator is up
    // and the file is still there. Without this the assertions below would hold
    // just as well over a finished delete, which is not the state under test.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(File(file.path).existsSync(), isTrue, reason: 'the delete was already over before the claim landed');

    _claimTempDir(container);
    await tester.pump();

    expect(find.byKey(storageDeleteLongReadKey), findsNothing, reason: 'a running delete was told it could not run');
    expect(find.byKey(storageDeleteBlockedKey), findsNothing);
    expect(
      find.text(longReadBusyMessage()),
      findsNothing,
      reason: 'the refusal reached the screen by some other route than the card',
    );

    await _settle(tester);
    expect(File(file.path).existsSync(), isFalse, reason: 'the delete did not finish');
  });

  testWidgets('the control: the same claim before the long press does refuse', (tester) async {
    final file = _seed();
    final container = _container();
    _claimTempDir(container);
    await _pumpDialog(tester, container, file);

    expect(
      find.byKey(storageDeleteLongReadKey),
      findsOneWidget,
      reason: 'the refusal this suite asserts is suppressed mid-run never appears at all',
    );
    expect(find.text(longReadBusyMessage()), findsOneWidget);
    expect(tester.widget<ButtonStyleButton>(_confirmButton()).enabled, isFalse);

    // And it is the refusal, not the dialog, that holds the file: pressing anyway
    // leaves it on disk.
    await tester.longPress(_confirmButton());
    await _settle(tester);
    expect(File(file.path).existsSync(), isTrue, reason: 'the delete ran through a live claim');
  });
}
