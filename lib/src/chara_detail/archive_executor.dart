/// Platform-selected archive execution boundary.
///
/// Callers use [archiveRecords] for both desktop and web. The desktop
/// implementation keeps its atomic native rename in one worker isolate, while
/// both platforms share the asynchronous post-archive cleanup workflow.
///
/// Why the *move* itself is not shared, when everything after it is: archiving a
/// record has to relocate a whole directory from `active/` to `archive/` without
/// ever leaving it visible in both places or in neither. The native filesystem
/// gives that for free — a same-volume `rename` is atomic, so
/// [archiveRecordOnNative] can move the tree in one call and treat any failure as
/// "nothing happened". OPFS has no atomic directory rename: web has to copy the
/// tree entry by entry and then erase the source, which is interruptible at every
/// step. [archiveRecordAsync] therefore drives a [RecordDirectoryTransaction],
/// whose on-disk manifest is what lets a reload resume or roll back a half-moved
/// record ([recoverArchiveTransactions]). The manifest is not a stylistic choice:
/// it is the substitute for the atomicity the platform does not provide.
///
/// Locking is *not* part of that divergence, and both entry points take the
/// record mutation lock. They differ only in where: web locks per record inside
/// [archiveRecordAsync] (its transaction is the unit that must be exclusive),
/// desktop locks the whole batch on the main isolate around the `compute` call,
/// because a lock taken inside a spawned isolate excludes nothing on the isolate
/// where every other desktop mutation runs. See `archive_executor_io.dart`.
///
/// *Thread placement* is a third, one-sided difference, and the platform, not a
/// preference, decides it: desktop puts the whole batch in a `compute` isolate,
/// web has no isolate to put it in. See `archive_executor_web.dart` and the doc
/// of `convertPngBatchAsync` in `image_converter.dart` for the constraint and
/// what it costs a web user.
///
/// The cost of keeping the two is a crash-recovery state machine only web
/// exercises. Collapsing onto the transactional path for both (desktop would gain
/// resumable archives, at two small manifest files per record) is a real option,
/// deliberately not taken on this branch. Revisit if a third archive behaviour
/// appears.
library;

export 'archive_executor_shared.dart'
    show
        archiveRecordAsync,
        archiveRecordOnNative,
        archiveRecordsAsync,
        archiveRecordsOnNative,
        recoverArchiveTransactions;
export 'archive_executor_types.dart';
export 'archive_executor_io.dart' if (dart.library.js_interop) 'archive_executor_web.dart' show archiveRecords;
