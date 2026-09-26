// A delete asks the long-read registry and claims its paths in one step, and the
// value it hands its action is the proof of origin an erase requires.
//
//   .fvm/flutter_sdk/bin/flutter test test/storage_delete_long_read_claim_test.dart
//
// WHAT THIS SUITE PINS. `holdForDelete` and the paths it is handed:
//  * **The one step.** A delete over a path something holds does not start, and
//    leaves no claim of its own behind; a delete that does start is registered
//    before its action runs, so a writer that asks while it runs finds it — the
//    automatic module install waits for it and resumes afterwards.
//  * **The paths a request claims.** `StorageDeleteRequest.longReadPaths`, and in
//    particular the settings request's, which is `settings/` on Windows and
//    nothing on web.
//
// WHAT IT DOES NOT REACH. Nothing in `lib/` calls `holdForDelete` from this suite:
// the storage view's delete and the record deletes are driven through their own
// entry points in their own suites, which is where "the claim is held until the
// app has forgotten what went" is measured. This suite is about the step and the
// value, not about when a caller releases.
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/storage_delete.dart';
import 'package:umacapture/src/core/storage/storage_group.dart';
import 'package:umacapture/src/core/version_check.dart';
import 'package:umacapture/src/gui/storage_delete_action.dart';

import 'support/localization.dart';

late Directory _tempRoot;
late PathInfo _layout;

DirectoryPath get _activeDir => _layout.charaDetailActiveDir;

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [
      pathInfoProvider.overrideWithValue(_layout),
      pathInfoLoader.overrideWith((ref) async => _layout),
      pathLayoutLoader.overrideWith((ref) async => _layout),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

List<LongReadKind> _claimedKinds(ProviderContainer container) => [
  for (final claim in container.read(longReadRegistryProvider).values) claim.kind,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_delete_claim');
    _layout = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
  });
  tearDown(() {
    if (_tempRoot.existsSync()) _tempRoot.deleteSync(recursive: true);
  });

  group('asking and claiming are one step', () {
    test('a delete over a free path is registered for as long as its action runs', () async {
      final container = _container();
      final registry = container.read(longReadRegistryProvider.notifier);
      final target = _activeDir / 'a';
      List<LongReadClaim>? during;

      await holdForDelete(
        registry,
        paths: [target],
        action: (_) async {
          during = container.read(longReadRegistryProvider).values.toList();
        },
      );

      expect(during, hasLength(1), reason: 'the delete ran without a claim of its own');
      expect(during?.single.kind, LongReadKind.delete);
      expect(during?.single.holds.map((hold) => hold.directoryPath), [target.path]);
      expect(container.read(longReadRegistryProvider), isEmpty, reason: 'the delete kept its claim after it ended');
    });

    test(
      'a delete over a path something holds is refused before its action, and leaves no claim',
      () async {
        final container = _container();
        final registry = container.read(longReadRegistryProvider.notifier);
        registry.claimUntilReleased(kind: LongReadKind.regeneration, paths: [_activeDir / 'a']);
        var ran = false;

        await expectLater(
          holdForDelete(
            registry,
            // The record's file, under the directory the batch holds: the same
            // containment the registry asks either way round.
            paths: [(_activeDir / 'a').filePath('record.json')],
            action: (_) async => ran = true,
          ),
          throwsA(
            isA<LongReadNotStartedException>().having((error) => error.heldBy, 'heldBy', LongReadKind.regeneration),
          ),
        );

        expect(ran, isFalse, reason: 'a delete started under a path a re-recognition was holding');
        expect(_claimedKinds(container), [
          LongReadKind.regeneration,
        ], reason: 'the refused delete left a claim of its own, or took the holder\'s with it');
      },
      // A delete that waits instead of refusing never returns here, so the
      // failure is a timeout rather than a hang of the whole run.
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test('a module install that defers waits for a delete over modules/ and runs once it lets go', () async {
      final container = _container();
      final registry = container.read(longReadRegistryProvider.notifier);
      final versionFile = File(_layout.modulesDir.filePath('version_info.json').path);
      final deleting = Completer<void>();
      final inside = Completer<void>();

      final delete = holdForDelete(
        registry,
        paths: [_layout.modulesDir],
        action: (_) async {
          inside.complete();
          await deleting.future;
        },
      );
      await inside.future;

      final install = runModuleInstall(container.read(containerRefProvider), _layout, () async {
        versionFile.parent.createSync(recursive: true);
        versionFile.writeAsStringSync('{}');
      }, contention: LongReadContention.defer);
      await pumpEventQueue();

      expect(container.read(longReadDeferralsProvider), {
        LongReadKind.moduleInstall: 1,
      }, reason: 'the install did not see the delete holding modules/');
      expect(versionFile.existsSync(), isFalse, reason: 'the install wrote into modules/ while a delete held it');

      deleting.complete();
      await delete;
      await install;

      expect(versionFile.existsSync(), isTrue, reason: 'the wait must end in the install running, not in a refusal');
      expect(container.read(longReadDeferralsProvider), isEmpty);
      expect(container.read(longReadRegistryProvider), isEmpty);
    });
  });

  group('what a request claims', () {
    StorageGroup groupOf(StorageGroupId id) => storageGroups.firstWhere((group) => group.id == id);

    test('the settings delete claims settings/ on Windows and nothing on web', () {
      final settings = groupOf(StorageGroupId.settings);

      expect(
        storageGroupDeleteRequest(_layout, settings, onWeb: false)?.longReadPaths.map((path) => path.path),
        [_layout.settingsDir.path],
        reason: 'a settings delete on Windows has to claim the directory a relocation moves wholesale',
      );
      expect(
        storageGroupDeleteRequest(_layout, settings, onWeb: true)?.longReadPaths,
        isEmpty,
        reason: 'on web the stores are IndexedDB databases, so there is no path of theirs to claim',
      );
    });

    test('a path delete claims exactly the paths it erases', () {
      final request = storageGroupDeleteRequest(_layout, groupOf(StorageGroupId.activeRecords), onWeb: false);

      expect(request?.longReadPaths.map((path) => path.path), [_activeDir.path]);
    });
  });
}
