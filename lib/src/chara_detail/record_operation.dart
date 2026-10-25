// What a user's operation writes, and at what time: the decisions of the operations on the values sync carries
// ([SyncValue]). Each is a pure function of the values the operation read and of the clock it is handed
// ([SyncWriteTime]): the app hands it the device's clock (`valueWriteTime`), and the sync model its own, so the two
// make one decision. Reading the values and writing the result stay with the caller, inside whatever lock or
// synchronous step it reads and writes in today.

import '/src/chara_detail/archive_executor_types.dart';
import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/record_sync_merge.dart';

/// The time a value written now carries over a value written at `current` (null where there is none, or it carries
/// no time).
typedef SyncWriteTime = int Function(int? current);

/// A value as a device holds it: [time] is null where it carries none — one written before values had times, or none
/// at all.
typedef SyncHeldValue<T> = ({T? value, int? time});

/// The time to write a value at, by a clock reading [now], over a value written at [current]: [now], or the
/// millisecond after [current] where [now] is not after it — so a value a device writes never loses to the one it
/// replaced, however far behind its clock is.
int syncWriteTime(int now, int? current) => current != null && now <= current ? current + 1 : now;

/// A value that held [held] set to [next]: [next], written at [writeAt] over the time [held] carries — or null, no
/// write, where it holds [next] already. A save that leaves a value as it was (a memo opened and closed with OK, a
/// rating set to the one it holds, a title confirmed) keeps the time the value had.
SyncValue<T?>? syncEdit<T>(SyncHeldValue<T> held, T? next, {required SyncWriteTime writeAt}) =>
    held.value == next ? null : SyncValue(next, writeAt(held.time));

/// A column storage removed: each record field of [cells] and the [title] set to none ([syncEdit]).
///
/// [cells] maps a record id to its field. The result holds an entry for every field of a [listed] record — the none
/// written at [writeAt], or null where the field held none already and keeps its time — and none for a record that is
/// not listed, whose field goes with what the storage held. [title] is the same: null where it is none already. A null
/// [listed] is a listing that could not be read, and counts every record as listed.
({Map<String, SyncValue<T?>?> cells, SyncValue<String?>? title}) syncRemoveColumn<T>({
  required Map<String, SyncHeldValue<T>> cells,
  required SyncHeldValue<String> title,
  required Set<String>? listed,
  required SyncWriteTime writeAt,
}) => (
  cells: {
    for (final MapEntry(key: id, value: held) in cells.entries)
      if (listed?.contains(id) ?? true) id: syncEdit<T>(held, null, writeAt: writeAt),
  },
  title: syncEdit<String>(title, null, writeAt: writeAt),
);

/// What a delete of the records [ids] keeps of the values carried outside their directories: the [cells] — keyed by
/// column and record id — of the records it does not delete, and the dismissed [pairs] ([syncPairOf]) neither of
/// whose records it deletes. A dismissal is of the record the device listed when it was made, so one of a deleted
/// record goes, and is not left to whatever record that id holds later.
({Map<(String, String), C> cells, Set<String> pairs}) syncForget<C>({
  required Map<(String, String), C> cells,
  required Set<String> pairs,
  required Set<String> ids,
}) => (
  cells: {
    for (final MapEntry(:key, :value) in cells.entries)
      if (!ids.contains(key.$2)) key: value,
  },
  pairs: {
    for (final pair in pairs)
      if (!pair.split('+').any(ids.contains)) pair,
  },
);

/// The ids a merge this device started into a record and has not finished holds back from a sync round ([R6-3],
/// [N15-02]), by the ids its merges in progress retire ([retired]: the retired ids of the record's
/// `merges_in_progress.json`, none where it has none, null where it cannot be read): none where none of them is a
/// record still ([isRecord]) — the record is settled —; else every one of them, which waits with the record until the
/// merge is finished. Null where they cannot be read: what the merges would retire is unknown, and the record is one the
/// device cannot read.
Set<String>? syncMergeWaiting(Iterable<String>? retired, {required bool Function(String id) isRecord}) {
  if (retired == null) return null;
  return retired.any(isRecord) ? {...retired} : const {};
}

/// The ids a sync round keeps as the server lists them, in the list it sends and on the device, for the records the
/// device holds and cannot read ([R7-3], [N15-20], [N15-26]) — those on its quarantine shelf ([shelf] by the ids their
/// notes name, and [unnamed] of them whose note names none), and those it could not open or read ([unread]) —, and for
/// the merges it started and has not finished ([R6-3], [N15-02]: [merging], the ends of those merges with the ids they
/// retire ([syncMergeWaiting])): none where it holds none of either; else every id of [unread] and of [merging], and,
/// where it holds a record it cannot read, of the ids the device holds no record of ([held]: each record it read, with
/// the ids it absorbed), every id on the shelf, and every id the device last agreed on with the server ([agreed]) but
/// one a record it read absorbed and one its user deleted from the shelf ([deleted]). An id the device holds a record
/// of is that record's, whatever the shelf holds of it: a record taken again from a zip while the one it was is on the
/// shelf. Each of those ids keeps with it every id of its unit ([syncUnitsOf] of the round's [records] — the device's,
/// the server's and the result's — and of the records split off ([splitFrom]), over their ids and the ids they
/// absorbed).
///
/// What a record the device cannot read absorbed cannot be read either, so of an id gone from the device it cannot be
/// told whether that record absorbed it or the user deleted it, and every such id is read on the wide side: kept, until
/// the device holds no record it cannot read. A record the user deletes from the list while it holds one is so kept,
/// and its delete does not reach the server meanwhile. A record on the shelf whose id the device cannot tell is such a
/// record, and its own id is one of those read on the wide side: whether the shelf holds a record is whether a
/// directory is on it, not whether a note names one. A shelf that could not be read ([shelf] null) is read as one that
/// holds a record.
///
/// A merge left half way is no record the device cannot read: what it retires is told by its mark, so it holds back
/// what it left half way and nothing more. A delete beside it goes.
///
/// What the server's list joins to a kept id cannot be put in place without it either, on receiving as on sending
/// ([N15-26]): a record the server's record of a kept id absorbed, which would go, and a record of the server's that
/// absorbed a kept id, which would take its images from a record the device cannot read ([R4-8] 5). So the unit goes
/// whole, the device's own records of it included, until the device reads every record of it again.
Set<String> syncUnreadHeld({
  required Set<String>? shelf,
  required int unnamed,
  required Set<String> unread,
  required Set<String> merging,
  required Set<String> deleted,
  required Set<String> agreed,
  required Map<String, Set<String>> held,
  required Iterable<SyncRecord> records,
  required Map<String, String> splitFrom,
}) {
  final wide = shelf == null || shelf.isNotEmpty || unnamed > 0 || unread.isNotEmpty;
  if (!wide && merging.isEmpty) return const {};
  final absorbed = {for (final ids in held.values) ...ids};
  final kept = {
    ...unread,
    ...merging,
    if (wide)
      for (final id in {...?shelf, ...agreed})
        if (!held.containsKey(id) &&
            ((shelf?.contains(id) ?? false) || (!absorbed.contains(id) && !deleted.contains(id))))
          id,
  };
  // An id on the shelf is no record's id: it joins the records only by what absorbed it.
  final ids = {for (final r in records) ...r.absorbed, for (final r in records) r.id};
  return {
    ...kept,
    for (final unit in syncUnitsOf(ids, records, splitFrom))
      if (unit.any(kept.contains)) ...unit,
  };
}

/// The ids [ids] in units: a record of [records] joined with the ids it absorbed, and a record split off with the
/// record it is split off ([splitFrom]: the id of each record split off → the id it is split off). The units in the
/// order of their least id, each one's ids sorted.
List<List<String>> syncUnitsOf(Set<String> ids, Iterable<SyncRecord> records, Map<String, String> splitFrom) {
  final up = <String, String>{};
  String root(String id) => switch (up[id]) {
    final u? => up[id] = root(u),
    null => id,
  };
  void join(String a, String b) {
    final (x, y) = (root(a), root(b));
    if (x != y) up[x.compareTo(y) < 0 ? y : x] = x.compareTo(y) < 0 ? x : y;
  }

  for (final r in records) {
    for (final id in r.absorbed) {
      join(r.id, id);
    }
  }
  splitFrom.forEach(join);
  final units = <String, List<String>>{};
  for (final id in ids.toList()..sort()) {
    (units[root(id)] ??= []).add(id);
  }
  return units.values.toList()..sort((a, b) => a.first.compareTo(b.first));
}

/// Of the records [deleted] from the quarantine shelf, those whose values carried outside their directories go with
/// them ([syncForget]): the ids of which neither store holds a record ([stored]: those a store holds one of). One a
/// store holds is the record of that id — taken again from a zip while the one it was stayed on the shelf — and keeps
/// what it carries.
Set<String> syncShelfDeletesForgotten(Set<String> deleted, {required Set<String> stored}) => {
  for (final id in deleted)
    if (!stored.contains(id)) id,
};

/// The body a recognizer's reading [read] writes over the body the record holds, [held] — none where there is no
/// record yet (a capture) — or null, no write, where the record holds what [read] shows already.
///
/// What a body shows is its content ([SyncBody.content]) and its icon ([SyncBody.icon]), and the decision of whether
/// and when it is written is that of an edit of the two ([syncEdit]): the content and icon of [read] at [writeAt] over
/// the time [held] carries. So a re-recognition that read the same content but cut the icon into other bytes writes
/// the body, naming the new icon; the binding and geometry it keeps are worked out, and carry no time ([R5-3]). A body
/// written over a held one keeps the held body's binding, geometry and parents — a re-recognition reads the images the
/// held body was read from, which it does not move the screen on, and the parents go with the record — and its content
/// is [read]'s, and so is its icon where the held body's binding is worked out: the recognizer cut the icon again from
/// those images. Where the binding is not worked out, the icon stays the held body's, to be worked out with the binding
/// ([R4-9]). With no held body, the body is [read] as it was read, but for its icon: a capture names none, as it names
/// no binding. The time [read] and the held body carry is not read; [held]'s time is.
SyncBody? syncBodyWrite(SyncHeldValue<SyncBody> held, SyncBody read, {required SyncWriteTime writeAt}) {
  final stored = held.value;
  final icon = stored == null ? null : (stored.binding == null ? stored.icon : read.icon);
  final written = syncEdit<(String, String?)>(
    (value: stored == null ? null : (stored.content, stored.icon), time: held.time),
    (read.content, icon),
    writeAt: writeAt,
  );
  if (written == null) return null;
  final from = stored ?? read;
  return SyncBody(
    read.content,
    binding: from.binding,
    geometry: from.geometry,
    icon: icon,
    parents: from.parents,
    time: written.time,
  );
}

/// The archive state a record in [held] takes when archived with [option]: [option] at [writeAt] over the time of
/// the state it is in — or null, no write, where it is in that state already ([syncEdit]).
SyncValue<ArchiveImageOption>? syncArchive(
  SyncHeldValue<ArchiveImageOption> held,
  ArchiveImageOption option, {
  required SyncWriteTime writeAt,
}) {
  final written = syncEdit<ArchiveImageOption>(held, option, writeAt: writeAt);
  return written == null ? null : SyncValue(option, written.time);
}

/// What a zip carries of a record that an import decides on ([R4-6]): its body — content, binding, geometry, icon and
/// parents; the time it carries is not read —, its archive state (null: normal) and whether it carries any image. A zip carries
/// nothing of a time an import reads, nor a relation bonus, which only the device that resolved it holds. The ids it
/// absorbed go with it as they are.
typedef SyncZip = ({SyncBody body, ArchiveImageOption? stage, bool carriesImages});

/// What an import writes of a record ([syncImport]): the [body] it shows — written where [writesBody], else the one it
/// held, with the zip's parents placed on it and the two bindings, geometries and icons merged —, the archive state written ([stage]; null
/// where none is) and where its images come from.
typedef SyncImportPlan = ({
  SyncBody body,
  bool writesBody,
  SyncValue<ArchiveImageOption?>? stage,
  SyncImagePlan images,
});

/// Where the images of a record a body is put on come from ([R4-8] 5).
sealed class SyncImagePlan {
  const SyncImagePlan();
}

/// The images the zip carries, and none of the record's own: a zip that carries an image carries the images of the
/// record.
final class SyncImagesCarried extends SyncImagePlan {
  const SyncImagesCarried();
}

/// The record's own, as they are: it keeps the body it holds.
final class SyncImagesKept extends SyncImagePlan {
  const SyncImagesKept();
}

/// Of the record's own, those the binding of its body names ([imagesBoundBy]); an image it keeps no form of, taken from
/// the first of [sources] — the device's other records, by id — that holds a form the binding names, and none where
/// no source does.
final class SyncImagesBound extends SyncImagePlan {
  const SyncImagesBound(this.sources);

  final List<String> sources;
}

/// The records of [others] — the device's records, each with its binding, null where it is not worked out — a record
/// [id] whose body is bound as [binding] can take images from ([R4-8] 5): those but [id] whose binding names an image
/// [binding] names ([RecordBinding.namesAnImageOf]), and those whose binding is not worked out yet, whose files only
/// their bytes can tell ([imagesBoundBy]) — a device binds a record the first time it needs it, so records it has not
/// bound yet are there. In either store. None where [binding] is null. By id.
List<String> syncImageDonors(String id, RecordBinding? binding, Map<String, RecordBinding?> others) => [
  if (binding != null)
    for (final MapEntry(key: other, value: bound) in others.entries)
      if (other != id && (bound?.namesAnImageOf(binding) ?? true)) other,
]..sort();

/// Where a record [id] that held the body [held] — none where the device holds no record of it — takes the images of
/// [body] from ([R4-8] 5): null where it holds that body already ([SyncBody.sameAs]), and keeps its images; else of its
/// own those [body]'s binding names, and the rest from the records [syncImageDonors] gives of [others].
List<String>? syncImageSources(String id, SyncBody? held, SyncBody body, Map<String, RecordBinding?> others) =>
    held != null && held.sameAs(body) ? null : syncImageDonors(id, body.binding, others);

/// Whether an import of [zip] can take images from the device's other records ([SyncImagesBound]): where the zip
/// carries none, its binding is known, and it is not an archive without images, which holds none (S-11).
bool syncImportTakesImages(SyncZip zip) =>
    !zip.carriesImages && zip.body.binding != null && zip.stage != ArchiveImageOption.none;

/// The archive state an import of a zip in [stage] writes over the state [held] of the device's record — null where the
/// device holds no record of the id ([R4-6]): [stage] at [writeAt] over the time [held] carries, where the device holds
/// no record of the id or holds it in another state; null, no write, where it holds it in [stage] already.
SyncValue<ArchiveImageOption?>? syncImportStage(
  SyncHeldValue<ArchiveImageOption>? held,
  ArchiveImageOption? stage, {
  required SyncWriteTime writeAt,
}) => held == null ? SyncValue(stage, writeAt(null)) : syncEdit<ArchiveImageOption>(held, stage, writeAt: writeAt);

/// What an import of [zip] writes over the record [id] the device holds ([R4-6], [R4-8] 5): of the body [body] — its
/// value none where the device holds no record of the id, or one it cannot read — and of the archive state [stage],
/// null where it holds no record of the id. Each held with the time it carries.
///
/// * **The body**: where the device's record shows what the zip's does ([SyncBody.sameAs]), it stays, its time
///   included, with the zip's parents placed on it (S-13) and the two bindings merged ([RecordBinding.mergedWith]),
///   and so the two geometries ([RecordGeometry.mergedWith]) and the two icons: the zip's where it carries the images,
///   whose `trainee.jpg` is then the record's, else the device's, each standing where both know one. An icon other
///   than the one the device's body names is a write of the body, as a re-recognition that cuts the icon again is
///   ([syncBodyWrite]): at [writeAt] over the time the held one carries. Else the body is the zip's, written at
///   [writeAt] over that time, with the zip's binding, geometry and icon.
/// * **The archive state** is the zip's ([syncImportStage]).
/// * **The images** are the zip's where it carries any ([SyncImagesCarried]) — none of the record's own then, nor of
///   another record, also where the zip carries only some. Where it carries none, the record keeps its own where it
///   keeps its body ([SyncImagesKept]), and otherwise keeps those the zip's binding names and takes the rest from the
///   records [syncImageDonors] gives of [others], the device's records with their bindings ([SyncImagesBound]) — none
///   where the zip's state is an archive without images ([syncImportTakesImages]).
SyncImportPlan syncImport(
  String id,
  SyncZip zip, {
  required SyncHeldValue<SyncBody> body,
  required SyncHeldValue<ArchiveImageOption>? stage,
  required Map<String, RecordBinding?> others,
  required SyncWriteTime writeAt,
}) {
  final mine = body.value;
  final z = zip.body;
  final kept = mine != null && mine.sameAs(z) ? mine : null;
  final (b, zb) = (kept?.binding, z.binding);
  final sources = syncImageSources(id, mine, z, others);
  final (g, zg) = (kept?.geometry, z.geometry);
  // The icon of a body kept is the zip's where the zip carries the images, its `trainee.jpg` being the one placed then;
  // else the device's. A name the body knows no other of gives it one, and is not written.
  final icon = kept == null ? z.icon : (zip.carriesImages ? z.icon ?? kept.icon : kept.icon ?? z.icon);
  final writes = kept == null || (kept.icon != null && icon != kept.icon);
  return (
    body: kept == null
        ? SyncBody(
            z.content,
            binding: zb,
            geometry: z.geometry,
            icon: icon,
            parents: z.parents,
            time: writeAt(body.time),
          )
        : SyncBody(
            kept.content,
            binding: b == null ? zb : (zb == null ? b : b.mergedWith(zb)),
            geometry: g == null ? zg : (zg == null ? g : g.mergedWith(zg)),
            icon: icon,
            parents: z.parents,
            time: writes ? writeAt(body.time) : kept.time,
          ),
    writesBody: writes,
    stage: syncImportStage(stage, zip.stage, writeAt: writeAt),
    images: zip.carriesImages
        ? const SyncImagesCarried()
        : switch (sources) {
            null => const SyncImagesKept(),
            final sources => SyncImagesBound(syncImportTakesImages(zip) ? sources : const []),
          },
  );
}

/// How long the id of a record, [a], has existed against that of [b]: negative where [a]'s is the older — the id a
/// merge of the two keeps ([syncMerge]). The record captured earlier ([captured], a time; null where the capture is not
/// known, which comes after every known one) is the older, and of two captured at one time the one whose id sorts
/// first: a record split off another is under that one's id with a mark after it ([recordSyncSplitId]), so it comes
/// after the record it was split off.
int syncCompareAge(({String id, int? captured}) a, ({String id, int? captured}) b) {
  final byCapture = switch ((a.captured, b.captured)) {
    (null, null) => 0,
    (null, _) => 1,
    (_, null) => -1,
    (final x?, final y?) => x.compareTo(y),
  };
  return byCapture != 0 ? byCapture : a.id.compareTo(b.id);
}

/// A record as a merge reads it ([syncMerge]): its id, its [body] — written at [bodyTime], null where it carries no
/// time; the time [body] carries is not read —, its archive [stage] and the ids it [absorbed].
typedef SyncMergeSide = ({
  String id,
  SyncBody body,
  int? bodyTime,
  SyncHeldValue<ArchiveImageOption> stage,
  Set<String> absorbed,
});

/// What a merge leaves of two records under the older one's id ([syncMerge]): the [body] it shows — written where
/// [writesBody], else the older record's time stays —, the archive state written ([stage]; null where the older
/// record's state stays, its time included), the ids it [absorbed], and the record whose relation bonus it keeps
/// ([bonusFrom]).
typedef SyncMergePlan = ({
  SyncBody body,
  bool writesBody,
  SyncValue<ArchiveImageOption?>? stage,
  Set<String> absorbed,
  String bonusFrom,
});

/// The body a merge leaves under the older record's id, which showed [older] ([older]'s time is the one held; the time
/// its body carries is not read), keeping the body [content] — the older record's own, or the one merged into it —
/// of a merge of the records [merging]: [content]'s content, binding, geometry and icon, with its parents but one that
/// names either of [merging] — a record is never its own parent; a slot it leaves empty stays empty, and the resolution
/// that follows the merge fills it. Written at [writeAt] over [older]'s time where [content] shows another than [older]
/// ([SyncBody.sameAs] — a binding not worked out says nothing of it), or names another icon than the one [older] names
/// — a merge that keeps the same content cut into another icon writes the body, as a re-recognition and an import do;
/// an icon not known on either side is worked out with the binding ([R4-9]) and is no write —; else [older]'s time
/// stays. The time of [content]'s own record is never carried.
({SyncBody body, bool writesBody}) syncMergeBody(
  SyncHeldValue<SyncBody> older,
  SyncBody content, {
  required Set<String> merging,
  required SyncWriteTime writeAt,
}) {
  final shown = older.value;
  final writes =
      shown == null ||
      !shown.sameAs(content) ||
      (shown.icon != null && content.icon != null && shown.icon != content.icon);
  return (
    body: SyncBody(
      content.content,
      binding: content.binding,
      geometry: content.geometry,
      icon: content.icon,
      parents: {
        for (final MapEntry(key: slot, value: parent) in content.parents.entries)
          if (!merging.contains(parent)) slot: parent,
      },
      time: writes ? writeAt(older.time) : older.time ?? 0,
    ),
    writesBody: writes,
  );
}

/// What a merge of the records [older] and [retired] leaves under [older]'s id, the content kept being [older]'s where
/// [contentFromOlder] and [retired]'s otherwise ([R4-3], S-04, S-13):
///
/// * **the body** is the kept one ([syncMergeBody]);
/// * **the archive state** is the kept record's, an edit of [older]'s ([syncEdit]): [older]'s time stays where the two
///   are in one state, and the time of the merge, written at [writeAt] over it, where they are not. The kept record's
///   own time is never carried;
/// * **the ids absorbed** are both records' and [retired]'s own;
/// * **the relation bonus** is the kept record's ([SyncMergePlan.bonusFrom]): it is derived from the parents, which go
///   with the body, and the resolution that follows the merge works it out again.
///
/// The values carried outside the records' directories are decided one by one: each rating and memo ([syncMergeCell]),
/// the dismissed pairs ([syncRekeyPairs]) and the parents of the other records ([syncReparented]).
SyncMergePlan syncMerge({
  required SyncMergeSide older,
  required SyncMergeSide retired,
  required bool contentFromOlder,
  required SyncWriteTime writeAt,
}) {
  final content = contentFromOlder ? older : retired;
  final body = syncMergeBody(
    (value: older.body, time: older.bodyTime),
    content.body,
    merging: {older.id, retired.id},
    writeAt: writeAt,
  );
  return (
    body: body.body,
    writesBody: body.writesBody,
    stage: syncEdit<ArchiveImageOption>(older.stage, content.stage.value, writeAt: writeAt),
    absorbed: {...older.absorbed, ...retired.absorbed, retired.id},
    bonusFrom: content.id,
  );
}

/// What a merge writes of one value carried outside the records' directories — the rating or memo of one column — that
/// the older record holds as [older] and the retired one as [retired] (none, both null, where it holds no cell),
/// keeping [chosen], the value the merge screen settled on ([R4-3]): the older record's cell set to [chosen]
/// ([syncEdit]) — null, no write, where it holds [chosen] already, and keeps its time — and the retired record's cell
/// goes, where it holds one ([dropsRetired]), its time with its value.
///
/// One decision for each column's file, made from what that file holds when the merge reaches it: on the merge's first
/// run, and on a run that finishes a merge whose survivor is already published, which reuses that survivor and settles
/// each file the run before it did not finish. A finished file holds nothing of the retired record and the value
/// chosen under the older id — the screen's choice of an unfinished merge keeps that value where the retired record
/// holds none — so it is not written again; an unfinished one is settled as the first run would have settled it.
({SyncValue<T?>? older, bool dropsRetired}) syncMergeCell<T>({
  required SyncHeldValue<T> older,
  required SyncHeldValue<T> retired,
  required T? chosen,
  required SyncWriteTime writeAt,
}) =>
    (older: syncEdit<T>(older, chosen, writeAt: writeAt), dropsRetired: retired.value != null || retired.time != null);

/// The dismissed [pairs] ([syncPairOf]) once a merge retired [retired] into [older]: a pair that names [retired] names
/// [older], and one that comes to name [older] twice goes — a record is never a candidate against itself. Null where no
/// pair names [retired]: the pairs stay as they are.
Set<String>? syncRekeyPairs(Set<String> pairs, {required String retired, required String older}) {
  if (!pairs.any((pair) => pair.split('+').contains(retired))) return null;
  return {
    for (final pair in pairs)
      if (pair.split('+').map((id) => id == retired ? older : id).toList() case [final a, final b] when a != b)
        syncPairOf(a, b),
  };
}

/// The [parents] of a record ([recordSyncParentSlots] → id) once a merge retired [retired] into [older]: a slot that
/// names [retired] names [older]. Null where none names [retired]: the record is not written.
Map<String, String>? syncReparented(Map<String, String> parents, {required String retired, required String older}) {
  if (!parents.containsValue(retired)) return null;
  return {for (final MapEntry(key: slot, value: parent) in parents.entries) slot: parent == retired ? older : parent};
}
