// The long-read refusal in front of a data-root relocation.
//
//   .fvm/flutter_sdk/bin/flutter test test/data_root_migration_long_read_gate_test.dart
//
// WHAT THESE CASES ARE TRYING TO FALSIFY, in one sentence: *a relocation renames
// `storage/`, `modules/` or the settings box away while a registered long reader
// is holding one of them.*
//
// WHY THIS IS NOT ALREADY COVERED BY THE ROOT RECORD SCOPE. `migrate` takes the
// exclusive root scope before it closes Hive, and a relocation that cannot get it
// reports `refusedSessionIntact` — which is why the relocation looks at first
// sight like a surface that could not be hurt. It can. The scope is not
// what a long reader takes: `StorageZipProgress.begin` and
// `CharaDetailRecordRegenerationController.start` both claim the registry
// directly, with no gate and therefore no lock, so a relocation started while a
// zip is bundling the active store acquires the scope with nothing in its way.
// The registry is the only place that collision is written down.
//
// AND IT IS ALSO THE WAIT. For a holder that *does* take the scope, the
// acquisition waits out its whole timeout first, with the dialog showing
// 「データを移行しています」 for a copy that has not begun and will not happen. The
// refusal below reaches the same outcome at once.
//
// WHY THE REFUSAL IS SHAPED UNLIKE THE RECORD SURFACES'. Those grey a confirm and
// put the reason in the dialog body. This one is answered by an outcome the
// dialog already ships a sentence for (`pages.settings.storage.dialog.refused`, reached
// through [MigrationOutcome.sessionUsable] with the back/close buttons that go
// with it), so no second sentence is written and nothing is greyed with no
// explanation beside it.
//
// WHO ASKS. The relocation's own claim, `dataRootRelocationLongReadDeclaration`:
// it asks the registry in the turn it registers and refuses, so there is no
// answer computed at the dialog for a reader to arrive after. Every case below
// hands `migrate` that real declaration over a real registry.
//
// WHAT THIS SUITE DOES NOT REACH.
//  * The dialog's own wiring. `_DataRootMigrationDialog._migrate` is private, so
//    that it passes this declaration is not asserted through the widget; the
//    dialog asks nothing of the registry itself, so there is no second
//    answer for it to get wrong, only the choice of declaration.
//  * Web, where `migrate` refuses before any of this on `kIsWeb`.
//  * A real relocation racing a real zip on disk. The refusal exists so that
//    timing is unreachable; asserting the damage would be asserting the defect.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/data_root_migration.dart';
import 'package:umacapture/src/core/fs/record_mutation_lock.dart';
import 'package:umacapture/src/core/fs/record_recovery_gate.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';
import 'package:umacapture/src/core/storage/long_read_registry.dart';
import 'package:umacapture/src/core/storage/zip_export.dart';

import 'support/localization.dart';

late Directory _tempRoot;
late PathInfo _source;
late DirectoryPath _target;

ProviderContainer _container() {
  final container = ProviderContainer.test();
  addTearDown(container.dispose);
  return container;
}

bool _relocated() => (_target / 'storage' / 'chara_detail' / 'active' / 'rec-1').existsSync();

/// What one relocation attempt did: its outcome, and whether it reached the root lock.
typedef _Attempt = ({MigrationOutcome outcome, bool sessionUsable, bool lockEntered});

/// Runs a relocation with the declaration the dialog passes, over [container]'s registry.
///
/// The lock refuses rather than running the copy: a relocation past it calls
/// `StorageBox.markHiveClosed()`, which is one-way for the process. Reaching the lock at all is
/// the difference these cases measure — a refusal by the claim comes before it, so a refused
/// attempt never enters.
Future<_Attempt> _attempt(ProviderContainer container, DataRootMigrationController controller) async {
  var lockEntered = false;
  final gate = RecordRecoveryGate(
    mutationLock: RecordMutationLock((name, mode, action) async {
      lockEntered = true;
      throw const RecordMutationLockBusy('record-root', Duration(seconds: 1));
    }),
  );
  final outcome = await controller.migrate(
    _target,
    isCapturing: false,
    declaration: dataRootRelocationLongReadDeclaration(container.read(containerRefProvider), controller),
    recoveryGate: gate,
  );
  return (outcome: outcome, sessionUsable: outcome.sessionUsable, lockEntered: lockEntered);
}

/// Whether a relocation attempted now is refused by its claim (never reaches the lock).
Future<bool> _refused(ProviderContainer container, DataRootMigrationController controller) async {
  final attempt = await _attempt(container, controller);
  expect(attempt.outcome, MigrationOutcome.refusedSessionIntact, reason: 'both exits here are refusals');
  expect(
    container.read(longReadRegistryProvider).values.where((claim) => claim.kind == LongReadKind.relocate),
    isEmpty,
    reason: 'a refused or finished attempt must not leave its claim behind',
  );
  return !attempt.lockEntered;
}

void _hold(ProviderContainer container, DirectoryPath directory) {
  expect(
    container.read(storageZipProgressProvider.notifier).begin(directory),
    isTrue,
    reason: 'the slot must have been free for the arrangement under test to mean anything',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppTranslations);

  setUp(() {
    _tempRoot = Directory.systemTemp.createTempSync('uma_relocation_gate');
    _source = PathInfo(
      documentDir: DirectoryPath('${_tempRoot.path}/documents'),
      supportDir: DirectoryPath('${_tempRoot.path}/support'),
      executableDir: DirectoryPath('${_tempRoot.path}/exe'),
      downloadDir: DirectoryPath('${_tempRoot.path}/downloads'),
    );
    _target = DirectoryPath(Directory('${_tempRoot.path}/target')..createSync(recursive: true));
    final record = _source.charaDetailActiveDir / 'rec-1';
    record.toDirectory().createSync(recursive: true);
    record.filePath('record.json').writeAsStringSync('{}');
  });

  tearDown(() {
    if (_tempRoot.existsSync()) _tempRoot.deleteSync(recursive: true);
  });

  group('what the relocation\'s claim asks before it starts one', () {
    test('a zip anywhere under a moved tree refuses it, and one outside them does not', () async {
      final container = _container();
      final controller = DataRootMigrationController(source: _source);

      // The control first: with nothing registered the attempt reaches the lock,
      // so a refusal below cannot come from a claim that always refuses.
      expect(await _refused(container, controller), isFalse);

      _hold(container, _source.charaDetailActiveDir / 'rec-1');
      expect(
        await _refused(container, controller),
        isTrue,
        reason: 'a record inside `storage/` is inside a tree the relocation renames away',
      );
      container.read(storageZipProgressProvider.notifier).finish();

      // The other control: a directory the relocation does not move. `downloads/`
      // is where a zip is *written*, and nothing about writing one there should
      // stop a relocation.
      _hold(container, _source.downloadDir);
      expect(await _refused(container, controller), isFalse);
    });

    test('a live capture is stopped rather than refused for, so it alone does not refuse', () async {
      // WHAT THIS CASE IS TRYING TO FALSIFY, in one sentence: *a relocation started while the user
      // is capturing is turned away with 「他の処理がレコードを使用中」 instead of stopping the
      // capture and going ahead.*
      //
      // `LongReadKind.liveCapture` holds the record store for the whole of a session, and
      // `movedRoots` contains it, so the plain fold answers "held" for every relocation attempted
      // during a capture. `migrate` already takes `isCapturing` and `stopCapture` — its doc states
      // that the flag is there so the capture can be stopped and not so the relocation can be
      // refused — and this exclusion is what keeps that decision intact now that the same fact is
      // also on the registry. The exclusion is data the declaration carries
      // (`disregarding`), so this case builds the real declaration.
      final container = _container();
      final controller = DataRootMigrationController(source: _source);
      final registry = container.read(longReadRegistryProvider.notifier);

      final capture = registry.claimUntilReleased(
        kind: LongReadKind.liveCapture,
        paths: [_source.charaDetailActiveDir],
      );
      expect(await _refused(container, controller), isFalse, reason: 'a live capture is this seam\'s to stop');

      // The control, over the very same path: any other kind holding it still refuses, so the pass
      // above comes from the kind and not from a claim that stopped seeing the tree.
      final other = registry.claimUntilReleased(kind: LongReadKind.zip, paths: [_source.charaDetailActiveDir]);
      expect(await _refused(container, controller), isTrue);

      // And once that holder lets go, the relocation is allowed again: the refusal is the holder's,
      // not a state the attempt left behind.
      registry.release(other);
      expect(await _refused(container, controller), isFalse);
      registry.release(capture);
    });

    test('the trees asked about are the ones the copy moves, not a second list', () {
      // The claim (which is also the question) and the copy both read `movedRoots`; a fourth
      // tree added to the migration therefore moves all three at once. Asserted
      // as an identity rather than by re-listing the three, because re-listing
      // them here is precisely the failure this arrangement exists to prevent.
      final controller = DataRootMigrationController(source: _source);
      expect(controller.movedRoots.map((root) => root.path), controller.pairs(_source).map((pair) => pair.src.path));
      expect(controller.movedRoots, isNotEmpty);
    });
  });

  group('the refusal itself', () {
    test('a relocation refused by its claim moves nothing and never reaches the lock', () async {
      final container = _container();
      final controller = DataRootMigrationController(source: _source);
      _hold(container, _source.charaDetailActiveDir / 'rec-1');

      final attempt = await _attempt(container, controller);

      expect(attempt.outcome, MigrationOutcome.refusedSessionIntact);
      expect(
        attempt.sessionUsable,
        isTrue,
        reason: 'nothing was closed, so the dialog must offer the way back rather than quit/restart',
      );
      expect(
        attempt.lockEntered,
        isFalse,
        reason: 'the refusal has to come before the wait, or it saves the user nothing',
      );
      expect(_relocated(), isFalse);
      expect(
        container.read(longReadRegistryProvider).values.map((claim) => claim.kind),
        [LongReadKind.zip],
        reason: 'a refused claim registers nothing of its own',
      );
    });

    test('the same arrangement with nothing held reaches the lock, so the refusal is what stopped it', () async {
      // The control the case above cannot be. Same gate, same target, same
      // directories on disk; only whether anything is holding them differs.
      final attempt = await _attempt(_container(), DataRootMigrationController(source: _source));

      expect(
        attempt.lockEntered,
        isTrue,
        reason: 'the claim refuses every relocation, so the case above proves nothing',
      );
    });
  });

  test('the sentence the refused relocation shows names the reason, and does not ask for a restart', () {
    // The shipped string this refusal reaches, read as a literal out of `ja.json`:
    // `.tr()` renders a missing key as the key, so a comparison against another
    // `.tr()` of the same key would hold whether or not the key exists.
    final refused = appSentenceAt('pages.settings.storage.dialog.refused');
    expect(refused, contains('使用中'), reason: 'the reason is what makes waiting the obvious response');
    expect(refused, contains('移行'));
    // The other half of `sessionUsable`: this outcome closed nothing, so the
    // sentence must not tell the user to quit or relaunch. Those belong to the
    // outcome that did close Hive, which has a sentence of its own.
    expect(refused, isNot(contains('再起動')));
    expect(refused, isNot(appSentenceAt('pages.settings.storage.dialog.failure')));
  });

  test('the sentence tells the user to wait for whatever is holding it, not for one named job', () {
    // The third clause said 「起動直後の読み込みが終わるまで待ってから」 — wait for the
    // load that runs at startup. That named *one* of the things this outcome
    // covers. `refusedSessionIntact` is returned for a bulk scan (which is the
    // startup load), for the one-time archive repair, for another relocation, for
    // every mutation that takes the shared root gate, and — since the registry
    // reached this dialog — for a zip, an export, a regeneration or a module
    // install that took no lock at all. A user waiting for their zip to finish was
    // told to wait for something that had finished minutes ago.
    //
    // Asserted as "does not narrow" rather than as a fixed clause: the wording may
    // be re-edited, and only a re-edit that goes back to naming one job has to
    // come back here. The clause's referent is checked too — 「他の処理」 appears in
    // the first clause as well, so the remedy points at the same subject the cause
    // named instead of introducing a new one.
    final refused = appSentenceAt('pages.settings.storage.dialog.refused');
    expect(refused, contains('他の処理'));
    expect(
      refused,
      isNot(contains('起動直後')),
      reason: 'the remedy names one of the four kinds of holder this outcome covers, and is wrong for the rest',
    );
    // The general control on the same idea: it names no registered long reader
    // either, for the reason `longReadBusyMessage` gives.
    for (final word in ['ZIP', 'アーカイブ', 'エクスポート', '再認識', 'モジュール']) {
      expect(refused, isNot(contains(word)), reason: word);
    }
  });
}
