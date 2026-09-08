import 'dart:typed_data';

import 'package:archive/archive.dart';

import '/src/core/fs/web_record_persistence.dart';
import '/src/core/fs/record_recovery_gate.dart';
import '/src/core/fs/web_record_write_transaction.dart';
import '/src/core/path_entity.dart';
import '/src/core/storage/long_read_registry.dart';

/// Why a record the zip carried was not written into the store.
///
/// A closed set, and every member owes the user a sentence
/// (`pages.chara_detail.import.refused.*`): a record that was in the zip and is
/// not in the table afterwards is a record the user has to be told about, and
/// "how many failed" is not enough — [alreadyArchived] calls for no action at
/// all, while [notStored] is a real loss. Collapsing the two into a count would
/// leave the common one reading as a fault.
enum RecordImportRefusal {
  /// The same record id already lives under `archive/`, so publishing it into
  /// `active/` would put one record in two stores at once
  /// ([WebRecordWriteResult.blockedByOtherStore]).
  ///
  /// The expected outcome of re-importing a zip exported from the archive view:
  /// the interchange format packs every record under `chara_detail/active/<id>/`
  /// regardless of the store it came from. The copy the user already has is left
  /// byte-for-byte untouched, so the correct advice is "nothing to do".
  alreadyArchived,

  /// Anything else the store refused or threw on for this record.
  ///
  /// Deliberately one bucket: the remaining reasons (a torn slot, a foreign
  /// manifest, corrupt staging, an outright throw) are all "your record did not
  /// arrive and the log says why", and none of them changes what the user can do
  /// about it here.
  notStored,
}

/// Outcome of a [RecordZipService.import] run.
class RecordImportResult {
  /// Ids of the records whose files were written (one per `<uuid>` directory).
  final Set<String> recordIds;

  /// Number of entries skipped: directory entries, plus the desktop layout's
  /// top-level `labels.json`. Unsafe file entries still reject the import.
  final int skippedEntries;

  /// The records the zip carried that the store did **not** write, by id.
  ///
  /// Derived from every id the store reported a non-committed status for — not
  /// from the failure map alone — so a refusal the store forgot to attach a
  /// reason to still appears here (as [RecordImportRefusal.notStored]) instead
  /// of vanishing between the two maps.
  final Map<String, RecordImportRefusal> refusals;

  const RecordImportResult({
    required this.recordIds,
    required this.skippedEntries,
    this.refusals = const <String, RecordImportRefusal>{},
  });

  int get recordCount => recordIds.length;
}

/// Thrown by [RecordZipService.import] when a zip exceeds one of the
/// decompressed-size or entry-count limits.
///
/// Extends [FormatException] so existing `is FormatException` handling keeps
/// matching it (e.g. a generic import-failure toast), while callers that want
/// to show a dedicated "too large, split the export" message can catch this
/// specific subtype instead. A plain [FormatException] (e.g. the zip-slip
/// rejection in [RecordZipService._parseEntry]) is a different failure mode
/// and must not be conflated with "too large".
class RecordZipTooLargeException extends FormatException {
  const RecordZipTooLargeException(super.message);
}

/// Imports record zips into the record store.
///
/// Two layouts are accepted, because the app produces both:
///
/// * the Stage-4 harness form — `chara_detail/active/<uuid>/<file>`, which
///   [export] and the web `ZipExporter.exportBytes` emit;
/// * the desktop `ZipExporter` form — `<uuid>/<file>` plus a top-level
///   `labels.json`, which `ZipFileEncoder.addDirectory`/`addFile` produce from
///   the record directories' own basenames.
///
/// The desktop layout predates this importer and is what every Windows user's
/// existing exports look like, so rejecting it would make the app unable to read
/// its own export. `labels.json` is a shared side-car, not record content: it is
/// counted as skipped rather than written. Every other entry is validated
/// against those two shapes — zip-slip vectors (absolute paths, `.`/`..`/empty
/// segments) and any mismatching file reject the whole import before persistent
/// storage is touched. Matching files are written under [storageDir]
/// through the async filesystem backend, so the same code path lands records in
/// OPFS on web and on disk on desktop.
///
/// A record id already present under `active/` is overwritten (the writes
/// replace the individual files), matching the design's "uuid collision =
/// overwrite" rule. A record id already present under `archive/` is *refused*
/// instead — one id belongs to one store — and comes back in
/// [RecordImportResult.refusals] as [RecordImportRefusal.alreadyArchived] so the
/// caller can say so rather than dropping the record without a word.
///
/// The service also builds the same layout back out ([export]), so an exported
/// zip re-imports without loss and stays byte-compatible with the Stage-4
/// harness.
class RecordZipService {
  const RecordZipService._();

  /// Builds a Stage-4-compatible zip from the given record directories.
  ///
  /// Reads every file in each record directory through the async filesystem
  /// backend — so the same code path reads records from OPFS on web and from
  /// disk on desktop — and packs them under `chara_detail/active/<uuid>/<file>`,
  /// where `<uuid>` is the record directory's own name. Entries are STORED
  /// (uncompressed) to match the harness exactly; the record files are already
  /// PNG/JPEG/JSON, so deflate would gain little.
  ///
  /// The `active/` segment is a fixed part of the interchange format regardless
  /// of the source the directories came from, so a zip exported from the archive
  /// view names the active store on re-import (mirroring [import]) — which the
  /// write transaction then refuses while the archived copy still exists, and
  /// [import] reports as [RecordImportRefusal.alreadyArchived].
  ///
  /// [declaration] is required and has no default for the same reason the gate's
  /// own argument does: this method reads every file of every record it is given
  /// and is the web leg of an operation whose desktop half declares a claim, so a
  /// caller that announced nothing here would be a silent divergence between the
  /// two legs rather than a decision.
  static Future<Uint8List> export(
    List<DirectoryPath> recordDirs, {
    RecordRecoveryGate? recoveryGate,
    required LongReadDeclaration declaration,
  }) async {
    if (recordDirs.isEmpty) return Uint8List.fromList(ZipEncoder().encodeBytes(Archive()));
    final storageRoots = recordDirs.map((directory) => directory.parent.parent.parent.path).toSet();
    if (storageRoots.length != 1) {
      throw ArgumentError('All exported record directories must share one storage root.');
    }
    final storageRoot = recordDirs.first.parent.parent.parent;
    final gate = recoveryGate ?? platformRecordRecoveryGate;
    return gate.runForRecords(
      storageRoot,
      recordDirs.map((directory) => directory.name),
      declaration: declaration,
      () async {
        final archive = Archive();
        for (final dir in recordDirs) {
          final recordId = dir.name;
          // Record directories are flat (the nine per-record files, no nested
          // directories), so every listed entry is a file; read each through the
          // async backend and store it verbatim.
          await for (final entry in dir.list()) {
            final bytes = await entry.asFilePath.readAsBytes();
            final name = "chara_detail/active/$recordId/${entry.name}";
            archive.addFile(ArchiveFile.noCompress(name, bytes.length, bytes));
          }
        }
        return ZipEncoder().encodeBytes(archive);
      },
    );
  }

  /// Maximum total decompressed size accepted from one import zip.
  ///
  /// Real records measure 4.3-5.5 MB across their 9 files. That was measured
  /// on a set of stitched sample records that is **no longer on this machine**
  /// — it is present neither in the scratch directory it was kept in nor under
  /// `testdata/`, so the figure cannot be re-derived from the tree; treat it as
  /// a recorded observation, not a reproducible one. At 1 GiB an import can
  /// carry roughly 200 records in one archive — far beyond a realistic manual
  /// batch — while still bounding memory use against a crafted or corrupted
  /// archive.
  static const int defaultMaxTotalUncompressedBytes = 1 << 30; // 1 GiB

  /// Maximum number of entries accepted from one import zip.
  ///
  /// ~220 records' worth at 9 files/record. Also blocks the "many tiny
  /// entries" zip-bomb variant, which a total-byte-size cap alone would not
  /// catch.
  static const int defaultMaxEntryCount = 2000;

  /// Maximum decompressed size accepted for a single zip entry.
  ///
  /// The largest file in a real record is `campaign.png` at 2.41 MB — from the
  /// same sample set as [defaultMaxTotalUncompressedBytes] above, which is no
  /// longer on this machine and cannot be re-measured. `import` only ever
  /// receives `active/` entries — the pre-downscale, largest-size case — so
  /// 20 MiB leaves ample margin.
  static const int defaultMaxEntryUncompressedBytes = 20 * 1024 * 1024; // 20 MiB

  /// Decodes [bytes] as a zip and writes every valid record file under
  /// [storageDir], returning which records were written and how many entries
  /// were skipped.
  ///
  /// Rejects the whole import with [RecordZipTooLargeException] (before
  /// [persistFiles] is called, so nothing is written) when the zip has more
  /// than [maxEntryCount] entries, any single entry decompresses past
  /// [maxEntryUncompressedBytes], or the total decompressed size across all
  /// entries passes [maxTotalUncompressedBytes]. The three parameters default
  /// to the production limits above; tests may inject smaller values instead
  /// of constructing multi-megabyte fixtures.
  ///
  /// The two byte-size limits are enforced against the *actual* decompressed
  /// size (via [_BoundedOutputStream]), not the zip header's declared
  /// `entry.size` — `archive` 4.0.9's zip decoder never validates that
  /// declared value against what actually comes out of inflate (no CRC or
  /// output-size check in `ZipFile.getStream()`/`decompress()`), so a crafted
  /// entry can under-report its size and still decompress to anything. See
  /// [_BoundedOutputStream] for how the real limit is enforced and its
  /// residual limitation, which applies on every platform, not just web (both
  /// route through an `archive` decoder that buffers a whole entry before this
  /// guard sees the first byte).
  static Future<RecordImportResult> import(
    Uint8List bytes,
    DirectoryPath storageDir, {
    WebRecordPersistence? persistence,
    int maxTotalUncompressedBytes = defaultMaxTotalUncompressedBytes,
    int maxEntryCount = defaultMaxEntryCount,
    int maxEntryUncompressedBytes = defaultMaxEntryUncompressedBytes,
  }) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    if (archive.length > maxEntryCount) {
      throw RecordZipTooLargeException(
        'Record ZIP has too many entries (${archive.length} > $maxEntryCount); split the export into smaller batches.',
      );
    }
    final files = <RecordPersistenceFile>[];
    var skipped = 0;
    var totalUncompressedBytes = 0;
    for (final entry in archive) {
      if (!entry.isFile) {
        skipped++;
        continue;
      }
      final parsed = _parseEntry(entry.name);
      if (parsed == null) {
        if (_isIgnorableSideCar(entry.name)) {
          // The desktop zip's shared label map. It is not record content and has
          // no record directory to land in, so it is skipped instead of
          // rejecting the whole archive (and is never decompressed).
          skipped++;
          continue;
        }
        throw FormatException('Unsafe or unexpected record ZIP entry: ${entry.name}');
      }

      // Cheap fast path only: `entry.size` is the zip header's self-reported
      // uncompressed size. A well-formed zip reports it correctly, so this
      // rejects an honestly-oversized entry without spending any time on
      // decompression. It is not the real guard -- see below.
      if (entry.size > maxEntryUncompressedBytes) {
        throw RecordZipTooLargeException(
          'Record ZIP entry "${entry.name}" is too large (${entry.size} > $maxEntryUncompressedBytes bytes); '
          'split the export into smaller batches.',
        );
      }
      final remainingTotalBudget = maxTotalUncompressedBytes - totalUncompressedBytes;
      if (remainingTotalBudget <= 0) {
        throw RecordZipTooLargeException(
          'Record ZIP exceeds the total size limit ($maxTotalUncompressedBytes bytes); split the export into smaller batches.',
        );
      }

      // The real guard: cap the entry's *actual* decompressed byte count,
      // not its declared one, to whichever is smaller of the per-entry limit
      // and what's left of the total budget, so one entry can never blow
      // past either limit regardless of what its header claims.
      final entryLimit = maxEntryUncompressedBytes < remainingTotalBudget
          ? maxEntryUncompressedBytes
          : remainingTotalBudget;
      final tooLargeMessage = maxEntryUncompressedBytes <= remainingTotalBudget
          ? 'Record ZIP entry "${entry.name}" decompresses past the $maxEntryUncompressedBytes byte '
                'per-entry limit; split the export into smaller batches.'
          : 'Record ZIP exceeds the total size limit ($maxTotalUncompressedBytes bytes); '
                'split the export into smaller batches.';
      final output = _BoundedOutputStream(entryLimit, tooLargeMessage);
      entry.decompress(output);
      final content = Uint8List.fromList(output.getBytes());
      totalUncompressedBytes += content.length;

      final (recordId, fileName) = parsed;
      files.add((recordId: recordId, relativeSegments: [fileName], bytes: content));
    }
    final result = await (persistence ?? platformWebRecordPersistence).persistFiles(storageDir, files);
    return RecordImportResult(recordIds: result.committedIds, skippedEntries: skipped, refusals: _refusals(result));
  }

  /// The non-committed half of [result], classified into the reasons the import
  /// UI has a sentence for.
  ///
  /// Walks the *statuses* — the store's own record of what it was asked to write
  /// — rather than the failure map, so a record that neither committed nor
  /// recorded a reason is still reported. Losing it here would put the silence
  /// back one layer down from where it was found.
  static Map<String, RecordImportRefusal> _refusals(WebRecordPersistenceResult result) {
    return {
      for (final id in result.statuses.keys)
        if (!result.committed(id))
          id: result.failures[id] == WebRecordWriteResult.blockedByOtherStore
              ? RecordImportRefusal.alreadyArchived
              : RecordImportRefusal.notStored,
    };
  }

  /// Parses a zip entry path, returning `(recordId, fileName)` when it matches
  /// one of the two accepted layouts, or `null` when it does not.
  ///
  /// Accepted: `chara_detail/active/<uuid>/<file>` (the harness / web form) and
  /// `<uuid>/<file>` (the desktop form). The two are disjoint by segment count,
  /// so neither can be read as the other.
  ///
  /// Splitting on both separators and rejecting `.`/`..`/empty segments closes
  /// the zip-slip vector for both: no accepted path can escape the `active/`
  /// directory, since only the last segment is ever used as a file name and only
  /// one segment is ever used as a record id.
  static (String, String)? _parseEntry(String name) {
    final segments = name.split(RegExp(r"[/\\]"));
    if (segments.any((s) => s.isEmpty || s == "." || s == "..")) {
      return null;
    }
    if (segments.length == 2) {
      return (segments[0], segments[1]);
    }
    if (segments.length != 4 || segments[0] != "chara_detail" || segments[1] != "active") {
      return null;
    }
    return (segments[2], segments[3]);
  }

  /// Whether [name] is a known non-record file of the desktop zip layout.
  ///
  /// Only the exact top-level `labels.json` the desktop exporter adds: an
  /// unknown root file still rejects the import, so this stays a targeted
  /// allowance rather than a general "ignore what we do not understand" rule.
  static bool _isIgnorableSideCar(String name) {
    final segments = name.split(RegExp(r"[/\\]"));
    return segments.length == 1 && segments.single == "labels.json";
  }
}

/// An [OutputMemoryStream] that throws [RecordZipTooLargeException] the
/// instant the number of bytes written would exceed [_limit].
///
/// `ArchiveFile.decompress(output)` (used by [RecordZipService.import])
/// writes decoded bytes into whatever [OutputStream] it is given, so passing
/// an instance of this class enforces the limit against the real
/// decompressed size as it is produced, not the zip header's self-reported
/// (and possibly understated) `entry.size`.
///
/// This does *not* bound peak memory during decompression, on any platform —
/// `dart:io` included. That is measured, not inferred from reading decoder
/// source, per this project's "measure before hypothesizing" rule: feeding a
/// 600 MiB entry through `entry.decompress(probe)` on the `dart:io` VM logged
/// 10,004 `writeBytes` calls, with the *first* call landing 359 ms into a
/// 646 ms total run — i.e. the entire 600 MiB was already inflated and
/// sitting in memory before this guard ever saw a byte.
///
/// The cause is `archive` 4.0.9's zlib glue on both platforms, not a
/// difference between them: `_zlib_decoder_io.dart` drives `dart:io`'s
/// `ZLibCodec` through `ChunkedConversionSink.withCallback`, whose
/// `_SimpleCallbackSink` (`dart:convert`'s `chunked_conversion.dart:35-48`)
/// accumulates every chunk internally and only invokes the callback — our
/// `output` sink — from `close()`, once decompression is complete. The
/// pure-Dart web decoder (`_zlib_decoder_web.dart`) also hands over the whole
/// entry in one `writeBytes` call, for its own (unrelated) reasons. Either
/// way, this class's checks fire only after the full entry is already
/// materialized, so there is no mid-decompression abort on this version of
/// `archive`, on either platform.
///
/// What this guard *does* still guarantee, on every platform: an oversized
/// buffer is rejected the instant it arrives, before anything is added to
/// the result set or persisted, so [RecordZipService.import] never writes
/// oversized content to disk/OPFS. It protects data-at-rest integrity, not
/// peak transient memory — a crafted zip of roughly 40 KiB can force a
/// several-hundred-MiB transient allocation on Windows desktop just as
/// easily as in a web renderer; this is not a web-only OOM risk. Closing that
/// gap needs a streaming inflate (a custom implementation or a different
/// package), which is out of scope here. The gap is a limitation of
/// `archive`'s decoders, not a design flaw in this guard.
class _BoundedOutputStream extends OutputMemoryStream {
  _BoundedOutputStream(this._limit, this._message);

  final int _limit;
  final String _message;

  void _guard(int additionalBytes) {
    if (length + additionalBytes > _limit) {
      throw RecordZipTooLargeException(_message);
    }
  }

  @override
  void writeByte(int value) {
    _guard(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _guard(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _guard(stream.length);
    super.writeStream(stream);
  }
}
