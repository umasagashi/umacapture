// What the judge may see of the world: the stores as a user (or an operator reading the server)
// would see them. Plain data with no reference to the rule core, so the judge cannot share a
// mistake with the rules through a common type.

import 'ops.dart';

class ObservedRecord {
  const ObservedRecord({
    required this.id,
    required this.contentSet,
    required this.archiveOption,
    required this.imageSet,
    required this.forkedFrom,
    required this.hasSnapshot,
    this.links = const {},
    this.recognition,
    this.holdsBody = true,
  });

  final String id;

  /// Whether the device holds the recognised content the record shows. Rules that keep it inside the
  /// record always do.
  final bool holdsBody;

  /// Which capture the recognised content came from.
  final String contentSet;

  /// Null when the record is active.
  final String? archiveOption;

  /// The source of the image files on this device, or null when it has none.
  final String? imageSet;
  final String? forkedFrom;

  /// Whether the device keeps the server row it last saw for this record. It has none for a record
  /// it took in from a zip under that record's own id and has not synced since, and for every
  /// record after its sync state file is lost.
  final bool hasSnapshot;

  /// The record's inheritance link as written in it: `parent1` and `parent2` (record ids) and `bonus`
  /// (the relation bonus); a field never written is absent. Empty under rules that do not link
  /// records.
  final Map<String, ObservedValue> links;

  /// The R# of the body the record shows, under rules whose devices show one per source; else null.
  final int? recognition;
}

/// One annotation cell: the value of [Cell.column] on record [Cell.id].
typedef Cell = ({Column column, String id});

/// A value a user wrote, and the time of the edit that wrote it.
class ObservedValue {
  const ObservedValue(this.value, this.time);
  final String? value;
  final int time;
}

class ObservedDevice {
  const ObservedDevice({
    required this.records,
    required this.annotations,
    required this.downloadImages,
    this.oldApp = false,
    this.titles = const {},
    this.dismissed = const {},
    this.held = false,
    this.roomRefusals = 0,
    this.confirmedBodies = const {},
  });

  /// The records the device lists.
  final Map<String, ObservedRecord> records;

  /// The recognised contents the records show in the state the device last received from the
  /// server, each by the name the server keeps it under ([Observation.serverBodies]).
  final Set<String> confirmedBodies;

  /// The annotation cells of the records the device lists.
  final Map<Cell, ObservedValue> annotations;
  final bool downloadImages;

  /// The device runs an app from before the operation log: it writes no log, and what it shows has
  /// no version.
  final bool oldApp;

  /// Column → its name (null: removed), for every column a title was ever written to.
  final Map<Column, ObservedValue> titles;

  /// Pair ([Dismiss.pair]) → `dismissed`, or null when offered again, for every pair of records the
  /// device lists that was ever dismissed.
  final Map<String, ObservedValue> dismissed;

  /// The device shows that a full storage holds part of what it has to send back.
  final bool held;

  /// How many times the server has refused this device a body or an image for room.
  final int roomRefusals;
}

/// What a device did with the zip it was asked to take in, as the device itself knows it: facts of the
/// import, which the judge is told rather than left to read off the operations the log holds
/// afterwards.
class ObservedImport {
  const ObservedImport({
    required this.refused,
    required this.known,
    required this.removed,
    required this.withOperations,
    required this.wrote,
  });

  /// The device listed the zip's record archived, and took nothing in.
  final bool refused;

  /// Before the import the device's log held a record of the zip's id: one it listed, or one it had
  /// removed or received the removal of ([removed]).
  final bool known;
  final bool removed;

  /// The device took the zip in with the operations it carried: its log holds them from here on.
  /// Else it took the zip's record in alone — the zip carried none, or the device left them out.
  final bool withOperations;

  /// The operations the device wrote of its own in the import (their ids): the root of a record it
  /// took in alone and did not know, a put, a recognition, and the links and the archive stage that
  /// go with them. None of the operations the zip carried.
  final Set<String> wrote;
}

class ObservedRow {
  const ObservedRow({
    required this.id,
    required this.alive,
    required this.archiveOption,
    required this.contentSet,
    required this.imageSet,
    this.links = const {},
    this.body,
  });

  /// The recognised content a live row shows, by the name the server keeps it under
  /// ([Observation.serverBodies]); null for a removed row, and under rules that keep it inside the row.
  final String? body;

  /// The values of [ObservedRecord.links], for a live row.
  final Map<String, String?> links;

  final String id;
  final bool alive;

  /// Null when active (or deleted).
  final String? archiveOption;
  final String? contentSet;

  /// The source of the image body the server holds for this row, or null.
  final String? imageSet;
}

class Observation {
  const Observation({
    required this.rows,
    required this.serverAnnotations,
    required this.imageForm,
    required this.devices,
    required this.fingerprint,
    this.serverTitles = const {},
    this.serverDismissed = const {},
    this.serverImages = const {},
    this.serverBodies = const {},
    this.serverOperations = 0,
  });

  /// The recognised contents the server holds apart from its rows, by name, whether or not a live row
  /// shows them; empty under rules that keep them inside the rows.
  final Set<String> serverBodies;

  /// How many operations the server stores, under rules whose server stores operations.
  final int serverOperations;

  final Map<String, ObservedRow> rows;

  /// The annotation cells of the server's live rows.
  final Map<Cell, String?> serverAnnotations;

  /// As [ObservedDevice.titles] and [ObservedDevice.dismissed], on the server.
  final Map<Column, String?> serverTitles;
  final Map<String, String?> serverDismissed;

  /// The account's image form (`png` / `jpeg` / `none`).
  final String imageForm;
  final Map<String, ObservedDevice> devices;

  /// Changes whenever anything in the world changes, including state the judge does not read.
  final String fingerprint;

  /// The image bodies the server holds whether or not a live row shows them (one kept after its
  /// release, say), for rules whose server keeps such bodies; the others list none here.
  final Set<String> serverImages;

  Iterable<ObservedRow> get liveRows => rows.values.where((r) => r.alive);
}
