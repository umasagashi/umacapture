/// The browser leg of the storage view's zip export (stage 5d).
///
/// **Built in memory, and therefore bounded.** A browser has no isolate to
/// spawn (`archive_executor_web.dart`), so the archive is assembled on the same
/// thread that draws the frame and peaks at roughly twice the folder's size
/// That is the constraint the whole leg is shaped by: the action is
/// offered *with* a refusal rule or not at all, because an offer with no limit
/// is an offer to kill the tab.
///
/// **The refusal comes before the read, not during it.** The limit is asked in
/// [platformStorageZipPreflight], which `exportDirectoryAsZip` consults before
/// [platformStorageZipRunner] — so a folder over the limit is declined without a
/// byte of its content being allocated. A guard inside the runner would discover
/// the problem after spending exactly the memory it exists to protect. What the
/// preflight spends instead is one enumeration, which on OPFS carries every
/// file's size with it (`fs_metadata_web_test.dart`) and reads no content.
///
/// **What is decided elsewhere.** The limit, the *shape* of the archive and the
/// assembly of its bytes live in `zip_export_limit.dart` and `zip_bundle.dart`
/// (`decideStorageZipLimit`, `planStorageZipLayout`, `buildStorageZipBytes`),
/// which import no Flutter: this file reaches `PathEntity` and cannot be
/// compiled by `dart2js`, so anything left in here is out of the browser suite's
/// reach — the defect `web_vfs.dart` carries. Those three are what
/// `storage_zip_export_web_test.dart` runs against real OPFS. What is
/// irreducibly left here is the OPFS walk itself, the `is FilePath` test on its
/// results, the byte reads, and the handover to the download seam.
///
/// The progress model, the single-flight guard and the messages are shared
/// (`zip_export.dart`) and need no web counterpart. Progress is still reported
/// per file, but nothing repaints while this runs: the view disables its
/// buttons and the figure is simply the last one written when the frame returns.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/core/path_entity.dart';
import '/src/core/utils.dart';

import 'directory_totals.dart';
import 'file_download.dart';
import 'storage_exclusion.dart';
import 'zip_bundle.dart';
import 'zip_export.dart';
import 'zip_export_limit.dart';

/// The browser offers the action, now that it can refuse the requests it cannot
/// survive; see [storageZipAvailableProvider].
const platformStorageZipAvailable = true;

/// The limit in force, as a dependency rather than as the constant itself.
///
/// Production reads [storageZipWebMaxTotalBytes] and nothing overrides it. The
/// seam exists for the reason `RecordZipService.import` states for its own limit
/// parameters — "tests may inject smaller values instead of constructing
/// multi-megabyte fixtures" — and the alternative is a suite that either builds
/// a 256 MiB fixture on every run or never exercises the refusal at all.
final storageZipWebLimitProvider = Provider<int>((_) => storageZipWebMaxTotalBytes);

/// Measures [directory] and declines it if it is over the limit.
///
/// The measurement is `aggregateDirectoryTotals`, the same walk the tree's size
/// column uses, so the figure quoted in the refusal is the figure the user can
/// see on the row they pressed. It resolves sizes from the listing and never
/// opens a file.
///
/// A folder that does not exist measures zero and is allowed through; the runner
/// then produces an empty archive rather than an error, which is what an empty
/// group is.
Future<String?> platformStorageZipPreflight(RefBase ref, DirectoryPath directory) async {
  final totals = await aggregateDirectoryTotals(directory);
  final decision = decideStorageZipLimit(
    totalBytes: totals.knownBytes,
    limitBytes: ref.read(storageZipWebLimitProvider),
  );
  switch (decision.verdict) {
    case StorageZipLimitVerdict.withinLimit:
      return null;
    case StorageZipLimitVerdict.tooLarge:
      // No `namedArgs`. The approved sentence names neither figure — it says the
      // folder is too large and what to do instead — so a `{size}` / `{limit}`
      // pair would have nowhere to land and `easy_localization` would drop it
      // silently. `storage_wording_test.dart` holds the two sides together in
      // both directions.
      return 'pages.storage.zip.too_large'.tr();
  }
}

/// Reads [directory] whole, zips it in memory, and hands the bytes to the
/// browser's download.
///
/// The enumeration is repeated here rather than carried over from the preflight:
/// the two are separate seams in the shared flow (`zip_export.dart`), and a
/// listing passed between them would be a snapshot of a tree that the second
/// step then reads by name anyway. One extra walk of handles is not one extra
/// read of content.
Future<StorageZipDelivery> platformStorageZipRunner(
  RefBase ref,
  DirectoryPath directory,
  StorageZipProgressSink onProgress,
  StorageExclusionGuard guard,
) async {
  // The group's exclusion covers the enumeration and every byte read, and stops
  // there. The encode below is arithmetic over bytes already in memory, and the
  // handover is the browser's; holding a Web Lock across either would keep other
  // tabs out of the record store for work that no longer touches it.
  final bundle = await guard(() => _readBundle(directory, onProgress));

  final bytes = buildStorageZipBytes(
    rootName: directory.name,
    files: bundle.sources,
    emptyDirectorySegments: bundle.emptyDirectorySegments,
  );
  await ref.read(storageSaveFileProvider)(
    dialogTitle: 'pages.storage.actions.zip_directory'.tr(),
    fileName: '${directory.name}.zip',
    bytes: bytes,
  );
  // Unconditionally a download, and the answer is not read: `file_picker`'s web
  // leg returns `null` whether or not the anchor click succeeded, because a
  // browser download has no path to report (`saveDialogReportsPathProvider`
  // states the same divergence for stage 5b). Treating that `null` as the native
  // leg does would report every successful export as a cancellation.
  return StorageZipDelivery.downloadRequested;
}

/// Walks [directory] and reads every file in it — the part of the export that
/// touches the store, and therefore the part that runs under the exclusion.
Future<({List<StorageZipSourceFile> sources, List<List<String>> emptyDirectorySegments})> _readBundle(
  DirectoryPath directory,
  StorageZipProgressSink onProgress,
) async {
  final listings = await directory.listWithMetadata(recursive: true);
  // Sorting the listing by kind is all of the archive's shape that stays in this
  // file, and it stays because `FilePath` / `DirectoryPath` are the one part of
  // the job that cannot leave: they reach `package:flutter` through
  // `path_entity.dart`, so anything typed on them is unbuildable by `dart2js`
  // and out of `dart test --platform chrome`'s reach. Past the `is` test the
  // values are plain segment lists, and every decision made on them — the
  // relative slicing, which folders need an entry of their own, the ancestor
  // rule — is `planStorageZipLayout` in `zip_bundle.dart`, where both suites run
  // it.
  final files = <FilePath>[];
  final modified = <DateTime?>[];
  final directories = <DirectoryPath>[];
  for (final listing in listings) {
    final entity = listing.entity;
    if (entity is FilePath) {
      files.add(entity);
      // Kept from the enumeration rather than asked for again: the walk already
      // resolved it, and it is what dates the archive's entries. Dropping it
      // here is what made every file in a browser-built archive dated at the
      // moment of export while the native leg preserved them.
      modified.add(listing.modified);
    } else if (entity is DirectoryPath) {
      directories.add(entity);
    }
  }
  final layout = planStorageZipLayout(
    rootSegmentCount: directory.segments.length,
    fileSegments: [for (final file in files) file.segments],
    directorySegments: [for (final child in directories) child.segments],
  );

  final sources = <StorageZipSourceFile>[];
  for (var index = 0; index < files.length; index++) {
    // Paired by index, which `planStorageZipLayout` promises: the bytes still
    // have to be read from the entity, and re-deriving the path here would be a
    // second implementation of the slicing that was just moved out.
    sources.add((
      relativeSegments: layout.fileSegments[index],
      bytes: await files[index].readAsBytes(),
      modified: modified[index],
    ));
    onProgress((index + 1) / files.length);
  }
  return (sources: sources, emptyDirectorySegments: layout.emptyDirectorySegments);
}
