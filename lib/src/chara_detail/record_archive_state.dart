// A record's archive state, and the time it was written.
//
// The state is read from two facts held as data: the store the record's directory is in, and the choice its archive
// was made with. A record in the active store is normal, whatever its note says; a record in the archive store has
// the state its note names, and one archived before notes were kept has none and is read as a reduced JPEG, written
// at no time (older than any state written with one).
//
// The note is one file in the record directory, holding the time the record was made normal and the choice and time
// of its archive. Archiving writes the choice into the note **before** the directory moves, and the move carries it:
// on desktop the move is one atomic rename, on web the record transaction, which a reload resumes or rolls back. So
// there is no moment, and no interruption, after which the store says one state and the note gives the time of
// another — the store moved and its slot is read, or it did not and the normal slot still holds the time it held.

import 'dart:convert';
import 'dart:typed_data';

import '/src/chara_detail/archive_executor_types.dart';
import '/src/chara_detail/value_write_time.dart';
import '/src/core/app_logger.dart';
import '/src/core/fs/fs_backend.dart';
import '/src/core/path_entity.dart';

/// The name of the note in a record directory.
const recordArchiveNoteName = 'archive.json';

enum RecordArchiveState {
  normal,

  /// Archived with its images as reduced JPEGs.
  jpeg,

  /// Archived with no images.
  none;

  static RecordArchiveState of(ArchiveImageOption option) => switch (option) {
    ArchiveImageOption.resizedJpeg => RecordArchiveState.jpeg,
    ArchiveImageOption.none => RecordArchiveState.none,
  };
}

/// A record's archive state and when it was written, in milliseconds since the epoch, or null for a state that
/// carries no time.
typedef RecordArchiveValue = ({RecordArchiveState state, int? writtenAt});

/// The note's two slots: the time the record was made normal, and the state and time of its archive.
class _Note {
  const _Note(this.normalWrittenAt, this.archived);

  final int? normalWrittenAt;
  final RecordArchiveValue? archived;

  static const empty = _Note(null, null);

  RecordArchiveValue valueIn({required bool archiveStore}) => archiveStore
      ? archived ?? (state: RecordArchiveState.jpeg, writtenAt: null)
      : (state: RecordArchiveState.normal, writtenAt: normalWrittenAt);

  List<int> toBytes() => utf8.encode(
    jsonEncode({
      if (normalWrittenAt != null) 'normal_written_at': normalWrittenAt,
      if (archived case final a?) 'archived': {'state': a.state.name, 'written_at': a.writtenAt},
    }),
  );

  static _Note decode(String text) {
    final map = jsonDecode(text) as Map<String, Object?>;
    final archived = map['archived'];
    return _Note(
      map['normal_written_at'] as int?,
      archived is Map<String, Object?>
          ? (
              state: RecordArchiveState.values.byName(archived['state'] as String),
              writtenAt: archived['written_at'] as int?,
            )
          : null,
    );
  }
}

Future<_Note> _readNote(DirectoryPath recordDir) async {
  final file = recordDir.filePath(recordArchiveNoteName);
  if (!await file.exists()) {
    return _Note.empty;
  }
  return _Note.decode(await file.readAsString());
}

/// The archive state of the record in [recordDir], which is in the archive store when [archiveStore] is true and in
/// the active store otherwise.
Future<RecordArchiveValue> readRecordArchiveState(DirectoryPath recordDir, {required bool archiveStore}) async {
  return (await _readNote(recordDir)).valueIn(archiveStore: archiveStore);
}

/// Whether the record directory [recordDir] is in the archive store — the fact its archive state is read from with
/// its note.
bool isInArchiveStore(DirectoryPath recordDir) => recordDir.parent.name == 'archive';

/// The note an export carries for a record in the archive store when [archiveStore], whose note holds [stored] — null
/// where it has none: the state the record is in, read as [readRecordArchiveState] reads it, from the store and the
/// note together, without the time of either slot. Null for a normal record, which a record carrying no note reads as.
///
/// So a record archived before notes were kept goes out archived, as it is read here, and a record made normal again
/// does not take the archive its note still remembers. A note this build cannot read is read as an empty one, logged.
Uint8List? exportedArchiveNote(Uint8List? stored, {required bool archiveStore}) {
  var note = _Note.empty;
  if (stored != null) {
    try {
      note = _Note.decode(utf8.decode(stored));
    } catch (error, stackTrace) {
      logger.w(
        'An archive note could not be read, so the record is exported as one without a note.',
        error,
        stackTrace,
      );
    }
  }
  final state = note.valueIn(archiveStore: archiveStore).state;
  if (state == RecordArchiveState.normal) return null;
  return utf8.encode(
    jsonEncode({
      'archived': {'state': state.name},
    }),
  );
}

/// [exportedArchiveNote] for the record in [recordDir], reading its note. The caller holds the record's lock.
Future<Uint8List?> exportedArchiveNoteOf(DirectoryPath recordDir) async {
  final file = recordDir.filePath(recordArchiveNoteName);
  return exportedArchiveNote(
    await file.exists() ? await file.readAsBytes() : null,
    archiveStore: isInArchiveStore(recordDir),
  );
}

/// The state the note in [bytes], as an export carries it, names — the state of its archive, else normal — read
/// without its times. A record that carries no note ([bytes] null), as one an older build exported does not, is
/// normal; so is one whose note this build cannot read, logged.
RecordArchiveState exportedArchiveState(Uint8List? bytes) {
  if (bytes == null) return RecordArchiveState.normal;
  try {
    return _Note.decode(utf8.decode(bytes)).archived?.state ?? RecordArchiveState.normal;
  } catch (error, stackTrace) {
    logger.w('An imported archive note could not be read, so the record is read as normal.', error, stackTrace);
    return RecordArchiveState.normal;
  }
}

/// The note an import publishes for a record it makes [state], over the record in [localDir] — in the archive store
/// when [localInArchive] — or over none where [localDir] is null.
///
/// Null where the record the device holds is already in [state]: the note stays as it is, its time included. Else
/// the device's note with [state] in the slot of the store [state] is held in, at the time of this write over the
/// time of the state the device's record is in ([valueWriteTime]); the other slot stays as it was. Throws when the
/// device's note cannot be read.
Future<Uint8List?> importedArchiveNote(
  RecordArchiveState state, {
  required DirectoryPath? localDir,
  required bool localInArchive,
}) async {
  final note = localDir == null ? _Note.empty : await _readNote(localDir);
  final current = localDir == null ? null : note.valueIn(archiveStore: localInArchive);
  if (current?.state == state) return null;
  final writtenAt = valueWriteTime(current?.writtenAt);
  final next = state == RecordArchiveState.normal
      ? _Note(writtenAt, note.archived)
      : _Note(note.normalWrittenAt, (state: state, writtenAt: writtenAt));
  return Uint8List.fromList(next.toBytes());
}

/// The note a merge publishes for its survivor, whose id is the record in [olderDir] and whose state is the one the
/// record in [keptDir] is read in: that state, at the time the older record's state holds where the two are the same
/// state and at the time of this write over it ([valueWriteTime]) where they are not. The kept record's own time is
/// never carried: the survivor shows the older record's value until the merge writes another.
///
/// Each record is read as being in the archive store when its `…InArchive` flag is true. The survivor lives in the
/// kept record's store, so the note holds the slot of that store and no other. Null where that note is empty and the
/// kept record has none, so the kept tree already reads as it. Throws when either note cannot be read.
Future<Uint8List?> survivorArchiveNote({
  required DirectoryPath olderDir,
  required bool olderInArchive,
  required DirectoryPath keptDir,
  required bool keptInArchive,
}) async {
  final shown = (await _readNote(olderDir)).valueIn(archiveStore: olderInArchive);
  final kept = (await _readNote(keptDir)).valueIn(archiveStore: keptInArchive);
  final writtenAt = kept.state == shown.state ? shown.writtenAt : valueWriteTime(shown.writtenAt);
  final note = keptInArchive ? _Note(null, (state: kept.state, writtenAt: writtenAt)) : _Note(writtenAt, null);
  if (note.normalWrittenAt == null &&
      note.archived == null &&
      !await keptDir.filePath(recordArchiveNoteName).exists()) {
    return null;
  }
  return Uint8List.fromList(note.toBytes());
}

/// Writes into the note of the active record in [recordDir] that it is archived with [option], at the time of this
/// write over the time of its normal state ([valueWriteTime]).
///
/// A note that already holds this choice, written after the normal state, is left as it is: an archive that stopped
/// before its move left it, and the retry is the same archive, so it moves the same bytes the stopped one staged — a
/// move resumes only over an identical tree.
///
/// Called before the directory moves to the archive store, under the record lock the move holds: until it moves the
/// record is still read as normal, at the time it was, and once it has moved it is read as this.
Future<void> noteArchiveChoiceUnlocked(DirectoryPath recordDir, ArchiveImageOption option) async {
  final note = await _readNote(recordDir);
  final current = note.valueIn(archiveStore: false);
  final state = RecordArchiveState.of(option);
  if (note.archived case (
    state: final noted,
    writtenAt: final at?,
  ) when noted == state && at > (current.writtenAt ?? -1)) {
    return;
  }
  final next = _Note(note.normalWrittenAt, (state: state, writtenAt: valueWriteTime(current.writtenAt)));
  final file = recordDir.filePath(recordArchiveNoteName);
  if (fsBackend.renameReplacesFileAtomically) {
    // A torn note would lose the time of the normal state; the staging file is replaced whole or not at all.
    final staging = recordDir.filePath('$recordArchiveNoteName.part');
    await staging.writeAsBytes(next.toBytes(), flush: true);
    await staging.rename(file);
  } else {
    // An OPFS writable is published whole when it closes.
    await file.writeAsBytes(next.toBytes(), flush: true);
  }
  logger.d('Noted the archive of ${recordDir.name} as ${state.name}.');
}
