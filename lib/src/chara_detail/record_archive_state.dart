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
import '/src/chara_detail/record_operation.dart';
import '/src/chara_detail/record_sync_merge.dart';
import '/src/chara_detail/value_write_time.dart';
import '/src/core/app_logger.dart';
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

  /// The state as sync carries it ([of] the other way): null where the record is normal.
  ArchiveImageOption? get option => switch (this) {
    RecordArchiveState.normal => null,
    RecordArchiveState.jpeg => ArchiveImageOption.resizedJpeg,
    RecordArchiveState.none => ArchiveImageOption.none,
  };
}

/// A record's archive state and when it was written, in milliseconds since the epoch, or null for a state that
/// carries no time.
typedef RecordArchiveValue = ({RecordArchiveState state, int? writtenAt});

/// The note's two slots: the time the record was made normal, and the state and time of its archive. A record
/// directory without a note holds [empty].
class RecordArchiveNote {
  const RecordArchiveNote(this.normalWrittenAt, this.archived);

  final int? normalWrittenAt;
  final RecordArchiveValue? archived;

  static const empty = RecordArchiveNote(null, null);

  /// The state of a record with this note, in the archive store when [archiveStore] and in the active store otherwise.
  RecordArchiveValue valueIn({required bool archiveStore}) => archiveStore
      ? archived ?? (state: RecordArchiveState.jpeg, writtenAt: null)
      : (state: RecordArchiveState.normal, writtenAt: normalWrittenAt);

  List<int> toBytes() => utf8.encode(
    jsonEncode({
      if (normalWrittenAt != null) 'normal_written_at': normalWrittenAt,
      if (archived case final a?) 'archived': {'state': a.state.name, 'written_at': a.writtenAt},
    }),
  );

  /// The note [text] holds. Throws where it is not one.
  static RecordArchiveNote decode(String text) {
    final map = jsonDecode(text) as Map<String, Object?>;
    final archived = map['archived'];
    return RecordArchiveNote(
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

Future<RecordArchiveNote> _readNote(DirectoryPath recordDir) async {
  final file = recordDir.filePath(recordArchiveNoteName);
  if (!await file.exists()) {
    return RecordArchiveNote.empty;
  }
  return RecordArchiveNote.decode(await file.readAsString());
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
  var note = RecordArchiveNote.empty;
  if (stored != null) {
    try {
      note = RecordArchiveNote.decode(utf8.decode(stored));
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
    return RecordArchiveNote.decode(utf8.decode(bytes)).archived?.state ?? RecordArchiveState.normal;
  } catch (error, stackTrace) {
    logger.w('An imported archive note could not be read, so the record is read as normal.', error, stackTrace);
    return RecordArchiveState.normal;
  }
}

/// The note of the record in [recordDir], [RecordArchiveNote.empty] where it carries none. Throws when it cannot be
/// read.
Future<RecordArchiveNote> readRecordArchiveNote(DirectoryPath recordDir) => _readNote(recordDir);

/// The note an import publishes for a record whose archive state [syncImport] writes as [written], over the note
/// [held] the device's record carries — [RecordArchiveNote.empty] where the device holds no record of the id: [written]
/// in the slot of the store its state is held in, the other slot as it was. Null where [written] is: the note stays as
/// it is, its time included.
Uint8List? importedArchiveNote(SyncValue<ArchiveImageOption?>? written, RecordArchiveNote held) {
  if (written == null) return null;
  final next = switch (written.value) {
    null => RecordArchiveNote(written.time, held.archived),
    final option => RecordArchiveNote(held.normalWrittenAt, (
      state: RecordArchiveState.of(option),
      writtenAt: written.time,
    )),
  };
  return Uint8List.fromList(next.toBytes());
}

/// The archive states a merge decides its survivor's on ([syncMerge]): the state the older record, its id's, is read in
/// ([shown]), the state of the record whose content it keeps ([kept]), and whether that record's directory holds a
/// note ([keptHasNote]).
typedef MergedArchiveStates = ({RecordArchiveValue shown, RecordArchiveValue kept, bool keptHasNote});

/// [MergedArchiveStates] of a merge of the record in [olderDir] that keeps the content of the record in [keptDir],
/// each read as being in the archive store when its `…InArchive` flag is true. Throws when either note cannot be read.
Future<MergedArchiveStates> readMergedArchiveStates({
  required DirectoryPath olderDir,
  required bool olderInArchive,
  required DirectoryPath keptDir,
  required bool keptInArchive,
}) async => (
  shown: (await _readNote(olderDir)).valueIn(archiveStore: olderInArchive),
  kept: (await _readNote(keptDir)).valueIn(archiveStore: keptInArchive),
  keptHasNote: await keptDir.filePath(recordArchiveNoteName).exists(),
);

/// The note a merge publishes for its survivor, whose id is the older record's and whose tree is the kept record's, of
/// the [states] it read: the kept record's state, written as the merge's decision writes it ([written] —
/// [SyncMergePlan.stage]), and at the time the older record's state holds where that decision writes none — the two
/// records are in one state. The kept record's own time is never carried: the survivor shows the older record's value
/// until the merge writes another.
///
/// The survivor lives in the kept record's store — the archive store when [keptInArchive] — so the note holds the slot
/// of that store and no other. Null where that note is empty and the kept record has none, so the kept tree already
/// reads as it.
Uint8List? survivorArchiveNote(
  SyncValue<ArchiveImageOption?>? written, {
  required MergedArchiveStates states,
  required bool keptInArchive,
}) {
  final writtenAt = written?.time ?? states.shown.writtenAt;
  final note = keptInArchive
      ? RecordArchiveNote(null, (state: states.kept.state, writtenAt: writtenAt))
      : RecordArchiveNote(writtenAt, null);
  if (note.normalWrittenAt == null && note.archived == null && !states.keptHasNote) {
    return null;
  }
  return Uint8List.fromList(note.toBytes());
}

/// Writes into the note of the active record in [recordDir] that it is archived with [option], at the time of this
/// write over the time of its normal state: [syncArchive]'s decision, by [valueWriteTime].
///
/// A note that already holds this choice, written after the normal state, is left as it is: an archive that stopped
/// before its move left it, and the retry is the same archive, so it moves the same bytes the stopped one staged — a
/// move resumes only over an identical tree.
///
/// Called before the directory moves to the archive store, under the record lock the move holds: until it moves the
/// record is still read as normal, at the time it was, and once it has moved it is read as this.
///
/// Returns the note [recordDir] holds afterwards, the one the move carries.
Future<RecordArchiveNote> noteArchiveChoiceUnlocked(DirectoryPath recordDir, ArchiveImageOption option) async {
  final note = await _readNote(recordDir);
  final current = note.valueIn(archiveStore: false);
  final state = RecordArchiveState.of(option);
  if (note.archived case (
    state: final noted,
    writtenAt: final at?,
  ) when noted == state && at > (current.writtenAt ?? -1)) {
    return note;
  }
  final written = syncArchive((value: current.state.option, time: current.writtenAt), option, writeAt: valueWriteTime);
  // Not null here: a record in the active store is normal, and an archive is never that state.
  if (written == null) return note;
  final next = RecordArchiveNote(note.normalWrittenAt, (
    state: RecordArchiveState.of(written.value),
    writtenAt: written.time,
  ));
  // A torn note would lose the time of the normal state.
  await recordDir.filePath(recordArchiveNoteName).replaceWhole(next.toBytes());
  logger.d('Noted the archive of ${recordDir.name} as ${state.name}.');
  return next;
}
