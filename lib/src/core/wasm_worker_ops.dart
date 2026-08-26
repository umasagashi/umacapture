/// The pure decisions of the Wasm worker client, kept apart from it so they can be
/// tested on the VM.
///
/// `wasm_worker_client.dart` imports `dart:js_interop` and `package:web`, so no VM
/// test can even compile it — the same reason `live_content_freeze.dart` exists. What
/// lives here is everything about the client that is a rule rather than a browser
/// call: which harvested files may be published, which of them a live session already
/// committed, how overlapping record regenerations are serialized, how long a stop may
/// wait for the incremental OPFS writes, which teardown in flight owns an arriving
/// `harvest` / `stopped`, when a repeated one-time setup has to be re-run rather than
/// coalesced, and which pending operations a worker-level failure is allowed to settle.
library;

import 'dart:async';
import 'dart:typed_data';

import '/src/core/video_import_ops.dart';

/// One record file crossing the worker boundary: [path] is storage-relative
/// (`chara_detail/active/<id>/<file>`), [bytes] the file's exact contents.
///
/// Structurally identical to `WasmWorkerClient`'s `HarvestedRecordFile` and to
/// `web_record_persistence.dart`'s `PersistentHarvestedRecordFile` — Dart record types
/// are structural, so the helpers here accept either without a conversion.
typedef WorkerRecordFile = ({String path, Uint8List bytes});

/// The file every record directory must contain to be publishable: the recognizer
/// writes it **last** (`chara_detail_recognizer.cpp`), so its absence is precisely the
/// signature of a record whose recognition did not finish.
const String _recordJsonName = 'record.json';

/// Splits a harvested storage-relative path into its segments, or returns null when it
/// is not a `chara_detail/active/<id>/…` record file.
///
/// The rules match `parseHarvestedRecordFiles` in `web_record_persistence.dart`
/// deliberately: that function is the persistence gate and **throws** for anything it
/// does not accept, so a pre-filter that accepted more would only move the throw one
/// step later. (The two implementations remain separate because the persistence layer
/// is not this layer's to reach into; keeping their rules identical is the contract.)
List<String>? _splitHarvestPath(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  if (parts.length < 4 || parts[0] != 'chara_detail' || parts[1] != 'active') {
    return null;
  }
  if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    return null;
  }
  if (!_isSafeRecordId(parts[2])) {
    return null;
  }
  return parts;
}

bool _isSafeRecordId(String id) => RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id);

/// The record id a harvested [path] belongs to, or null when the path does not name a
/// record file at all.
String? recordIdFromHarvestPath(String path) => _splitHarvestPath(path)?[2];

/// The outcome of [selectPublishableRecordFiles]: the files that may be handed to the
/// persistence layer, plus what was left out and why.
typedef HarvestSelection = ({
  List<WorkerRecordFile> publishable,
  List<String> incompleteRecordIds,
  List<String> rejectedPaths,
});

/// Keeps only the files of records that are complete enough to publish.
///
/// The worker's final sweep collects **every** directory under its MEMFS active root
/// with no completeness check, and a recognizer that threw part-way leaves a directory
/// with no `record.json` behind for the rest of the session. The persistence layer
/// validates the whole batch before writing anything, so handing it one such directory
/// throws away every completed record of the same session. Grouping here and dropping
/// only the incomplete group is what keeps one failed record from costing the others.
///
/// Order is preserved, and a record is judged solely on whether its own `record.json`
/// is present in this batch.
HarvestSelection selectPublishableRecordFiles(Iterable<WorkerRecordFile> files) {
  final rejectedPaths = <String>[];
  final byRecord = <String, List<WorkerRecordFile>>{};
  final complete = <String>{};
  for (final file in files) {
    final parts = _splitHarvestPath(file.path);
    if (parts == null) {
      rejectedPaths.add(file.path);
      continue;
    }
    final recordId = parts[2];
    byRecord.putIfAbsent(recordId, () => <WorkerRecordFile>[]).add(file);
    if (parts.length == 4 && parts[3] == _recordJsonName) {
      complete.add(recordId);
    }
  }
  final publishable = <WorkerRecordFile>[];
  final incompleteRecordIds = <String>[];
  for (final entry in byRecord.entries) {
    if (complete.contains(entry.key)) {
      publishable.addAll(entry.value);
    } else {
      incompleteRecordIds.add(entry.key);
    }
  }
  return (
    publishable: List.unmodifiable(publishable),
    incompleteRecordIds: List.unmodifiable(incompleteRecordIds),
    rejectedPaths: List.unmodifiable(rejectedPaths),
  );
}

/// Drops the files of records the incremental live path already committed to OPFS, so
/// the final sweep does not re-publish them.
///
/// A file whose path names no record is kept: judging it is
/// [selectPublishableRecordFiles]'s job, and silently dropping bytes here would hide
/// the very divergence this parsing could introduce.
List<WorkerRecordFile> filterUncommittedHarvest(Iterable<WorkerRecordFile> files, Set<String> committedRecordIds) {
  return files
      .where((file) {
        final recordId = recordIdFromHarvestPath(file.path);
        return recordId == null || !committedRecordIds.contains(recordId);
      })
      .toList(growable: false);
}

/// Waits for the incremental live-record OPFS writes [persists] to settle, for at most
/// [drainTimeout], and reports whether they all did (`false` means the bound expired
/// with at least one still in flight).
///
/// **This bound is the only thing that bounds them.** Each persist is a main-thread OPFS
/// write with no timeout of its own, so an unbounded wait on them is an unbounded wait,
/// full stop — and putting one behind a timed-out operation's completion turns that
/// operation's timeout into a promise it cannot keep.
///
/// A failed persist settles the wait like a successful one: [Future.wait] would rethrow
/// the first error, and an error escaping here would leave the caller's operation
/// pending forever — the exact failure the bound exists to prevent. A write that failed
/// simply never marks its record committed, so the final sweep republishes it.
///
/// The set is snapshotted on entry: a write started *after* the drain began belongs to
/// work that started after the stop, and waiting for it could postpone the answer
/// indefinitely.
Future<bool> drainLiveRecordPersists(Iterable<Future<void>> persists, Duration drainTimeout) {
  final pending = persists.toList(growable: false);
  if (pending.isEmpty) {
    return Future.value(true);
  }
  final settled = Future.wait(pending.map((persist) => persist.then((_) {}, onError: (Object _) {})));
  return settled.then((_) => true).timeout(drainTimeout, onTimeout: () => false);
}

/// Settles [stop] with [harvest] once the incremental live-record writes [persists] have
/// settled, or [drainTimeout] has expired with some still in flight. Returns whether the
/// writes drained in time.
///
/// Draining first is what lets the final sweep suppress the records OPFS already holds
/// (see [filterUncommittedHarvest]): a successful incremental write can otherwise race
/// the sweep and the same record is published twice. Bounding the drain is what keeps the
/// caller's own timeout honest — see [drainLiveRecordPersists].
///
/// [harvest] is invoked **only** when this call is the one that settles [stop], because
/// producing the harvest consumes the client's buffers; a [stop] already settled by
/// another path (a teardown, or a first completion attempt that won the race) keeps its
/// own answer.
Future<bool> completeStopAfterPersists({
  required Completer<List<WorkerRecordFile>> stop,
  required Iterable<Future<void>> persists,
  required Duration drainTimeout,
  required List<WorkerRecordFile> Function() harvest,
}) async {
  final drained = await drainLiveRecordPersists(persists, drainTimeout);
  if (!stop.isCompleted) {
    stop.complete(harvest());
  }
  return drained;
}

/// Serializes operations that must not overlap, in submission order.
///
/// Record regeneration needs this: the worker's staging area is a module-global MEMFS
/// path, so two `updateRecord`s for the same record in flight at once would stage into
/// each other's directory. The serialization is Dart's responsibility, which is why the
/// gate is a plain queue that **survives everything**. It is the *affordance*; the worker
/// keeps a per-record window of its own and refuses a duplicate, and [UpdateSlots] keeps
/// the replies apart, so an overlap that slips past the gate is bounded rather than
/// catastrophic — see [UpdateSlots] for what that overlap used to cost.
///
/// In particular a teardown must never replace the gate. Doing so releases whatever is
/// still queued on the old chain while the next submission starts on the new one, which
/// is exactly the two-at-once case the gate exists to prevent. A queued action recovers
/// on its own — it re-establishes the worker when it finally runs — so there is nothing
/// a reset could buy.
class SerialGate {
  Future<void> _tail = Future.value();

  /// Queues [action] behind everything already queued and returns its result.
  ///
  /// The tail is captured and advanced synchronously, before any suspension, so two
  /// callers in the same turn can never observe the same predecessor. Errors advance the
  /// queue like successes: one failed operation must not wedge the rest.
  Future<T> run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }
}

/// The two endings one record regeneration has, handed to whoever started it.
///
/// [answer] is the caller's result — the regenerated files, or the reason there are none.
/// [handlerEnded] is the worker's confirmation that its `handleUpdateRecord` is over. They
/// are different events and [UpdateSlots] exists to keep them apart; see that class.
/// [handlerEnded] never carries an error, so it is always safe to await.
typedef UpdateRegistration = ({Future<List<WorkerRecordFile>> answer, Future<void> handlerEnded});

class _UpdateSlot {
  final Completer<List<WorkerRecordFile>> answer = Completer<List<WorkerRecordFile>>();
  final Completer<void> handlerEnded = Completer<void>();

  /// Whether the `updateRecord` message has actually been sent. A slot is registered when the
  /// caller submits, which is before the gate lets it run, so registration alone does not mean
  /// the worker knows about this record — and a worker failure must not be attributed to a
  /// regeneration that has not left this side yet.
  bool posted = false;
}

/// The record regenerations in flight, keyed by record id, and which one a reply belongs to.
///
/// **A map, not a slot, and two endings rather than one.** Both halves fix the same defect
/// class — *advancing state without checking whose reply it is* — from the two directions it
/// reached:
///
///  * **The reply.** The worker stamps every `updated` with its `recordId`, and the client
///    used to ignore it and settle whichever single completer it happened to be holding. A
///    reply produced for record A then answered record B's caller. Nothing here settles
///    anything without being told the id ([settle] returns false rather than guessing), which
///    is the same rule `_videoFrameRequests` already follows for the frame-grab queries.
///  * **The gate.** [SerialGate] serializes regenerations so the worker never has two at once,
///    but it can only advance when the action it is running completes — and the action used to
///    complete as soon as the *caller's* future settled. A worker-level `error` settles that
///    future by attribution rather than by knowledge ([scopeWorkerFailure]'s documented
///    misattribution), and the worker's handler is still parked in its own wait when it does.
///    The next regeneration was then posted into a worker that still owned the first one, whose
///    bookkeeping the second overwrote — and whose exit then threw a TypeError out of the
///    worker's message dispatch, failing the rest of the batch by cascade. So a misattributed
///    failure settles the [answer] only ([failAnswers]); the gate holds until the worker says
///    its handler ended, which `web/worker.js` guarantees by posting exactly one `updated` per
///    `updateRecord` on every exit, including a throw.
///
/// Registration is refused rather than overwritten ([begin] throws on a duplicate id), because
/// a second regeneration of the *same* record is the one case a map cannot represent and
/// silently clobbering it is what a slot did.
class UpdateSlots {
  final Map<String, _UpdateSlot> _slots = <String, _UpdateSlot>{};

  /// Whether any regeneration has been posted and not yet answered — what
  /// [scopeWorkerFailure]'s `updateInFlight` means. Counted from the map at every ask, never
  /// remembered in a flag, so a reader cannot go stale when one starts or ends while it is
  /// deciding. Registered-but-not-yet-posted records are deliberately not counted: the worker
  /// has not been told about them.
  bool get inFlight => _slots.values.any((slot) => slot.posted);

  /// The record ids currently registered — posted or merely queued — in registration order.
  Iterable<String> get recordIds => _slots.keys;

  bool contains(String recordId) => _slots.containsKey(recordId);

  /// Records that the `updateRecord` message for [recordId] is now on its way to the worker.
  /// From here on a worker failure may be attributed to it and its reply is expected.
  void markPosted(String recordId) {
    final slot = _slots[recordId];
    if (slot != null) {
      slot.posted = true;
    }
  }

  /// Registers [recordId] and hands back its two endings.
  ///
  /// Throws a [StateError] when [recordId] is already registered: the caller must decide what a
  /// duplicate means, and no answer here can be right for both of them.
  UpdateRegistration begin(String recordId) {
    if (_slots.containsKey(recordId)) {
      throw StateError('a regeneration of $recordId is already in flight');
    }
    final slot = _UpdateSlot();
    _slots[recordId] = slot;
    return (answer: slot.answer.future, handlerEnded: slot.handlerEnded.future);
  }

  /// Settles the regeneration of [recordId] with the worker's verdict, and releases the gate.
  ///
  /// Exactly one of [files] / [error] is meaningful; [error] wins when both are given. Returns
  /// whether a slot matched — a reply for an id nobody is awaiting is the caller's to log and
  /// drop, never to apply to somebody else.
  ///
  /// Tolerates an [answer] another path already settled (a misattributed failure, then the
  /// worker's own late verdict): the handler-ended signal still fires, which is the point.
  bool settle(String recordId, {List<WorkerRecordFile>? files, Object? error}) {
    final slot = _slots.remove(recordId);
    if (slot == null) {
      return false;
    }
    if (!slot.answer.isCompleted) {
      if (error != null) {
        slot.answer.completeError(error);
      } else {
        slot.answer.complete(files ?? const <WorkerRecordFile>[]);
      }
    }
    if (!slot.handlerEnded.isCompleted) {
      slot.handlerEnded.complete();
    }
    return true;
  }

  /// A worker-level failure that names no operation: fails the [answer] of every **posted**
  /// regeneration and **leaves every [handlerEnded] alone**, because a worker that is still
  /// there is still running them.
  ///
  /// [error] is built per record id so the message can name the record it is failing. Returns
  /// the ids whose answer this failed, for the caller's log.
  List<String> failAnswers(Object Function(String recordId) error) {
    final failed = <String>[];
    _slots.forEach((recordId, slot) {
      if (slot.posted && !slot.answer.isCompleted) {
        slot.answer.completeError(error(recordId));
        failed.add(recordId);
      }
    });
    return failed;
  }

  /// The worker is gone: settle both endings of every **posted** regeneration and forget them.
  /// No `updated` can arrive from a worker that no longer exists, so holding the gate for one
  /// would wedge it. A queued regeneration is left alone on purpose — it has not been posted to
  /// the worker that died, and it re-establishes a worker of its own when its turn comes.
  List<String> abandonAll(Object Function(String recordId) error) {
    final abandoned = [
      for (final entry in _slots.entries)
        if (entry.value.posted) entry.key,
    ];
    for (final recordId in abandoned) {
      settle(recordId, error: error(recordId));
    }
    return abandoned;
  }
}

/// Which pending worker operations a worker-level failure may settle.
typedef WorkerFailureScope = ({bool stop, bool liveStart, bool firstFrame, bool update, bool videoImportStart});

/// Decides the blast radius of a worker failure.
///
/// The worker's `{type:'error'}` carries no operation id, and the protocol is fixed, so
/// attribution has to be made from what is in flight on this side.
///
/// * [workerGone] — the worker itself was torn down (`terminate()`). Nothing it owed can
///   still arrive, so every pending operation has to be settled here or its caller waits
///   for a reply that no longer has a sender.
/// * [updateInFlight] — a record regeneration is running. Regeneration is a *passenger*
///   on the shared event loop (deliberately, and identically to the desktop runner), so
///   it coexists with a live capture and fails independently of it. An error that arrives
///   in that window is attributed to the regeneration alone: failing the live session's
///   operations too used to abort a healthy session start and — far worse — error the
///   pending stop, after which `stopCapture` never reached its OPFS persist and the whole
///   session's already-shipped records were dropped.
///
/// **Known misattribution, and its direction.** This attributes by what is *in flight*,
/// not by what actually failed, because the worker's `error` carries no operation id. So
/// an error caused by the **live session** while a regeneration happens to be running
/// fails the innocent regeneration and spares the broken session — never the reverse,
/// since an error with no regeneration in flight cannot be blamed on one. The cost of
/// that direction is bounded on both halves: the regeneration's record is simply not
/// updated (nothing is written, nothing is corrupted, the user can retry), and the live
/// session is not spared indefinitely — it waits out its full `startLive` bound instead
/// of failing fast. The complete fix is an `op` field on the worker's `fail()`, i.e. a
/// protocol change, which was deliberately declined; this is a heuristic on purpose and
/// must not be read as exact attribution.
///
/// A stop is **never** failed by an error from a worker that is still there: an error
/// does not cancel a `stopped` that is still coming (the session's harvest travels with
/// it), and a `stopped` that never comes is the stop timeout's business, which delivers
/// the buffered harvest instead of discarding it.
/// A video import's **start** is scoped exactly like a live session's start, and for the
/// same reason: a start that the worker refuses (a cross-kind conflict, a core with no
/// offline push, an undecodable clip) is reported as an `error` and by nothing else, so
/// leaving it out would make every refusal wait out a timeout instead of failing at once.
/// Its *terminal* message is deliberately not in the scope — the worker guarantees exactly
/// one `videoImportDone` per import and posts the failure immediately before it, so an
/// error from a worker that is still there is a preface to that message, not a substitute
/// for it. Only a worker that is gone (`workerGone`) owes nothing further.
///
/// **An unacknowledged import start outranks a regeneration in flight**, which is the one
/// exception to the precedence above and the only one this heuristic can justify: it is
/// decided by which pending operation has *no other channel*. A start is reported by an
/// `error` and by nothing else, so an error withheld from it is an answer the user never
/// gets — they wait out the full start bound and are then told the import timed out
/// instead of why it was refused. A posted regeneration is owed exactly one `updated` on
/// every exit including a throw, so withholding this error from it costs it nothing: its
/// own verdict is still coming, and taking this one instead reports a record as failed
/// that the worker may well be regenerating correctly. Failing a record the user did not
/// ask to change is the heavier of the two errors, and it is avoidable here.
///
/// The two cannot both be unacknowledged in a way that reopens the ambiguity the doc above
/// names: the worker posts `videoImportStarted` *before* it decodes anything, and message
/// order is preserved, so by the time it can refuse a regeneration for an import that owns
/// the loop, this side has already seen that acknowledgement and [videoImportStarting] is
/// false.
WorkerFailureScope scopeWorkerFailure({
  required bool workerGone,
  required bool updateInFlight,
  bool videoImportStarting = false,
}) {
  if (workerGone) {
    return (stop: true, liveStart: true, firstFrame: true, update: true, videoImportStart: true);
  }
  if (updateInFlight) {
    return (
      stop: false,
      liveStart: false,
      firstFrame: false,
      update: !videoImportStarting,
      videoImportStart: videoImportStarting,
    );
  }
  return (stop: false, liveStart: true, firstFrame: true, update: false, videoImportStart: videoImportStarting);
}

/// Whether a worker-level failure belongs to a running video import rather than to the
/// capture status area.
///
/// The capture page's status area and its failure chime describe **live capture**. An
/// import has its own result tile with a translated line per outcome, and the worker
/// reports an import's refusals — an undecodable codec, a clip with no video track, a
/// start refused because a record regeneration is in flight — on the same `error` channel
/// every other failure uses. Relayed as an `onError` those become `captureState.fail()`
/// plus the chime, i.e. a raw English worker string in the capture status for an ordinary
/// app state, next to the properly translated tile that is already saying it. So the
/// failure is withheld from the relay and reaches the user through the import's own
/// terminal outcome instead — the worker guarantees exactly one, and posts the failure
/// immediately before it.
///
/// Attribution follows [scopeWorkerFailure]'s precedence exactly, and for the same reason:
/// the worker's `error` carries no operation id, so a regeneration in flight keeps the
/// failure to itself (it is the narrower claim, and it has its own reporting path). That
/// also removes the one genuine ambiguity — the worker refuses a **regeneration** while an
/// import owns the loop, which is a message that arrives precisely when an import is
/// running and is not the import's.
///
/// [videoImportStarting] carries [scopeWorkerFailure]'s one exception through to the relay,
/// so the two cannot disagree about whose failure it is. A start the worker refuses
/// *because* a regeneration is in flight is the case that made this necessary: that refusal
/// is the import's by construction, and routing it to the capture status put the worker's
/// raw English sentence and the failure chime in front of a user who was starting an
/// import — the exact outcome this function exists to prevent, produced by the very
/// precedence that was meant to prevent it.
bool videoImportOwnsWorkerFailure({
  required bool updateInFlight,
  required bool videoImportInFlight,
  bool videoImportStarting = false,
}) => videoImportInFlight && (videoImportStarting || !updateInFlight);

/// What a `stop` / `stopLive` must do about the stop slot the client already holds.
enum StopArming {
  /// Nothing is armed: post the teardown and arm a fresh completer for it.
  post,

  /// A stop is already in flight and its `stopped` is coming: join its future and post
  /// nothing, so one teardown is not run twice.
  coalesce,

  /// A video import armed the slot **for an ending nobody has asked for yet**: post the
  /// teardown and hand it this very completer.
  adopt,
}

/// Decides [StopArming] from the two facts that distinguish the cases.
///
/// The distinction that matters is between a slot armed by a *posted* stop and one armed by
/// a running import, because they mean opposite things. A posted stop's completer says "the
/// worker is already tearing down, wait for it". An import's says "this side is holding a
/// completer for an ending the import will produce on its own, minutes from now" — and
/// coalescing onto that made `stop()` and `stopLive()` return the import's future **without
/// posting anything**: `stopCapture`'s no-live-session branch sat out the entire import in
/// silence, and the worker's documented `endedByTeardown` ordering — which this client
/// explicitly codes for — was unreachable from Dart.
///
/// [StopArming.adopt] rather than a second completer because the stop *takes the import's
/// ending over*: the worker revokes the producer, joins it, harvests and posts `stopped`
/// exactly once. Two completers over one `stopped` would leave whichever lost the race
/// waiting for a message the other consumed.
StopArming resolveStopArming({required bool stopArmed, required bool awaitsImportTeardown}) {
  if (!stopArmed) {
    return StopArming.post;
  }
  return awaitsImportTeardown ? StopArming.adopt : StopArming.coalesce;
}

/// One teardown of the worker's event loop that is still owed an answer, together with the
/// harvest buffer the worker's `harvest` messages for it fill.
///
/// **One of these per teardown, never one per client.** A live session's stop and a video
/// import's self-ending teardown can be armed at the same moment: the import arms its
/// completer at `startVideoImport`, minutes before the ending it is armed for, while a stop
/// posted by the user — or by a controller rebuild tearing a session down — is waiting for a
/// `stopped` of its own. Holding "the teardown in flight" in a single field let the second
/// arming destroy the first: the earlier completer was replaced with no one left to settle
/// it, and the harvest already buffered for it was overwritten with an empty list.
///
/// Those bytes are the only copy — the worker deletes each harvested record directory from
/// its MEMFS the moment it has posted the message — so that overwrite was silent, permanent
/// loss of records the user had captured. Silent in the strict sense: it bypassed the
/// stranded-harvest rescue, so there was no log line, no Sentry event, and no toast; the
/// only symptom was a capture that never appeared in the list.
///
/// Ownership is the fix, and it has to be **data**: whose completer this is, and whose
/// harvest, are properties of the slot rather than of whatever the client happened to be
/// doing when a message arrived.
class PendingTeardown {
  PendingTeardown({required this.awaitsImportTeardown});

  /// The answer owed to whoever armed this teardown: the record files it harvested.
  final Completer<List<WorkerRecordFile>> completer = Completer<List<WorkerRecordFile>>();

  /// Whether this slot is a video import's **expected** teardown rather than one a posted
  /// `stop` armed — the distinction [resolveStopArming] turns into a decision. Cleared when
  /// a stop adopts the slot, because from then on the ending has been posted.
  bool awaitsImportTeardown;

  /// Whether the worker's `stopped` for this teardown has already been claimed.
  ///
  /// Not the same as "answered", and the gap between them is why this exists: a claimed
  /// `stopped` settles its completer only after the incremental OPFS writes have drained
  /// (up to `_livePersistDrainTimeout`), and routing the *next* teardown's `harvest` into
  /// this slot during that window would hand one session's files to another.
  bool stopClaimed = false;

  /// The record files the worker has shipped for this teardown so far.
  List<WorkerRecordFile> harvested = const [];
}

/// Every teardown the worker still owes a `harvest` + `stopped` for, oldest first.
///
/// A **set of owners, not a current one.** See [PendingTeardown] for what the single slot
/// this replaces cost. The worker serves one teardown at a time and `postMessage` preserves
/// order, so "oldest first" is not a guess about the protocol: it is the protocol.
///
/// Completed slots are pruned lazily, on every access, rather than by a `whenComplete` hook
/// on each completer. A hook runs a microtask later, so between `complete()` and the hook
/// the registry would still be reporting a teardown as pending — and every caller here acts
/// synchronously on that answer.
class TeardownRegistry {
  final List<PendingTeardown> _pending = <PendingTeardown>[];

  /// Harvested files that belong to no pending teardown: the worker shipped them after the
  /// teardown they belonged to had already been answered (its bound expired, or a worker
  /// failure settled it from the buffer). They are still the session's uncommitted tail, so
  /// they are kept for the rescue path rather than dropped.
  List<WorkerRecordFile> _unowned = const [];

  /// Drops the slots that have been answered, moving anything they still buffered to the
  /// unowned harvest so it can be rescued rather than discarded with the slot.
  void _prune() {
    _pending.removeWhere((slot) {
      if (!slot.completer.isCompleted) {
        return false;
      }
      if (slot.harvested.isNotEmpty) {
        _unowned = [..._unowned, ...slot.harvested];
        slot.harvested = const [];
      }
      return true;
    });
  }

  /// The teardowns still awaiting an answer, oldest first.
  List<PendingTeardown> get pending {
    _prune();
    return List<PendingTeardown>.unmodifiable(_pending);
  }

  bool get isEmpty {
    _prune();
    return _pending.isEmpty;
  }

  /// The most recently armed teardown — the one a `stop` arriving now would see — or null
  /// when none is armed.
  PendingTeardown? get latest {
    _prune();
    return _pending.isEmpty ? null : _pending.last;
  }

  /// Whether any pending teardown is a video import's expected one. Read by the client to
  /// decide whether the records it is shipping right now belong to an import.
  bool get awaitsImportTeardown {
    _prune();
    return _pending.any((slot) => slot.awaitsImportTeardown);
  }

  /// Whether a teardown other than [slot] is still pending. The client asks before clearing
  /// state that is shared across teardowns, so answering one cannot reach into another's.
  bool hasOtherPending(PendingTeardown slot) {
    _prune();
    return _pending.any((other) => !identical(other, slot));
  }

  /// Arms a teardown and returns its slot. **Adds; it never replaces.**
  PendingTeardown arm({required bool awaitsImportTeardown}) {
    _prune();
    final slot = PendingTeardown(awaitsImportTeardown: awaitsImportTeardown);
    _pending.add(slot);
    return slot;
  }

  /// Buffers a `harvest` against the teardown it belongs to: the oldest one that has not had
  /// its `stopped` yet. With none, the files are held as unowned (see [takeUnowned]).
  void addHarvest(List<WorkerRecordFile> files) {
    if (files.isEmpty) {
      return;
    }
    final slot = _awaitingWorker;
    if (slot == null) {
      _unowned = [..._unowned, ...files];
      return;
    }
    slot.harvested = [...slot.harvested, ...files];
  }

  PendingTeardown? get _awaitingWorker {
    _prune();
    for (final slot in _pending) {
      if (!slot.stopClaimed) {
        return slot;
      }
    }
    return null;
  }

  /// Claims the worker's `stopped` for the oldest teardown that has not had one, or returns
  /// null when the message belongs to no one (its teardown was already answered).
  PendingTeardown? claimStopped() {
    final slot = _awaitingWorker;
    slot?.stopClaimed = true;
    return slot;
  }

  /// Takes [slot]'s harvest for delivery, minus the records [committedRecordIds] already
  /// holds, and empties that slot's buffer. Touches no other slot's.
  List<WorkerRecordFile> takeHarvest(PendingTeardown slot, Set<String> committedRecordIds) {
    final taken = filterUncommittedHarvest(slot.harvested, committedRecordIds);
    slot.harvested = const [];
    return taken;
  }

  /// Drops [slot] — **and only [slot]** — from the registry, stranding whatever it still
  /// buffered rather than discarding it.
  ///
  /// The caller that releases a slot is releasing the one it armed. It used to release
  /// whatever the client's single field pointed at, which after a second arming was somebody
  /// else's: a refused import's cleanup answered a live session's stop with an empty harvest
  /// and left that session's records unreachable.
  void release(PendingTeardown slot) {
    if (!_pending.remove(slot)) {
      return;
    }
    if (slot.harvested.isNotEmpty) {
      _unowned = [..._unowned, ...slot.harvested];
      slot.harvested = const [];
    }
    _prune();
  }

  /// Drops every pending teardown, stranding what they buffered. For a worker that is gone:
  /// nothing it owed can still arrive, so no slot may stay armed for it.
  void releaseAll() {
    for (final slot in List<PendingTeardown>.of(_pending)) {
      release(slot);
    }
  }

  /// Takes the harvest no teardown can receive any more, and forgets it, so it can never be
  /// delivered to an unrelated later teardown. The rescue path is what saves it.
  List<WorkerRecordFile> takeUnowned() {
    _prune();
    final stranded = _unowned;
    _unowned = const [];
    return stranded;
  }
}

/// What a repeated one-time-`init` must do about a worker that is already set up.
enum SetupRefresh {
  /// The module set behind the new `init` is byte-identical to the one the worker holds, so
  /// this is one of the several `PlatformController` rebuilds a page load produces: join the
  /// existing setup and post nothing.
  coalesce,

  /// The module set changed and nothing owns the worker: tear it down and set it up again,
  /// so the running recognizer is the one the user just installed.
  reissue,

  /// The module set changed but a session (or a record regeneration) owns the worker.
  /// Tearing it down would end that session silently, so the new set is recorded as the one
  /// to set up with, and the next spawn is what applies it.
  deferToNextSpawn,
}

/// Decides [SetupRefresh] from the two facts that distinguish the cases.
///
/// **The defect this exists to remove.** `init` was coalesced on "setup has been issued"
/// alone, so after a module update the running worker kept the ONNX set and the
/// `version_info.json` of the *previous* module for the rest of the page's life — while the
/// settings screen, which re-reads that file straight from storage, showed the new version.
/// Every record recognized afterwards was stamped with the old `recognizer_version`, so the
/// re-recognition the update kicks off wrote the old verdict back and the "these records are
/// out of date" state never cleared. Nothing said so; the UI said the opposite.
///
/// So the coalesce condition is the **assets**, not the fact that a setup once happened. That
/// costs one read of the module set out of storage per post-ready `init`, which is why the
/// asset loader is a closure: the reads that do not need to happen — the rebuilds that land
/// while the first setup is still in flight — still do not.
SetupRefresh resolveSetupRefresh({required bool assetsChanged, required bool workerBusy}) {
  if (!assetsChanged) {
    return SetupRefresh.coalesce;
  }
  return workerBusy ? SetupRefresh.deferToNextSpawn : SetupRefresh.reissue;
}

/// Whether two module asset sets are the same bytes under the same names.
///
/// Keyed rather than positional because the loader walks a directory and nothing promises
/// two walks the same order, and compared by content rather than by length or count because
/// a module update can replace a model with one of exactly the same size. It is the identity
/// of what the worker was set up with, so a weaker comparison would answer "unchanged" for
/// precisely the update this is asked about.
bool sameWorkerAssets(Map<String, Uint8List> a, Map<String, Uint8List> b) {
  if (a.length != b.length) {
    return false;
  }
  for (final entry in a.entries) {
    final other = b[entry.key];
    if (other == null || other.length != entry.value.length) {
      return false;
    }
    for (var i = 0; i < other.length; i++) {
      if (other[i] != entry.value[i]) {
        return false;
      }
    }
  }
  return true;
}

/// How long a running video import may report **no progress at all** before its terminal
/// completer is settled as a failure.
///
/// This is an *inactivity* bound, not a total one, and the difference is the whole point:
/// an import legitimately runs for minutes (it is paced by the pipeline, not by the clock),
/// so a total bound would answer a healthy import's future while it was still working. What
/// no healthy import does is fall silent. The worker posts a progress report every
/// `PROGRESS_INTERVAL_MS = 250` of wall clock while frames flow, plus one before the first
/// frame and one after the last, and the only thing that legitimately pauses that stream is
/// the flow gate's park — which is bounded by `OFFLINE_INFLIGHT_MAX = 8` resident frames,
/// i.e. by the pipeline consuming at most eight frames. 120 s is ~480 times the reporting
/// cadence and far beyond any plausible park, so nothing short of a genuinely dead producer
/// reaches it.
///
/// **The same bound governs the Windows import**, which reuses [VideoImportSlots] (see
/// `video_import_io.dart`). The premise holds there for the same reason and not by luck: the
/// runner throttles to the same 250 ms and emits a final unconditional tick, and where web parks
/// on a flow gate the runner blocks on its own `Block` queue — a pause bounded by the pipeline
/// consuming, not by anything that can stall indefinitely. What it bounds there is a runner thread
/// that died without publishing its terminal message.
///
/// Without a bound of some kind the terminal completer settles only on `videoImportDone` or
/// on the worker being torn down, and a worker the browser kills under memory pressure — a
/// multi-gigabyte clip next to the wasm heap is exactly the case that provokes it — posts
/// neither. The import then stays `importing` forever: capture START stays disabled, cancel
/// is a no-op, and a page reload is the only exit.
const Duration videoImportProgressTimeout = Duration(seconds: 120);

/// The client-side slots one video import occupies, and the rule that governs them:
/// **the terminal outcome settles exactly once, and always settles.**
///
/// Extracted from `WasmWorkerClient` — which imports `dart:js_interop` and so cannot be
/// compiled by the VM test runner at all — because that rule is the whole of the import's
/// client-side correctness and is otherwise reachable only from a browser. Everything here
/// is plain `dart:async`: the three `videoImport*` messages arrive as decoded
/// `Map<String, dynamic>`s, and what leaves is a completed future and a progress value.
class VideoImportSlots {
  VideoImportSlots({this.progressTimeout = videoImportProgressTimeout, this.onProgressChanged, this.onStalled});

  /// The inactivity bound, overridable so a test does not have to wait one out.
  final Duration progressTimeout;

  /// Invoked whenever [progress] changes, including when it is cleared at the ending.
  final void Function(VideoImportProgress? progress)? onProgressChanged;

  /// Invoked when [progressTimeout] expires, before the import is failed, so the client
  /// can log the stall it is about to report.
  final void Function(Duration silence)? onStalled;

  Completer<void>? _start;
  Completer<VideoImportOutcome>? _done;
  Timer? _watchdog;

  /// The most recent progress report, or null when none has arrived (or the import ended).
  VideoImportProgress? progress;

  /// Whether an import owns the worker's event loop right now.
  bool get isRunning {
    final done = _done;
    return done != null && !done.isCompleted;
  }

  /// Whether a start is still waiting for its acknowledgement.
  bool get isStarting {
    final start = _start;
    return start != null && !start.isCompleted;
  }

  /// Takes both slots for a new import: the [start] acknowledgement's completer (handed to
  /// the caller's bounded request) and the [terminal] outcome's future.
  ///
  /// The inactivity bound is armed here rather than at `videoImportStarted`, so a start the
  /// worker never acknowledges *and* never refuses is bounded too.
  ({Completer<void> start, Future<VideoImportOutcome> terminal}) arm() {
    _publish(null);
    // THE IMPORT'S OWN WINDOW OPENS HERE, and with it the counting of the sessions that end empty
    // during it. Here rather than at `videoImportStarted`, and for the same reason the inactivity
    // bound is armed here: this is the one moment both front ends share (web's worker posts its own
    // `videoImportStarted`, which never reaches the shared native dispatch), and a run that is never
    // acknowledged must still start from zero rather than inherit the previous import's tally.
    videoImportSessionTally.beginRun();
    final start = Completer<void>();
    final done = Completer<VideoImportOutcome>();
    _start = start;
    _done = done;
    _touch();
    return (start: start, terminal: done.future);
  }

  /// Applies one `videoImportStarted` / `videoImportProgress` / `videoImportDone` message.
  ///
  /// Returns the terminal outcome when this message ended the import (and it was this call
  /// that settled it), null otherwise — including for a terminal message that arrives with
  /// no import awaiting one, which the caller reports rather than acts on.
  VideoImportOutcome? handle(String type, Map<String, dynamic> message) {
    switch (type) {
      case 'videoImportStarted':
        // The session is open and the clip is being read. Everything the import needs is
        // already armed; this only releases its caller.
        _touch();
        final start = _start;
        if (start != null && !start.isCompleted) {
          start.complete();
        }
        _start = null;
        return null;
      case 'videoImportProgress':
        _touch();
        _publish((
          decoded: _asInt(message['decoded']) ?? 0,
          supplied: _asInt(message['supplied']) ?? 0,
          mediaTimeMs: _asInt(message['mediaTimeMs']),
          durationMs: _asInt(message['durationMs']),
        ));
        return null;
      case 'videoImportDone':
        // EXACTLY ONE per import, whatever ended it, so this completes rather than errors: a
        // failed import is an outcome with a reason, and the worker relays the failure itself
        // immediately before this message, so nothing is lost by not throwing.
        return settle(videoImportOutcomeOf(message));
      default:
        return null;
    }
  }

  /// Settles the terminal slot with [outcome], if it is still open.
  ///
  /// Idempotent and the single door: `videoImportDone`, the inactivity bound, a worker that
  /// is gone and a start that never left all arrive here, so "exactly once" is a property of
  /// this method rather than of four call sites agreeing. Returns the outcome that was
  /// recorded, or null when the slot was already settled (or never armed).
  VideoImportOutcome? settle(VideoImportOutcome outcome) {
    _watchdog?.cancel();
    _watchdog = null;
    _publish(null);
    // A terminal message implies the session did open (the worker posts `videoImportStarted`
    // before it decodes anything, and refuses without a terminal message otherwise), so a
    // start still pending here is released rather than left to wait out its own bound.
    final start = _start;
    _start = null;
    if (start != null && !start.isCompleted) {
      start.complete();
    }
    // THE JOIN, and the only one: the record count arrived on the terminal message and the session
    // losses arrived on the pipeline's notify relay, and this is the single point every ending of
    // every front end passes through. Closed here rather than at `videoImportDone` alone because the
    // other endings — a start that never left, an inactivity bound, a worker-level failure — settle
    // straight through this door with no wire message at all, and each of them still owes its caller
    // whatever the run had lost by then. Unconditional, so an ending that armed nothing simply reads
    // back zeroes and leaves the tally closed rather than counting a later live capture into it.
    final sessions = videoImportSessionTally.endRun();
    final done = _done;
    _done = null;
    if (done == null || done.isCompleted) {
      return null;
    }
    final settled = outcome.withSessions(sessions);
    done.complete(settled);
    return settled;
  }

  /// Fails a start that the worker refused, which it reports as an ordinary `error` and by
  /// no other means. Returns whether there was one to fail.
  bool failStart(Object error) {
    final start = _start;
    if (start == null || start.isCompleted) {
      return false;
    }
    start.completeError(error);
    _start = null;
    return true;
  }

  /// Drops both slots for a start that can never be answered (the post itself threw), so a
  /// later import is not refused by the corpse of this one.
  void release() {
    _start = null;
    settle(
      const VideoImportOutcome(
        kind: VideoImportOutcomeKind.refused,
        reason: VideoImportReason.neverStarted,
        message: 'the import never started',
      ),
    );
  }

  void _touch() {
    _watchdog?.cancel();
    if (!isRunning) {
      _watchdog = null;
      return;
    }
    _watchdog = Timer(progressTimeout, _onStalled);
  }

  void _onStalled() {
    _watchdog = null;
    onStalled?.call(progressTimeout);
    settle(
      VideoImportOutcome(
        kind: VideoImportOutcomeKind.failed,
        reason: VideoImportReason.stalled,
        message: 'the import reported no progress for ${progressTimeout.inSeconds}s',
      ),
    );
  }

  void _publish(VideoImportProgress? value) {
    if (progress == null && value == null) {
      return;
    }
    progress = value;
    onProgressChanged?.call(value);
  }
}

/// Reads one `videoImportDone` message into an outcome.
///
/// Every field is parsed tolerantly and defaulted, because this is the message a front end
/// stops waiting on: a malformed one must still end the import rather than throw out of the
/// message handler and leave it running forever.
VideoImportOutcome videoImportOutcomeOf(Map<String, dynamic> message) {
  return VideoImportOutcome(
    kind: videoImportOutcomeKind(message['reason']?.toString() ?? 'failed'),
    // The named cause, when the producer had one. Tolerated exactly like every other field: a
    // discriminator this build does not know is not worth ending an import over, and
    // [videoImportReasonOf] answers null for it, which is the generic line.
    reason: videoImportReasonOf(message['reasonKind']),
    decoded: _asInt(message['decoded']) ?? 0,
    supplied: _asInt(message['supplied']) ?? 0,
    rejected: _asInt(message['rejected']) ?? 0,
    // Defaulted to 0 like the three frame counts above, and safe for the same reason the worker is
    // free to omit the field: a zero here is never read as "this import produced nothing". That
    // classification is the core's (`videoImportVerdictOf` rewrites it to `refused` + `no_records`),
    // and the only readers of this number require it to be positive before they say anything
    // (`VideoImportOutcome.records`). A missing count therefore stays silent rather than becoming a
    // claim, without a nullable field to branch on.
    records: _asInt(message['records']) ?? 0,
    // BOTH LEGS HAVE ALWAYS SENT THESE and this parser used to drop them on the floor:
    // `native_api_messages.h`'s `videoImportDone` writes `durationMs` / `matrixConverted` and
    // `web/worker.js` writes the same two names. They are the only record of how long the clip the
    // import actually decoded was, and of a colour conversion a browser's decoder imposed — the
    // second of which leaves no other trace anywhere. Defaulted like every other field: a message
    // from an older producer is not worth ending an import over.
    durationMs: _asInt(message['durationMs']) ?? 0,
    matrixConverted: message['matrixConverted']?.toString() ?? '',
    message: message['message']?.toString() ?? '',
  );
}

int? _asInt(Object? value) => value is num ? value.toInt() : null;

/// One record's files, grouped so they can be handed to the per-record persistence sink
/// as a unit ([LateHarvestPlan.recoverable]).
typedef LateHarvestRecord = ({String recordId, List<WorkerRecordFile> files});

/// What can still be saved out of a harvest that arrived after its stop was answered, and
/// what cannot: [recoverable] holds one entry per publishable record, [unrecoverablePaths]
/// every remaining file, so the loss can be reported instead of vanishing.
typedef LateHarvestPlan = ({List<LateHarvestRecord> recoverable, List<String> unrecoverablePaths});

/// Plans what to do with a harvest whose stop is already settled — the worker answered
/// after its bounded wait expired, or a teardown settled the stop first.
///
/// **Nothing here may be dropped quietly.** The worker deletes each harvested record
/// directory from its MEMFS the moment it has posted the message, so the buffer these files
/// came from is the only remaining copy of the session's uncommitted tail; discarding it is
/// irreversible user-data loss behind a UI that reported a normal stop. Every file therefore
/// leaves this function in exactly one of the two lists.
///
/// The rules are the ones the ordinary paths already apply, and for the same reasons:
/// records the incremental path committed to OPFS are dropped as duplicates rather than
/// counted as losses (they are on disk — [filterUncommittedHarvest]), and a record with no
/// `record.json` is not publishable and cannot be made so ([selectPublishableRecordFiles]),
/// so it is reported rather than handed to a persistence layer that would reject the whole
/// batch. Grouping by record is what lets the surviving records be written one at a time,
/// through the same sink the incremental live path uses.
LateHarvestPlan planLateHarvestRecovery(Iterable<WorkerRecordFile> files, Set<String> committedRecordIds) {
  final uncommitted = filterUncommittedHarvest(files, committedRecordIds);
  final selection = selectPublishableRecordFiles(uncommitted);
  final grouped = <String, List<WorkerRecordFile>>{};
  final publishable = <String>{};
  for (final file in selection.publishable) {
    publishable.add(file.path);
    final recordId = recordIdFromHarvestPath(file.path);
    if (recordId == null) {
      // Unreachable: a file is only publishable once its path parsed into a record id.
      continue;
    }
    grouped.putIfAbsent(recordId, () => <WorkerRecordFile>[]).add(file);
  }
  final recoverable = <LateHarvestRecord>[
    for (final entry in grouped.entries) (recordId: entry.key, files: List.unmodifiable(entry.value)),
  ];
  final unrecoverablePaths = <String>[
    for (final file in uncommitted)
      if (!publishable.contains(file.path)) file.path,
  ];
  return (recoverable: List.unmodifiable(recoverable), unrecoverablePaths: List.unmodifiable(unrecoverablePaths));
}

/// Posts a worker request whose reply settles [completer], and returns the bounded future.
///
/// [post] is everything that has to happen before the worker can answer: spawning it,
/// copying the payload into transferable buffers, `postMessage`. All of that can throw
/// **synchronously** — a CSP that forbids `worker-src` makes the `Worker` constructor throw
/// `SecurityError`, a multi-megabyte copy can fail to allocate, `postMessage` can throw
/// `DataCloneError` — and a throw there is a different failure from every other one on this
/// path: the completer is already installed in the client's "this operation is in flight"
/// slot, but no message left, so neither a worker reply nor a timeout can ever settle it.
///
/// So a throwing [post] settles [completer] with that error and first calls [releaseSlot],
/// which must clear the field holding this completer. That is the whole point: without it
/// every later caller coalesces onto a future nothing will ever complete, and since the slot
/// is shared by the setup and everything that awaits it, one synchronous failure would wedge
/// the client for the life of the page with no way back but a reload. Releasing it makes the
/// failure ordinary — the next call issues a fresh request and can succeed.
///
/// [arm] (the timeout) is reached only when the message is actually out. Arming it over a
/// request that was never sent would leave a timer behind that later errors a completer
/// nobody is listening to any more.
Future<T> issueBoundedRequest<T>({
  required Completer<T> completer,
  required void Function() post,
  required Future<T> Function() arm,
  required void Function() releaseSlot,
}) {
  try {
    post();
  } catch (error, stackTrace) {
    releaseSlot();
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
    // The completer's own future, not a rethrow: the error is delivered exactly once, to the
    // caller that is awaiting this request.
    return completer.future;
  }
  return arm();
}
