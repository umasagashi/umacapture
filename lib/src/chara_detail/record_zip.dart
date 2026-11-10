import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';

import '/src/chara_detail/archive_executor_shared.dart';
import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/record_archive_state.dart';
import '/src/chara_detail/record_binding.dart';
import '/src/chara_detail/record_body.dart';
import '/src/chara_detail/record_export_shape.dart';
import '/src/chara_detail/record_notes.dart';
import '/src/chara_detail/record_operation.dart';
import '/src/chara_detail/record_sync_merge.dart';
import '/src/chara_detail/value_write_time.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/fs/web_record_persistence.dart';
import '/src/core/fs/record_recovery_gate.dart';
import '/src/core/fs/web_record_write_transaction.dart';
import '/src/core/path_entity.dart';
import '/src/core/utils.dart';
import '/src/core/storage/long_read_registry.dart';

/// Why a record the zip carried was not written into the store.
///
/// A closed set, and every member owes the user a sentence
/// (`pages.chara_detail.import.refused.*`): a record that was in the zip and is
/// not in the table afterwards is a record the user has to be told about, and
/// "how many failed" is not enough — [duplicateOfExisting] calls for no action
/// at all, while [notStored] is a real loss. Collapsing the two into a count
/// would leave the common one reading as a fault.
enum RecordImportRefusal {
  /// The store already holds a record with this one's contents under a different
  /// id, so writing it would put the same chara in the table twice.
  ///
  /// The zip format addresses records by id, and an id collision is an overwrite;
  /// content duplication is a separate question, asked here so that a record
  /// exported, re-captured and imported again does not arrive as a second row of
  /// the same chara. Decided with the capture path's own duplicate rule, so the
  /// two entrances to the store agree on what "the same record" is.
  duplicateOfExisting,

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

  /// The records this import actually wrote, decoded.
  ///
  /// A selection is imported one zip at a time, so the caller weighing a later
  /// zip against "what this selection has already taken" needs the records
  /// themselves and not just their ids. Only committed ones are listed: a record
  /// that failed to persist is not in the store and must not withhold a copy of
  /// it that arrives later.
  final List<CharaDetailRecord> acceptedRecords;

  const RecordImportResult({
    required this.recordIds,
    required this.skippedEntries,
    this.refusals = const <String, RecordImportRefusal>{},
    this.acceptedRecords = const <CharaDetailRecord>[],
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

/// The device's records an import reads before its batch ([RecordZipService._donorsFor]): id → binding, and id → the
/// image files of those a record of the zip can take images from.
typedef _Donors = ({Map<String, RecordBinding?> bindings, Map<String, Map<String, Uint8List>> images});

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
/// Each record is made the record the zip carries ([_importPublication]): its
/// body, the ids it absorbed and its archive state are the zip's, it lands in
/// the store that state is held in — taken out of the other store where that
/// one held it, as one id belongs to one store — and its images follow its body.
/// The ratings, memos and dismissed pairs of the id are not in the record
/// directory and are not touched.
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
  /// disk on desktop — and packs them, as the export table says
  /// (`recordFileForExport`), under `chara_detail/active/<uuid>/<file>`,
  /// where `<uuid>` is the record directory's own name. Entries are STORED
  /// (uncompressed) to match the harness exactly; the record files are already
  /// PNG/JPEG/JSON, so deflate would gain little.
  ///
  /// The `active/` segment is a fixed part of the interchange format regardless
  /// of the source the directories came from: the store a record is in follows
  /// from its archive state, which `archive.json` carries, and [import] places
  /// it by that.
  ///
  /// [declaration] is required and has no default for the same reason the gate's
  /// own argument does: this method reads every file of every record it is given
  /// and is the web leg of an operation whose desktop half declares a claim, so a
  /// caller that announced nothing here would be a silent divergence between the
  /// two legs rather than a decision.
  static Future<Uint8List> export(
    List<DirectoryPath> recordDirs, {
    required RefBase ref,
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
        // The binding goes out with each record, placed first where the record
        // carries none; the zip carries it even where `record.json` could not
        // be rewritten.
        final recordJsons = await placeRecordBindingsUnlocked(ref, recordDirs);
        for (final dir in recordDirs) {
          final recordId = dir.name;
          final recordJson = recordJsons[dir.path];
          // Record directories are flat (the per-record files, no nested
          // directories), so every listed entry is a file; each is packed as the
          // export table says, and one it leaves on the device is not read.
          await for (final entry in dir.list()) {
            if (recordFileExportOf(entry.name) == RecordFileExport.left) continue;
            final stored = entry.name == 'record.json' && recordJson != null
                ? recordJson
                : await entry.asFilePath.readAsBytes();
            final bytes = recordFileForExport(entry.name, stored);
            if (bytes == null) continue;
            final name = "chara_detail/active/$recordId/${entry.name}";
            archive.addFile(ArchiveFile.noCompress(name, bytes.length, bytes));
          }
          if (await exportedArchiveNoteOf(dir) case final note?) {
            final name = "chara_detail/active/$recordId/$recordArchiveNoteName";
            archive.addFile(ArchiveFile.noCompress(name, note.length, note));
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
    bool Function(CharaDetailRecord record, Iterable<CharaDetailRecord> stored)? isDuplicate,
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
      files.add((
        recordId: recordId,
        relativeSegments: [fileName],
        bytes: fileName == "record.json" ? _upgradedRecordJson(content) : content,
      ));
    }
    final result = await importFiles(files, storageDir, persistence: persistence, isDuplicate: isDuplicate);
    return RecordImportResult(
      recordIds: result.recordIds,
      skippedEntries: skipped,
      refusals: result.refusals,
      acceptedRecords: result.acceptedRecords,
    );
  }

  /// Writes the record files [files] into the store under [storageDir], each record as the record its files hold
  /// ([_importPublication]), and returns which records were written and which were refused: the way into the store
  /// that every import shares, whatever brought the files — a zip ([import]) or a shared record's link
  /// (`record_link_import.dart`) —, so the duplicate rule, the images and the archive state are decided once.
  ///
  /// [files] are trusted to be record files by name (`relativeSegments` one segment, a record id one directory):
  /// the caller is the one that validated where they came from. [RecordImportResult.skippedEntries] is zero.
  static Future<RecordImportResult> importFiles(
    List<RecordPersistenceFile> files,
    DirectoryPath storageDir, {
    WebRecordPersistence? persistence,
    bool Function(CharaDetailRecord record, Iterable<CharaDetailRecord> stored)? isDuplicate,
  }) async {
    final grouped = <String, List<RecordPersistenceFile>>{};
    for (final file in files) {
      grouped.putIfAbsent(file.recordId, () => <RecordPersistenceFile>[]).add(file);
    }
    final store = persistence ?? platformWebRecordPersistence;
    final duplicateRule = isDuplicate;
    // Decoded up front, judged one at a time. What a record *is* follows from
    // its own bytes and from nothing the store does, so it is settled here; a
    // body the mapper cannot read is simply absent, which is how a record no
    // question of sameness has an answer for stays out of every comparison.
    final decoded = <String, CharaDetailRecord>{};
    if (duplicateRule != null) {
      for (final entry in grouped.entries) {
        final record = _decodeRecord(entry.value);
        if (record != null) decoded[entry.key] = record;
      }
    }
    List<CharaDetailRecord> recordsOf(Iterable<String> ids) {
      final records = <CharaDetailRecord>[];
      for (final id in ids) {
        final record = decoded[id];
        if (record != null) records.add(record);
      }
      return records;
    }

    final donors = await _donorsFor(storageDir, grouped, store);
    final refusals = <String, RecordImportRefusal>{};
    final written = <String, CharaDetailRecord>{};
    // The whole zip goes to the store as one batch -- one acquisition, every
    // record lock taken once -- and the duplicate rule is asked inside it, as
    // each record is reached. The rule asks "is an equivalent copy already in
    // the store", and only a record the store took is in the store: answering
    // for every record before the batch starts would answer it with records that
    // had not been written yet and might never be, and a copy the store then
    // refuses -- its id is held by `archive/`, its slot is torn -- would already
    // have withheld the one equivalent copy that could have landed, leaving the
    // zip to import neither. Weighing each record against the ones this run has
    // committed leaves a provisional admission with nothing to suppress.
    final result = await store.persistFiles(
      storageDir,
      files,
      plan: (recordId, payload, committed) async {
        final record = decoded[recordId];
        if (duplicateRule != null && record != null && duplicateRule(record, recordsOf(committed))) {
          refusals[recordId] = RecordImportRefusal.duplicateOfExisting;
          return null;
        }
        final planned = await _importPublication(storageDir, recordId, payload, donors);
        if (planned.record case final writtenRecord?) written[recordId] = writtenRecord;
        return planned.publication;
      },
    );
    refusals.addAll(_refusals(result));
    return RecordImportResult(
      recordIds: result.committedIds,
      skippedEntries: 0,
      refusals: refusals,
      acceptedRecords: [for (final id in result.committedIds) ?(written[id] ?? decoded[id])],
    );
  }

  /// How the record [recordId], whose files the zip carries as [payload], is published over the record the device
  /// holds of that id, and the record its `record.json` then holds (null where the zip's does not decode).
  ///
  /// What [syncImport] decides is written ([R4-6], [R4-8] 5), read from the device's record and the zip, and lowered
  /// into the files of the record:
  ///
  /// * **The body** goes into `record.json` ([composeBodyImport]). The zip's binding is the one it carries; a zip of an
  ///   older build carries none, and it is then worked out from the images the zip carries, or known for none of them
  ///   where it carries no image. The device's binding is the one its record carries, or worked out from its images
  ///   where the two hold the same content.
  /// * **The absorbed ids** are the zip's `merged_ids.json`, and none where it carries none.
  /// * **The archive state** is the one the zip's `archive.json` notes — normal where it carries none — and goes into
  ///   the device's note ([importedArchiveNote]). The record lands in the store of that state, and its images take the
  ///   form that state holds them in.
  /// * **The images** are the zip's, the device's as they are, or those of the device's that the zip's binding names
  ///   with the rest taken from [donors] ([recordImagesBoundBy]); `trainee.jpg`, cut from the factor image, goes with
  ///   it. An image's geometry (`<image>.json`) goes with its forms; of a form placed — the zip's, or one taken from
  ///   [donors] — it is written from the body's geometry ([recordGeometryFiles]).
  ///
  /// Nothing the zip carries of a time is read, nor its relation bonus, which only the device that resolved it holds.
  /// The files the export table leaves on a device are not taken from the zip either ([recordFileExportOf]).
  static Future<({RecordPublication publication, CharaDetailRecord? record})> _importPublication(
    DirectoryPath storageDir,
    String recordId,
    List<RecordPersistenceFile> payload,
    _Donors donors,
  ) async {
    final carried = {for (final file in payload) file.relativeSegments.join('/'): file.bytes};
    final dataRoot = storageDir / 'chara_detail';
    final archived = dataRoot / 'archive' / recordId;
    final active = dataRoot / WebRecordWriteTransaction.activeStoreName / recordId;
    final localDir = await active.exists() ? active : (await archived.exists() ? archived : null);
    final localInArchive = localDir != null && localDir.path == archived.path;

    final state = exportedArchiveState(carried[recordArchiveNoteName]);
    final store = state == RecordArchiveState.normal ? WebRecordWriteTransaction.activeStoreName : 'archive';
    final note = localDir == null ? RecordArchiveNote.empty : await readRecordArchiveNote(localDir);
    final heldStage = switch (localDir == null ? null : note.valueIn(archiveStore: localInArchive)) {
      final held? => (value: held.state.option, time: held.writtenAt),
      null => null,
    };
    final asIs = [
      for (final MapEntry(:key, :value) in carried.entries)
        if (recordFileExportOf(key) == RecordFileExport.asIs)
          (recordId: recordId, relativeSegments: [key], bytes: value),
    ];
    Future<void> shape(DirectoryPath published) => shapeArchivedImagesUnlocked(published, state);
    final afterCommit = state == RecordArchiveState.normal ? null : shape;
    RecordPersistenceFile? noteFileOf(SyncValue<ArchiveImageOption?>? stage) =>
        switch (importedArchiveNote(stage, note)) {
          final bytes? => (recordId: recordId, relativeSegments: const [recordArchiveNoteName], bytes: bytes),
          null => null,
        };

    final imported = _decodeRecordJson(carried['record.json']);
    if (imported == null) {
      final noteFile = noteFileOf(syncImportStage(heldStage, state.option, writeAt: valueWriteTime));
      // A body this build cannot read is no body to weigh against the device's: the files go as the zip has them,
      // and the loader judges the record.
      final recordJson = (recordId: recordId, relativeSegments: const ['record.json'], bytes: carried['record.json']!);
      return (
        publication: (
          files: [recordJson, ...asIs, ?noteFile],
          removals: const <String>{},
          store: store,
          fromOtherStore: true,
          afterCommit: afterCommit,
        ),
        record: null,
      );
    }
    final local = localDir == null ? null : await _readLocalRecord(localDir);
    final carriesImages = carried.keys.any(isRecordImageFile);
    // A record whose binding is not worked out — one a zip from before the binding carries, or one the device holds
    // from before it — has it worked out here, with the geometry and the icon, from the images it comes with.
    final importedImages = imported.metadata.binding != null
        ? _imagesOf(imported)
        : (carriesImages
              ? await compute(recordBodyImagesOf, {
                  for (final MapEntry(:key, :value) in carried.entries)
                    if (isRecordImageFile(key)) key: value,
                })
              : null);
    final localImages = local == null || localDir == null
        ? null
        : local.metadata.binding != null
        ? _imagesOf(local)
        : (recognizedContentKey(local) == recognizedContentKey(imported)
              ? await computeRecordBodyImages(localDir)
              : null);
    final plan = syncImport(
      recordId,
      (body: _bodyOf(imported, importedImages), stage: state.option, carriesImages: carriesImages),
      body: switch (local) {
        final local? => (value: _bodyOf(local, localImages), time: local.metadata.bodyWrittenAt),
        null => (value: null, time: null),
      },
      stage: heldStage,
      others: donors.bindings,
      writeAt: valueWriteTime,
    );
    final record = composeBodyImport(local, imported, body: plan.body, writes: plan.writesBody);

    final removals = <String>{if (!carried.containsKey(mergedIdsFileName)) mergedIdsFileName};
    final localFiles = localDir == null ? const <String, Uint8List>{} : await readRecordImageFiles(localDir);
    final Map<String, Uint8List> taken;
    // The image files the record holds once it is published, and of those the ones placed from the zip or another
    // record, whose geometry is written from the body's.
    final Set<String> holds;
    final Iterable<String> placed;
    switch (plan.images) {
      case SyncImagesCarried():
        removals.addAll(localFiles.keys);
        taken = const {};
        holds = {...carried.keys.where(isRecordImageFile)};
        placed = holds;
      case SyncImagesKept():
        taken = const {};
        holds = const {};
        placed = const [];
      case SyncImagesBound(:final sources):
        final bound = await recordImagesBoundBy(plan.body.binding, localFiles, [
          for (final source in sources) donors.images[source] ?? const {},
        ]);
        removals.addAll(localFiles.keys.toSet().difference(bound.kept));
        taken = bound.taken;
        holds = {...bound.kept, ...taken.keys};
        placed = taken.keys;
    }
    final geometryFiles = recordGeometryFiles(plan.body.geometry, placed: placed, holds: holds);
    return (
      publication: (
        files: [
          (recordId: recordId, relativeSegments: const ['record.json'], bytes: record.toRecordJsonBytes()),
          for (final file in asIs)
            if (!geometryFiles.containsKey(file.relativeSegments.join('/'))) file,
          ?noteFileOf(plan.stage),
          for (final MapEntry(key: name, value: bytes) in {...taken, ...geometryFiles}.entries)
            (recordId: recordId, relativeSegments: [name], bytes: bytes),
        ],
        removals: removals,
        store: store,
        fromOtherStore: true,
        afterCommit: afterCommit,
      ),
      record: record,
    );
  }

  /// The body of [record] as sync carries it ([syncBodyOf]), with the binding, geometry and icon of [images]: those it
  /// carries ([_imagesOf]), or those worked out of its images where it carries none; none where neither is.
  static SyncBody _bodyOf(CharaDetailRecord record, RecordBodyImages? images) {
    final body = syncBodyOf(record);
    return SyncBody(
      body.content,
      binding: images?.binding,
      geometry: images?.geometry,
      icon: images?.icon,
      parents: body.parents,
      time: body.time,
    );
  }

  /// The binding, geometry and icon [record] carries.
  static RecordBodyImages _imagesOf(CharaDetailRecord record) =>
      (binding: record.metadata.binding, geometry: record.metadata.geometry, icon: record.metadata.icon);

  /// The device's records an import of the records [grouped] can take images from ([SyncImagesBound]): the binding of
  /// each record of either store — null where it is not worked out, or its `record.json` cannot be read — and the
  /// image files of each one [syncImageDonors] gives for a record of the zip that can take images
  /// ([syncImportTakesImages]). Nothing is read where no record of the zip can.
  ///
  /// Read before the batch, each record under its own lock ([WebRecordPersistence.readRecord]), let go of before the
  /// next is taken and before the batch's acquisition, which takes only the locks of the records it publishes: no
  /// lock is taken inside another. A record that changes between this read and the publication — archived, deleted,
  /// written over, by another operation or by this batch — is not read again. What a record takes from these bytes is
  /// what its binding names in them ([recordImagesBoundBy] hashes them against it), so only the images of the zip's
  /// body land, whatever the record read from holds by then; a record no longer there, or no longer holding them, has
  /// still held them on this device.
  static Future<_Donors> _donorsFor(
    DirectoryPath storageDir,
    Map<String, List<RecordPersistenceFile>> grouped,
    WebRecordPersistence store,
  ) async {
    final taking = <({String id, RecordBinding? binding})>[];
    for (final MapEntry(key: id, value: files) in grouped.entries) {
      final carried = {for (final file in files) file.relativeSegments.join('/'): file.bytes};
      final imported = _decodeRecordJson(carried['record.json']);
      if (imported == null) continue;
      final binding = imported.metadata.binding;
      final zip = (
        body: _bodyOf(imported, _imagesOf(imported)),
        stage: exportedArchiveState(carried[recordArchiveNoteName]).option,
        carriesImages: carried.keys.any(isRecordImageFile),
      );
      if (syncImportTakesImages(zip)) taking.add((id: id, binding: binding));
    }
    final donors = (bindings: <String, RecordBinding?>{}, images: <String, Map<String, Uint8List>>{});
    if (taking.isEmpty) return donors;
    final dataRoot = storageDir / 'chara_detail';
    for (final name in [WebRecordWriteTransaction.activeStoreName, 'archive']) {
      final storeDir = dataRoot / name;
      if (!await storeDir.exists()) continue;
      await for (final entry in storeDir.list()) {
        if (entry is! DirectoryPath || donors.bindings.containsKey(entry.name)) continue;
        final id = entry.name;
        try {
          await store.readRecord(storageDir, id, () async {
            if (!await entry.exists()) return;
            final binding = (await _readRecordOrNull(entry))?.metadata.binding;
            final images = taking.any((t) => syncImageDonors(t.id, t.binding, {id: binding}).isNotEmpty)
                ? await readRecordImageFiles(entry)
                : null;
            donors.bindings[id] = binding;
            if (images != null) donors.images[id] = images;
          }, declaration: _readsTheImagesOfARecord);
        } catch (error, stackTrace) {
          // A record that cannot be read is one the import takes no image from; the records of the zip are still the
          // user's to import.
          logger.w('The import reads no image of $id: it could not be read.', error, stackTrace);
        }
      }
    }
    return donors;
  }

  static const _readsTheImagesOfARecord = LongReadDeclaration.none(
    reason: 'reads the record.json and images of one record and lets go; the import above owns the window',
  );

  /// The record in [directory], or null where it holds none this build can read, logged.
  static Future<CharaDetailRecord?> _readRecordOrNull(DirectoryPath directory) async {
    final file = directory.filePath('record.json');
    try {
      if (!await file.exists()) return null;
      return CharaDetailRecord.fromRecordJson(await file.readAsString());
    } catch (error, stackTrace) {
      logger.w(
        'The record.json of ${directory.name} could not be read; its images are told by their bytes.',
        error,
        stackTrace,
      );
      return null;
    }
  }

  static CharaDetailRecord? _decodeRecordJson(Uint8List? bytes) {
    if (bytes == null) return null;
    try {
      return CharaDetailRecord.fromRecordJson(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
  }

  /// The record the device holds in [directory], or null where it holds none this build can read — which an import
  /// then writes over as it would over no record.
  static Future<CharaDetailRecord?> _readLocalRecord(DirectoryPath directory) async {
    final file = directory.filePath('record.json');
    try {
      if (!await file.exists()) return null;
      return CharaDetailRecord.fromRecordJson(await file.readAsString());
    } catch (error, stackTrace) {
      logger.w('The record.json of ${directory.name} could not be read; the import writes over it.', error, stackTrace);
      return null;
    }
  }

  /// The record [files] carries in its `record.json`, or `null` when it carries
  /// none or the one it carries does not decode.
  ///
  /// A record with no readable `record.json` is never weighed against anything
  /// and never becomes something to weigh others against: the question "is this
  /// a duplicate" has no answer for it. Only a confirmed duplicate is withheld,
  /// so a record that does not decode is still handed to the store.
  static CharaDetailRecord? _decodeRecord(List<RecordPersistenceFile> files) {
    for (final file in files) {
      if (file.relativeSegments.last != "record.json") continue;
      try {
        return CharaDetailRecord.fromRecordJson(utf8.decode(file.bytes));
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// [bytes] upgraded to [recordFormatVersion] when they are a record stored in an older format, and
  /// [bytes] themselves otherwise -- including when they do not decode, which is the loader's to judge.
  ///
  /// A zip exported by an older build carries its records in the older format, and this is where they
  /// enter the store: upgraded here, what is published is already current, and the duplicate rule
  /// weighs them in the same format as the records the store already holds.
  static Uint8List _upgradedRecordJson(Uint8List bytes) {
    try {
      final stored = CharaDetailRecordMapper.fromJson(utf8.decode(bytes));
      final upgraded = stored.upgradeFormat();
      return identical(upgraded, stored) ? bytes : upgraded.toRecordJsonBytes();
    } catch (_) {
      return bytes;
    }
  }

  /// The non-committed half of [result], as the reason the import UI has a
  /// sentence for: every record the store did not write is [RecordImportRefusal.notStored].
  ///
  /// Walks the *statuses* — the store's own record of what it was asked to write
  /// — rather than the failure map, so a record that neither committed nor
  /// recorded a reason is still reported. Losing it here would put the silence
  /// back one layer down from where it was found.
  static Map<String, RecordImportRefusal> _refusals(WebRecordPersistenceResult result) {
    return {
      for (final id in result.statuses.keys)
        if (!result.committed(id)) id: RecordImportRefusal.notStored,
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
