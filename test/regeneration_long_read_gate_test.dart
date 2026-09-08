// The long-read refusal inside [CharaDetailRecordRegenerationController.start].
//
//   .fvm/flutter_sdk/bin/flutter test test/regeneration_long_read_gate_test.dart
//
// WHAT THESE CASES ARE TRYING TO FALSIFY, in one sentence: *a regeneration batch
// begins over a record directory a registered long reader is already holding.*
//
// WHY THE REFUSAL IS IN `start` AND NOT ONLY ON THE CONTROLS. `start`'s own
// comment counts five ways into a batch and says two of them are not controls at
// all: a manual module install auto-starts one from its own success path, and
// every store build re-checks record versions. Neither has anything to disable,
// so a refusal written only on the three controls would leave the other two
// rewriting `prediction.json` and the geometry files under a directory an
// archive move is renaming away or a zip is reading. This is the same argument
// the video-import refusal beside it makes, tested in
// `regeneration_import_gate_test.dart`, and the two are asserted separately
// because they are two conditions on one door.
//
// The control half — the row menu greying its entry, and the dialog saying why —
// is `record_action_extraction_gate_test.dart`'s. Neither replaces the other:
// this file cannot see a button, and that one cannot reach the two UI-less
// entrances.
//
// WHAT THIS SUITE DOES NOT REACH.
//  * The two UI-less entrances themselves (`ModuleManualUpdateDialog`'s success
//    path and the store build's version check). They are asserted here only in
//    the sense that they call this method; driving them needs a module install
//    and a Hive-backed store build respectively.
//  * `RegenerateAllRecordsTile`. It asks the registry itself, over the same
//    derivation this door claims, and resolves its own blocker enum to word the
//    refusal; nothing here can see that. `regenerate_all_records_tile_test.dart`
//    is where it is asserted.
//  * The native side. Whether the worker would in fact damage a record it shares
//    with a zip is not observable from a VM suite; the refusal exists so the
//    overlap does not arise.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/chara_detail/chara_detail_record.dart';
import 'package:umacapture/src/chara_detail/storage.dart';
import 'package:umacapture/src/core/mapper_init.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/platform_channel_io.dart';
import 'package:umacapture/src/core/platform_controller.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/zip_export.dart';
import 'package:umacapture/src/core/version_check.dart';

import 'support/localization.dart';
import 'support/records.dart';

late Directory _tempRoot;

PathInfo _pathInfoFor(DirectoryPath root) => PathInfo(
  documentDir: root,
  supportDir: root,
  executableDir: root / 'exe',
  downloadDir: root / 'dl',
  dataRoot: root,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    initializeMappers();
    loadAppTranslations();
  });

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_regeneration_gate');
    // `start` and the completion tail both reach the native channel; answered
    // with null so an unanswered channel cannot turn into a `fail(id)` racing
    // the assertions.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      (call) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformChannel.channel,
      null,
    );
    if (_tempRoot.existsSync()) {
      _tempRoot.deleteSync(recursive: true);
    }
  });

  DirectoryPath activeDir() => _pathInfoFor(DirectoryPath(_tempRoot.path)).charaDetailActiveDir;

  /// The write transaction journal a batch publishes through on web.
  DirectoryPath journalDir() => _pathInfoFor(DirectoryPath(_tempRoot.path)).charaDetailWriteTransactionDir;

  /// A container whose `start` reaches a batch — the same arrangement
  /// `regeneration_long_read_claim_test.dart` uses, so "declined" here means the
  /// refusal and not a headless container turning back at something else.
  ProviderContainer containerFor() {
    final root = DirectoryPath(_tempRoot.path);
    final container = ProviderContainer(
      overrides: [
        pathInfoLoader.overrideWith((ref) async => _pathInfoFor(root)),
        moduleVersionLoader.overrideWith((ref) async => null),
        platformControllerLoader.overrideWith((ref) async {
          final controller = PlatformController(ref, const {});
          ref.onDispose(controller.dispose);
          return controller;
        }),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  CharaDetailRecord record(String id) => makeRecord(id: id, card: 1);

  /// Whether a `start` over [ids] began a batch.
  ///
  /// Read off the registry rather than off `Progress`: a batch that began is a
  /// claim of its own kind, and the reading stays true whether or not the
  /// arrangement also holds a zip claim — so the same observable answers both the
  /// declined and the accepted case.
  bool began(ProviderContainer container) {
    return container.read(longReadRegistryProvider).values.any((claim) => claim.kind == LongReadKind.regeneration);
  }

  /// Publishes a zip over [directory] through the notifier `exportDirectoryAsZip`
  /// claims its slot with — the shortest real path into the registry.
  void hold(ProviderContainer container, DirectoryPath directory) {
    expect(container.read(storageZipProgressProvider.notifier).begin(directory), isTrue);
  }

  test('a batch over a held record is declined before it claims anything', () async {
    final container = containerFor();
    hold(container, activeDir() / 'r1');

    await container.read(charaDetailRecordRegenerationControllerProvider.notifier).start([record('r1')]);

    expect(began(container), isFalse, reason: 'the batch would rewrite files the zip has open');
    // Nothing half-started either: a declined batch must leave the progress model
    // alone, or the record table sits behind an overlay for a batch that is not
    // running.
    expect(container.read(charaDetailRecordRegenerationControllerProvider).isCompleted, isTrue);
  });

  test('one held record declines the whole batch, and a batch that misses it is accepted', () async {
    final container = containerFor();
    hold(container, activeDir() / 'r2');

    final controller = container.read(charaDetailRecordRegenerationControllerProvider.notifier);
    await controller.start([record('r1'), record('r2')]);
    expect(began(container), isFalse, reason: 'a batch is one operation; half of it cannot be refused');

    // The control for "any", and the control that separates this gate from "start
    // never begins a batch": a selection that misses the held record still runs,
    // with the zip still in flight.
    await controller.start([record('r1'), record('r3')]);
    expect(began(container), isTrue);
  });

  test('a zip over the whole active store declines every record under it', () async {
    final container = containerFor();
    hold(container, activeDir());

    await container.read(charaDetailRecordRegenerationControllerProvider.notifier).start([record('r1')]);

    expect(began(container), isFalse);
  });

  test(
    'a zip over the write transaction journal declines the batch, and one over the archive journal does not',
    () async {
      // The journal is no record's directory, and it is what this gate used to miss:
      // on web every record the batch rewrites is published through a slot under it,
      // and 「アプリの残骸」 offers a zip and a delete over exactly that directory.
      final container = containerFor();
      hold(container, journalDir());

      await container.read(charaDetailRecordRegenerationControllerProvider.notifier).start([record('r1')]);
      expect(began(container), isFalse, reason: 'the batch would publish through the folder the zip has open');

      // The control that keeps this about the write journal and not about any
      // directory beside `active/`: the archive's own journal is a sibling of the
      // same parent and a re-recognition never writes it.
      container.read(storageZipProgressProvider.notifier).finish();
      hold(container, _pathInfoFor(DirectoryPath(_tempRoot.path)).charaDetailArchiveTransactionDir);
      await container.read(charaDetailRecordRegenerationControllerProvider.notifier).start([record('r1')]);
      expect(began(container), isTrue);
    },
  );

  test('with nothing registered a batch runs exactly as before', () async {
    final container = containerFor();

    await container.read(charaDetailRecordRegenerationControllerProvider.notifier).start([record('r1')]);

    expect(began(container), isTrue, reason: 'the refusal was applied to a batch nothing was holding');
  });

  test('the hold ending lets the same batch through', () async {
    final container = containerFor();
    hold(container, activeDir() / 'r1');
    final controller = container.read(charaDetailRecordRegenerationControllerProvider.notifier);

    await controller.start([record('r1')]);
    expect(began(container), isFalse);

    container.read(storageZipProgressProvider.notifier).finish();
    await controller.start([record('r1')]);
    expect(began(container), isTrue, reason: 'the refusal outlived the reader that caused it');
  });
}
