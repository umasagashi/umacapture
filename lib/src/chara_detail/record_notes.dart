// What a record directory holds about its record beside `record.json`, as the stores keep it with the record: the
// archive note (`archive.json`, [RecordArchiveNote]) and the ids the record absorbed (`merged_ids.json`).
//
// Both are read when the record is: the loaders read `record.json` and these two together ([readRecordNotesIn],
// [readRecordNotesSync]), each by its name, finding a missing file by the one read failing. A record carrying neither
// holds [RecordNotes.none], which is what most records hold.

import 'dart:convert';
import 'dart:typed_data';

import '/src/chara_detail/record_archive_state.dart';
import '/src/core/app_logger.dart';
import '/src/core/path_entity.dart';

/// File name of the absorbed ids beside a record's `record.json`: every id the record has absorbed, by a merge on this
/// device or by one that reached it with the record (a zip, a sync).
///
/// A fact about the record that travels with it, and nothing more: it does not say whether a merge on this device has
/// finished, so a record that carries another's id beside that other record is an ordinary pair of records. Whether a
/// merge this device started is still unfinished is `merges_in_progress.json`, a separate file. Published by the
/// journal transaction that makes the record the survivor of a merge, so it exists exactly when that survivor does.
/// The stores hold it with the record ([RecordNotes.absorbed]), and the native re-recognizer rewrites named files and
/// leaves it, so it is a fact about the record without being part of its body.
const mergedIdsFileName = 'merged_ids.json';

/// [ids] as the bytes of a `merged_ids.json`: sorted and de-duplicated, in the same 4-space-indent encoding every
/// other file of a record directory carries.
Uint8List mergedIdsBytes(List<String> ids) {
  final sorted = ids.toSet().toList()..sort();
  return Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('    ').convert({'ids': sorted})));
}

/// What a record directory holds about its record beside `record.json`. A field is null where its file is there and
/// cannot be read.
class RecordNotes {
  const RecordNotes({required this.archive, required this.absorbed});

  /// What a record directory holding neither file holds.
  static const none = RecordNotes(archive: RecordArchiveNote.empty, absorbed: {});

  /// The archive note; [RecordArchiveNote.empty] where there is none.
  final RecordArchiveNote? archive;

  /// The ids the record absorbed; empty where it absorbed none.
  final Set<String>? absorbed;
}

/// What [recordDir] holds about its record beside `record.json`.
Future<RecordNotes> readRecordNotes(DirectoryPath recordDir) async =>
    readRecordNotesIn(await recordDir.open(), recordDir);

/// [readRecordNotes] through a directory the caller has resolved already — [recordDir] itself, or one it lies beneath —
/// to read `record.json` and more from it as well.
Future<RecordNotes> readRecordNotesIn(OpenedDirectory opened, DirectoryPath recordDir) async {
  final archive = recordDir.filePath(recordArchiveNoteName);
  final absorbed = recordDir.filePath(mergedIdsFileName);
  return RecordNotes(
    archive: _decodeArchiveNote(archive, await _readIfPresent(opened, archive)),
    absorbed: _decodeAbsorbed(absorbed, await _readIfPresent(opened, absorbed)),
  );
}

/// [readRecordNotes] on the synchronous file API, for the loaders that read `record.json` with it (io only).
RecordNotes readRecordNotesSync(DirectoryPath recordDir) {
  final archive = recordDir.filePath(recordArchiveNoteName);
  final absorbed = recordDir.filePath(mergedIdsFileName);
  return RecordNotes(
    archive: _decodeArchiveNote(archive, _readIfPresentSync(archive)),
    absorbed: _decodeAbsorbed(absorbed, _readIfPresentSync(absorbed)),
  );
}

/// The ids [recordDir]'s record has absorbed, `null` when the file is there and cannot be used.
///
/// Absent is the empty list, because a record that has absorbed nothing and a record that has never been part of a
/// merge are the same record. "There and unusable" is a third answer and not an empty list: the merge publishes the
/// union of both sides' ids, and a union over a list it could not read would drop ids.
Future<List<String>?> readMergedIds(DirectoryPath recordDir) async {
  final file = recordDir.filePath(mergedIdsFileName);
  return _decodeAbsorbed(file, await _readIfPresent(await recordDir.open(), file))?.toList();
}

/// A read that could not be made: the file is there, or may be, and its bytes are not known.
const _failed = (bytes: null, failed: true);

typedef _Read = ({Uint8List? bytes, bool failed});

Future<_Read> _readIfPresent(OpenedDirectory opened, FilePath file) async {
  try {
    return (bytes: await opened.readAsBytesIfPresent(file), failed: false);
  } catch (error, stackTrace) {
    logger.w('Could not read ${file.path}.', error, stackTrace);
    return _failed;
  }
}

_Read _readIfPresentSync(FilePath file) {
  try {
    return (bytes: file.readAsBytesIfPresentSync(), failed: false);
  } catch (error, stackTrace) {
    logger.w('Could not read ${file.path}.', error, stackTrace);
    return _failed;
  }
}

RecordArchiveNote? _decodeArchiveNote(FilePath file, _Read read) {
  if (read.failed) return null;
  final bytes = read.bytes;
  if (bytes == null) return RecordArchiveNote.empty;
  try {
    return RecordArchiveNote.decode(utf8.decode(bytes));
  } catch (error, stackTrace) {
    logger.w('The archive note at ${file.path} cannot be read.', error, stackTrace);
    return null;
  }
}

Set<String>? _decodeAbsorbed(FilePath file, _Read read) {
  if (read.failed) return null;
  final bytes = read.bytes;
  if (bytes == null) return const {};
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    final ids = decoded is Map ? decoded['ids'] : decoded;
    if (ids is List && ids.every((entry) => entry is String)) return ids.cast<String>().toSet();
    logger.w('The absorbed ids at ${file.path} are not a list of ids.');
  } catch (error, stackTrace) {
    logger.w('Could not read the absorbed ids at ${file.path}.', error, stackTrace);
  }
  return null;
}
