// What each [RootMaintenanceReason] may be answered from, asked of the memo
// table that answers it.
//
// In its own file rather than in `root_storage_maintenance_test.dart`: this is
// about the *reason* a caller states and the one decision the sweep takes off
// it, and the case has to stay readable as the third caller of `runForRoot`
// arrives with a fourth reason.
//
// Run: .fvm/flutter_sdk/bin/flutter test test/root_maintenance_reason_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/record_recovery_reason.dart';
import 'package:umacapture/src/core/fs/root_storage_maintenance.dart';
import 'package:umacapture/src/core/fs/root_storage_maintenance_shared.dart';
import 'package:umacapture/src/core/fs/web_record_write_transaction.dart';
import 'package:umacapture/src/core/path_entity.dart';
import 'package:umacapture/src/core/providers.dart';

void main() {
  late Directory tempRoot;
  late DirectoryPath dataRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('uma_root_maintenance_reason');
    dataRoot = DirectoryPath(tempRoot.path) / 'chara_detail';
  });
  tearDown(() => tempRoot.deleteSync(recursive: true));

  /// A maintenance object whose write-journal pass reports one slot it could not
  /// drain, and counts how many times it was asked.
  ///
  /// The stub is what makes "the sweep ran" observable at all: a real pass over
  /// an empty journal returns the same empty outcome whether it ran or was
  /// answered from the memo, which is precisely the confusion this case is about.
  ({JournalRootStorageMaintenance maintenance, List<int> sweeps}) maintenanceOverOneSlot() {
    final sweeps = <int>[];
    final slot = charaDetailWriteTransactionDirOf(dataRoot) / 'v1' / 'stranded';
    Directory(slot.path).createSync(recursive: true);
    return (
      maintenance: JournalRootStorageMaintenance.writeJournalOnly(
        recoverWrites: (root) async {
          sweeps.add(sweeps.length);
          return [
            WebRecordWriteRecovery(
              recordId: 'stranded-record',
              result: WebRecordWriteResult.incomplete,
              slot: slot,
              reason: RecordRecoveryIncompleteReason.unresumableState,
            ),
          ];
        },
        quarantineForeignArchiveSlots: (root) async => [],
      ),
      sweeps: sweeps,
    );
  }

  Future<RootMaintenanceOutcome> ask(JournalRootStorageMaintenance maintenance, RootMaintenanceReason reason) {
    return maintenance.runUnlocked(RootStorageMaintenanceRequest(recordDataRoot: dataRoot, reason: reason));
  }

  test('beforeRewritingRecords is never answered from the sweep memo', () async {
    final (:maintenance, :sweeps) = maintenanceOverOneSlot();

    // The memo is set by a successful sweep, and only by one.
    final first = await ask(maintenance, RootMaintenanceReason.readyToUse);
    expect(sweeps, hasLength(1));
    expect(first.undrained, hasLength(1), reason: 'the stub reported nothing, so nothing below is being measured');

    // The control, and it is the half that makes the case separable: the memo
    // really does answer the cheap reason, so a second sweep below cannot be a
    // memo that never worked.
    final memoized = await ask(maintenance, RootMaintenanceReason.readyToUse);
    expect(sweeps, hasLength(1), reason: 'the memo stopped answering readyToUse');
    expect(memoized.undrained, isEmpty, reason: 'a memoized answer says what this call swept, which is nothing');

    // The case: the merge is about to rewrite records from memory, so a slot the
    // sweep might publish has to be looked for now and not remembered from
    // before.
    final beforeRewrite = await ask(maintenance, RootMaintenanceReason.beforeRewritingRecords);
    expect(sweeps, hasLength(2), reason: 'the merge was handed a memo of a sweep taken before its own session wrote');
    expect(
      beforeRewrite.undrained,
      hasLength(1),
      reason: 'the undrained slot is what the merge refuses on; a memoized RootMaintenanceOutcome.none hides it',
    );

    // Its sibling, unchanged: both reasons whose caller acts on the answer sweep
    // every time, and this is the one that was already like that.
    final beforeDelete = await ask(maintenance, RootMaintenanceReason.beforeDestroyingJournals);
    expect(sweeps, hasLength(3));
    expect(beforeDelete.undrained, hasLength(1));
  });
}
