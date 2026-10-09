// Operations as values, so any sequence can be built, printed, stored and replayed (the generator
// and the shrinker in `random_check.dart` work on lists of these). Both rule sets read the same
// operations; an operation a rule set has no path for is not applicable there.

sealed class Op {
  const Op(this.device);
  final String device;
}

/// A capture of a new record whose content and images come from its own capture.
final class Capture extends Op {
  const Capture(super.device, this.id, this.captured, {this.withImages = true});
  final String id;
  final int captured;
  final bool withImages;
  @override
  String toString() => '$device: capture $id@$captured${withImages ? '' : ' (no images)'}';
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
  const Archive(super.device, this.id, this.option);
  final String id;
  final String option;
  @override
  String toString() => '$device: archive $id ($option)';
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
  const EditMemo(String device, String id, this.value, {Column column = memoColumn}) : super(device, id, column);
  @override
  final String? value;
  @override
  String toString() {
    final v = value;
    final shown = overMemoLimit(v) ? '${v!.substring(0, 12)}…(${v.runes.length} chars)' : v;
    return '$device: memo $id${column == memoColumn ? '' : ' [${column.key}]'} = $shown';
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

/// A pair of records offered as a merge candidate, dismissed, or offered again ([dismissed] false).
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

/// The inheritance resolver links record [id]'s parent slot [slot] (1 or 2) to record [parent] and
/// writes the relation bonus it computed ([bonus]). The resolver fills only a slot the device shows
/// empty.
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
  const ExportZip(super.device, this.id, this.slot);
  final String id;
  final String slot;
  @override
  String toString() => '$device: export $id -> $slot';
}

final class ImportZip extends Op {
  const ImportZip(super.device, this.slot);
  final String slot;
  @override
  String toString() => '$device: import $slot';
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

/// The user asks for a sync now, or the app starts again: a device a full storage holds back tries
/// again in its next round.
final class Resume extends Op {
  const Resume(super.device);
  @override
  String toString() => '$device: resume';
}
