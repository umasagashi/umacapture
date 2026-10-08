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

final class EditMemo extends Op {
  const EditMemo(super.device, this.id, this.value);
  final String id;
  final String? value;
  @override
  String toString() => '$device: memo $id = $value';
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

/// One sync round: pull to the last page, then push 1–5. [pageSize] sets every `changes` page.
final class SyncRound extends Op {
  const SyncRound(super.device, {this.pageSize = 500});
  final int pageSize;
  @override
  String toString() => '$device: sync${pageSize == 500 ? '' : ' (page $pageSize)'}';
}

final class Pull extends Op {
  const Pull(super.device, {this.pageSize = 500});
  final int pageSize;
  @override
  String toString() => '$device: pull${pageSize == 500 ? '' : ' (page $pageSize)'}';
}

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
