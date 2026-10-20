// What of a record directory leaves the device, and in what form.
//
// Every export that carries a record's files — the record zip on desktop and on web, and the storage view's folder
// zip — packs them by one table ([recordFileExportOf]) and puts each through one function ([recordFileForExport]).
// A record leaves with its body, its binding, its parents, its absorbed ids, its archive state and its images. It
// leaves without the times its values were written, and without what only this device can work out again: the
// relation bonus is recomputed from the lineage by the resolver. Files that are not the record — the recognizer's
// result waiting to be composed, the recognizer's history of earlier results, a replacement's staging file, and the
// merges this device started and has not finished — stay on the device. Nothing here removes a file from the record directory.

import 'dart:convert';
import 'dart:typed_data';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/enhancement_merge.dart';
import '/src/chara_detail/record_archive_state.dart';
import '/src/chara_detail/record_quarantine_ledger.dart';

/// How one file of a record directory goes into an export.
enum RecordFileExport {
  /// `record.json`, without the fields only this device holds ([recordJsonWithoutLocalFields]).
  body,

  /// The archive state note. Not packed from the file: every export adds the note of the state the record is in, read
  /// from its store and its note ([exportedArchiveNoteOf]), whether the record has the file or not.
  archiveState,

  /// Packed byte for byte: the images, `trainee.jpg`, `merged_ids.json`, `prediction.json`.
  asIs,

  /// Not packed: `recognized.json`, a `record_<ts>.json` history file, a `<name>.part` staging file,
  /// `merges_in_progress.json`, and the quarantine shelf's note of which record a directory on it is
  /// ([quarantineOriginName]), which a zip of a directory on the shelf carries.
  left,
}

/// The recognizer's history of a record's earlier results, `record_<milliseconds>.json`.
final _recognizerHistoryName = RegExp(r'^record_\d+\.json$');

/// The suffix every replacement in a record directory stages under — `record.json.part` and `archive.json.part` by
/// the app, `recognized.json.part` by the recognizer — before renaming it over the file it replaces.
const _replacementSuffix = '.part';

/// The row of the table for the file named [fileName] in a record directory.
RecordFileExport recordFileExportOf(String fileName) {
  if (fileName == 'record.json') return RecordFileExport.body;
  if (fileName == recordArchiveNoteName) return RecordFileExport.archiveState;
  if (fileName == CharaDetailRecord.recognizedJsonName ||
      fileName == mergesInProgressFileName ||
      fileName == quarantineOriginName ||
      fileName.endsWith(_replacementSuffix) ||
      _recognizerHistoryName.hasMatch(fileName)) {
    return RecordFileExport.left;
  }
  return RecordFileExport.asIs;
}

/// The bytes an export packs for the file named [fileName] of a record directory holding [bytes], or null when the
/// file is not packed.
Uint8List? recordFileForExport(String fileName, Uint8List bytes) => switch (recordFileExportOf(fileName)) {
  RecordFileExport.body => recordJsonWithoutLocalFields(bytes),
  RecordFileExport.archiveState => null,
  RecordFileExport.asIs => bytes,
  RecordFileExport.left => null,
};

/// The `metadata` fields of a record that stay on the device: the time its body was written, and the relation bonus.
const _localMetadataKeys = ['body_written_at', 'relation_bonus'];

/// [recordJson], a decoded `record.json`, without the fields only this device holds.
///
/// The one function that decides what of a record's body leaves the device; the record zip and the body object the
/// sync sends both go through it.
Map<String, Object?> withoutLocalRecordFields(Map<String, Object?> recordJson) {
  final metadata = recordJson['metadata'];
  if (metadata is! Map<String, Object?> || !_localMetadataKeys.any(metadata.containsKey)) {
    return recordJson;
  }
  return {
    for (final entry in recordJson.entries)
      entry.key: entry.key == 'metadata'
          ? {
              for (final field in metadata.entries)
                if (!_localMetadataKeys.contains(field.key)) field.key: field.value,
            }
          : entry.value,
  };
}

/// The bytes of a `record.json` holding [bytes], without the fields only this device holds
/// ([withoutLocalRecordFields]), in the form the app writes `record.json`.
///
/// A `record.json` carrying none of them is returned as it is. One that is not a JSON object is returned as it is
/// too: nothing can read a field out of it, so it carries none.
Uint8List recordJsonWithoutLocalFields(Uint8List bytes) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException {
    return bytes;
  }
  if (decoded is! Map<String, Object?>) return bytes;
  final stripped = withoutLocalRecordFields(decoded);
  if (identical(stripped, decoded)) return bytes;
  return utf8.encode(const JsonEncoder.withIndent('    ').convert(stripped));
}
