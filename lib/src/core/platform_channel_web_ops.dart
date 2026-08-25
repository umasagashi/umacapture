/// The pure decisions of the web platform channel, kept apart from it so they can be
/// tested on the VM.
///
/// `platform_channel_web.dart` imports `dart:js_interop` and `package:web`, so no VM test
/// can even compile it — the same reason `wasm_worker_ops.dart` exists one layer down, for
/// the worker client. What lives here is the channel's own rule rather than the client's:
/// how long the stop path may wait for the *final* harvest's OPFS write, and what happens
/// to that write's records once it has stopped waiting.
///
/// The bound is deliberately built on the client's [drainLiveRecordPersists] instead of a
/// second timeout of its own: that helper already encodes "settle on the answer we have,
/// never fail", including the rule that a failed write settles the wait like a successful
/// one, and a parallel implementation here would only be a second thing to keep true.
library;

import 'dart:async';

import '/src/core/wasm_worker_ops.dart';

/// The `onError` code the channel relays when a harvest has **confirmed** that records
/// the user just captured were not stored.
///
/// It must stay listed in `platform_controller.dart`'s web toast codes. A code outside
/// that set is routed to the capture state instead, and `onCaptureStopped` — relayed
/// moments later by the same stop — resets it, so the user would get the error chime
/// and no text at all.
const String liveRecordsNotStoredErrorCode = 'live_records_not_stored';

/// The records a finished persistence attempt has confirmed it could not store.
///
/// [isFinalSweep] is what turns a failed write into a *confirmed* loss. An incremental
/// live-record write that fails is not one: the worker keeps that record's MEMFS copy
/// until the write is acknowledged, so the stop path's final sweep writes it again, and
/// reporting it here would name a record that is about to be stored normally. Only the
/// final sweep has no later attempt behind it.
///
/// [committedRecordIds] is compared against the ids actually present in [publishable],
/// so a whole-batch rejection — which commits nothing and can report no per-record
/// status — is counted exactly like a batch whose records each failed on their own.
Set<String> confirmedUnstoredRecordIds({
  required Iterable<WorkerRecordFile> publishable,
  required Set<String> committedRecordIds,
  required bool isFinalSweep,
}) {
  if (!isFinalSweep) {
    return const <String>{};
  }
  final unstored = <String>{};
  for (final file in publishable) {
    final recordId = recordIdFromHarvestPath(file.path);
    if (recordId != null && !committedRecordIds.contains(recordId)) {
      unstored.add(recordId);
    }
  }
  return Set.unmodifiable(unstored);
}

/// Waits at most [bound] for the final stop harvest's OPFS write, [persist], then hands the
/// record ids it committed to [publish]. Returns whether the write settled within [bound].
///
/// **What this bounds is the wait, not the write.** An OPFS write cannot be cancelled, so
/// when [bound] expires the write is still running; this only stops *waiting* for it, which
/// is what lets `stopCapture` relay `onCaptureStopped` on a schedule OPFS cannot stretch.
/// The write keeps its own course and [publish] is still called — late — with whatever it
/// commits, so expiring the bound delays records rather than discarding them. Precisely
/// because of that, a `false` return is **not** a report that records were lost: only
/// [publish] not being called says that, and a write that never commits never calls it.
///
/// [publish] is called at most once, and never with an empty set: an empty commit is
/// nothing to merge, not a merge of nothing.
///
/// [persist] is expected not to throw — `_persistHarvestToOpfs` contains its own failures
/// and returns the ids that landed — but an error is routed to [onFailure] rather than
/// swallowed or rethrown: once the bound has expired, the caller has moved on and a rethrow
/// would surface as an unhandled asynchronous error with nobody left to handle it.
Future<bool> publishFinalHarvestWithinBound({
  required Future<Set<String>> persist,
  required Duration bound,
  required void Function(Set<String> recordIds) publish,
  required void Function(Object error, StackTrace stackTrace) onFailure,
}) async {
  // Errors are turned into "nothing committed" here, at the single point every path below
  // observes the write through, so neither the bounded nor the late branch can leave one
  // unobserved.
  final settled = persist.then<Set<String>?>(
    (recordIds) => recordIds,
    onError: (Object error, StackTrace stackTrace) {
      onFailure(error, stackTrace);
      return null;
    },
  );
  void publishIfAny(Set<String>? recordIds) {
    if (recordIds != null && recordIds.isNotEmpty) {
      publish(recordIds);
    }
  }

  if (await drainLiveRecordPersists([settled], bound)) {
    // Already settled, so this await returns in the same microtask.
    publishIfAny(await settled);
    return true;
  }
  // The write outlived the bound and cannot be cancelled. Keeping this listener is the only
  // thing that can still publish what it commits, so the session's records appear late
  // instead of being stranded in a completed future nobody reads.
  unawaited(settled.then(publishIfAny));
  return false;
}

/// Whether tearing the web channel down **ended a live capture session**, which is what
/// `PlatformController.dispose` announces so the capture flag cannot outlive its session.
///
/// [stopInFlight] is the part that is easy to leave out and impossible to recover from.
/// `stopCapture` clears both [liveActive] and [hasLiveStream] *before its first await*, so a
/// teardown landing mid-stop sees a channel that looks idle while a session is still being
/// wound down — and that stop's own terminal `onCaptureStopped` is dropped by the disposed
/// relay, so nothing else is left to answer for it. A stop that has begun is therefore a
/// session this teardown ends, exactly like one that never started stopping.
bool disposalEndedCaptureSession({required bool liveActive, required bool hasLiveStream, required bool stopInFlight}) {
  return liveActive || hasLiveStream || stopInFlight;
}

/// What a finished harvest settled, held until a channel can announce it.
///
/// **The defect this exists for is "the tidy-up threw away a finished result".** A web
/// capture's records enter the in-memory record list on one path only — the channel relaying
/// `onLiveRecordsHarvested` — and a channel that has been disposed relays nothing: its
/// callback belongs to a controller whose `Ref` is gone. The commit itself still happens, so
/// the records exist on disk and are missing from the table until the page is reloaded.
///
/// A disposal is a *rebuild* far more often than it is a shutdown (`platformControllerLoader`
/// watches the module version and the platform config, and the latter watches the trainer id),
/// so there is almost always a successor that can announce them. Holding the ids here until one
/// registers its callback is what turns "dropped" into "late". This is the web counterpart of
/// the desktop `CapturedRecordRetention`, expressed on the announcement rather than on the
/// store's ingestion, because on web nothing else re-scans: the record store attaches no capture
/// listener there.
///
/// Only the *durable outcomes of a harvest* are retained, deliberately — not messages in
/// general. A stop's `onCaptureStopped` must not be replayed into a successor that has no
/// session (the shared `PlatformController.dispose` reaction already answered for that one),
/// and a preview frame or a progress update is worthless a rebuild later. What survives a
/// teardown is what the teardown cannot undo: bytes that are already on disk, and bytes that
/// are confirmed never to reach it.
class PendingHarvestAnnouncements {
  /// Kept apart by origin because the origin decides whether the merge chimes: a live
  /// capture's records announce themselves, an import's stay silent. Merging the two buckets
  /// would make a late announcement chime for records the user imported.
  final Set<String> _live = <String>{};
  final Set<String> _fromVideoImport = <String>{};

  /// Records a final sweep confirmed it could **not** store (see [confirmedUnstoredRecordIds]),
  /// held for the same reason the committed ids are: the loss is as durable as a commit. The
  /// worker deletes a harvested record's MEMFS copy once it has posted it, so no successor
  /// writes these again and no later sweep re-discovers the failure — this retention is the only
  /// thing left that can tell the user the records they just captured are gone.
  ///
  /// Not split by origin, unlike the two above: the report is one `onError` code carrying no ids,
  /// and an import's own failure path settles its outcome itself. The ids are held rather than a
  /// bare flag so the announcement can say how many records it is about, and so two retentions
  /// naming the same record collapse into one report.
  final Set<String> _unstored = <String>{};

  bool get isEmpty => _live.isEmpty && _fromVideoImport.isEmpty && _unstored.isEmpty;

  /// Holds [recordIds] until a channel can announce them. An empty set is nothing to hold.
  void retain(Set<String> recordIds, {required bool fromVideoImport}) {
    if (recordIds.isEmpty) {
      return;
    }
    (fromVideoImport ? _fromVideoImport : _live).addAll(recordIds);
  }

  /// Takes everything held, one batch per origin, and empties the retention.
  ///
  /// Emptied *before* the batches are announced, so a caller that cannot announce after all can
  /// simply [retain] them again — the retry re-enters through the one door instead of needing a
  /// second "put it back" path that could disagree with this one.
  List<({Set<String> recordIds, bool fromVideoImport})> drain() {
    final batches = <({Set<String> recordIds, bool fromVideoImport})>[
      if (_live.isNotEmpty) (recordIds: Set<String>.of(_live), fromVideoImport: false),
      if (_fromVideoImport.isNotEmpty) (recordIds: Set<String>.of(_fromVideoImport), fromVideoImport: true),
    ];
    _live.clear();
    _fromVideoImport.clear();
    return batches;
  }

  /// Holds a confirmed not-stored report until a channel can make it. A sweep that lost no record
  /// adds nothing, so an empty set leaves the retention empty and schedules no announcement.
  void retainUnstored(Set<String> recordIds) {
    _unstored.addAll(recordIds);
  }

  /// Takes the confirmed losses held, and empties the retention.
  ///
  /// Emptied before they are announced, for the same reason [drain] is: a caller that turns out
  /// not to be able to announce them re-enters through [retainUnstored] rather than through a
  /// second "put it back" path that could disagree with this one.
  Set<String> drainUnstored() {
    final recordIds = Set<String>.of(_unstored);
    _unstored.clear();
    return recordIds;
  }
}

/// Announcements no live channel has been able to make yet.
///
/// Module level, and therefore outliving any one channel, because the channel that committed
/// the records is by construction the one that can no longer speak (see
/// [PendingHarvestAnnouncements]). The successor drains it when it registers its callback.
final PendingHarvestAnnouncements pendingHarvestAnnouncements = PendingHarvestAnnouncements();

/// Relay messages a disposed channel could not send but that stay true for its successor.
///
/// **The same defect [PendingHarvestAnnouncements] exists for, on the messages that are not
/// about a harvest.** The channel's plain relay logs and returns once the channel is disposed,
/// which is right for everything that describes the *session* — a preview frame, a progress
/// update, the stop's own `onCaptureStopped` (`disposalEndedCaptureSession` speaks for that one
/// in shared code). It is wrong for a message that describes work already finished somewhere
/// the teardown cannot reach: OPFS, or the browser's screen-share picker. Those messages are
/// the whole of the user's notice that the thing they asked for is done, and there is no second
/// producer behind them — nothing re-runs a regeneration or re-takes a screenshot because a
/// controller was rebuilt.
///
/// The messages are held **verbatim**, as the JSON the relay would have sent, rather than as
/// per-case retention types. Nothing about them needs interpreting on the way out: they carry
/// their own record id or screenshot path, `handleNativeMessage` dispatches them exactly as it
/// would have a moment earlier, and their order is the order they settled in. A retention that
/// re-encoded them would be a second place for the wire format to be stated.
///
/// Retention is opt-in per call site (`_relayDurableNotify` in `platform_channel_web.dart`), not
/// a blanket policy on the relay: the question "does this still mean anything a rebuild later"
/// is answered by what the message is about, and only the sender knows that.
class PendingDurableNotifications {
  /// A list rather than a set keyed by anything: two messages naming the same record — a
  /// regeneration that failed, then one that succeeded — are two outcomes in an order that
  /// matters, and every consumer downstream already tolerates hearing about a record twice
  /// (`CharaDetailRecordRegenerationController` counts each id once; the report dialog matches
  /// on the path it asked for). Nothing accumulates without bound: a message is only retained
  /// while a channel is disposed, and the count is bounded by the regeneration batch that was
  /// in flight.
  final List<String> _messages = <String>[];

  bool get isEmpty => _messages.isEmpty;

  /// Holds one relay message until a channel can send it.
  void retain(String message) {
    _messages.add(message);
  }

  /// Takes everything held, in the order it was retained, and empties the retention.
  ///
  /// Emptied *before* the messages are relayed, for the same reason [PendingHarvestAnnouncements.drain]
  /// is: a successor that turns out to be disposed too re-enters through [retain], so the retry uses
  /// the one door instead of a second "put it back" path that could disagree with this one.
  List<String> drain() {
    final messages = List<String>.of(_messages);
    _messages.clear();
    return messages;
  }
}

/// Messages no live channel has been able to relay yet. Module level for the same reason
/// [pendingHarvestAnnouncements] is.
final PendingDurableNotifications pendingDurableNotifications = PendingDurableNotifications();

/// Whether anything a superseded channel left behind is still waiting to be announced.
///
/// The single question `PlatformChannel.setCallback` asks before it schedules its drain, so that
/// **a retention which is held but never drained cannot exist**: holding without counting here is
/// exactly as silent as never holding at all. Every retention declared in this library belongs in
/// this expression, and gets a case in `platform_channel_dispose_handoff_test.dart` saying so.
bool hasPendingChannelAnnouncements() {
  return !pendingHarvestAnnouncements.isEmpty || !pendingDurableNotifications.isEmpty;
}

/// Serializes record regeneration across the whole app, from the first byte read to the last
/// byte written back.
///
/// The regeneration batch fires one `updateRecord` per obsoleted record in a single unawaited
/// loop, and the per-record OPFS lock each one takes is *per record*, so they all proceed at
/// once. Every one of them reads the record's seven input files — megabytes each, dominated by
/// the stitched tab PNGs — into main-thread `Uint8List`s and only then reaches the worker's
/// own serialization. So the whole library could be resident at once, queued behind a gate that
/// admits one at a time anyway.
///
/// Admitting *before* the read is what bounds it: at most one record's inputs are alive, and the
/// throughput is unchanged because the worker was already the serial part. The worker's gate is
/// not moved here — it defends the worker's module-global staging area and must keep doing that
/// whoever calls it — this one defends main-thread memory, which is a different resource with a
/// different owner.
Future<T> admitRecordRegeneration<T>(Future<T> Function() regenerate) {
  return _recordRegenerationAdmission.run(regenerate);
}

final SerialGate _recordRegenerationAdmission = SerialGate();
