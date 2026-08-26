import '/src/core/fs/record_recovery_gate.dart';

import 'archive_executor_shared.dart';
import 'archive_executor_types.dart';

/// Archives the batch through the async OPFS-safe implementation.
///
/// No wrapping lock here, unlike the desktop twin: [archiveRecordAsync] already
/// takes each record's lock around its own transaction, and the locks are not
/// re-entrant, so a batch-level acquisition would wait for itself.
///
/// The batch also stays on the UI thread end to end, which the desktop twin's
/// does not. The desktop wrapper exists partly to put the work in a `compute`
/// isolate; web has no isolate to spawn (`Isolate.spawn` throws
/// `UnsupportedError` there and Flutter's web `compute` is a same-thread call),
/// so there is nothing to wrap. The visible cost is the per-image decode/encode
/// block in `convertPngBatchAsync` (`image_converter.dart`), whose doc carries
/// the constraint, the measured per-image cost, and the worker alternatives that
/// were considered and rejected.
Future<List<bool>> archiveRecords(ArchiveBatchArgs args, {RecordRecoveryGate? recoveryGate}) =>
    archiveRecordsAsync(args, recoveryGate: recoveryGate);
