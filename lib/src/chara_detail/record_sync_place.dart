// The device's side of a sync round: every read and write a round ([runSyncRoundOn]) makes on the device, as one
// contract. The round decides what to read and what to write, and when; a place applies it at the point the contract
// states — under the lock it names, against what the device holds then — and decides nothing of sync. What a round
// read is handed back to the place as data ([SyncPublication.asRead], [SyncMetadataWrite.read]), so that a place
// writes only where the device still holds what the round read, and leaves the rest to the next round.
//
// The app's place is [AppSyncPlace], over the record stores, the column controllers and the data directory.

import 'dart:typed_data';

import '/src/chara_detail/record_sync_list.dart';
import '/src/chara_detail/record_sync_merge.dart';
import '/src/chara_detail/record_sync_round.dart';

/// The two lists a round keeps on the device ([SyncKeptList]).
enum SyncKept {
  /// The list the device and the server last both held.
  base,

  /// The list the device asked the server to take, until it knows the answer.
  sent,
}

/// A record the device holds without a binding ([SyncPlace.unbound]), and the store it is in.
typedef SyncUnbound = ({String id, bool archiveStore});

/// What [SyncPlace.read] read: the device's records, columns and pairs, and the ids of the records a store could not
/// open, which are on disk and in neither store.
typedef SyncLocal = ({LocalSyncRead local, Set<String> unavailable});

/// Where the body of a record a round publishes comes from.
sealed class SyncBodySource {
  const SyncBodySource();
}

/// The `record.json` of the device's record of the id published, as the device holds it at the publication.
final class SyncDeviceBody extends SyncBodySource {
  const SyncDeviceBody();
}

/// The `record.json` of the device's record the record published is split off ([SyncPublication.splitFrom]), as
/// [SyncPlace.carriedBy] read it.
final class SyncSplitBody extends SyncBodySource {
  const SyncSplitBody();
}

/// A body the server gave.
final class SyncServerBody extends SyncBodySource {
  const SyncServerBody(this.text);

  final String text;
}

/// One record a round publishes: [record] of the result, under its id. [C] is what a record split off carries
/// ([SyncPlace.carriedBy]).
class SyncPublication<C> {
  const SyncPublication({
    required this.record,
    required this.asRead,
    required this.source,
    this.splitFrom,
    this.splitAway = false,
    this.imageSources,
  });

  /// The record as the result has it: its body's binding, parents and time, what it absorbed and its stage.
  final SyncRecord record;

  /// The device's record of the id as the round read it; null where it read none.
  final SyncRecord? asRead;

  /// Where the body comes from.
  final SyncBodySource source;

  /// The id of the device's record [record] is split off, and what [SyncPlace.carriedBy] read of it; null where
  /// [record] is not split off a record.
  final ({String id, C carried})? splitFrom;

  /// Whether the device's record of the id is split off it, to another id or to none: the id then holds nothing that
  /// only the device held of that record (its relation bonus), which goes with the record split off.
  final bool splitAway;

  /// The device's records [record] takes an image it holds none of from, in the order they are looked in ([R4-8] 5);
  /// null where it keeps the body the device's record held, and with it the images.
  final List<String>? imageSources;
}

/// Why a write of a record a round makes ([SyncPlace.publish], [SyncPlace.remove]) wrote nothing.
enum SyncWriteStop {
  /// The device holds the record not as the round read it: an operation of this device changed it since — the user's,
  /// or one of the app's own, as an inheritance resolution —, and the place wrote nothing over it. Nothing failed: the
  /// record is the next round's to merge.
  changed,

  /// A write failed, or the record could not be read.
  failed,
}

/// What a publication of a round's came to ([SyncPlace.publish]).
sealed class SyncPublished {
  const SyncPublished();
}

/// The publication committed, and wrote the body [name] names ([syncObjectName] of [syncBodyBytes]).
final class SyncPublishedAs extends SyncPublished {
  const SyncPublishedAs(this.name);

  final String name;
}

/// The publication did not commit, for [stop].
final class SyncNotPublished extends SyncPublished {
  const SyncNotPublished(this.stop);

  final SyncWriteStop stop;
}

/// The cells, titles and dismissed pairs a round writes in one step, and what it read of them.
class SyncMetadataWrite {
  const SyncMetadataWrite({
    required this.result,
    required this.read,
    required this.ids,
    required this.columns,
    required this.titles,
    required this.pairs,
  });

  /// The values to write.
  final SyncSide result;

  /// What the round read, or what the steps before this one left: a value is written only where the device still
  /// holds it as this has it.
  final SyncList read;

  /// The records whose cells are written, in each of [columns].
  final Set<String> ids;

  /// The column storages written ([syncColumnOf]), in this order.
  final List<String> columns;

  /// Whether each of [columns] takes [result]'s title.
  final bool titles;

  /// The dismissed pairs the round leaves: the change from [read]'s to these is applied to what the device holds.
  /// Null where the round changes none.
  final Set<(String, String)>? pairs;
}

/// The device's side of a sync round. [C] is what a record split off carries, as the place reads it.
///
/// An operation that answers false, or a stop ([SyncWriteStop]), wrote nothing it was not sure of, and the round ends
/// without moving its base; the next round merges what it left again. Anything thrown is a failure of the device: the
/// round catches it where it catches a failed write, and leaves it to the round's caller elsewhere, as it says at each
/// call.
abstract interface class SyncPlace<C> {
  /// The list kept as [which]; null where there is none. One that cannot be read is none, logged: a round without a
  /// base takes the more of the two sides, which loses nothing.
  Future<SyncKeptList?> readKept(SyncKept which);

  /// Replaces the list kept as [which] with [list], whole in one write; null forgets it. Done once the write is.
  Future<void> keep(SyncKept which, SyncKeptList? list);

  /// Done when both record stores have loaded what they load: before the round reads the device, and after it put the
  /// result in place ([published]), so that the stores hold what it published.
  Future<void> loaded();

  /// The records the stores hold in memory without a binding ([R4-9]), the active store's first, each store's in its
  /// order; and how many records the stores hold. Reads memory only, at the point it is called.
  ({List<SyncUnbound> records, int held}) unbound();

  /// Works out and places the binding of the record [record] under its lock, and puts the record that changed into
  /// its store. Nothing where its `record.json` carries one, or cannot be read.
  Future<void> workOutBinding(SyncUnbound record);

  /// What the device holds, each record read under its lock ([readLocalSyncList]). Given [previous], the records the
  /// stores show may have changed since ([syncRecordsChangedSince]) alone, the rest as [previous] has them. Null where
  /// a store has not loaded.
  Future<SyncLocal?> read({LocalSyncRead? previous});

  /// What the device's record [id], as the round read it ([asRead]), carries to a record split off it, read under its
  /// lock before anything is put in place: its `record.json`, and every file of its directory but that and what a
  /// round writes beside it. Throws where it cannot be read; the round does not catch it.
  Future<C> carriedBy(String id, SyncRecord asRead);

  /// Writes [write] under the root lock, which a merge and a dismissal take to write the same files.
  ///
  /// Each column storage of [SyncMetadataWrite.columns] is written through its controller, the chain every edit of it
  /// writes through: the controller's pending write is flushed first, and a storage whose last write did not land, or
  /// that cannot be read, is not written ([N15-21]). Each cell of [SyncMetadataWrite.ids], and the title where
  /// [SyncMetadataWrite.titles], takes the result's value only where the controller still holds what
  /// [SyncMetadataWrite.read] has, compared as the reader encodes it; one the user changed since is the next round's.
  /// The controller is flushed again, and a title written is given to the columns of every preset it heads
  /// ([N15-23]) once that write landed. Then the pairs, where [SyncMetadataWrite.pairs] is not null, from the file:
  /// the change from what was read to them, a pair dismissed or put back since kept as it is; not written where the
  /// file cannot be read. The column and pair providers are invalidated once the lock's work is done, whatever it did.
  ///
  /// Answers whether every file holds what it was to. Throws where the root lock could not be taken or a write
  /// failed; the round reads that as false.
  Future<bool> putMetadata(SyncMetadataWrite write);

  /// Publishes [publication] as an import publishes a record, and answers the name of the body it wrote
  /// ([SyncPublishedAs]); where the publication did not commit, logged, why ([SyncNotPublished]): the device holds the
  /// record not as the round read it ([SyncWriteStop.changed]), or a write failed or the record could not be read.
  ///
  /// Before the record's lock: the images of each of [SyncPublication.imageSources] the device holds then, in either
  /// store, each read under that record's lock. Under the record's lock, the record is composed from the source for a
  /// check of its shape before any file is written. In the publication, under the lock again, and only where the
  /// device holds the record then as [SyncPublication.asRead] has it (none where that is null) or as
  /// [SyncPublication.record] has it — a record this device changed since the round read it is not written over, nor
  /// one that cannot be read — the record is composed once more from the source as it is then: the body with the
  /// result's id, binding, parents and time, and what only this device holds of it (the relation bonus of the record
  /// it is split off where that holds one, else of its own id, as the stores hold it then; none where
  /// [SyncPublication.splitAway]). In the same write go the archive note with the
  /// result's state and time ([R5-6]), the absorbed ids (removed where none), the files a record split off carries,
  /// and the images: where [SyncPublication.imageSources] is not null, the record's own images, read under the lock,
  /// those its binding does not name let go of, and an image it holds none of taken from the sources
  /// ([recordImagesBoundBy]). The record goes into the store of its stage, out of the other; once it commits, the
  /// images are shaped for an archive stage.
  Future<SyncPublished> publish(SyncPublication<C> publication);

  /// Removes the records [asRead] names as the user removes them, the active store's and then the archive store's
  /// (by the stage each was read in), each only where the device holds it then as [asRead] has it, asked under its
  /// lock. Answers null where every one went; else it stops there, and answers why: a record left because the device
  /// holds it not as [asRead] has it ([SyncWriteStop.changed]), or a delete that failed or a record that could not be
  /// read ([SyncWriteStop.failed]), which outweighs the first.
  Future<SyncWriteStop?> remove(Map<String, SyncRecord> asRead);

  /// The stores read again what the round published, as after an import: the records [ids] whose publication
  /// committed. Called once the round stops placing records, whether or not it went on.
  void published(Iterable<String> ids);

  /// The body ([syncBodyBytes]) of the `record.json` the device holds now of the record [listed], in the store of its
  /// stage, read under its lock; null where there is none. Whether it is still the body the list names is the round's
  /// to tell.
  Future<Uint8List?> bodyOf(SyncRecord listed);
}
