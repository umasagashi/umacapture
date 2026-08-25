/// The one predicate that decides whether a string may name a record directory.
///
/// A record id is used as a *path segment* on both platforms — as the name of
/// `active/<id>/`, as the key a transaction slot encodes, and as a mutation lock
/// name — so what it may contain is a property of the store, not of any one
/// caller. It used to be restated at four call sites, one of which had drifted
/// into a different predicate (it asked `PathEntity.parseSegments(id).length ==
/// 1`, which on the url-style `p.Context` the web build selects accepts a
/// backslash that `WebVfs._split` would then read as two segments).
///
/// WHO READS IT, written out so the sentence above can be checked instead of
/// believed: `record_directory_transaction.dart`, `record_loader_web.dart`,
/// `web_record_write_transaction.dart` and `web_record_persistence.dart` all call
/// [isSafeRecordId].
///
/// ONE COPY IS STILL OUT THERE, and naming it is the point: `wasm_worker_ops.dart`
/// matches the character class alone and leans on `_splitHarvestPath`, its only
/// caller, to exclude `.` and `..` — for every segment, so today the two agree.
/// That agreement rests on where the check sits rather than on what an id is,
/// which is exactly the arrangement this file exists to end; it is the next thing
/// to merge here. `test/fs_record_id_predicate_test.dart` holds every reader and
/// that copy to the same answers, so a drift fails there rather than passing
/// quietly on one platform.
library;

/// Characters a record directory name may consist of.
///
/// The class is what enforces the rest of the contract as well, so nothing here
/// is weaker than the longhand it replaced: `+` refuses the empty string, and
/// neither `/` nor `\` is in the class, so no accepted id can carry a separator
/// into a path builder. Only `.` and `..` need naming separately, because both
/// are spelled entirely with characters the class allows.
final RegExp _safeRecordIdPattern = RegExp(r'^[A-Za-z0-9._-]+$');

/// Whether [id] may be used as a record directory name.
///
/// Deliberately not length-bounded: every id the app produces is a UUID4, and a
/// name too long for the underlying filesystem fails loudly at the create rather
/// than being silently reclassified here. A bound would also be a *new*
/// restriction on data already in a store, which this consolidation is not.
bool isSafeRecordId(String id) {
  return id != '.' && id != '..' && _safeRecordIdPattern.hasMatch(id);
}

/// A single path segment that may stand in for [id] when [id] itself may not.
///
/// Quarantine does not ask [isSafeRecordId] for permission — moving a directory
/// aside destroys nothing, so an unusable name is a reason to quarantine and
/// never a reason to refuse. It does need a *destination*, and that is where the
/// character class stops being advisory: `quarantineRoot / id` is joined into a
/// path string, and on web `WebVfs` splits that string on `/` **and** `\`, so a
/// name carrying either separator would land the record two levels down instead
/// of directly under `quarantine/`. Windows splits the same string the same way
/// for the same reason. The name is what has to give, because the alternative is
/// a record filed somewhere the folder's own reader does not look.
///
/// Derived from the class rather than from a table of known-bad characters, so a
/// character nobody thought of is folded too: everything outside the class
/// becomes `_`, and a leading `_` is prepended if what is left is still not a
/// usable name (the empty string, `.`, `..`). The result therefore satisfies
/// [isSafeRecordId] for every input, which is the property
/// `test/fs_record_id_predicate_test.dart` asserts over the same boundary table
/// the predicate itself is measured on.
///
/// A safe [id] is returned unchanged: the folder is the user's to browse, and a
/// record that could have kept its name must keep it. Two different names can
/// fold to the same one, which the caller's existing `_<n>` collision loop
/// resolves exactly as it resolves two records with the same id.
String safeRecordDirectoryName(String id) {
  if (isSafeRecordId(id)) return id;
  final folded = id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  return isSafeRecordId(folded) ? folded : '_$folded';
}

/// A record directory whose name [isSafeRecordId] refuses.
///
/// Exists so the outcome can be *reported* rather than skipped. The store scan
/// no longer refuses such a directory — it quarantines it, which is the whole of
/// the remedy when the move succeeds: the directory leaves `active/` and stops
/// being something the scan loses. One of these lands in
/// `RecordScanResult.unavailable` only when that move fails and the directory is
/// therefore still standing in `active/`, unreadable and unmovable. That is what
/// tells the user their view of the record set is incomplete. Dropping such a
/// directory silently made it indistinguishable from a store that never held the
/// record — the same harm `RecordStoreUnavailable` names at store scope, at
/// per-record granularity.
final class UnsafeRecordId implements Exception {
  const UnsafeRecordId(this.id);

  /// The refused directory name, exactly as it was read from the store.
  final String id;

  @override
  String toString() =>
      'UnsafeRecordId: "$id" is not usable as a record directory name '
      '(only A-Za-z0-9._- , and neither "." nor "..")';
}
