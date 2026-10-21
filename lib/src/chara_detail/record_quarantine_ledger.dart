// What the quarantine shelf holds of records, kept as data that outlives a restart.
//
// A record the app cannot read is moved whole onto the shelf (`chara_detail/quarantine/<name>`), and the name it lands
// under is not its id: a collision takes an `_<n>` suffix, and other routes put other things there. So the move writes
// the record's id and the store it was in into the directory it moved ([quarantineOriginName]), and the shelf is read
// back from those notes, never from the names. A note on the shelf means the record is kept as the server holds it
// while it stays there ([N15-20]). A directory on the shelf with no note is a record too, one whose id the device
// cannot tell: it is counted, and read as one the device cannot read ([R7-3]).
//
// The two ways off the shelf leave two different facts. A record whose `record.json` reads again as its own id is put
// back into the store it came from by the next scan of that store, and the note goes with the move. A quarantined
// record the user deletes from the storage view is gone, and its id is added to the shelf's list of ids the user
// deleted ([quarantineUserDeletedName]) — the fact that it is a delete, which the record's note no longer exists to say.

import 'dart:convert';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/core/app_logger.dart';
import '/src/core/path_entity.dart';

/// The note a quarantine move leaves in the directory it moved: `{"id": <record id>, "store": "active" | "archive"}`.
const quarantineOriginName = 'quarantine_origin.json';

/// The shelf's list of the ids of quarantined records the user deleted, a JSON list of ids at the shelf's root.
const quarantineUserDeletedName = '.user_deleted.json';

/// A record on the quarantine shelf: its id, the store it was moved out of, and where it is now.
typedef QuarantinedRecord = ({String id, String store, DirectoryPath directory});

/// What the shelf at a `quarantine/` directory holds of records: those whose note names them ([kept]), the number of
/// directories on it whose note does not ([unnamed]), and the ids of the records the user deleted from it.
typedef QuarantineLedger = ({List<QuarantinedRecord> kept, int unnamed, Set<String> userDeleted});

String _originJson(DirectoryPath source) => jsonEncode({'id': source.name, 'store': source.parent.name});

/// Notes in [destination], where a quarantine has just moved the record directory [source], which record it is.
/// Logged when it cannot be written: the move has happened, and the record is still on the shelf.
void noteQuarantineOriginSync(DirectoryPath source, DirectoryPath destination) {
  try {
    destination.filePath(quarantineOriginName).writeAsStringSync(_originJson(source));
  } catch (error, stackTrace) {
    logger.e('Could not note which record ${destination.name} on the quarantine shelf is.', error, stackTrace);
  }
}

/// Asynchronous counterpart of [noteQuarantineOriginSync], for the web / main-isolate quarantine.
Future<void> noteQuarantineOrigin(DirectoryPath source, DirectoryPath destination) async {
  try {
    await destination.filePath(quarantineOriginName).writeAsString(_originJson(source));
  } catch (error, stackTrace) {
    logger.e('Could not note which record ${destination.name} on the quarantine shelf is.', error, stackTrace);
  }
}

/// The record [directory] on the shelf is, or null where it carries no readable note.
Future<QuarantinedRecord?> _quarantinedRecordAt(DirectoryPath directory) async {
  final file = directory.filePath(quarantineOriginName);
  try {
    if (!await file.exists()) return null;
    final note = jsonDecode(await file.readAsString());
    if (note case {'id': final String id, 'store': final String store}) {
      return (id: id, store: store, directory: directory);
    }
    logger.w('The quarantine note in ${directory.name} names no record.');
  } catch (error, stackTrace) {
    logger.w('The quarantine note in ${directory.name} could not be read.', error, stackTrace);
  }
  return null;
}

Future<Set<String>> _readUserDeleted(DirectoryPath shelf) async {
  final file = shelf.filePath(quarantineUserDeletedName);
  if (!await file.exists()) return {};
  final decoded = jsonDecode(await file.readAsString());
  return {for (final id in decoded as List) id as String};
}

/// What the quarantine shelf [shelf] holds: the records on it, each from its note, the number of directories on it
/// that carry no readable note, and the ids of those the user deleted. A directory with no note is still something
/// set aside — a write's recovery moves what it gives up on here without one, and the user may delete the note alone
/// from the storage view — and so a record the device holds and cannot name. A shelf that is not there holds nothing.
/// Throws when the list of deleted ids cannot be read.
Future<QuarantineLedger> readQuarantineLedger(DirectoryPath shelf) async {
  if (!await shelf.exists()) return (kept: const <QuarantinedRecord>[], unnamed: 0, userDeleted: const <String>{});
  final kept = <QuarantinedRecord>[];
  var unnamed = 0;
  await for (final entry in shelf.list()) {
    if (entry is! DirectoryPath) continue;
    if (await _quarantinedRecordAt(entry) case final record?) {
      kept.add(record);
    } else {
      unnamed++;
    }
  }
  return (kept: kept, unnamed: unnamed, userDeleted: await _readUserDeleted(shelf));
}

/// Adds [ids] to the shelf [shelf]'s list of the quarantined records the user deleted. The caller holds the root lock.
Future<void> noteQuarantineUserDeletedUnlocked(DirectoryPath shelf, Set<String> ids) async {
  if (ids.isEmpty) return;
  final current = await _readUserDeleted(shelf);
  if (current.containsAll(ids)) return;
  await shelf.create(recursive: true);
  await shelf.filePath(quarantineUserDeletedName).writeAsString(jsonEncode(([...current, ...ids]..sort())));
}

/// Puts back into the store [store] every record on the shelf beside it that came from it, whose `record.json` reads
/// again as its own id, and whose id neither store holds — one taken again from a zip meanwhile is the record of that
/// id, and a second copy would be two records of one id; answers the ids put back. The note goes with the move:
/// the record is off the shelf. A record still unreadable stays where it is, so a scan does not move it back and forth.
///
/// Called by each store's scan under the root lock it holds, before the store is listed, so a record put back is
/// listed by the same scan. A move that fails leaves the record on the shelf, logged.
Future<List<String>> releaseRepairedQuarantinesUnlocked(DirectoryPath store) async {
  final shelf = store.parent / 'quarantine';
  final released = <String>[];
  if (!await shelf.exists()) return released;
  final candidates = <QuarantinedRecord>[];
  try {
    await for (final entry in shelf.list()) {
      if (entry is! DirectoryPath) continue;
      final record = await _quarantinedRecordAt(entry);
      if (record != null && record.store == store.name) candidates.add(record);
    }
  } catch (error, stackTrace) {
    logger.w('The quarantine shelf could not be listed; nothing on it is put back.', error, stackTrace);
    return released;
  }
  for (final record in candidates) {
    final destination = store / record.id;
    try {
      if (await (store.parent / 'active' / record.id).exists() ||
          await (store.parent / 'archive' / record.id).exists()) {
        continue;
      }
      final body = record.directory.filePath('record.json');
      if (!await body.exists() || !CharaDetailRecord.readsAs(await body.readAsString(), record.id)) continue;
      final moved = await record.directory.moveAsyncSafe(destination);
      if (moved == null) continue;
      await moved.filePath(quarantineOriginName).delete(emptyOk: true);
      released.add(record.id);
      logger.i('Put the repaired record ${record.id} back from the quarantine shelf.');
    } catch (error, stackTrace) {
      logger.w('The quarantined record ${record.id} could not be put back.', error, stackTrace);
    }
  }
  return released;
}
