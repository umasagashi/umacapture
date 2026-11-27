// What a sync round asks the user before it puts a merge's result in place on the device: the changes of the device's
// records, images, ratings and memos the result would make that lose what the device holds — a record deleted, one
// absorbed by a merge, one archived, one whose body or images are replaced, a rating or memo overwritten or cleared.
// Each such change is a confirmation item ([SyncConfirmItem]); [syncConfirmItemsOf] counts them, a pure function of the
// merge and the device's list. An approval is of the items it was asked of: an attempt puts its result in place only
// where every item it applies is one the user approved in that round, the value it applies included.

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '/src/chara_detail/archive_executor_types.dart';
import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/record_sync_list.dart';
import '/src/chara_detail/record_sync.dart' show syncConfirmApprove;
import '/src/chara_detail/record_sync_merge.dart';

/// What a confirmation item does to a record of the device.
enum SyncConfirmKind {
  /// The record is removed: the other device deleted it.
  deleted,

  /// The record is removed: a merge absorbed it into another record.
  absorbed,

  /// The record is archived, or archived further: its images are shrunk or dropped.
  archived,

  /// The record's body, its parents or its images are replaced by another record's of the same id; or the device's
  /// version split off it is placed nowhere.
  replaced,
}

/// What a record holds that a confirmation item compares: the ids it absorbed, its body's content, time and parents,
/// and its archive stage — and, of the record a round applies, its binding, which decides the images it lets go.
@immutable
class SyncRecordPrint {
  const SyncRecordPrint._(this.absorbed, this.content, this.time, this.parents, this.stage, this.binding);

  /// The print of the device's record [record], as a round reads it: without its binding, which a round in parts writes
  /// on a record held back without changing anything the user sees.
  factory SyncRecordPrint.read(SyncRecord record) => SyncRecordPrint._(
    record.absorbed,
    record.body.content,
    record.body.time,
    record.body.parents,
    record.stage,
    null,
  );

  /// The print of the record [record] a round applies, with its binding.
  factory SyncRecordPrint.applied(SyncRecord record) => SyncRecordPrint._(
    record.absorbed,
    record.body.content,
    record.body.time,
    record.body.parents,
    record.stage,
    record.body.binding,
  );

  final Set<String> absorbed;
  final String content;
  final int time;
  final Map<String, String> parents;
  final SyncValue<ArchiveImageOption?> stage;
  final RecordBinding? binding;

  static const _sets = SetEquality<String>();
  static const _maps = MapEquality<String, String>();

  @override
  bool operator ==(Object other) =>
      other is SyncRecordPrint &&
      _sets.equals(absorbed, other.absorbed) &&
      content == other.content &&
      time == other.time &&
      _maps.equals(parents, other.parents) &&
      stage == other.stage &&
      binding == other.binding;

  @override
  int get hashCode => Object.hash(_sets.hash(absorbed), content, time, _maps.hash(parents), stage, binding);
}

/// One change a round would make on the device that the user confirms first. Two items are one item where each of
/// their values is equal: what they do, to what, the device's value the round read, and the value it applies.
@immutable
sealed class SyncConfirmItem {
  const SyncConfirmItem(this.id);

  /// The record the item changes.
  final String id;
}

/// A change of the device's record [id], which the round read as [was].
final class SyncRecordChange extends SyncConfirmItem {
  SyncRecordChange(this.kind, super.id, {required this.was, this.to, Set<String> into = const {}})
    : into = Set.unmodifiable(into);

  final SyncConfirmKind kind;
  final SyncRecordPrint was;

  /// The record the round applies in its place: of [SyncConfirmKind.archived] and [SyncConfirmKind.replaced]; none of a
  /// removal, and of a version split off that is placed nowhere.
  final SyncRecordPrint? to;

  /// Of [SyncConfirmKind.absorbed], the records of the result that absorb it.
  final Set<String> into;

  static const _sets = SetEquality<String>();

  @override
  bool operator ==(Object other) =>
      other is SyncRecordChange &&
      kind == other.kind &&
      id == other.id &&
      was == other.was &&
      to == other.to &&
      _sets.equals(into, other.into);

  @override
  int get hashCode => Object.hash(kind, id, was, to, _sets.hash(into));

  @override
  String toString() => 'SyncRecordChange(${kind.name}, $id)';
}

/// A rating or memo of the record [id] in [column] ([syncColumnOf]) the round overwrites with [to], or clears ([to]
/// none, or of a null value): the device held [was].
final class SyncCellChange extends SyncConfirmItem {
  const SyncCellChange(this.column, super.id, {required this.was, this.to});

  final String column;
  final SyncValue<String?> was;
  final SyncValue<String?>? to;

  /// Whether the round clears the cell.
  bool get clears => to?.value == null;

  @override
  bool operator ==(Object other) =>
      other is SyncCellChange && column == other.column && id == other.id && was == other.was && to == other.to;

  @override
  int get hashCode => Object.hash(column, id, was, to);

  @override
  String toString() => 'SyncCellChange($column, $id)';
}

/// What a round asks the user to approve: of the round of [account], the items [items]; and, for the screen that asks,
/// the title of each column of a [SyncCellChange] of them as the device held it when the round read it ([titles]).
class SyncConfirmRequest {
  SyncConfirmRequest({
    required this.account,
    required Set<SyncConfirmItem> items,
    Map<String, String?> titles = const {},
  }) : items = Set.unmodifiable(items),
       titles = Map.unmodifiable(titles);

  final String account;
  final Set<SyncConfirmItem> items;

  /// Column ([syncColumnOf]) → the device's title of it; null where the device held none.
  final Map<String, String?> titles;
}

/// Asks the user to approve [SyncConfirmRequest]: true where they approve it, false where they decline.
typedef SyncApprove = Future<bool> Function(SyncConfirmRequest request);

/// How every round of the app's asks the user to approve what it would change ([runSyncRound]): through the request
/// the confirmation dialog answers ([syncConfirmApprove]).
final syncApproveProvider = Provider<SyncApprove>(syncConfirmApprove);

int _strength(ArchiveImageOption? stage) => switch (stage) {
  null => 0,
  ArchiveImageOption.resizedJpeg => 1,
  ArchiveImageOption.none => 2,
};

/// The kind of item [was], the device's record, takes where [to] is applied in its place: archived where [to] is
/// archived further; else replaced where it shows another body, other parents or images the device's do not agree
/// with; else none.
SyncConfirmKind? _changeOf(SyncRecord was, SyncRecord to) {
  if (_strength(to.stage.value) > _strength(was.stage.value)) return SyncConfirmKind.archived;
  if (!was.body.sameAs(to.body) || was.body.time != to.body.time || !was.body.sameParents(to.body)) {
    return SyncConfirmKind.replaced;
  }
  return null;
}

/// The confirmation items of a round that puts [merged] in place on the device that holds [local], leaving the ids
/// [kept] as they are: of each of the device's records the round removes, absorbs into another, archives further or
/// replaces, and of each rating and memo of the device's that holds a value the result does not hold.
///
/// - A record the result removes is [SyncConfirmKind.absorbed] where a record of the result absorbs it, else
///   [SyncConfirmKind.deleted] — the records `_apply` removes.
/// - The device's record of an id the result holds is compared with the result's record of that id, whether or not
///   it is one a record of the device is split off to.
/// - The device's record split off its id (S7) is compared with the result's record of the id it is split off to, not
///   with the record of its own id, which is the server's: the device's version lives on there. One placed nowhere is
///   [SyncConfirmKind.replaced] with nothing applied in its place.
/// - A cell of the device's goes with its record, to the id it is split off to, and with a record placed nowhere,
///   nowhere: it is compared with the result's cell where it goes.
///
/// Counts no new record, no record the result keeps for a removal undone (S4), no column title, no dismissed pair and
/// nothing of a record on the quarantine shelf (those are of [kept]).
Set<SyncConfirmItem> syncConfirmItemsOf(RecordSyncOutcome merged, SyncList local, Set<String> kept) {
  final result = merged.result;
  final items = <SyncConfirmItem>{};
  for (final MapEntry(key: id, value: row) in local.rows.entries) {
    if (kept.contains(id)) continue;
    final was = row.record;
    final print = SyncRecordPrint.read(was);
    if (merged.moved[id] case final split?) {
      if (merged.placedNowhere.contains(id)) {
        items.add(SyncRecordChange(SyncConfirmKind.replaced, id, was: print));
      } else if (result.records[split] case final to?) {
        if (_changeOf(was, to) case final kind?) {
          items.add(SyncRecordChange(kind, id, was: print, to: SyncRecordPrint.applied(to)));
        }
      }
      continue;
    }
    final to = result.records[id];
    if (to == null) {
      final into = {
        for (final r in result.records.values)
          if (r.absorbed.contains(id)) r.id,
      };
      items.add(
        SyncRecordChange(into.isEmpty ? SyncConfirmKind.deleted : SyncConfirmKind.absorbed, id, was: print, into: into),
      );
    } else if (_changeOf(was, to) case final kind?) {
      items.add(SyncRecordChange(kind, id, was: print, to: SyncRecordPrint.applied(to)));
    }
  }
  for (final MapEntry(key: (column, id), value: was) in local.cells.entries) {
    if (was.value == null || kept.contains(id)) continue;
    final split = merged.moved[id];
    final goesTo = split == null ? id : (merged.placedNowhere.contains(id) ? null : split);
    final to = goesTo == null ? null : result.cells[(column, goesTo)];
    if (to?.value != was.value) items.add(SyncCellChange(column, id, was: was, to: to));
  }
  return items;
}
