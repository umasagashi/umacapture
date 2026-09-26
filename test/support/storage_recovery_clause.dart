// What a delete's result panel says about a transaction slot recovery could not empty, asserted on a
// failure the real delete produced rather than on a detail built by hand.
import 'package:flutter_test/flutter_test.dart';
import 'package:umacapture/src/core/fs/record_recovery_reason.dart';
import 'package:umacapture/src/core/storage/storage_delete.dart';

/// Expects [failure] to be the refusal a delete reports for a slot recovery left undrained: the
/// recovery-incomplete reason, a detail carrying [recordId] and [reason] as recovery facts — not a
/// thrown error, whose `toString` the survivor row would show verbatim — and a rendering that is the
/// shipped sentence for those facts.
///
/// Needs `loadAppTranslations`: an unloaded localization renders every key as itself, which this
/// refuses, so a suite that forgot it fails here instead of comparing two keys.
void expectRecoveryIncompleteFailure(
  StorageDeleteFailure failure, {
  required String? recordId,
  required RecordRecoveryIncompleteReason reason,
}) {
  expect(failure.reason, StorageDeleteFailureReason.recoveryIncomplete);
  expect(
    failure.detail,
    isA<StorageDeleteRecoveryIncompleteDetail>()
        .having((detail) => detail.recordId, 'recordId', recordId)
        .having((detail) => detail.reason, 'reason', reason),
    reason: 'the survivor row has to render the recovery facts, not a thrown error in whatever words it holds',
  );
  final shown = storageDeleteFailureDetailText(failure.detail);
  expect(shown, storageRecoveryIncompleteDetail(recordId: recordId, reason: reason));
  expect(shown, isNot(contains('pages.storage.')), reason: 'the recovery sentence did not resolve to a translation');
}
