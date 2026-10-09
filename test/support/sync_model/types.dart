// Value types shared by the sync rule core, the fake server and the in-memory device.
//
// The judge (`judge.dart`) does not import this file: it reads the world only through
// `observation.dart`, so a mistake in these types cannot be shared by the rules and the judge.

/// Which rules the core follows.
enum Rules {
  /// The rules as designed.
  designed,

  /// The designed rules with three shortcuts in retiring records, kept as a positive control: a
  /// received tombstone of a deleted record drops the unsent merge's retired set that its delete
  /// intent carries (row 302 instead of 353), and so does the same id entering the store again
  /// (row 354 drops the set instead of moving it into the record's m); the terminal of a
  /// retirement is read from the device's own copy or `retired_index` before the server, and its
  /// row is passed through `reconcile` only when the device lacks that record (row 309); and a
  /// record whose server row has the image form `none` never sends images, even an active record
  /// whose images a merge gave it (push-4 (i)(ii)). Only those rows branch on this.
  retirementShortcuts,

  /// The lineage rules (`lineage_core.dart`), run by `LineageWorld` instead of `World`; the rest of
  /// this file and `core.dart` never see this value.
  lineage,

  /// The operation-log rules (`oplog_core.dart`), run by `OplogWorld`; likewise unseen here.
  oplog,
}

enum RowState { active, archived, deleted }

/// Image form of an index row: `pending` means the row has no image body yet.
abstract final class ImageForm {
  static const png = 'png';
  static const jpeg = 'jpeg';
  static const none = 'none';
  static const pending = 'pending';
}

abstract final class ArchiveOption {
  static const none = 'none';
  static const resizedJpeg = 'resized_jpeg';

  /// The record is archived but its option file is missing; sent as `resized_jpeg`.
  static const unknown = '?';
}

/// Source name of a record with no image files at all.
const noImageSet = 'img:none';

/// The hash of a record's stored body (`meta.zip`): its recognised content and version, and the
/// `merged_ids.json` inside it, so a merge that keeps the survivor's content still changes it.
String metaHashOf(String contentSet, int version, Set<String> mergedIds) =>
    '$contentSet@$version[${(mergedIds.toList()..sort()).join(',')}]';

/// One index row, in the shape every row-carrying answer uses (`changes`, `?ids=`, accepted `row`,
/// 410 and `conflict`). The snapshot W on a device is a copy of one of these.
class Row {
  const Row({
    required this.id,
    required this.state,
    required this.seq,
    this.archiveOption,
    this.contentSet,
    this.version,
    this.captured,
    this.forkedFrom,
    this.imagesForm = ImageForm.pending,
    this.imagesSet,
    this.retiredInto,
    this.absorbed = const {},
    this.metaHash,
  });

  final String id;
  final RowState state;
  final int seq;
  final String? archiveOption;
  final String? contentSet;
  final int? version;
  final int? captured;
  final String? forkedFrom;
  final String imagesForm;
  final String? imagesSet;
  final String? retiredInto;

  /// The ids this record absorbed directly through the server's acceptances (`absorbed`): the ids
  /// a merge onto it tombstoned, and the retired ids that had no row yet. Empty on a tombstone.
  final Set<String> absorbed;

  /// `meta_hash`, written with every accepted body; null on a tombstone.
  final String? metaHash;

  bool get alive => state != RowState.deleted;
  bool get isArchivedNone => state == RowState.archived && archiveOption == ArchiveOption.none;

  Row copyWith({
    RowState? state,
    int? seq,
    String? archiveOption,
    String? contentSet,
    int? version,
    String? imagesForm,
    String? imagesSet,
    bool clearImagesSet = false,
    String? retiredInto,
    Set<String>? absorbed,
    String? metaHash,
  }) => Row(
    id: id,
    state: state ?? this.state,
    seq: seq ?? this.seq,
    archiveOption: archiveOption ?? this.archiveOption,
    contentSet: contentSet ?? this.contentSet,
    version: version ?? this.version,
    captured: captured,
    forkedFrom: forkedFrom,
    imagesForm: imagesForm ?? this.imagesForm,
    imagesSet: clearImagesSet ? null : (imagesSet ?? this.imagesSet),
    retiredInto: retiredInto ?? this.retiredInto,
    absorbed: absorbed ?? this.absorbed,
    metaHash: metaHash ?? this.metaHash,
  );

  @override
  String toString() =>
      'Row($id ${state.name}${archiveOption == null ? '' : '($archiveOption)'} cs=$contentSet v=$version '
      'img=$imagesForm/$imagesSet${retiredInto == null ? '' : ' ->$retiredInto'}'
      '${absorbed.isEmpty ? '' : ' abs=${(absorbed.toList()..sort()).join(',')}'} seq=$seq)';
}

/// What a device had seen of a record when it acted on it: the record's content source (null when
/// unknown) and the absorptions it had seen — the `absorbed` of its copy of the server row together
/// with the record's own `merged_ids`. Sent as the base of a merge, of each retired id, and of a
/// delete.
class RecordBase {
  const RecordBase({required this.contentSet, required this.absorbed});

  final String? contentSet;
  final Set<String> absorbed;

  @override
  String toString() => '{$contentSet, [${(absorbed.toList()..sort()).join(',')}]}';
}

/// Whether [row] holds a choice the device that saw [base] had not seen: its content moved on, or it
/// absorbed an id the device did not see it absorb. The server keeps such a record instead of
/// retiring or deleting it (the merge acceptance, the retire function and a delete's root), and the
/// device resolves an intent the server would refuse this way (rows 356 and 357).
bool conflicts(Row row, RecordBase base) =>
    (base.contentSet != null && row.contentSet != base.contentSet) || !base.absorbed.containsAll(row.absorbed);

/// The unsent merge m (`content_set.json`'s `merge` field): what the survivor was when the device
/// merged onto it, and for each retired id what that record was when the device retired it. `base`
/// is null only on a fork's N′, which carries the retired set without a base (it is sent as
/// `created`).
class PendingMerge {
  const PendingMerge({required this.base, required this.retired});

  final RecordBase? base;
  final Map<String, RecordBase> retired;
}

/// A row of `deleted_ids.json` (component K). K = 1 for a delete intent; K = w for a row whose delete
/// of the root was withdrawn (row 357) and which still carries a retired set to send.
class DeleteIntent {
  const DeleteIntent({this.base, this.retired, this.withdrawn = false});

  /// What the deleted record was when the user deleted it (row 337); null on a withdrawn row.
  final RecordBase? base;

  /// The retired set of the unsent merge the deleted record carried (row 337).
  final Map<String, RecordBase>? retired;

  /// K = w: the root is no longer to be deleted; only [retired] remains to be sent.
  final bool withdrawn;

  /// K = 1. A withdrawn row reads as K = 0 everywhere except push-1 and component J.
  bool get deletesRoot => !withdrawn;

  @override
  String toString() => withdrawn ? 'w$retired' : 'K($base${retired == null ? '' : ' $retired'})';
}

/// The device-side components of one stored record (E ∈ {A, R}), as the core reads them.
class RecordView {
  const RecordView({
    required this.id,
    required this.captured,
    required this.contentSet,
    required this.version,
    required this.archive,
    required this.imageSetLocal,
    required this.imageForm,
    required this.m,
    required this.forkedFrom,
    required this.mergedIds,
    required this.snapshotAbsorbed,
  });

  final String id;
  final int captured;
  final String contentSet;
  final int version;

  /// Null for E = A; otherwise the option o of R(o).
  final String? archive;

  /// [noImageSet] when the record has no image files.
  final String imageSetLocal;

  /// `png` / `jpeg`, or null when there are no image files.
  final String? imageForm;
  final PendingMerge? m;
  final String? forkedFrom;

  /// `merged_ids.json`: every id merged into this record, as its own merges and the server body it
  /// last took in record them.
  final Set<String> mergedIds;

  /// The `absorbed` of the device's copy W of this record's server row (empty without a copy, or
  /// while sync is off and the state file is not read).
  final Set<String> snapshotAbsorbed;

  /// What the device has seen of this record (`seen`).
  RecordBase get seen => RecordBase(contentSet: contentSet, absorbed: {...snapshotAbsorbed, ...mergedIds});

  bool get isArchived => archive != null;
  bool get hasImages => imageForm != null;

  /// Component I = match.
  bool get imagesMatch => hasImages && imageSetLocal == contentSet;
  String get metaHash => metaHashOf(contentSet, version, mergedIds);
}
