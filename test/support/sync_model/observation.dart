// What the judge may see of the world: the stores as a user (or an operator reading the server)
// would see them. Plain data with no reference to the rule core, so the judge cannot share a
// mistake with the rules through a common type.

class ObservedRecord {
  const ObservedRecord({
    required this.id,
    required this.contentSet,
    required this.archiveOption,
    required this.imageSet,
    required this.forkedFrom,
    required this.hasSnapshot,
  });

  final String id;

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
}

class ObservedMemo {
  const ObservedMemo(this.value, this.time);
  final String? value;
  final int time;
}

class ObservedDevice {
  const ObservedDevice({required this.records, required this.memos, required this.downloadImages});

  final Map<String, ObservedRecord> records;
  final Map<String, ObservedMemo> memos;
  final bool downloadImages;
}

class ObservedRow {
  const ObservedRow({
    required this.id,
    required this.alive,
    required this.archiveOption,
    required this.contentSet,
    required this.imageSet,
  });

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
    required this.serverMemos,
    required this.imageForm,
    required this.devices,
    required this.fingerprint,
  });

  final Map<String, ObservedRow> rows;
  final Map<String, String?> serverMemos;

  /// The account's image form (`png` / `jpeg` / `none`).
  final String imageForm;
  final Map<String, ObservedDevice> devices;

  /// Changes whenever anything in the world changes, including state the judge does not read.
  final String fingerprint;

  Iterable<ObservedRow> get liveRows => rows.values.where((r) => r.alive);
}
