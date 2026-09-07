/// Whether a folder is small enough for the browser to bundle (stage 5d).
///
/// This is the **decision**, not the refusal, for the same reason
/// `settings_value_render.dart` is separate from the widget that shows its
/// result: a size limit *is* the whole of the browser leg's answer to a folder
/// too big to bundle — the alternative, a Chromium-only streaming write, was
/// declined — so it has to be assertable on its own. It is also the one part of
/// the browser leg that a
/// browser can run — `zip_export_web.dart` reaches `PathEntity`, which reaches
/// `package:flutter`, which `dart2js` cannot build; a limit written in there
/// would be checkable from neither the VM suite nor
/// `dart test --platform chrome`, which is the defect `web_vfs.dart` already
/// carries in this repository.
///
/// **Pure Dart, deliberately.** No imports at all, so both suites compile it.
library;

/// The largest folder the browser leg will bundle, in bytes (256 MiB).
///
/// **Derived from this installation's own data, not from the import side's
/// figure.** `record_zip.dart`'s `defaultMaxTotalUncompressedBytes` is 1 GiB,
/// and 1 GiB — or 512 MiB — refuses *nothing* that exists here: measured on the
/// real store, the largest thing a user can ask for is the active-record group
/// at 459 MB, followed by the unclassified group's `_feedback` at 291 MB. A
/// limit that declines no reachable request is not a limit, and the largest
/// request it would wave through is precisely the one that kills the tab: a
/// browser holds the whole archive in memory while it builds it and peaks at
/// roughly twice the folder's size, so 459 MB is a ~920 MB peak.
///
/// 256 MiB declines those two group-level requests and one selectable folder
/// (`_feedback`), and declines nothing a user does routinely. Measured over the
/// 105 records in this installation's active group, one training record averages
/// 4.37 MB and the **largest is 10.22 MB** (10,223,416 B); the median is 3.99 MB
/// and the 90th percentile 6.36 MB. The upper figure is the one quoted here on
/// purpose: an average invites the next person to tighten this constant until it
/// refuses records that exist, and the tail is more than twice the mean. Even so
/// a single record — the unit the view is actually used on — passes with more
/// than an order of magnitude to spare, and nothing in that sample comes within
/// 25x of the limit.
///
/// The import side's 1 GiB is not wrong for what it guards: it bounds a
/// *crafted* archive arriving from outside. This one bounds a peak the app
/// itself is about to allocate from a source it can measure first, which is a
/// different question with a different answer.
const int storageZipWebMaxTotalBytes = 268435456; // 256 MiB

/// Why a request was declined, or that it was not.
enum StorageZipLimitVerdict {
  /// Small enough to build. The browser leg proceeds to read.
  withinLimit,

  /// Larger than [StorageZipLimitDecision.limitBytes].
  tooLarge,
}

/// The answer, with the two numbers it was decided on.
///
/// [totalBytes] and [limitBytes] travel with the verdict so that the decision
/// reports the figures it was made on and not only its outcome. The limit is
/// injected (`storageZipWebLimitProvider`), so *which* limit was in force cannot
/// be recovered from the verdict alone, and anything that re-derived it could
/// check the decision against a number the decision was not made on.
///
/// **No shipped sentence quotes either figure.** The refusal
/// (`pages.storage.zip.too_large`) names neither the size nor the limit, and its
/// call site in `zip_export_web.dart` deliberately passes no `namedArgs`. Nothing
/// in `lib` reads these two fields today; `storage_zip_web_export_test.dart` is
/// what they exist for.
typedef StorageZipLimitDecision = ({StorageZipLimitVerdict verdict, int totalBytes, int limitBytes});

/// Whether a folder measuring [totalBytes] may be bundled in a browser.
///
/// **The comparison is `>`, so a folder of exactly [limitBytes] is allowed.**
/// Stated because it is the kind of boundary that gets described in prose and
/// then implemented the other way round: the limit is the largest size that
/// still works, not the first size that fails.
///
/// [totalBytes] is what the enumeration measured, and on OPFS that is every
/// file's size — the walk resolves it from the handle it already holds
/// (`fs_metadata_web_test.dart`). An entry whose size the walk could *not*
/// resolve is one that vanished between the listing and the metadata read, and
/// it contributes no bytes to the peak this limit protects, so a lower bound
/// here is not an under-count of the memory at risk.
///
/// **No entry-count limit, and that is a decision rather than an omission.**
/// The import side caps entries at 2000 because it is handed an archive from
/// outside whose declared sizes cannot be trusted — many tiny entries are a
/// zip-bomb shape that a byte cap alone misses. Here the source is the user's
/// own tree and every size is known before the first byte is read, so the byte
/// cap binds first in every case that matters: 2000 files of record content is
/// ~880 MB and is refused on size several times over, while 5000 one-kilobyte
/// files is 5 MB and builds without trouble. A count limit would only decline
/// requests that work.
StorageZipLimitDecision decideStorageZipLimit({required int totalBytes, int limitBytes = storageZipWebMaxTotalBytes}) {
  final verdict = totalBytes > limitBytes ? StorageZipLimitVerdict.tooLarge : StorageZipLimitVerdict.withinLimit;
  return (verdict: verdict, totalBytes: totalBytes, limitBytes: limitBytes);
}
