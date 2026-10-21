// Operations as values, so any sequence can be built, printed, stored and replayed (the generator
// and the shrinker in `random_check.dart` work on lists of these). Both rule sets read the same
// operations; an operation a rule set has no path for is not applicable there.

sealed class Op {
  const Op(this.device);
  final String device;
}

/// A capture of a new record whose content and images come from its own capture.
final class Capture extends Op {
  const Capture(
    super.device,
    this.id,
    this.captured, {
    this.withImages = true,
    this.beforeTheUpgrade = false,
    this.parents = const {},
  });
  final String id;
  final int captured;
  final bool withImages;

  /// A record the app captured before it bound what a record shows to its images: under the rules of file
  /// sync, a record that carries no binding until the device works it out from its directory. No other
  /// rule set has such a record.
  final bool beforeTheUpgrade;

  /// What the captured screens show of the inheritance: slot (1, 2) → the capture of the parent that slot
  /// names, none where the slot names no parent. A fact of the capture, and so of every content read from
  /// its images, from which a resolver derives a record's parents ([Link]). Only the rules of file sync
  /// read it; the others take the parent a [Link] names.
  final Map<int, String> parents;
  @override
  String toString() =>
      '$device: capture $id@$captured${withImages ? '' : ' (no images)'}${beforeTheUpgrade ? ' (before the upgrade)' : ''}'
      '${parents.isEmpty ? '' : ' (parents ${[for (final e in parents.entries) '${e.key}=${e.value}'].join(',')})'}';
}

/// How a removal reached a record without leaving the trace the lineage rules read. The judge reads
/// a removal of either kind as the user's own delete or merge.
enum Untracked {
  /// Made through the record store, by the app the rules describe.
  none,

  /// Made by an app that writes no lineage and no delete tombstone: a version from before lineages,
  /// or v0.3.0 used on the same data directory.
  legacyApp,

  /// The storage screen's raw path delete, which bypasses the record store's delete path.
  storageScreen,
}

/// The GUI merge of [a] and [b], keeping the content of [contentFrom].
final class Merge extends Op {
  const Merge(super.device, this.a, this.b, {required this.contentFrom, this.untracked = Untracked.none});
  final String a;
  final String b;
  final String contentFrom;

  /// [Untracked.none] or [Untracked.legacyApp]; the storage screen does not merge.
  final Untracked untracked;
  @override
  String toString() => '$device: ${_untrackedPrefix(untracked)}merge $a+$b keep $contentFrom';
}

final class Delete extends Op {
  const Delete(super.device, this.id, {this.untracked = Untracked.none});
  final String id;
  final Untracked untracked;
  @override
  String toString() => '$device: ${_untrackedPrefix(untracked)}delete $id';
}

String _untrackedPrefix(Untracked u) => u == Untracked.none ? '' : '${u.name} ';

/// [option] is `none` or `resized_jpeg`.
final class Archive extends Op {
  const Archive(super.device, this.id, this.option, {this.untracked = Untracked.none});
  final String id;
  final String option;

  /// [Untracked.none] or [Untracked.legacyApp]; the storage screen does not archive.
  final Untracked untracked;
  @override
  String toString() => '$device: ${_untrackedPrefix(untracked)}archive $id ($option)';
}

/// What an annotation column holds: a rating (a number) or a memo (text).
enum AnnotationKind { rating, memo }

/// An annotation column: what it holds, and the key its values are stored under. A record's
/// annotation is one value per column.
typedef Column = ({AnnotationKind kind, String key});

/// The memo column every rule set has; the operation-log rules also have the columns the generator
/// draws besides it.
const Column memoColumn = (kind: AnnotationKind.memo, key: 'memo');

/// A memo longer than this many characters (code points) is not sent: it stays on the devices whose
/// log holds it, and the server refuses it (413).
const memoSendLimit = 200;

/// Whether [value], typed into a memo column, is longer than [memoSendLimit].
bool overMemoLimit(String? value) => value != null && value.runes.length > memoSendLimit;

/// An edit of one annotation cell: [column] of record [id] set to [value] (null clears it).
sealed class EditAnnotation extends Op {
  const EditAnnotation(super.device, this.id, this.column);
  final String id;
  final Column column;
  String? get value;
}

final class EditMemo extends EditAnnotation {
  const EditMemo(String device, String id, this.value, {Column column = memoColumn, this.fromBeforeTheLimit = false})
    : super(device, id, column);
  @override
  final String? value;

  /// Not an edit a user makes: the memo the cell held before the app limited what a user types, which
  /// carries no edit time. Under the rules of file sync, the only way a memo over [memoSendLimit] is
  /// in a cell.
  final bool fromBeforeTheLimit;
  @override
  String toString() {
    final v = value;
    final shown = overMemoLimit(v) ? '${v!.substring(0, 12)}…(${v.runes.length} chars)' : v;
    return '$device: ${fromBeforeTheLimit ? 'memo from before the limit' : 'memo'} $id'
        '${column == memoColumn ? '' : ' [${column.key}]'} = $shown';
  }
}

/// A rating saved by the rating slider: one edit per value saved.
final class EditRating extends EditAnnotation {
  const EditRating(super.device, super.id, super.column, this.rating);
  final int? rating;
  @override
  String? get value => rating?.toString();
  @override
  String toString() => '$device: rating $id [${column.key}] = $value';
}

/// A column's name set, or the column removed (null).
final class Title extends Op {
  const Title(super.device, this.column, this.name);
  final Column column;
  final String? name;
  @override
  String toString() => '$device: title ${column.key} = $name';
}

/// The storage screen deletes the store of [column]: its title and every value the device holds of it.
final class DeleteColumnStore extends Op {
  const DeleteColumnStore(super.device, this.column);
  final Column column;
  @override
  String toString() => '$device: delete column store ${column.key}';
}

/// A pair of records offered as a merge candidate, dismissed, or offered again ([dismissed] false).
/// The rules of file sync, as the app of today, offer no pair again by itself: there the pairs
/// dismissed are offered again all at once ([DeleteDismissalFile]).
final class Dismiss extends Op {
  const Dismiss(super.device, this.a, this.b, {required this.dismissed});
  final String a;
  final String b;
  final bool dismissed;

  /// The pair, in either order.
  String get pair => ([a, b]..sort()).join('+');
  @override
  String toString() => '$device: ${dismissed ? 'dismiss' : 'undismiss'} $a+$b';
}

/// The storage screen's delete of the file [device] keeps its dismissed pairs in: every pair is
/// offered again there.
final class DeleteDismissalFile extends Op {
  const DeleteDismissalFile(super.device);
  @override
  String toString() => '$device: delete dismissal file';
}

/// The inheritance resolver links record [id]'s parent slot [slot] (1 or 2) to record [parent] and
/// writes the relation bonus it computed ([bonus]). The resolver fills only a slot the device shows
/// empty. Under the rules of file sync the resolver derives the parent itself, from what the record shows
/// ([Capture.parents]), and [parent] is not read ([SyncWorld.derivesParents]).
final class Link extends Op {
  const Link(super.device, this.id, this.slot, this.parent, this.bonus);
  final String id;
  final int slot;
  final String parent;
  final int bonus;
  @override
  String toString() => '$device: link $id parent$slot = $parent (bonus $bonus)';
}

/// Export [id] to a zip kept under [slot].
final class ExportZip extends Op {
  const ExportZip(super.device, this.id, this.slot, {this.beforeTheUpgrade = false});
  final String id;
  final String slot;

  /// A zip the app made before it bound what a record shows to its images ([Capture.beforeTheUpgrade]):
  /// under the rules of file sync, one that carries no binding. No other rule set has such a zip.
  final bool beforeTheUpgrade;
  @override
  String toString() => '$device: export $id -> $slot${beforeTheUpgrade ? ' (before the upgrade)' : ''}';
}

final class ImportZip extends Op {
  const ImportZip(super.device, this.slot, {this.beforeTheUpgrade = false});
  final String slot;

  /// Taken in by the app from before the upgrade: what it leaves is a value from before the upgrade, as a
  /// [Capture.beforeTheUpgrade] is.
  final bool beforeTheUpgrade;
  @override
  String toString() => '$device: import $slot${beforeTheUpgrade ? ' (before the upgrade)' : ''}';
}

final class Rerecognize extends Op {
  const Rerecognize(super.device, this.id, this.version);
  final String id;
  final int version;
  @override
  String toString() => '$device: rerecognize $id v$version';
}

/// The account's image form, changed on this device (`png` / `jpeg` / `none`).
final class SetImageForm extends Op {
  const SetImageForm(super.device, this.form);
  final String form;
  @override
  String toString() => '$device: image form $form';
}

/// One sync round: pull to the last page, then push 1–5. [pageSize] sets every `changes` page. Under
/// the operation-log rules: send, receive, fold the log again and the image step, each once.
final class SyncRound extends Op {
  const SyncRound(super.device, {this.pageSize = 500});
  final int pageSize;
  @override
  String toString() => '$device: sync${pageSize == 500 ? '' : ' (page $pageSize)'}';
}

/// The receiving half of a round. Under the operation-log rules: a round in which the server refuses
/// every write from the first (429), so the device sends nothing — no operation, image or release —
/// and receives.
final class Pull extends Op {
  const Pull(super.device, {this.pageSize = 500});
  final int pageSize;
  @override
  String toString() => '$device: pull${pageSize == 500 ? '' : ' (page $pageSize)'}';
}

/// The sending half of a round. Under the operation-log rules: a round that ends with its sending — no
/// answer comes to what follows, or the app stops — so nothing is received and the image step does not
/// run.
final class Push extends Op {
  const Push(super.device);
  @override
  String toString() => '$device: push';
}

/// Sync on/off (for a device that is merely offline, simply do not run its rounds).
final class SetSyncEnabled extends Op {
  const SetSyncEnabled(super.device, {required this.enabled});
  final bool enabled;
  @override
  String toString() => '$device: sync ${enabled ? 'on' : 'off'}';
}

final class LoseStateFile extends Op {
  const LoseStateFile(super.device);
  @override
  String toString() => '$device: lose state file';
}

/// The user deletes the account on [device]: the server drops the account's operations, bodies and
/// images at once. No device's log or records change; every device's next sync logs in again, which
/// makes a new account, in the image form `none` until the user chooses one ([SetImageForm]).
final class DeleteAccount extends Op {
  const DeleteAccount(super.device);
  @override
  String toString() => '$device: delete account';
}

/// How many days the server keeps a released image or body before it deletes it (U-S6).
const retentionDays = 7;

/// [days] days pass. Only the server's retention reads the date ([retentionDays]); [device] is
/// whoever waits.
final class Elapse extends Op {
  const Elapse(super.device, this.days);
  final int days;
  @override
  String toString() => '$device: $days days pass';
}

/// From here until its [Upgrade], [device] runs an app from before the operation log: it keeps no
/// log and does not sync, its merges and deletes leave only `merged_ids` and a missing directory,
/// its archive leaves no option, and its zips carry no operations. Applicable only to a device that
/// holds nothing yet.
final class OldApp extends Op {
  const OldApp(super.device);
  @override
  String toString() => '$device: old app';
}

/// The app of the operation log starts for the first time on [device] and reads what the app before
/// it left on disk (§3.6).
final class Upgrade extends Op {
  const Upgrade(super.device);
  @override
  String toString() => '$device: upgrade';
}

/// The account's storage has no room for another body or image ([full]): the server refuses each new
/// one (507) until it has room again.
final class SetStorageFull extends Op {
  const SetStorageFull(super.device, {required this.full});
  final bool full;
  @override
  String toString() => '$device: storage ${full ? 'full' : 'has room'}';
}

/// The server stores [rows] more operations each day and refuses the rest (429) until the date
/// changes ([Elapse]); null lifts the limit.
final class SetDailyRows extends Op {
  const SetDailyRows(super.device, this.rows);
  final int? rows;
  @override
  String toString() => '$device: daily rows ${rows ?? 'unlimited'}';
}

/// The server answers [reads] reads each day — a page of operations, a body or an image it gives a
/// device — and refuses the rest (429) until the date changes ([Elapse]); null lifts the limit. A
/// round ends at the read the server refuses, as one whose answer never comes.
final class SetDailyReads extends Op {
  const SetDailyReads(super.device, this.reads);
  final int? reads;
  @override
  String toString() => '$device: daily reads ${reads ?? 'unlimited'}';
}

/// A push that ends early. The server answers the first [answered] operations sent; the next one gets
/// no answer — the server having stored it ([stored]: the response is lost, or the app stops before
/// writing it down) or not (the request is lost, or the app stops before it leaves). The round ends
/// there: nothing more is sent, and no pull follows.
final class PushCut extends Op {
  const PushCut(super.device, this.answered, {required this.stored});
  final int answered;
  final bool stored;
  @override
  String toString() => '$device: push cut after $answered (${stored ? 'response' : 'request'} lost)';
}

/// A round of the app's own that ends at a swap with no answer, read on the server's endpoints: the server answers
/// the first [answered] swaps of the round, and the next gets none — the server having swapped it ([stored]: the
/// response is lost, or the app stops before it writes it down) or not (the request is lost). A swap is the app's
/// unit of a push, where the model's round counts each body, image and list it sends ([PushCut]).
final class SwapCut extends PushCut {
  const SwapCut(super.device, super.answered, {required super.stored});

  @override
  String toString() => '$device: swap cut after $answered (${stored ? 'response' : 'request'} lost)';
}

/// A round that ends while it receives. The device sends as in any round, takes the first [received]
/// operations the server numbered after the last one it had, and gets no answer to its next read — the
/// answer is lost, the server refuses the read (429), or the app stops. What it took is part of its
/// log; the round does nothing more, so it takes no body and no image.
final class ReceiveCut extends Op {
  const ReceiveCut(super.device, this.received);
  final int received;

  @override
  String toString() => '$device: receive cut after $received';
}

/// A round of the app's own that ends while it puts what it received in place, read on the device's place: the first
/// [received] writes of the round's result on the device land — each call of the place that writes it is one — and
/// the next one fails, as one does where the app stops. The round does nothing more.
final class PlaceCut extends ReceiveCut {
  const PlaceCut(super.device, super.received);

  @override
  String toString() => '$device: place cut after $received writes';
}

/// The user asks for a sync now, or the app starts again: a device a full storage holds back tries
/// again in its next round.
final class Resume extends Op {
  const Resume(super.device);
  @override
  String toString() => '$device: resume';
}

/// An operation on the quarantine shelf of the rules of file sync, or one that has the record stores scan it: only those
/// rules, on the app's round, have a shelf. The other rule sets have no path for any.
sealed class ShelfOp extends Op {
  const ShelfOp(super.device);
}

/// How a record comes to be one the app cannot read, which a store's scan moves onto the quarantine shelf.
enum QuarantineCause {
  /// Its `record.json` is torn or broken: a save cut short, a file damaged.
  unreadable,

  /// The user deleted its `record.json` alone from the storage view ([N15-22] (b)), which leaves the directory and
  /// rescans the store.
  recordJsonDeleted,
}

/// The record [id] becomes one the app cannot read, as [cause] says, and the scan of its store moves its directory
/// whole onto the quarantine shelf, noting the id: the record, its images and what only the device holds of it go
/// there; its cells and the dismissed pairs that name it stay in their files. Where [noted] is false, the directory on
/// the shelf carries no note of the id: a write's recovery set it aside with none, or the user deleted the note alone
/// from the storage view. The app neither names it nor puts it back.
final class Quarantine extends ShelfOp {
  const Quarantine(super.device, this.id, {this.cause = QuarantineCause.unreadable, this.noted = true});
  final String id;
  final QuarantineCause cause;
  final bool noted;
  @override
  String toString() =>
      '$device: ${cause == QuarantineCause.unreadable ? 'quarantine' : 'delete the record.json of'} $id'
      '${noted ? '' : ', with no note'}';
}

/// The user deletes the record [id] on the quarantine shelf from the storage view ([N15-22] (d)): its directory goes,
/// and the shelf notes the id as one the user deleted. Its cells and the pairs that name it go, as a delete from the
/// list takes them.
final class DeleteQuarantined extends ShelfOp {
  const DeleteQuarantined(super.device, this.id);
  final String id;
  @override
  String toString() => '$device: delete $id from the quarantine shelf';
}

/// The `record.json` of the record [id] on the quarantine shelf is made readable again from outside the app, as it was
/// before the record went there. The next scan of its store puts it back ([Restart]).
final class RepairQuarantined extends ShelfOp {
  const RepairQuarantined(super.device, this.id);
  final String id;
  @override
  String toString() => '$device: repair $id on the quarantine shelf';
}

/// The app starts again: the record stores scan again, and each record on the quarantine shelf whose `record.json`
/// reads again as its own id, and whose id neither store holds, is put back where it came from.
final class Restart extends ShelfOp {
  const Restart(super.device);
  @override
  String toString() => '$device: restart';
}
