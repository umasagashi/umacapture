// The judge: "did anything vanish, come back, or stay stuck?", written from what the product
// promises the user — not from the sync rules. It must not import the rule core (or anything that
// imports it): it reads the world only through `observation.dart` and the user's operations in
// `ops.dart`.
//
// The promises it checks:
//  - A record's content stays somewhere unless the user deleted the record holding it, merged it
//    away by keeping the other side, or overwrote it with a zip import (sync off). "The user" means
//    the device where the user acted, and what the user discarded is what that device showed at
//    that moment — together with the choices that device had already received. A merge made on
//    another device is a choice of its own (which content to keep, even when it is the survivor's
//    own), and a device that had not received it does not discard it; the same merge (the same
//    pair, keeping the same content) made on two devices is one choice, which either device
//    discards. A zip import under a new id is a choice too, and so is a zip import under the id it
//    was exported from when it changes what the device shows: an overwrite with other content, or
//    taking back an id the device had removed or received a removal of. Any other capture or zip
//    import under the record's own id is the record itself: deleting or merging away that record
//    discards every copy of it, including copies made later on a device that had not yet received
//    that delete or merge.
//  - An image stays somewhere while the content it belongs to must stay, unless the user removed
//    it (archived, without images, a record showing that content), or the loss has the exact shape
//    of one of the accepted outcomes below. A copy made without the images (a zip import under a new
//    id, a record split off without them, or a merge that kept such a copy's content) does not need
//    the image once any device discards the record it was copied from: the image is the record's,
//    and goes with it.
//  - What a device took in from a zip is what the exporting device had made or received when it
//    exported: a user acting on the imported record has seen those choices.
//  - After every device has synced to rest: every device lists the server's live records with the
//    server's content and state, and the server's memo for each of them; what a user deleted or
//    merged away is gone everywhere, unless another device that had not received that delete or
//    merge chose that record (a merge onto it), which keeps it; an image one device holds reaches
//    the server and the devices that download images while the account form is png / jpeg.
//  - What a user deleted or merged away does not come back as another record. The only way it may
//    stay is that some device chose to keep it without having seen that delete or merge; that
//    choice is kept (under a new id when the server did not take it). The deleted or merged-away
//    record itself staying is the promise above about what is gone everywhere, reported once.
//  - For a record never merged or deleted (nor split off one that was), the last memo the user
//    typed (by edit time) is the value everywhere.

import 'observation.dart';
import 'ops.dart';

enum ViolationKind {
  recordLost,
  imageLost,
  notConverged,
  intentNotDelivered,
  imageNotDelivered,
  memoLost,
  noQuiescence,
  discardedReturned,
}

class Violation {
  const Violation(this.kind, this.subject, this.detail);
  final ViolationKind kind;
  final String subject;
  final String detail;
  @override
  String toString() => '${kind.name}($subject): $detail';
}

/// The departures from the promises above that the product accepts. Each entry is one outcome the
/// owner decided to live with rather than design away, and it is matched by the exact shape that
/// decision describes: a loss or a return of any other shape is reported, however close.
enum Accepted {
  /// Device B discards a record whose image only B holds — deletes it, or merges it away keeping
  /// the other side — and device A, without having received that discard, chooses that record's
  /// content without holding its image: by a merge of any pair that keeps it (also as one step of a
  /// chain of merges, and also when the server takes the other merge first and A's is kept as a new
  /// record split off), or by importing a zip of it without images. A's choice stays and its image
  /// survives nowhere. Accepted because keeping it would mean B holding on to the images of records
  /// its user discarded, with no point at which B may let go of them. Ordinary use reaches it (two
  /// devices acting before they sync) and the image is lost for good, which is why the merge
  /// confirmation tells the user.
  discardedTheOnlyImage,

  /// Device B archives record X without images, and device A, before receiving that archive,
  /// merges another record into X keeping the other record's content, whose image A does not hold.
  /// X is an archive without images, so that image is not carried onto it and survives nowhere.
  /// Accepted as part of [otherDeviceArchiveNoneDeletesImages]: the result is an archive without
  /// images, and nothing the user did asks for its images.
  mergedOntoArchivedNone,

  /// An archive without images chosen on one device removes the images of that record wherever
  /// they are held when it arrives — on the server and on every other device, including images
  /// another device had not sent yet. The owner chose this over holding the arrival back for a
  /// decision: the archive is an explicit request to drop the record's images.
  otherDeviceArchiveNoneDeletesImages,

  /// What a user deleted, merged away or overwrote comes back as a duplicate because a device cannot
  /// tell, from its own data, whether its copy is older than that change: a device that keeps no
  /// server row for the record — for any reason: it captured the record and has not synced it, took
  /// it in from a zip under its own id, or lost its sync state file — splits the content off as a
  /// new record (a fork) when the delete or the merge arrives, or sends the record under its own id
  /// while the server has no row of it (a merge away of a record without a row writes no tombstone);
  /// or a zip import overwrote a record while sync was off, and turning sync on
  /// again brings the overwritten content back from the server under that id. Dropping such a copy
  /// would silently lose a re-imported record; a duplicate is something the user can delete.
  discardedComesBackAsDuplicate,

  /// What a user removed with an app that leaves no trace of the removal — a version from before
  /// record lineages, or v0.3.0 used on the same data, deleting a record or merging it away — comes
  /// back from another device or the server. Nothing on any device says the record was removed
  /// rather than never received. Only those removals: a copy on a device that keeps no server row
  /// (a zip import under its own id, a lost sync state file) carries its lineage and must not
  /// bring back what a tracked delete or merge discarded.
  untrackedDiscardReturns,

  /// [discardedTheOnlyImage] where the server held the image too: device B, the only device holding
  /// the image, discards the record (and with it the server's copy, which a delete hides and a merge
  /// away tombstones), and device A, without having received that discard, chooses that content
  /// without the image. The owner put this inside the same acceptance rather than have a split-off
  /// record recover the hidden server copy.
  discardedImageAlsoOnServer,
}

/// The accepted outcomes of the rules in `core.dart`.
const acceptedUnderDesigned = {
  Accepted.discardedTheOnlyImage,
  Accepted.mergedOntoArchivedNone,
  Accepted.otherDeviceArchiveNoneDeletesImages,
  Accepted.discardedComesBackAsDuplicate,
};

/// The accepted outcomes of the lineage rules (`lineage_core.dart`): the duplicate after a tracked
/// discard is no longer accepted, only the return after an untracked one.
const acceptedUnderLineage = {
  Accepted.discardedTheOnlyImage,
  Accepted.mergedOntoArchivedNone,
  Accepted.otherDeviceArchiveNoneDeletesImages,
  Accepted.untrackedDiscardReturns,
  Accepted.discardedImageAlsoOnServer,
};

/// Shapes that are reported, not accepted, but are named so a run can count them apart: outcomes
/// the owner has not decided on yet.
enum Candidate {
  /// A record removed on the storage screen, which writes no delete tombstone, comes back.
  storageScreenDeleteReturns,
}

/// Readings of the promises other than the ones above, each narrower than the default reading. They
/// are not accepted outcomes: a run under one says how many reports depend on how the promise is
/// read, and nothing else.
class JudgeReadings {
  const JudgeReadings({this.copyDiscardsOnlyItself = false, this.pushAnswerIsReceipt = false});

  /// A push whose answers changed what the device shows (a row handed back with the answer) counts
  /// as receiving everything sent before it, as a pull does.
  final bool pushAnswerIsReceipt;

  /// Discarding one record of two that show the same content and descend from the same choice (a
  /// record and a fork split off it while both still show that content) discards that record only:
  /// the other copy keeps the choice.
  final bool copyDiscardsOnlyItself;
}

/// Something must keep content [token]: made by a capture, a merge that kept it, or a zip import, on
/// [creator] at step [made]. [ids] are the record it was made on plus the forks that carried it on.
class _Obligation {
  _Obligation(this.token, String id, this.creator, this.made, {this.choice = false}) : ids = {id};

  /// The pair of the merge that made this obligation, or null.
  Set<String>? mergePair;
  final String token;
  final Set<String> ids;
  final String creator;
  final int made;

  /// Made by a merge, or by a zip import under a new id: a choice a device discards only once it has
  /// received it. Otherwise it is the record itself.
  final bool choice;

  /// The step of the creator's first push after [made], or null.
  int? published;
  bool released = false;

  /// Whether the image must stay with this content. It must when some record held it as the
  /// obligation was made, or when it was gone by then only because of a delete or merge the creator
  /// had not received (from the creator's view the image still existed). A copy made after the
  /// creator had itself seen the last image go — say from a zip without images — loses nothing.
  bool needsImage = false;

  /// Made as a copy, without the image of [token], of record [copiedFrom]: a zip import under a new
  /// id, or a merge keeping the content of such a copy or of a record split off without the image.
  String? copiedFrom;

  /// Devices that have seen this obligation through a zip the exporting device made after it.
  final Set<String> seenThroughZip = {};
}

/// A user on [device] deleted or merged away record [id] while it showed [token], at step [made].
/// [kept]: a merge that kept [token] on the survivor (the record ends, its content does not).
class _Discard {
  _Discard(this.id, this.token, this.device, this.made, this.untracked, {this.kept = false});
  final String id;
  final String token;
  final String device;
  final int made;
  final Untracked untracked;
  final bool kept;

  /// The step of the device's first push after [made], or null.
  int? published;
}

/// A user's operation as the device that made it showed it: [pulledBefore] is the step of that
/// device's last pull before it, which decides what it had received from other devices.
abstract class _Made {
  _Made(this.device, this.step, this.pulledBefore);
  final String device;
  final int step;
  final int pulledBefore;

  /// The step of the device's first push after [step], or null.
  int? published;

  /// Whether this device had received [other] when it made this operation.
  bool saw(_Made other) => other.device == device || (other.published != null && pulledBefore > other.published!);
}

class _MergeMade extends _Made {
  _MergeMade(
    super.device,
    super.step,
    super.pulledBefore, {
    required this.pair,
    required this.survivor,
    required this.retired,
    required this.keptFrom,
    required this.kept,
    required this.keptHadImage,
    required this.keptImageOnlyElsewhere,
    required this.discarded,
    required this.discardedImageOnlyHere,
    required this.discardedImageHereAndOnServer,
  });

  final Set<String> pair;
  final String survivor;
  final String retired;

  /// The record whose content the user kept, that content, and whether the device held its image.
  final String keptFrom;
  final String kept;
  final bool keptHadImage;

  /// Neither this device nor the server held the kept content's image; another device did.
  final bool keptImageOnlyElsewhere;

  /// The content of the other side, and whether its image was held by this device and nowhere else.
  final String discarded;
  final bool discardedImageOnlyHere;

  /// The other side's image was held by this device and the server, and by no other device.
  final bool discardedImageHereAndOnServer;
}

class _DeleteMade extends _Made {
  _DeleteMade(
    super.device,
    super.step,
    super.pulledBefore, {
    required this.id,
    required this.token,
    required this.imageOnlyHere,
    required this.imageHereAndOnServer,
  });
  final String id;
  final String token;

  /// The deleted record's image was held by this device and nowhere else.
  final bool imageOnlyHere;

  /// The deleted record's image was held by this device and the server, and by no other device.
  final bool imageHereAndOnServer;
}

class _ImportMade extends _Made {
  _ImportMade(super.device, super.step, super.pulledBefore, {required this.token, required this.hadImage});
  final String token;
  final bool hadImage;
}

class _ArchiveNoneMade extends _Made {
  _ArchiveNoneMade(super.device, super.step, super.pulledBefore, {required this.id});
  final String id;
}

/// A record split off [from] on [device], first seen holding [token]. [copyless]: the device kept
/// no server row for [from] just before.
class _ForkSeen {
  const _ForkSeen(this.from, this.token, this.device, {required this.copyless});
  final String from;
  final String token;
  final String device;
  final bool copyless;
}

class _Intent {
  _Intent(this.id, this.token, this.what, this.untracked);
  final String id;
  final String token;
  final String what;
  final Untracked untracked;
  bool cleared = false;
}

class _MemoEdit {
  const _MemoEdit(this.id, this.value, this.time);
  final String id;
  final String? value;
  final int time;
}

class Judge {
  /// [accepted] defaults to every accepted outcome; leaving one out is the judge's positive control.
  Judge({Set<Accepted>? accepted, this.readings = const JudgeReadings()})
    : accepted = accepted ?? Accepted.values.toSet();

  final Set<Accepted> accepted;
  final JudgeReadings readings;
  final List<_Obligation> _obligations = [];
  final List<_Intent> _intents = [];
  final Set<String> _syncOff = {};
  final Map<String, String> _zipIds = {};
  final List<_Discard> _discards = [];
  final Map<String, int> _lastPull = {};
  int _step = 0;
  final Set<String> _imagesSeen = {};
  final List<_MemoEdit> _memoEdits = [];
  final Set<String> _mergedOrDeleted = {};
  final Map<String, Violation> _violations = {};

  final List<_Made> _made = [];
  final Map<String, _ForkSeen> _forks = {};

  /// Record id → the record it is a copy of without that record's image: a zip import under a new id,
  /// or a record split off (forked) without the image.
  final Map<String, String> _copyOf = {};

  /// Zip slot → the obligations the exporting device had made or received on the exported record.
  final Map<String, List<_Obligation>> _zipCarries = {};

  /// Content → the ids a zip import overwrote while that content was on them and sync was off.
  final Map<String, Set<String>> _overwrittenWhileOff = {};

  /// Content → id → the last step a device sent that record holding that content while neither it
  /// nor the server had a row of it, so nothing could tell the device what a user had discarded.
  final Map<String, Map<String, int>> _sentWithoutCopy = {};

  /// Contents whose images a user removed: they archived, without images, a record showing it.
  final Set<String> _imagesDroppedByUser = {};

  /// Images an archive without images removed where it arrived (on the server or another device).
  final Set<String> _imagesDroppedOnArrival = {};

  /// id → content → the last step the server listed that content on that id's live row.
  final Map<String, Map<String, int>> _rowLastHeld = {};

  /// Image → the step it was first found on no record anywhere while some content needed it.
  final Map<String, int> _imagesLost = {};

  /// Departures that happened but have the shape of an accepted outcome (subject → which one).
  final Map<String, Accepted> tolerated = {};

  /// Reported violations (`kind:subject`) whose shape is a [Candidate].
  final Map<String, Candidate> candidates = {};

  List<Violation> get violations => _violations.values.toList();

  void _report(Violation v) => _violations.putIfAbsent('${v.kind.name}:${v.subject}', () => v);

  /// Called before an operation is applied, with what the acting device shows.
  void beforeOp(Op op, Observation obs) {
    final dev = obs.devices[op.device];
    if (dev == null) return;
    switch (op) {
      case Merge(:final a, :final b, :final contentFrom, :final untracked):
        for (final id in [a, b]) {
          final r = dev.records[id];
          if (r == null) continue;
          final kept = id == contentFrom;
          _release(r.contentSet, id, op.device, untracked, _otherHolders(obs, r.contentSet, id), kept);
          _mergedOrDeleted.add(id);
        }
      case Delete(:final id, :final untracked):
        final r = dev.records[id];
        if (r != null) {
          _release(r.contentSet, id, op.device, untracked, _otherHolders(obs, r.contentSet, id));
          _intents.add(_Intent(id, r.contentSet, 'deleted on ${op.device}', untracked));
        }
        _mergedOrDeleted.add(id);
      case Archive(:final id, :final option) when option == 'none':
        final r = dev.records[id];
        if (r != null) _imagesDroppedByUser.add(r.contentSet);
      default:
        break;
    }
  }

  /// [device] discards content [token] shown on record [id]: the obligations it had received end, and
  /// a copy without images it made of that content no longer needs the image of the record it
  /// discards.
  void _release(
    String token,
    String id,
    String device, [
    Untracked untracked = Untracked.none,
    Set<String> otherHolders = const {},
    bool kept = false,
  ]) {
    _discards.add(_Discard(id, token, device, _step, untracked, kept: kept));
    for (final o in _obligations) {
      if (o.released || o.token != token) continue;
      if (readings.copyDiscardsOnlyItself && o.ids.any(otherHolders.contains)) continue;
      if (!o.ids.contains(id)) {
        if (o.copiedFrom == id) o.needsImage = false;
        continue;
      }
      if (!o.choice ||
          _received(device, o.creator, o.published) ||
          o.seenThroughZip.contains(device) ||
          _madeTheSameMerge(device, o)) {
        o.released = true;
      }
    }
  }

  /// A copy made after a user had already discarded the record it copies (on a device the copier had
  /// not received that from): the image goes with that record as it would had the copy come first.
  void _copyOfDiscarded(_Obligation o) {
    if (_discards.any((d) => d.id == o.copiedFrom && d.token == o.token)) o.needsImage = false;
  }

  /// Whether a record [device] lists appeared or shows other content after the step.
  static bool _showsChange(String device, Observation before, Observation after) {
    final pre = before.devices[device]?.records ?? const {};
    final post = after.devices[device]?.records ?? const {};
    return post.entries.any((e) => pre[e.key]?.contentSet != e.value.contentSet);
  }

  /// The ids other than [id] of the records (on any device, or live on the server) showing [token].
  static Set<String> _otherHolders(Observation obs, String token, String id) => {
    for (final r in obs.liveRows)
      if (r.contentSet == token && r.id != id) r.id,
    for (final d in obs.devices.values)
      for (final r in d.records.values)
        if (r.contentSet == token && r.id != id) r.id,
  };

  /// [device] itself made the merge that made [o]: the same merge is one choice.
  bool _madeTheSameMerge(String device, _Obligation o) {
    final pair = o.mergePair;
    if (pair == null) return false;
    return _made.whereType<_MergeMade>().any(
      (m) => m.device == device && m.kept == o.token && m.pair.length == pair.length && m.pair.containsAll(pair),
    );
  }

  /// Whether [device] had received what [maker] did: it is the maker, or it pulled after the maker's
  /// next push. A push the server answers with a conflict counts too; a merge is then carried by the
  /// fork the maker publishes, so a device that later deletes that fork has seen it.
  bool _received(String device, String maker, int? published) {
    if (maker == device) return true;
    return published != null && (_lastPull[device] ?? -1) > published;
  }

  /// A new obligation, made in the world [now]; a copy of a record that a not yet received delete or
  /// merge already discarded is born discarded.
  void _oblige(Observation now, String token, String id, String device, {bool choice = false}) {
    final o = _Obligation(token, id, device, _step, choice: choice)
      ..needsImage =
          _imagePresent(now, token) ||
          _discards.any((d) => d.token == token && !_received(device, d.device, d.published));
    o.released =
        !choice && _discards.any((d) => d.id == id && d.token == token && !_received(device, d.device, d.published));
    _obligations.add(o);
  }

  /// Which device has pulled, and which of its operations have been pushed, by the end of step
  /// [_step]. [before] is the world as the push found it.
  void _noteSync(Op op, Observation before) {
    final d = op.device;
    switch (op) {
      case SetSyncEnabled(:final enabled):
        enabled ? _syncOff.remove(d) : _syncOff.add(d);
      case SyncRound() || Pull() || Push() when !_syncOff.contains(d):
        if (op is! Push) _lastPull[d] = _step;
        if (op is Pull) return;
        for (final o in _obligations) {
          if (o.creator == d && o.published == null) o.published = _step;
        }
        for (final x in _discards) {
          if (x.device == d && x.published == null) x.published = _step;
        }
        for (final m in _made) {
          if (m.device == d && m.published == null) m.published = _step;
        }
        for (final r in before.devices[d]?.records.values ?? const <ObservedRecord>[]) {
          if (r.hasSnapshot || before.rows[r.id] != null) continue;
          _sentWithoutCopy.putIfAbsent(r.contentSet, () => {})[r.id] = _step;
        }
      default:
        break;
    }
  }

  /// Called after an operation, with the world before and after it.
  void afterOp(Op op, Observation before, Observation after) {
    _step++;
    _noteSync(op, before);
    if (readings.pushAnswerIsReceipt && (op is Push || op is SyncRound) && _showsChange(op.device, before, after)) {
      _lastPull[op.device] = _step;
    }
    _noteArrivalDrops(op, before, after);
    _noteNewForks(before, after);
    final pre = before.devices[op.device];
    final post = after.devices[op.device];
    if (pre == null || post == null) return;
    final pulled = _lastPull[op.device] ?? -1;
    switch (op) {
      case Capture(:final id):
        final r = post.records[id];
        if (r != null) _oblige(after, r.contentSet, id, op.device);
      case Merge(:final a, :final b, :final contentFrom, :final untracked):
        final keep = pre.records[contentFrom];
        final other = pre.records[contentFrom == a ? b : a];
        final survivor = post.records.containsKey(a) ? a : b;
        final retired = survivor == a ? b : a;
        if (keep != null) {
          _oblige(after, keep.contentSet, survivor, op.device, choice: true);
          final o = _obligations.last..mergePair = {a, b};
          o.released = _discards.any(
            (d) =>
                d.token == o.token &&
                d.id == survivor &&
                d.device != op.device &&
                _made.whereType<_MergeMade>().any(
                  (m) =>
                      m.device == d.device &&
                      m.step <= d.made &&
                      m.kept == o.token &&
                      m.pair.length == 2 &&
                      m.pair.containsAll({a, b}),
                ),
          );
          final copied = keep.imageSet == keep.contentSet ? null : _copyOf[contentFrom];
          if (copied != null && copied != survivor) {
            o.copiedFrom = copied;
            _copyOf[survivor] = copied;
            _copyOfDiscarded(o);
          }
        }
        _MergeMade? made;
        if (keep != null && other != null) {
          made = _MergeMade(
            op.device,
            _step,
            pulled,
            pair: {a, b},
            survivor: survivor,
            retired: retired,
            keptFrom: contentFrom,
            kept: keep.contentSet,
            keptHadImage: keep.imageSet == keep.contentSet,
            keptImageOnlyElsewhere: _heldOnlyByOthers(before, op.device, keep.contentSet),
            discarded: other.contentSet,
            discardedImageOnlyHere: _heldOnlyBy(before, op.device, other.contentSet),
            discardedImageHereAndOnServer: _heldHereAndOnServerOnly(before, op.device, other.contentSet),
          );
          _made.add(made);
        }
        final seen = pre.records[retired]?.contentSet;
        if (seen != null) _intents.add(_Intent(retired, seen, 'merged away on ${op.device}', untracked));
      case Delete(:final id):
        final r = pre.records[id];
        if (r != null) {
          _made.add(
            _DeleteMade(
              op.device,
              _step,
              pulled,
              id: id,
              token: r.contentSet,
              imageOnlyHere: _heldOnlyBy(before, op.device, r.contentSet),
              imageHereAndOnServer: _heldHereAndOnServerOnly(before, op.device, r.contentSet),
            ),
          );
        }
      case Archive(:final id, :final option) when option == 'none':
        _made.add(_ArchiveNoneMade(op.device, _step, pulled, id: id));
      case ExportZip(:final id, :final slot):
        _zipIds[slot] = id;
        final r = pre.records[id];
        _zipCarries[slot] = [
          for (final o in _obligations)
            if (r != null &&
                !o.released &&
                o.token == r.contentSet &&
                o.ids.contains(id) &&
                (_received(op.device, o.creator, o.published) || o.seenThroughZip.contains(op.device)))
              o,
        ];
      case ImportZip(:final slot):
        for (final o in _zipCarries[slot] ?? const <_Obligation>[]) {
          o.seenThroughZip.add(op.device);
        }
        for (final r in post.records.values) {
          final old = pre.records[r.id];
          final sameId = r.id == _zipIds[slot];
          // An overwrite is an import onto an active record of the same id with sync off; with sync on
          // the import lands under a new id and this record is untouched.
          final overwrites = old != null && old.archiveOption == null && _syncOff.contains(op.device);
          final overRemoval =
              sameId &&
              (overwrites ||
                  (old == null &&
                      _discards.any(
                        (d) => d.id == r.id && (d.device == op.device || _received(op.device, d.device, d.published)),
                      )));
          // An overwrite that leaves the content as it was changes nothing the user sees: no choice.
          if (old != null && old.contentSet == r.contentSet) continue;
          if (old != null) {
            _release(old.contentSet, r.id, op.device);
            if (_syncOff.contains(op.device)) _overwrittenWhileOff.putIfAbsent(old.contentSet, () => {}).add(r.id);
          }
          final hadImage = r.imageSet == r.contentSet;
          _oblige(after, r.contentSet, r.id, op.device, choice: !sameId || overRemoval);
          if (!hadImage && !sameId) {
            final from = _zipIds[slot]!;
            final original = _copyOf[from] ?? from;
            _obligations.last.copiedFrom = original;
            _copyOf[r.id] = original;
            _copyOfDiscarded(_obligations.last);
          }
          _made.add(_ImportMade(op.device, _step, pulled, token: r.contentSet, hadImage: hadImage));
          for (final i in _intents) {
            if (i.id == r.id) i.cleared = true;
          }
        }
      case EditMemo(:final id):
        final m = post.memos[id];
        if (m != null) _memoEdits.add(_MemoEdit(id, m.value, m.time));
      default:
        break;
    }
  }

  static bool _holds(ObservedDevice? d, String image) => d?.records.values.any((r) => r.imageSet == image) ?? false;

  /// Image [image] was held on [device] and on no other device or server row.
  static bool _heldOnlyBy(Observation obs, String device, String image) =>
      _holds(obs.devices[device], image) && !_heldOnServerOr(obs, image, except: device);

  /// Image [image] was held on some other device than [device], and neither on [device] nor on the server.
  static bool _heldOnlyByOthers(Observation obs, String device, String image) =>
      !_holds(obs.devices[device], image) &&
      !obs.liveRows.any((r) => r.imageSet == image) &&
      obs.devices.entries.any((e) => e.key != device && _holds(e.value, image));

  /// Image [image] was held on [device] and on a server row, and on no other device.
  static bool _heldHereAndOnServerOnly(Observation obs, String device, String image) =>
      _holds(obs.devices[device], image) &&
      obs.liveRows.any((r) => r.imageSet == image) &&
      !obs.devices.entries.any((e) => e.key != device && _holds(e.value, image));

  static bool _heldOnServerOr(Observation obs, String image, {required String except}) =>
      obs.liveRows.any((r) => r.imageSet == image) ||
      obs.devices.entries.any((e) => e.key != except && _holds(e.value, image));

  /// Images an arriving archive without images removed: a record on another device, or the
  /// server's row, that held an image before this step and is an archive without images, holding
  /// none, after it. The device that archives a record itself is the user's own removal.
  void _noteArrivalDrops(Op op, Observation before, Observation after) {
    bool droppedBy(String? archiveBefore, String? archiveAfter, String? imageAfter) =>
        archiveBefore != 'none' && archiveAfter == 'none' && imageAfter == null;
    for (final MapEntry(key: name, value: d) in before.devices.entries) {
      if (name == op.device && op is Archive) continue;
      for (final r in d.records.values) {
        final image = r.imageSet;
        final now = after.devices[name]?.records[r.id];
        if (image == null || now == null) continue;
        if (droppedBy(r.archiveOption, now.archiveOption, now.imageSet)) _imagesDroppedOnArrival.add(image);
      }
    }
    for (final r in before.liveRows) {
      final image = r.imageSet;
      final now = after.rows[r.id];
      if (image == null || now == null || !now.alive) continue;
      if (droppedBy(r.archiveOption, now.archiveOption, now.imageSet)) _imagesDroppedOnArrival.add(image);
    }
  }

  /// Records split off another record during this step.
  void _noteNewForks(Observation before, Observation after) {
    for (final MapEntry(key: name, value: d) in after.devices.entries) {
      final pre = before.devices[name];
      for (final r in d.records.values) {
        final from = r.forkedFrom;
        if (from == null || _forks.containsKey(r.id) || (pre?.records.containsKey(r.id) ?? false)) continue;
        final source = pre?.records[from];
        _forks[r.id] = _ForkSeen(from, r.contentSet, name, copyless: source != null && !source.hasSnapshot);
        if (r.imageSet != r.contentSet) _copyOf[r.id] = _copyOf[from] ?? from;
      }
    }
  }

  /// The per-step check: nothing that must stay has vanished from everywhere.
  void check(Observation obs) {
    _noteImages(obs);
    _noteForks(obs);
    for (final r in obs.liveRows) {
      final c = r.contentSet;
      if (c != null) _rowLastHeld.putIfAbsent(r.id, () => {})[c] = _step;
    }
    for (final o in _obligations.where((o) => !o.released)) {
      if (!_contentPresent(obs, o.token)) {
        _report(
          Violation(ViolationKind.recordLost, o.token, 'content ${o.token} (made at ${o.ids.first}) is on no record'),
        );
      }
      _checkImage(obs, o);
    }
  }

  /// A fork carries the content it was split off with to a new id; the obligations on the record it
  /// came from follow it there, so deleting the fork discards them. A fork of a merged or deleted
  /// record carries that merge, and with it the memos the merge moves.
  void _noteForks(Observation obs) {
    for (final d in obs.devices.values) {
      for (final r in d.records.values) {
        final from = r.forkedFrom;
        if (from == null) continue;
        if (_mergedOrDeleted.contains(from)) _mergedOrDeleted.add(r.id);
        for (final o in _obligations) {
          if (o.token == r.contentSet && o.ids.contains(from)) o.ids.add(r.id);
        }
      }
    }
  }

  void _noteImages(Observation obs) {
    for (final d in obs.devices.values) {
      for (final r in d.records.values) {
        final s = r.imageSet;
        if (s != null) _imagesSeen.add(s);
      }
    }
    for (final r in obs.rows.values) {
      final s = r.imageSet;
      if (s != null) _imagesSeen.add(s);
    }
  }

  static bool _contentPresent(Observation obs, String token) =>
      obs.liveRows.any((r) => r.contentSet == token) ||
      obs.devices.values.any((d) => d.records.values.any((r) => r.contentSet == token));

  static bool _imagePresent(Observation obs, String token) =>
      obs.liveRows.any((r) => r.imageSet == token) ||
      obs.devices.values.any((d) => d.records.values.any((r) => r.imageSet == token));

  /// Notes when the image [o] needs is first on no record. Whether that loss is accepted depends on
  /// how the merges that caused it were later taken, so it is decided when the run ends.
  void _checkImage(Observation obs, _Obligation o) {
    final token = o.token;
    if (!o.needsImage || !_imagesSeen.contains(token)) return;
    if (_imagesDroppedByUser.contains(token)) return;
    if (_imagePresent(obs, token)) return;
    _imagesLost.putIfAbsent(token, () => _step);
  }

  /// A lost image is reported when some content still needs it at the end: an image whose last
  /// claimant was later discarded by a user who had seen it go (say, the device that kept the
  /// content merged it away again before sending) is no loss anyone can see.
  void _judgeLostImages() {
    for (final token in _imagesLost.keys) {
      if (!_obligations.any((o) => o.token == token && !o.released && o.needsImage)) continue;
      final shape = _imageLossShapes(token).where(accepted.contains).firstOrNull;
      if (shape != null) {
        tolerated.putIfAbsent(token, () => shape);
        continue;
      }
      _report(Violation(ViolationKind.imageLost, token, 'image of $token is on no device and not on the server'));
    }
  }

  /// The accepted outcomes whose exact shape the loss of image [t] has.
  Set<Accepted> _imageLossShapes(String t) {
    final merges = _made.whereType<_MergeMade>().toList();
    final shapes = <Accepted>{};
    final discards = <_Made>[
      for (final m in merges)
        if (m.discarded == t && m.discardedImageOnlyHere) m,
      for (final d in _made.whereType<_DeleteMade>())
        if (d.token == t && d.imageOnlyHere) d,
    ];
    final choices = <_Made>[
      for (final a in merges)
        if (a.kept == t && !a.keptHadImage) a,
      for (final i in _made.whereType<_ImportMade>())
        if (i.token == t && !i.hadImage) i,
    ];
    if (discards.any((x) => choices.any((c) => c.device != x.device && !c.saw(x)))) {
      shapes.add(Accepted.discardedTheOnlyImage);
    }
    final alsoOnServer = <_Made>[
      for (final m in merges)
        if (m.discarded == t && m.discardedImageHereAndOnServer) m,
      for (final d in _made.whereType<_DeleteMade>())
        if (d.token == t && d.imageHereAndOnServer) d,
    ];
    if (alsoOnServer.any((x) => choices.any((c) => c.device != x.device && !c.saw(x)))) {
      shapes.add(Accepted.discardedImageAlsoOnServer);
    }
    for (final ar in _made.whereType<_ArchiveNoneMade>()) {
      final ontoIt = merges.any(
        (a) =>
            a.device != ar.device &&
            a.survivor == ar.id &&
            a.keptFrom != ar.id &&
            a.kept == t &&
            a.keptImageOnlyElsewhere &&
            !a.saw(ar),
      );
      if (ontoIt) shapes.add(Accepted.mergedOntoArchivedNone);
    }
    if (_imagesDroppedOnArrival.contains(t)) shapes.add(Accepted.otherDeviceArchiveNoneDeletesImages);
    return shapes;
  }

  /// The check after every device synced to rest.
  List<Violation> finish(Observation obs, {required bool quiesced}) {
    if (!quiesced) _report(const Violation(ViolationKind.noQuiescence, '-', 'syncing never came to rest'));
    check(obs);
    _judgeLostImages();
    _checkConvergence(obs);
    _checkIntents(obs);
    _checkImageDelivery(obs);
    _checkMemos(obs);
    _checkNothingReturned(obs);
    return violations;
  }

  void _checkConvergence(Observation obs) {
    final live = {for (final r in obs.liveRows) r.id: r};
    for (final MapEntry(key: name, value: d) in obs.devices.entries) {
      for (final id in {...live.keys, ...d.records.keys}) {
        final row = live[id];
        final rec = d.records[id];
        if (row == null || rec == null) {
          final where = row == null ? 'on $name but not on the server' : 'on the server but not on $name';
          _report(Violation(ViolationKind.notConverged, '$name/$id', '$id is $where'));
          continue;
        }
        if (row.contentSet != rec.contentSet || row.archiveOption != rec.archiveOption) {
          _report(
            Violation(
              ViolationKind.notConverged,
              '$name/$id',
              'server ${row.contentSet}/${row.archiveOption} vs $name ${rec.contentSet}/${rec.archiveOption}',
            ),
          );
        }
        final server = obs.serverMemos[id];
        final local = d.memos[id]?.value;
        if (server != local) {
          _report(Violation(ViolationKind.notConverged, '$name/$id/memo', 'server memo $server vs $name $local'));
        }
      }
    }
  }

  void _checkIntents(Observation obs) {
    for (final i in _intents.where((i) => !i.cleared)) {
      final onServer = obs.rows[i.id];
      final alive =
          (onServer != null && onServer.alive && onServer.contentSet == i.token) ||
          obs.devices.values.any((d) => d.records[i.id]?.contentSet == i.token);
      if (!alive) continue;
      // A choice on this record the discarding device had not received — another device's merge
      // onto it — is not discarded by that delete or merge (its obligation stays), so the record
      // staying is that choice kept, not the intent undelivered.
      if (_obligations.any((o) => o.choice && !o.released && o.token == i.token && o.ids.contains(i.id))) continue;
      if (_sentAfterDiscard(i.token, i.id)) {
        if (_tolerate(Accepted.discardedComesBackAsDuplicate, 'intent:${i.id}')) continue;
      }
      if (i.untracked == Untracked.legacyApp && _tolerate(Accepted.untrackedDiscardReturns, 'intent:${i.id}')) {
        continue;
      }
      final v = Violation(ViolationKind.intentNotDelivered, i.id, '${i.id} was ${i.what} but is still live');
      _report(v);
      if (i.untracked == Untracked.storageScreen) _candidate(v, Candidate.storageScreenDeleteReturns);
    }
  }

  void _candidate(Violation v, Candidate c) => candidates.putIfAbsent('${v.kind.name}:${v.subject}', () => c);

  /// The removals that discarded [token], when there are any and every one of them was [untracked]. A
  /// merge that kept [token] did not discard it.
  bool _onlyUntrackedDiscards(String token, Untracked untracked) {
    final ds = _discards.where((d) => d.token == token && !d.kept);
    return ds.isNotEmpty && ds.every((d) => d.untracked == untracked);
  }

  /// Whether record [id] holding [token] was sent, without a row on either side, after a user discarded
  /// [token] on [id].
  bool _sentAfterDiscard(String token, String id) {
    final sent = _sentWithoutCopy[token]?[id];
    return sent != null && _discards.any((x) => x.token == token && x.id == id && x.made < sent);
  }

  bool _tolerate(Accepted shape, String subject) {
    if (!accepted.contains(shape)) return false;
    tolerated.putIfAbsent(subject, () => shape);
    return true;
  }

  void _checkImageDelivery(Observation obs) {
    if (obs.imageForm != 'png' && obs.imageForm != 'jpeg') return;
    for (final row in obs.liveRows) {
      if (row.archiveOption == 'none') continue;
      final c = row.contentSet;
      final held = obs.devices.values.any((d) => d.records[row.id]?.imageSet == c);
      if (held && row.imageSet != c) {
        _report(
          Violation(ViolationKind.imageNotDelivered, row.id, 'a device holds the image of $c; the server does not'),
        );
      }
      if (row.imageSet != c) continue;
      for (final MapEntry(key: name, value: d) in obs.devices.entries) {
        final rec = d.records[row.id];
        if (!d.downloadImages || rec == null || rec.archiveOption == 'none') continue;
        if (rec.imageSet != c) {
          _report(Violation(ViolationKind.imageNotDelivered, '$name/${row.id}', 'the image of $c never reached $name'));
        }
      }
    }
  }

  void _checkMemos(Observation obs) {
    final latest = <String, _MemoEdit>{};
    for (final e in _memoEdits) {
      if (_mergedOrDeleted.contains(e.id)) continue;
      final cur = latest[e.id];
      if (cur == null || e.time >= cur.time) latest[e.id] = e;
    }
    for (final e in latest.values) {
      if (!(obs.rows[e.id]?.alive ?? false)) continue;
      final values = [obs.serverMemos[e.id], for (final d in obs.devices.values) d.memos[e.id]?.value];
      if (values.any((v) => v != e.value)) {
        _report(Violation(ViolationKind.memoLost, e.id, 'last memo "${e.value}" is not everywhere: $values'));
      }
    }
  }

  /// Every content still listed after rest, on a record other than the one a user deleted or merged
  /// away with it, has an obligation no user has discarded — or every record holding it is a fork a
  /// device without a server row made, a record such a device sent before receiving the discard, or
  /// the record a zip import overwrote while sync was off (the accepted duplicate).
  void _checkNothingReturned(Observation obs) {
    final holders = <String, Set<String>>{};
    final ids = <String, Set<String>>{};
    void hold(String token, String id, String where) {
      if (_intents.any((i) => !i.cleared && i.id == id && i.token == token)) return;
      holders.putIfAbsent(token, () => {}).add('$where/$id');
      ids.putIfAbsent(token, () => {}).add(id);
    }

    for (final r in obs.liveRows) {
      final c = r.contentSet;
      if (c != null) hold(c, r.id, 'server');
    }
    for (final MapEntry(key: name, value: d) in obs.devices.entries) {
      for (final r in d.records.values) {
        hold(r.contentSet, r.id, name);
      }
    }
    for (final MapEntry(key: token, value: at) in holders.entries) {
      if (_obligations.any((o) => o.token == token && !o.released)) continue;
      final overwritten = _overwrittenWhileOff[token] ?? const {};
      final duplicate = ids[token]!.every(
        (id) => (_forks[id]?.copyless ?? false) || overwritten.contains(id) || _sentAfterDiscard(token, id),
      );
      if (duplicate && _tolerate(Accepted.discardedComesBackAsDuplicate, 'returned:$token')) continue;
      if (_onlyUntrackedDiscards(token, Untracked.legacyApp) &&
          _tolerate(Accepted.untrackedDiscardReturns, 'returned:$token')) {
        continue;
      }
      final v = Violation(
        ViolationKind.discardedReturned,
        token,
        'content $token was deleted or merged away by a user, and is back on ${at.join(', ')}',
      );
      _report(v);
      if (_onlyUntrackedDiscards(token, Untracked.storageScreen)) _candidate(v, Candidate.storageScreenDeleteReturns);
    }
  }
}
