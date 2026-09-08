import 'dart:async';
import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '/src/chara_detail/chara_detail_record.dart';
import '/src/chara_detail/storage.dart';
import '/src/core/capture_preview.dart';
import '/src/core/path_entity.dart';
import '/src/core/platform_channel.dart';
import '/src/core/providers.dart';
import '/src/core/raw_frame_probe.dart';
import '/src/core/sentry_util.dart';
import '/src/core/utils.dart';
import '/src/core/version_check.dart';
import '/src/core/video_import.dart';
import '/src/core/video_import_ops.dart';
import '/src/gui/capture.dart';
import '/src/gui/toast.dart';
import '/src/preference/notifier.dart';
import '/src/preference/settings_state.dart';
import '/src/preference/storage_box.dart';

final capturingStateProvider = Provider<bool>((ref) {
  return ref
      .watch(captureTriggeredEventProvider)
      .when(
        data: (data) => data,
        loading: () => false,
        error: (error, stack) {
          logger.e("error: $error, $stack");
          return false;
        },
      );
});

/// The import state every gate outside the capture card reads, as a substitutable value.
///
/// `videoImportState` is a top-level `ValueListenable` chosen by conditional export, and the
/// notifier behind it is private to its front end. The capture card reaches it directly because
/// its widgets already carry a `debugVideoImportState` seam of their own; a gate anywhere else has
/// no such seam, and a rule that cannot be driven from a test is a rule that ships unmeasured.
final videoImportListenableProvider = Provider<ValueListenable<VideoImportState>>((_) => videoImportState);

/// **What the capture card is doing right now, as a Riverpod value.**
///
/// [resolveCaptureActivity] is the app's one answer to that question and this provider does not
/// give a second one -- it calls it. What it adds is a subscription: the capture half arrives from
/// a provider and the import half from a `ValueListenable`, and a consumer that is not the capture
/// card has no `ValueListenableBuilder` around it to notice the second one moving.
///
/// **Why this exists at all.** `video_import_ops.dart` records what happened when four gates each
/// read `capturingStateProvider` and `VideoImportState` separately and combined them their own way:
/// they disagreed, and an open file dialog was explained as a running import. A fifth reader that
/// took only the capture half would repeat that in a quieter form -- it would not disagree about
/// what is running, it would simply not see half of it.
final captureActivityProvider = NotifierProvider<CaptureActivityNotifier, CaptureActivity>(CaptureActivityNotifier.new);

class CaptureActivityNotifier extends Notifier<CaptureActivity> {
  @override
  CaptureActivity build() {
    // Watched, so a change to the capture half re-runs this whole method and the listener below is
    // re-attached to whatever listenable is current then.
    final capturing = ref.watch(capturingStateProvider);
    final imports = ref.watch(videoImportListenableProvider);
    void onImportChanged() {
      state = resolveCaptureActivity(capturing: capturing, importState: imports.value);
    }

    imports.addListener(onImportChanged);
    ref.onDispose(() => imports.removeListener(onImportChanged));
    return resolveCaptureActivity(capturing: capturing, importState: imports.value);
  }
}

/// The live capture session's frame geometry and rate, as the capture page's two badges
/// render them -- and **only** a live session's.
///
/// A video import drives the same shared core, so it emits the same `onFrameSizeReported` /
/// `onFrameRateReported` messages, and those writes used to land here: the capture area then
/// showed a size and an fps badge next to "capture is stopped", and they stayed on screen after
/// the import ended because only a capture session's teardown clears them. The badges are not
/// merely labelled for live capture, they are *graded* for it -- the fps chip turns red below
/// 15 to say "the share is too slow" -- and an import is deliberately decoupled from playback
/// speed, so grading its decode rate on that scale states something untrue about a healthy
/// import. Both reports are therefore ignored while an import runs, where the clip's own
/// numbers already have a home in the import section's progress and result lines.
///
/// Desktop is unaffected by construction: `videoImportState` is the stub's constant idle there.
final capturingFrameSizeProvider = settableNotifierProvider<Size?>(null);

final capturingFrameRateProvider = settableNotifierProvider<double?>(null);

// Monotonic id so every sound-trigger event yields a distinct StreamProvider value. The sound
// listeners use ref.listen(), which skips equal consecutive AsyncData; without a changing payload a
// repeated event (same scroll index, same error message) would be deduplicated and play no sound
// (e.g. retrying a capture quickly, or opening/closing the same tab repeatedly).
int _soundEventSequence = 0;

/// Web `onError` codes that must reach the user as a toast rather than as capture state.
///
/// Membership is a routing decision, not a severity one. Everything else becomes
/// `CharaDetailCaptureState.error`, which the very next `onCaptureStopped` resets — fine
/// for a failure *during* a session, useless for one reported as the session ends. The
/// three start failures are reported before a session exists; `live_records_not_stored`
/// is reported by the stop path itself, moments before it relays `onCaptureStopped`.
/// Either way the capture state would be wiped before it could be read, leaving the error
/// chime with no text behind it.
const _webToastedErrorCodes = <String>{
  'screen_share_denied',
  'screen_share_no_video',
  'live_capture_start_failed',
  // See `liveRecordsNotStoredErrorCode` in platform_channel_web_ops.dart. Kept as a literal
  // with the others rather than imported: this switch is shared code, and the codes it
  // routes are web-only strings that never resolve to anything on desktop.
  'live_records_not_stored',
};

final _errorEvent = EventStreamProvider<int>();
final errorEventProvider = _errorEvent.provider;

final _captureTriggeredEvent = EventStreamProvider<bool>();
final captureTriggeredEventProvider = _captureTriggeredEvent.provider;

final _scrollReadyEvent = EventStreamProvider<int>();
final scrollReadyEventProvider = _scrollReadyEvent.provider;

final _pageReadyEvent = EventStreamProvider<int>();
final pageReadyEventProvider = _pageReadyEvent.provider;

/// One record the core has finished, and **which kind of session produced it**.
///
/// The origin travels on the event, as data, rather than being inferred at the far end from
/// whatever `videoImportState` happens to hold when the merge finally runs. Both are answers to the
/// same question and they are not equally durable: the state-derived one is only correct while the
/// merge is guaranteed to happen inside the import's own window, which is a property of the merge
/// being synchronous (see `CharaDetailRecordStorage.build`'s capture listener) rather than anything
/// the code states. Making one function on that path async would silence nothing loudly — an import
/// would simply start chiming again. Carried here, the fact cannot be lost by a scheduling change.
///
/// `fromVideoImport` is derived from `onCharaDetailFinished`'s optional `origin` field, whose
/// absence means live capture (`native_api_messages.h -- charaDetailFinished`). It is the same
/// marker, with the same value and the same fail-open direction, that web puts on
/// `onLiveRecordsHarvested`; see [harvestOriginVideoImport].
typedef CharaDetailRecordCapturedEvent = ({String id, bool fromVideoImport});

final _charaDetailRecordCapturedEvent = EventStreamProvider<CharaDetailRecordCapturedEvent>();
final charaDetailRecordCapturedEventProvider = _charaDetailRecordCapturedEvent.provider;

/// Captured record ids the record store has not ingested yet.
///
/// [charaDetailRecordCapturedEventProvider] is a broadcast stream with no
/// buffering, and the store's `ref.listen` on it lives inside
/// `CharaDetailRecordStorage.build()`: it is dropped when a rebuild starts and
/// re-attached only after that build's awaits (the path lookup and the record
/// scan). A capture that finishes inside that window is delivered to nobody, so
/// the record stays on disk but is missing from the list until some later full
/// scan.
///
/// Web never had this hole. Its live harvest is relayed to a merge that *reads*
/// the store after awaiting its future rather than subscribing to it, and the
/// worker keeps its MEMFS copy of a record until the OPFS write is acknowledged,
/// so an unconsumed record is re-harvested instead of lost
/// (`PlatformChannelWeb._onLiveRecordHarvested`). This is the desktop
/// counterpart of that retention, expressed on the id rather than the bytes,
/// because the desktop recognizer has already written the record to disk by the
/// time it announces it: the producer holds the id until the store acknowledges
/// it, and a freshly built store drains whatever is still outstanding.
///
/// Desktop only. On web nothing ever calls [acknowledge] — the store attaches no
/// capture listener there — so retaining would only grow a set nobody reads.
final class CapturedRecordRetention {
  /// Announced-but-unacknowledged ids, in announcement order, each mapped to its origin.
  ///
  /// A map rather than a set because the drain is a *deferred* merge: the record it ingests is
  /// merged after the import that produced it may already have ended, which is exactly the case the
  /// origin exists for. Storing only the id would make the retention path the one hole in
  /// [CharaDetailRecordCapturedEvent]'s guarantee.
  final _pending = <String, bool>{};

  /// Ids announced but not yet acknowledged, oldest first.
  List<String> get pending => List.unmodifiable(_pending.keys);

  /// The same ids with their origin, for a consumer that merges them (see [pending]).
  List<CharaDetailRecordCapturedEvent> get pendingEvents => [
    for (final entry in _pending.entries) (id: entry.key, fromVideoImport: entry.value),
  ];

  /// Announces [id] as captured and not yet ingested.
  ///
  /// [fromVideoImport] defaults to false for the same reason the wire field's absence means live:
  /// a lost origin costs an import one extra chime, never a live capture a missing one.
  void retain(String id, {bool fromVideoImport = false}) => _pending[id] = fromVideoImport;

  /// Marks [id] as ingested by the record store.
  void acknowledge(String id) => _pending.remove(id);

  @visibleForTesting
  void clear() => _pending.clear();
}

final capturedRecordRetention = CapturedRecordRetention();

class CharaDetailLink {
  String id;

  CharaDetailLink({required this.id});
}

/// A single, mutually exclusive capture status derived from [CharaDetailCaptureState].
///
/// The capture tab presents each status on two axes -- what is happening now and what the user
/// should do next -- so the UI must map every state to exactly one of these. Deriving them in one
/// place (rather than each widget re-deciding from the raw fields) keeps the shown messages from
/// contradicting one another.
enum CharaDetailCaptureStatus {
  /// Capturing, but no detail screen has been detected yet.
  waitingForDetail,

  /// Detail screen detected, nothing captured yet (safe to start or to switch characters).
  detailReady,

  /// Scroll capture in progress on at least one tab (not safe to switch until complete).
  capturing,

  /// Every tab captured; the record was saved.
  succeeded,

  /// The early duplicate probe suggests this character is likely already captured (a hint, not an error).
  duplicateHint,

  /// A completed capture was rejected because the character is already stored.
  alreadyCaptured,

  /// The capture failed (e.g. the detail screen was lost before completion).
  failed,
}

class CharaDetailCaptureState {
  /// Native tab index for the factor tab (skill=0, factor=1, campaign=2).
  static const int factorTabIndex = 1;

  double skillTabProgress;

  double factorTabProgress;

  double campaignTabProgress;

  /// Whether a chara-detail screen is currently open (set from the native started/restarted events).
  bool detailOpened;

  CharaDetailLink? link;
  String? error;

  /// The id of the existing record this capture duplicates, when a duplicate was detected
  /// (duplicated_character_probe / duplicated_character). Lets the UI focus that record in the table.
  String? duplicateRecordId;

  /// The tab currently displayed (skill=0, factor=1, campaign=2), from the native scroll-position event.
  int currentTab;

  /// Whether the current tab is at its scroll-top, from the native scroll-position event.
  ///
  /// This is the single authoritative scroll-position fact. Native reports it directly rather than the
  /// UI inferring it from capture-progress deltas, so "capturing" (scrolled) and "safe to switch" (factor
  /// tab at top) are both derived from it and can never disagree. A non-scrollable tab counts as at top.
  bool atTop;

  CharaDetailCaptureState({
    this.skillTabProgress = 0,
    this.factorTabProgress = 0,
    this.campaignTabProgress = 0,
    this.detailOpened = false,
    this.link,
    this.error,
    this.duplicateRecordId,
    this.currentTab = 0,
    this.atTop = true,
  });

  CharaDetailCaptureState clone() {
    return CharaDetailCaptureState(
      skillTabProgress: skillTabProgress,
      factorTabProgress: factorTabProgress,
      campaignTabProgress: campaignTabProgress,
      detailOpened: detailOpened,
      link: link,
      error: error,
      duplicateRecordId: duplicateRecordId,
      currentTab: currentTab,
      atTop: atTop,
    );
  }

  CharaDetailCaptureState reset() {
    return CharaDetailCaptureState();
  }

  CharaDetailCaptureState started() {
    final state = reset();
    state.detailOpened = true;
    return state;
  }

  CharaDetailCaptureState progress(int index, double progress) {
    final state = clone();
    // Progress is purely the ring value (how much of the tab has been captured). Scroll position -- whether
    // the tab is at its top -- is a separate fact reported by the native scroll-position event, so it is not
    // inferred from progress deltas here.
    switch (index) {
      case 0:
        state.skillTabProgress = progress;
        break;
      case 1:
        state.factorTabProgress = progress;
        break;
      case 2:
        state.campaignTabProgress = progress;
        break;
    }
    return state;
  }

  /// Records the current tab and whether it is at its scroll-top, from the native scroll-position event.
  CharaDetailCaptureState scrollPosition(int index, bool atTop) {
    final state = clone();
    state.currentTab = index;
    state.atTop = atTop;
    return state;
  }

  CharaDetailCaptureState success({required String id}) {
    final state = reset();
    // Keep every tab pinned at 100% instead of clearing it, so the completed progress rings (and the
    // "safe to switch" indicator alongside them) stay visible until the next character is opened.
    state.skillTabProgress = 1;
    state.factorTabProgress = 1;
    state.campaignTabProgress = 1;
    state.link = CharaDetailLink(id: id);
    return state;
  }

  CharaDetailCaptureState fail({required String message, String? duplicateRecordId}) {
    final state = clone();
    state.error = message;
    state.duplicateRecordId = duplicateRecordId;
    return state;
  }

  /// The single capture status this state represents.
  ///
  /// This is the one place that classifies the raw fields, so every message on the capture tab is
  /// derived from the same decision instead of each widget re-deciding independently.
  CharaDetailCaptureStatus get status {
    final currentError = error;
    // Confirmed duplicate and hard failures are terminal, regardless of progress.
    if (currentError == "duplicated_character") {
      return CharaDetailCaptureStatus.alreadyCaptured;
    }
    if (currentError != null && currentError != "duplicated_character_probe") {
      return CharaDetailCaptureStatus.failed;
    }
    // Past here the only possible error is the non-fatal duplicate probe hint (or none).
    if (link != null) {
      return CharaDetailCaptureStatus.succeeded;
    }
    if (!detailOpened) {
      return CharaDetailCaptureStatus.waitingForDetail;
    }
    // The probe hint only stands while the factor tab is still at its top (where the hint fired). Once the
    // user scrolls or navigates to another tab, factorAtTop is false and the stale hint degrades to the
    // ordinary phase below.
    if (currentError == "duplicated_character_probe" && factorAtTop) {
      return CharaDetailCaptureStatus.duplicateHint;
    }
    // Two states only: the current tab is either at its top (detailReady, and switchable when it is the
    // factor tab) or scrolled (capturing). There is no intermediate, because both derive from the same
    // atTop fact rather than from two independent heuristics.
    if (!atTop) {
      return CharaDetailCaptureStatus.capturing;
    }
    return CharaDetailCaptureStatus.detailReady;
  }

  /// Whether the factor tab is currently displayed at its scroll-top -- the one point mid-capture where a
  /// character switch is detectable (Rule 3). Derived from the single (currentTab, atTop) fact.
  bool get factorAtTop => atTop && currentTab == factorTabIndex;

  /// Whether it is safe to navigate to an adjacent character without closing the detail screen.
  ///
  /// Native can only detect and re-capture a switch when the factor tab is at its top (Rule 3) or
  /// every tab is complete (Rule 2); switching anywhere else loses the new character's first frame.
  /// So a switch is safe only at [factorAtTop] (during capture) or after success. Returns null when
  /// there is no meaningful guidance (no detail session, or a hard error surfaced separately).
  bool? get switchSafety => switch (status) {
    // succeeded and alreadyCaptured both mean every tab was captured, so a switch is detectable (Rule 2).
    CharaDetailCaptureStatus.succeeded ||
    CharaDetailCaptureStatus.alreadyCaptured ||
    CharaDetailCaptureStatus.duplicateHint => true,
    CharaDetailCaptureStatus.detailReady || CharaDetailCaptureStatus.capturing => factorAtTop,
    _ => null,
  };
}

class CharaDetailCaptureStateNotifier extends Notifier<CharaDetailCaptureState> {
  @override
  CharaDetailCaptureState build() => CharaDetailCaptureState();

  void reset() => state = state.reset();

  void started() => state = state.started();

  void progress(int index, double progress) => state = state.progress(index, progress);

  void scrollPosition(int index, bool atTop) => state = state.scrollPosition(index, atTop);

  void success(String id) => state = state.success(id: id);

  void fail(String message, {String? duplicateRecordId}) =>
      state = state.fail(message: message, duplicateRecordId: duplicateRecordId);
}

final charaDetailCaptureStateProvider = NotifierProvider<CharaDetailCaptureStateNotifier, CharaDetailCaptureState>(
  CharaDetailCaptureStateNotifier.new,
);

/// The most recent thing that **happened** on the capture card, as opposed to what is
/// happening now.
///
/// The card states two different kinds of thing and used to state both through one banner,
/// which is why neither was reliable. The banner is the PRESENT TENSE: it names whatever owns
/// the pipeline and is replaced the instant that changes. An event is the PAST TENSE: a
/// character was captured, a clip finished, an import was refused.
///
/// **The past tense has to outlive the state that produced it, and the capture state does not
/// outlive itself.** A duplicate hint stands only while the factor tab is at its top
/// ([CharaDetailCaptureState.factorAtTop]), so scrolling one pixel erased the only notice a
/// user ever got that this character may already be in the table; a success is cleared by the
/// next `started()`. Deriving the line from the live state therefore cannot work — it has to
/// be recorded when it happens.
sealed class CaptureEvent {
  const CaptureEvent();
}

/// One character the recognizer finished with, whatever the outcome.
///
/// Carries the resolved [status] rather than the state it came from: [CharaDetailCaptureState]
/// is mutable and is reset by the next character, so a reference to it would silently change
/// meaning after the fact.
final class CharaCaptureEvent extends CaptureEvent {
  final CharaDetailCaptureStatus status;

  /// The failure code, for the line keyed by it. Null unless [status] is
  /// [CharaDetailCaptureStatus.failed].
  final String? error;

  /// The record this event points at — the one just captured, or the existing duplicate — so
  /// the event can focus it in the table. Null when there is none to focus.
  final String? recordId;

  const CharaCaptureEvent({required this.status, this.error, this.recordId});
}

/// How the last video import ended.
final class VideoImportCaptureEvent extends CaptureEvent {
  final VideoImportOutcome outcome;

  const VideoImportCaptureEvent(this.outcome);
}

/// The statuses that are FACTS about a character the recognizer has finished with, rather than
/// a position inside the one it is on.
///
/// The other three — `waitingForDetail`, `detailReady`, `capturing` — say only where the
/// recognizer is within the current character, which is what the three progress rings show
/// frame by frame. Recording them would replace the last outcome with a restatement of the
/// rings, which is the one thing an event must never do: it is the only surface that still
/// remembers what happened.
const _eventfulCaptureStatuses = {
  CharaDetailCaptureStatus.succeeded,
  CharaDetailCaptureStatus.duplicateHint,
  CharaDetailCaptureStatus.alreadyCaptured,
  CharaDetailCaptureStatus.failed,
};

/// The import endings that are events, which is **not the same as the endings that exist**.
///
/// A live capture records nothing when a session starts or stops — only what happened to each
/// CHARACTER. An import ending normally is the same kind of non-news, and it was doing real
/// damage: "動画の取り込みが完了しました" replaced the last character's line, which is the one
/// that names a record and opens the table, with a sentence carrying no information the banner
/// returning to "キャプチャ停止中" does not already give. A cancel is the user's own doing and is
/// silent for the same reason a stopped capture is.
///
/// What remains are the two endings the user has to act on, and neither has a live counterpart to
/// be symmetrical with: a refusal names a cause with a remedy ("H.264 形式の MP4 に変換するか…"),
/// and a failure says the clip stopped part-way through.
const _eventfulImportOutcomeKinds = {VideoImportOutcomeKind.refused, VideoImportOutcomeKind.failed};

/// Whether [outcome] earns the card's one event slot: the kinds above, **plus the one completion
/// that is news** — a run that registered records and still left a session unaccounted for.
///
/// A predicate rather than a wider set, because partiality is not a property of the kind: the same
/// `completed` ending is silent or not depending on [VideoImportOutcome.sessions], which is joined
/// on this side (see `VideoImportSessionTally`) and is the very thing a set keyed by kind cannot
/// see. `videoImportIsPartial` states the rule once, for every front end.
///
/// **This one DOES overwrite the last character's line, and that is the accepted cost.** The
/// exclusion above exists because "動画の取り込みが完了しました" carried no information the banner
/// did not already give, so paying a record link for it was a loss on both sides. A partial line
/// names a count, states that something did not come out whole, and asks for a check the user
/// cannot make from anywhere else on this screen — it is the kind of thing this surface is for,
/// and the record it displaces is one tab away and still in the table. A second slot was
/// considered and refused: "exactly one is kept" is what makes this a control surface rather than
/// a console.
bool _isEventfulImportOutcome(VideoImportOutcome outcome) =>
    _eventfulImportOutcomeKinds.contains(outcome.kind) || videoImportIsPartial(outcome);

/// Test-only stand-in for the import front end's notifier.
///
/// Same seam, and the same reason, as [PlatformController.debugVideoImportState]:
/// `video_import.dart` resolves to the desktop stub on the VM, whose notifier is a constant
/// idle by construction, so without this the import half of this notifier could only be
/// exercised in a browser. Set before the provider is first read.
@visibleForTesting
ValueListenable<VideoImportState>? debugCaptureEventImportStates;

/// Records the latest [CaptureEvent] from the two sources that produce one.
///
/// **Exactly one is kept.** The card is a control surface, not a console: what a user needs
/// from it is what happened to the last character or the last clip, not a history they would
/// have to scroll past the controls to read.
///
/// This listens rather than being called from the widget layer because the capture page is one
/// tab of several. A user who switches to the record table while a clip imports must come back
/// to the outcome of the character that finished meanwhile, and a widget that is not mounted
/// records nothing. See the `ref.read` in [listenCapturePreview] that keeps it alive.
class CaptureEventNotifier extends Notifier<CaptureEvent?> {
  @override
  CaptureEvent? build() {
    // A NEW SESSION CLEARS THE SLATE, whichever kind it is. The event is the last thing that
    // happened, and once the user starts capturing again it stops being that: "新規ウマ娘を登録
    // しました" left over from the previous session points at a record from minutes ago while the
    // rings underneath it fill for a different character, and its link is aimed at neither.
    //
    // Deliberately on the START, not on the stop: an event has to survive the end of the session
    // that produced it (a clip's last character is read after its import finished), and it is only
    // when the next one begins that it becomes stale.
    ref.listen<bool>(capturingStateProvider, (previous, next) {
      if (next && previous != true) {
        state = null;
      }
    });

    ref.listen<CharaDetailCaptureState>(charaDetailCaptureStateProvider, (previous, next) {
      final status = next.status;
      if (!_eventfulCaptureStatuses.contains(status)) {
        return;
      }
      // Scroll-position and progress reports keep arriving while a terminal status stands, each
      // one a fresh state object. Without this the same outcome would be re-recorded (and the
      // card rebuilt) many times a second.
      if (previous != null &&
          previous.status == status &&
          previous.error == next.error &&
          previous.link?.id == next.link?.id &&
          previous.duplicateRecordId == next.duplicateRecordId) {
        return;
      }
      state = CharaCaptureEvent(
        status: status,
        error: next.error,
        // The duplicate first: on a duplicate the record worth opening is the one already in the
        // table, not the capture that was just refused (which has no id anyway).
        recordId: next.duplicateRecordId ?? next.link?.id,
      );
    });

    final imports = debugCaptureEventImportStates ?? videoImportState;
    // The phase this notifier last saw, so an import CLAIMING the pipeline can be told from one
    // that already had it. `isRunning` alone is a level, and the slate is cleared on the edge.
    var lastImportRunning = imports.value.isRunning;
    void onImportChanged() {
      final value = imports.value;
      final wasRunning = lastImportRunning;
      lastImportRunning = value.isRunning;
      // The import half of the new-session rule above. `picking` is excluded by `isRunning`, which
      // is what we want here too: an open file dialog owns nothing and may be abandoned, so it must
      // not wipe the outcome of the session before it.
      if (value.isRunning && !wasRunning) {
        state = null;
        return;
      }
      final outcome = value.outcome;
      // `finished` is the only phase that carries an outcome, and it is reached once per import.
      if (value.phase != VideoImportPhase.finished || outcome == null) {
        return;
      }
      if (!_isEventfulImportOutcome(outcome)) {
        return;
      }
      state = VideoImportCaptureEvent(outcome);
    }

    imports.addListener(onImportChanged);
    ref.onDispose(() => imports.removeListener(onImportChanged));
    return null;
  }

  /// Drops the recorded event, so the card shows none.
  void clear() => state = null;
}

final captureEventProvider = NotifierProvider<CaptureEventNotifier, CaptureEvent?>(CaptureEventNotifier.new);

final trainerIdProvider = Provider<String>((ref) {
  final entry = StorageBox(StorageBoxKey.trainerId).entry<String>("trainer_id");
  var id = entry.pull();
  // Logs are included in bug reports, so we should not casually print the trainer ID.
  if (id == null) {
    id = const Uuid().v4();
    entry.push(id);
    if (kDebugMode) {
      logger.i("Trainer ID generated: $id");
    }
  } else {
    if (kDebugMode) {
      logger.i("Trainer ID loaded: $id");
    }
  }
  return id;
});

/// Whether the pipeline resizes the frames it recognizes towards the core's frame-resize band.
///
/// Not *containment*: `Frame::resizedIntoBand` (`native/src/cv/frame.h`) scales a narrow capture UP to the
/// lower bound, but only shrinks one that has reached `Frame::kShrinkDeadband` times the upper bound
/// (1.5 x 720 = 1080 px today), so a capture between the upper bound and that point is recognised above the
/// band and left there. What the setting turns on is the resize, not a guarantee about the resulting width.
///
/// This is the **only** thing the app decides about the resize: the band's bounds belong to the core and
/// are never named here (see [frameResizeConfig]). The setting is on/off, and so is the config block.
///
/// Defaults to **true**, on every platform: the resize leaves a capture untouched unless it is genuinely
/// far from the recognizer's reference width — narrower than the lower bound, or half again wider than the
/// upper one — so what the setting actually buys is recognition at a sane width for exactly those captures,
/// at no cost to the rest. That is the shipped behaviour rather than an escape hatch, and turning it off is
/// the exception now.
///
/// `native/src/core/cli.cpp` ships the same default (`--frame-resize`, with `--no-frame-resize` as the
/// escape hatch), so a fresh-settings app session and a plain CLI run build the same `frame_resize` block.
/// That agreement is what lets the live-capture harness compare the app against a CLI-made golden
/// (`docs/live-capture-harness.md`); the integration suite does not lean on it, since every case in
/// `native/test/integration/cases.json` states its own `frame_resize`.
final forceResizeModeStateProvider = BooleanNotifierProvider(() {
  return BooleanNotifier(entryKey: SettingsEntryKey.forceResizeMode.name, defaultValue: true);
});

/// Whether the core auto-calibrates the character-detail crop from in-game landmarks.
///
/// Defaults to **true**, matching native's own default (an absent `detail_crop_calibration` key means
/// enabled), so a fresh install and a config that predates the key behave identically.
final detailCropCalibrationStateProvider = BooleanNotifierProvider(() {
  return BooleanNotifier(entryKey: SettingsEntryKey.detailCropCalibration.name, defaultValue: true);
});

/// One crop rectangle as native reports it: integer pixels, left/top plus extent.
///
/// Deliberately not `dart:ui`'s [Rect]: these are whole pixels of a captured frame, and rendering a
/// difference of "-1.0" for what native measured as -1 px would be noise, not precision.
@immutable
class DetailCropRect {
  final int left;
  final int top;
  final int width;
  final int height;

  const DetailCropRect({required this.left, required this.top, required this.width, required this.height});

  /// Parses one `{left, top, width, height}` object, or null when any field is missing or not a number.
  static DetailCropRect? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final left = json['left'];
    final top = json['top'];
    final width = json['width'];
    final height = json['height'];
    if (left is! num || top is! num || width is! num || height is! num) {
      return null;
    }
    return DetailCropRect(left: left.toInt(), top: top.toInt(), width: width.toInt(), height: height.toInt());
  }

  @override
  bool operator ==(Object other) =>
      other is DetailCropRect &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() => '($left,$top) ${width}x$height';
}

/// The detail-crop calibration as native last reported it (`onDetailCropReported`).
@immutable
class DetailCropReport {
  /// The intersection the frame would have had with no calibration at all.
  final DetailCropRect defaultRect;

  /// The intersection it actually has. Equal to [defaultRect] while nothing has been measured.
  final DetailCropRect correctedRect;

  /// Whether the value is latched, i.e. frozen until an explicit release.
  final bool latched;

  const DetailCropReport({required this.defaultRect, required this.correctedRect, required this.latched});
}

/// The last [DetailCropReport] from native, or null when none has arrived.
///
/// Deliberately **not** cleared when a session stops: the core owns the calibration across sessions (a
/// latch survives teardown and is only released at the next session start), so the last report is still
/// the truth about what native holds. It is cleared only by the settings reset, which is the one action
/// that makes it stale.
final detailCropReportProvider = settableNotifierProvider<DetailCropReport?>(null);

typedef JsonMap = Map<String, dynamic>;

/// The neutral, platform-independent `frame_resize` block of the native start config: whether the
/// pipeline resizes the frames it forwards to the scraper towards the recognizer's size band. Towards, not
/// into — see [forceResizeModeStateProvider] for the shrink arm's dead band and the widths it leaves above
/// the upper bound.
///
/// Deliberately top-level and platform-agnostic (rather than a Windows `window_recorder` field, which is
/// where this lived while it was a runner-side capture resize): the resize is applied by shared pipeline
/// code, after the detail-crop calibration, so it must reach the core on every platform including web.
///
/// **The block carries `enabled` and nothing else — the band's bounds are the core's, not the app's.**
/// `readFrameResizeBand` (`native/src/core/pipeline_config.h`) treats an absent bound as "use the shipped
/// default", so omitting both resolves to `kDefaultFrameResizeMinUnit` / `kDefaultFrameResizeMaxUnit`,
/// which is the single source of truth for what every front end recognizes at. The app used to mirror
/// those two numbers here as Dart literals; nothing compared the two copies, and nothing in the app can
/// ask for a different band anyway — there is no UI for it — so the mirror could only ever drift. A Dart
/// literal moving alone would have been silent: the integration suite drives the CLI, not the app, so the
/// app could have shipped a band no golden, no regression rung and no device measurement had ever run.
/// The values are now pinned once, on the C++ side, by
/// `the shipped frame-resize band is 540-720 px` in `native/test/core/test_pipeline_config.cpp` — which is
/// what makes that case the whole contract between this app and the band it ships.
///
/// The key name is still part of what ships. The core **warns** about the pre-band `unit` key rather than
/// ignoring it, because a writer still saying `unit` is asking for something the reader no longer does and
/// would then be served the defaults without anything failing. Emitting no bound at all is a different
/// thing entirely, and is the documented way to ask for the shipped band.
///
/// Visible for testing because this is the single place the block becomes JSON: the start config
/// ([platformControllerLoader]) and both halves of the mid-session toggle
/// ([PlatformController.setForceResizeMode]) build it here, so pinning this function pins every
/// `frame_resize` the app ever sends. Pinned by `test/frame_resize_band_test.dart`.
@visibleForTesting
JsonMap frameResizeConfig(bool enabled) => {"enabled": enabled};

/// Native config key for the detail-crop auto-calibration. A plain top-level bool; an absent key means
/// enabled on the native side, so this is always written explicitly rather than omitted when off.
const _detailCropCalibrationKey = "detail_crop_calibration";

/// Timeout, in milliseconds, of the core's live-capture frame stall watchdog: how long the frame stream
/// may go silent before an in-progress scene is force-closed (`closed_before_completed`). 2000 is the
/// value the watchdog was hardcoded to before it became configurable, so this changes nothing by itself.
///
/// **This must stay a single value shared by every platform.** The key exists only as an escape hatch for
/// the case where false stall detections are actually measured in the field; it is deliberately *not* a
/// knob for making web behave differently from Windows. Do not branch on `kIsWeb` here, and do not
/// override the key from the web channel: a web-only, more lenient timeout would silently widen the very
/// web/Windows behaviour gap the watchdog was enabled on web to close. See `readFrameStallTimeout` in
/// `native/src/core/pipeline_config.h` for the matching native-side note.
const int _frameStallTimeoutMs = 2000;

final platformConfigLoader = FutureProvider<JsonMap>((ref) async {
  JsonMap config = {
    "chara_detail": {},
    "directory": {},
    "video_mode": false,
    // Written here, in the platform-agnostic config, precisely so web and Windows cannot drift apart.
    "frame_stall_timeout_ms": _frameStallTimeoutMs,
    "trainer_id": ref.watch(trainerIdProvider),
  };

  await Future.wait([
    ref.watch(pathInfoLoader.future).then((directory) {
      config["directory"]["temp_dir"] = directory.tempDir.path;
      config["directory"]["storage_dir"] = directory.storageDir.path;
      config["directory"]["modules_dir"] = directory.modulesDir.path;
    }),
    rootBundle
        .loadString('assets/config/chara_detail/scene_context.json')
        .then((text) => config["chara_detail"]["scene_context"] = jsonDecode(text)),
    rootBundle
        .loadString('assets/config/chara_detail/scene_scraper.json')
        .then((text) => config["chara_detail"]["scene_scraper"] = jsonDecode(text)),
    rootBundle
        .loadString('assets/config/chara_detail/scene_stitcher.json')
        .then((text) => config["chara_detail"]["scene_stitcher"] = jsonDecode(text)),
    rootBundle
        .loadString('assets/config/chara_detail/recognizer.json')
        .then((text) => config["chara_detail"]["recognizer"] = jsonDecode(text)),
    rootBundle.loadString('assets/config/platform.json').then((text) => config["platform"] = jsonDecode(text)),
  ]);

  return config;
});

// Native prefix for the onError that reports a failed record regeneration. The core emits exactly
// `updateRecord failed for record_id=<id>: <reason>` for a failed updateRecord (since 50cbbc5).
const _updateRecordFailurePrefix = 'updateRecord failed for record_id=';

/// Extracts the record id from a native `onError` [message] that reports a failed
/// record regeneration, or null if [message] is not such a report.
///
/// Only the strict [_updateRecordFailurePrefix] is matched, so an unrelated onError
/// never spuriously advances a regeneration batch. The id is the text between the
/// prefix and the `:` that separates it from the human-readable reason.
@visibleForTesting
String? parseFailedUpdateRecordId(String message) {
  if (!message.startsWith(_updateRecordFailurePrefix)) {
    return null;
  }
  final rest = message.substring(_updateRecordFailurePrefix.length);
  final colon = rest.indexOf(':');
  final id = (colon >= 0 ? rest.substring(0, colon) : rest).trim();
  return id.isEmpty ? null : id;
}

final platformControllerLoader = FutureProvider<PlatformController?>((ref) async {
  if ((await ref.watch(moduleVersionLoader.future)) == null) {
    return null;
  }
  return ref.watch(platformConfigLoader.future).then((config) {
    final forceResizeMode = ref.read(forceResizeModeStateProvider);
    config["frame_resize"] = frameResizeConfig(forceResizeMode);
    config[_detailCropCalibrationKey] = ref.read(detailCropCalibrationStateProvider);

    final controller = PlatformController(ref, config);
    // A superseded controller still owns its preview sink, and on web that sink can be holding an
    // ImageBitmap -- a GPU surface nothing but close() releases.
    ref.onDispose(controller.dispose);
    ref.listen<bool>(forceResizeModeStateProvider, (_, enable) {
      controller.setForceResizeMode(enable);
    });
    ref.listen<bool>(detailCropCalibrationStateProvider, (_, enable) {
      controller.setDetailCropCalibration(enable);
    });
    listenCapturePreview(ref, controller);
    // Beside the preview wiring and for the same structural reason: both are session-scoped
    // listeners that have to exist before a session can begin, and this element is the one whose
    // life a session is nested inside. See `listenLiveCaptureLongRead` for what a rebuild does to
    // a claim that is already on.
    listenLiveCaptureLongRead(ref);

    // Never autostart on web: live capture opens getDisplayMedia, which requires a user gesture, so a
    // load-time start would only reject and play the error chime on every page load. The kIsWeb guard
    // leaves the desktop autostart (a genuine gesture-free window capture) unchanged.
    if (!kIsWeb && ref.read(autoStartCaptureStateProvider)) {
      controller.startCapture();
    }
    return controller;
  });
});

final platformControllerProvider = Provider<PlatformController?>((ref) {
  return ref.watch(platformControllerLoader).value;
});

/// Wires the capture preview preference to [controller], and keeps it wired.
///
/// Four things happen here, and all four are needed:
///  * the image notifier is instantiated, so it is mounted (and therefore able to receive
///    frames) before the first one arrives — the producers publish through a module-level
///    slot, not through a `ref`;
///  * the current preference and expected crop state are pushed **once**, because the preference defaults
///    to on and is persisted,
///    so a fresh session must not wait for a toggle to start producing;
///  * every later change to either value is pushed, with duplicate report updates suppressed;
///  * a video import is given the same preview a live capture gets — the session gate is opened for
///    it and the expected pane state is corrected for the offline producer (see [_importPreviewCropped]).
///
/// **A video import has no preview switch of its own.** It rides [capturePreviewEnabledProvider]
/// exactly as live capture does, so a user who turned the preview off gets none during an import
/// either; there is one enable state, pushed from one place.
///
/// Extracted from [platformControllerLoader] (which also needs the module version check, the
/// asset bundle and the storage layer) so the wiring itself can be tested.
@visibleForTesting
void listenCapturePreview(Ref ref, PlatformController controller) {
  ref.read(capturePreviewFrameProvider.notifier);
  // Instantiated here for the same reason the image notifier above is: it has to be listening
  // before the first thing worth recording happens, and nothing else reads it until the capture
  // page is opened -- which may be after several characters have already been captured.
  ref.read(captureEventProvider.notifier);
  final imports = controller.videoImportStates;
  (bool, bool)? lastPushed;
  void push() {
    final cropped = imports.value.isRunning
        ? _importPreviewCropped
        : ref.read(detailCropReportProvider)?.latched == true;
    final next = (ref.read(capturePreviewEnabledProvider), cropped);
    if (next == lastPushed) {
      return;
    }
    lastPushed = next;
    controller.setCapturePreview(next.$1, next.$2);
  }

  void onImportChanged() {
    // Open (or close) the preview's session gate for the import, then restate the expected pane state
    // for whichever producer now owns the pipeline. Both are derived from the ONE import state the
    // front end already publishes, so there is no second "an import is running" flag to get stuck.
    controller.setVideoImportPreviewSession(imports.value.isRunning);
    push();
  }

  // The initial state goes through the SAME function the listener does. A bare `push()` here would
  // state the pane for an import that is already running while leaving the session gate closed, and
  // the controller is rebuilt mid-import whenever `moduleVersionLoader` or `platformConfigLoader`
  // is invalidated -- after which every decoded frame is disposed on arrival, with nothing said.
  onImportChanged();
  imports.addListener(onImportChanged);
  ref.onDispose(() => imports.removeListener(onImportChanged));
  ref.listen<bool>(capturePreviewEnabledProvider, (_, _) {
    push();
  });
  ref.listen<DetailCropReport?>(detailCropReportProvider, (previous, next) {
    if (previous?.latched != next?.latched) {
      push();
    }
  });
}

/// The pane state a video import's frames actually carry, which is **never** cropped.
///
/// Divergence, stated at the divergence (`.claude/rules/platform-parity.md`): the offline producers
/// shape nothing. `Module.pushOfflineFrame` builds its `Frame` with `ShapingMode::AnchorOnly` and no
/// pane snapshot (`native/wasm/wasm_api.cpp`), so `NativeApi::updateFrame` reads `actual_cropped ==
/// false` for every imported frame — even after `DetailCropTracker` has latched a pane on the
/// consumer side and the core has reported it as `latched`. `LivePreviewPolicy`'s agreement gate
/// publishes nothing while the expected bit disagrees with the actual one, so sending the live
/// capture's `latched` here would silence the import's preview from the first latch onwards, which
/// is precisely the part of an import a user needs to watch.
const bool _importPreviewCropped = false;

class PlatformController {
  final Ref _ref;

  final PlatformChannel _platformChannel;

  final Map<String, dynamic> nativeConfig;

  // The self-factors from the most recent factor probe. Native re-probes whenever the factor-tab content
  // changes (a character switch), but may emit the same probe more than once; comparing against this key
  // suppresses a redundant duplicate check (and its error cue) for an unchanged character.
  List<Factor>? _lastProbeKey;

  /// Serializes the web live session's incremental record merges (Stage 5). Each
  /// `onLiveRecordsHarvested` chains its [_addHarvestedLiveRecords] onto this future
  /// so the per-record merges (and the final stop harvest) run strictly one after
  /// another. Two overlapping [_addHarvestedLiveRecords] would each resolve their
  /// addition against a stale record set and the later `state` write would drop the
  /// earlier record; chaining keeps every merge sequential, as the video import's
  /// awaited loop already is. Advanced ignoring errors so one failed merge never
  /// wedges the chain. Web-only; desktop never emits `onLiveRecordsHarvested`.
  Future<void> _liveMergeChain = Future.value();

  PlatformController(Ref ref, Map<String, dynamic> config)
    : _ref = ref,
      nativeConfig = config,
      _platformChannel = PlatformChannel() {
    _platformChannel.setCallback((message) => handleNativeMessage(message));
    // Fire-and-forget from a sync constructor, so surface a native rejection instead of dropping it on an
    // unobserved future: a failed initial config means capture silently never works.
    _platformChannel.setConfig(jsonEncode(config)).catchError(_reportConfigPushFailure);

    // This is not required, but we will need storage later anyway, so start it up.
    ref.read(charaDetailRecordStorageLoaderProvider);
  }

  /// Releases what this controller owns beyond Dart's collector.
  ///
  /// Wired to [platformControllerLoader]'s `ref.onDispose`, so it runs whenever the provider is
  /// re-created (a module-version or platform-config reload) or the container is torn down (a
  /// hot restart, or app shutdown). A hot **reload** does not trigger this: it keeps the
  /// existing `ProviderContainer`, so `ref.onDispose` callbacks do not run. The preview
  /// sink needs it — it lives in the platform channel on both platforms now, and can be holding a
  /// payload that owns a GPU surface (the web `ImageBitmap`) which a superseded controller would
  /// otherwise strand. Closing also makes the sink refuse late arrivals, so a decode still in flight
  /// disposes its image instead of publishing a frame from a controller nothing is listening to.
  ///
  /// The channel additionally answers whether tearing it down **ended a capture session that is
  /// still running**, which on web it does and on desktop it never does (the reasons are stated at
  /// each `dispose`). Reacting to that answer here, rather than inside either channel, is what
  /// keeps the two platforms converged: a session that ends without the user stopping it leaves
  /// exactly the state a stopped one leaves.
  void dispose() {
    final endedCaptureSession = _platformChannel.dispose() || debugDisposeEndsCaptureSession;
    if (endedCaptureSession) {
      _endCaptureSessionTornDownByDisposal();
    }
  }

  /// Test-only: makes [dispose] answer as the **web** channel's does.
  ///
  /// The only channel that reports a disposal-ended session is `platform_channel_web.dart`, which
  /// cannot be compiled on the VM (`dart:js_interop`) and has no web test target in CI. Without
  /// this seam the shared reaction below — the part the defect actually lived in — would have no
  /// test at all, which is how it shipped.
  @visibleForTesting
  bool debugDisposeEndsCaptureSession = false;

  /// Announces a capture session that a teardown ended, so the shared capture state cannot
  /// outlive the session that produced it.
  ///
  /// Without this, a web session torn down by a controller rebuild — a module install invalidates
  /// `moduleVersionLoader`, which [platformControllerLoader] watches — left
  /// [capturingStateProvider] true for the rest of the page load: the button stayed on "stop", the
  /// preview froze on its last frame, and pressing stop reached a *freshly built* channel that had
  /// no session to end. Only a page reload recovered.
  ///
  /// **This runs inside Riverpod's `onDispose` life-cycle**, where reading any other provider
  /// throws (`Ref._throwIfInvalidUsage` asserts on a non-empty life-cycle callback stack), so the
  /// ordinary `onCaptureStopped` dispatch cannot be used as-is. The one signal that must never be
  /// lost — the capture flag itself — therefore goes straight onto its module-level broadcast
  /// stream, which needs no `Ref`; the rest of the session-scoped provider state is released one
  /// microtask later, after the life-cycle callback has unwound and before the rebuild riverpod
  /// schedules on a timer. `mounted` is re-checked there because the other way here is the
  /// container being torn down (hot restart, shutdown), where there is no UI left to restore.
  void _endCaptureSessionTornDownByDisposal() {
    _captureTriggeredEvent.add(false);
    scheduleMicrotask(() {
      if (!_ref.mounted) {
        return;
      }
      _resetSessionScopedState();
    });
  }

  /// Drops everything scoped to one capture session.
  ///
  /// Shared by the `onCaptureStopped` dispatch and by [_endCaptureSessionTornDownByDisposal] so
  /// the two cannot drift: a session ended by a teardown must leave the same state behind as one
  /// ended by the button.
  void _resetSessionScopedState() {
    _ref.read(charaDetailCaptureStateProvider.notifier).reset();
    _lastProbeKey = null;
    _ref.read(capturingFrameSizeProvider.notifier).set(null);
    _ref.read(capturingFrameRateProvider.notifier).set(null);
    // The session is over, so the last frame is stale: drop it (and its texture) and
    // return the tile to its idle placeholder. Closing the gate as well as clearing is
    // what makes that stick — a frame emitted just before the stop can still be decoding,
    // and `clear()` alone would let it repopulate the tile a few milliseconds later.
    _liveSessionOpen = false;
    _syncCapturePreviewSession();
  }

  /// Whether a live capture session is open, as told by the `onCaptureStarted` / `onCaptureStopped`
  /// dispatch.
  bool _liveSessionOpen = false;

  /// Whether a video import is open, as told by [setVideoImportPreviewSession].
  bool _importSessionOpen = false;

  /// Opens the preview's session gate while **either** producer owns the pipeline.
  ///
  /// Two writers, one gate, and therefore an OR rather than two independent `setCapturing` calls:
  /// the core refuses a cross-kind session, so the two are mutually exclusive today — but a single
  /// slot written by whichever event landed last is exactly the shape that closes the gate on a
  /// running session, and a preview closed by somebody else's teardown is silent and permanent.
  void _syncCapturePreviewSession() {
    _ref.read(capturePreviewFrameProvider.notifier).setCapturing(_liveSessionOpen || _importSessionOpen);
  }

  /// Tells the preview gate whether a video import currently owns the pipeline.
  ///
  /// Called from [listenCapturePreview]'s listener on the import front end's own state, which is the
  /// single source of truth for "an import is running" — every ending an import can have (completion,
  /// cancellation, refusal, failure, a worker teardown that settles the outcome) moves that state out
  /// of [VideoImportState.isRunning], so nothing here can be left latched open.
  void setVideoImportPreviewSession(bool open) {
    if (_importSessionOpen == open) {
      return;
    }
    _importSessionOpen = open;
    _syncCapturePreviewSession();
  }

  /// Issues one `Dart -> native` command and makes a native rejection reportable.
  ///
  /// **Every command below is invoked unawaited** — from a button callback, from a `ref.listen`,
  /// from the regeneration batch's loop — so the future's rejection is observed here or nowhere.
  /// Dropped, it became an unhandled asynchronous error in the app's zone and nothing else: on
  /// Windows a `startCapture` that throws inside the runner answers `Error("PlatformMethodError",
  /// …)` (`windows/runner/platform_channel.h`) and emits no `notify`, so the user watched a
  /// spinner run out and got no message, no chime and no failure line.
  ///
  /// Routed into [handleNativeMessage] as an `onError` rather than reported directly, because
  /// that is what the **web** leg already does with its own failures: it catches everything
  /// internally and relays an `onError` (`platform_channel_web.dart`). Feeding the io leg's
  /// rejection into the same dispatch is what leaves the two legs saying the same thing about a
  /// failed command, instead of one being reportable and the other not.
  ///
  /// [code] names what the user is told. It defaults to [name], which no translation matches, so
  /// the capture page renders its generic failure line (`capture.dart`'s `_failureText` falls
  /// back rather than showing a raw key). A caller passes something else only when the message
  /// has to carry data the dispatch reads back out of it — `updateRecord`, whose failure must
  /// also advance the regeneration batch.
  Future<void> _command(String name, Future<void> command, {String? code}) {
    return command.catchError((Object error, StackTrace stackTrace) {
      logger.e('The native "$name" command was rejected', error, stackTrace);
      captureException(error, stackTrace);
      handleNativeMessage(jsonEncode({'type': 'onError', 'message': code ?? name}));
    });
  }

  // Report a native config-push failure. The config setters are fire-and-forget (called from the sync
  // constructor and a ref.listen callback), so an unhandled PlatformException would otherwise vanish and leave
  // capture broken with no feedback. Mirrors the log-then-toast idiom used by the clipboard path.
  void _reportConfigPushFailure(Object error, StackTrace stackTrace) {
    logger.e("Failed to push native config: $error\n$stackTrace");
    captureException(error, stackTrace);
    Toaster.show(ToastData.error(description: "toast.config_failure".tr()));
  }

  // Order-sensitive equality of two probe keys (factors are compared by value; their order is stable).
  bool _sameFactorKey(List<Factor> a, List<Factor>? b) {
    if (b == null || a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  /// Test-only: stands in for the import [videoImportState] reports.
  ///
  /// `video_import.dart` resolves to the desktop stub on the VM, whose notifier is a constant idle by
  /// construction, so without this seam the frame-report guards below — which exist for a web-only
  /// state — could only be exercised in a browser. Same reason as [debugDisposeEndsCaptureSession].
  @visibleForTesting
  ValueListenable<VideoImportState>? debugVideoImportState;

  /// The import front end's observable state — the real one, or the test seam above.
  ///
  /// The single source of truth for "an import owns the pipeline", read by both consumers here: the
  /// frame-report guards below and [listenCapturePreview]'s preview gate.
  ValueListenable<VideoImportState> get videoImportStates => debugVideoImportState ?? videoImportState;

  /// Whether an import currently owns the pipeline; see [capturingFrameSizeProvider].
  bool get _videoImportRunning => videoImportStates.value.isRunning;

  /// Dispatches one raw notification from the core (the single `native -> Dart` entry point).
  ///
  /// Exposed for tests so a notification can be driven through the real dispatch with its real wire format,
  /// rather than by constructing the resulting state by hand; production callers reach it only through the
  /// channel callback installed in the constructor.
  @visibleForTesting
  void handleNativeMessage(String message) {
    // Native payloads are untyped and cross the platform channel, where neither
    // the field set nor the Dart runtime types are guaranteed. Wrap the whole
    // dispatch so a malformed message is logged and dropped instead of throwing
    // out of the method-channel callback (where the error would be hard to trace
    // and the event silently lost anyway).
    try {
      final data = jsonDecode(message) as Map;
      final dataType = data['type'].toString();
      final captureState = _ref.read(charaDetailCaptureStateProvider.notifier);
      switch (dataType) {
        case 'onError':
          {
            // Coerce a missing/non-String message so routing cannot throw before the error event clears
            // pending controls. The web codes above are transient toasts; capture-time failures remain state.
            final message = data['message']?.toString() ?? 'unknown_error';
            // A failed record regeneration is reported as an onError (native emits no onCharaDetailUpdated
            // for it), so route it to the regeneration controller too or its batch progress wedges forever.
            // Only the strict native prefix is matched; every other onError keeps its existing behavior.
            final failedRecordId = parseFailedUpdateRecordId(message);
            if (failedRecordId != null) {
              _ref.read(charaDetailRecordRegenerationControllerProvider.notifier).fail(failedRecordId);
            }
            if (_webToastedErrorCodes.contains(message)) {
              Toaster.show(ToastData.error(description: "$tr_capture.capture_control.web.error.$message".tr()));
            } else {
              captureState.fail(message);
            }
            _errorEvent.add(_soundEventSequence++);
          }
          break;
        case 'onRecordRegenerationFailed':
          // Web-only: platform_channel_web synthesizes this when a record's regeneration could not even reach
          // the recognizer (missing inputs, worker not configured), so the batch still completes. Unlike
          // onError it carries no capture-state / chime side effects: a genuine recognizer failure relays its
          // own onError, which the regeneration controller dedups against this by record id.
          final regenFailedId = data['id'];
          if (regenFailedId is! String) {
            throw ArgumentError.value(regenFailedId, 'id', 'onRecordRegenerationFailed expects a String id');
          }
          _ref.read(charaDetailRecordRegenerationControllerProvider.notifier).fail(regenFailedId);
          break;
        case 'onLiveRecordsHarvested':
          // Web-only: platform_channel_web synthesizes this on live-capture stop after writing the harvested
          // records to OPFS, so they can be merged into the list here (the channel has no Riverpod ref). It
          // reuses the same incremental addFromFileAsync path a video import uses; on desktop native never
          // emits it (records are added live via the storage capture listener instead).
          //
          // WHY WINDOWS IMPORTS TAKE A DIFFERENT ROUTE (.claude/rules/platform-parity.md).
          // Web harvests records in BATCHES because its harvest sweeps the MEMFS active root
          // indiscriminately: an import therefore has to be scoped to its own `storage_dir`, which
          // puts its records outside the real store until a batch moves them in. Windows has no
          // sweep — the recognizer writes each record straight to the file system, into the same
          // active root live capture uses — so an import's records are announced one at a time on
          // `onCharaDetailFinished` and picked up by the store's existing capture listener. That
          // transport difference is forced; the intent marker is not, and it is NOT dropped: both
          // routes carry the same `origin` field, with the same [harvestOriginVideoImport] value and
          // the same "absent means live" rule, and both hand it to the merge as `notifyDuplicate`.
          // The only asymmetry left is per-batch here versus per-record there, which is just the
          // granularity each transport already had.
          final harvestedIds = data['ids'];
          if (harvestedIds is! List) {
            throw ArgumentError.value(harvestedIds, 'ids', 'onLiveRecordsHarvested expects a List of ids');
          }
          // `origin` names the session that produced these records; anything other than the import's
          // value (including a missing field, which is what an older relay sends) means live capture,
          // so a message that loses the field keeps its chime rather than losing it.
          _enqueueHarvestedLiveRecords(
            harvestedIds.whereType<String>().toList(),
            fromVideoImport: data['origin'] == harvestOriginVideoImport,
          );
          break;
        case 'onCaptureStarted':
          _captureTriggeredEvent.add(true);
          captureState.reset();
          // Open the preview gate for this session. Frames that finish decoding outside a
          // session are dropped, so without this the tile would never fill.
          _liveSessionOpen = true;
          _syncCapturePreviewSession();
          break;
        case 'onCaptureStopped':
          _captureTriggeredEvent.add(false);
          _resetSessionScopedState();
          break;
        case 'onScrollReady':
          _scrollReadyEvent.add(_soundEventSequence++);
          break;
        case 'onFactorProbe':
          {
            // Native deferred the factor-tab scroll-ready cue and instead sent the self-factors
            // visible before scrolling. Run the early duplicate check: only emit the scroll-ready
            // cue when it is not a duplicate; otherwise the storage layer raises the duplicate error.
            final factorsRaw = data['factors'];
            if (factorsRaw is! List) {
              break;
            }
            final probeSelf = factorsRaw
                .whereType<Map>()
                .map((e) => FactorMapper.fromMap(Map<String, dynamic>.from(e)))
                .toList();
            // The probe only fires at the factor tab's top, so it marks the one safe point to switch
            // characters mid-capture. Reassert the factor-at-top position before the dedup break, so even
            // a re-emitted probe (e.g. a settling frame after briefly leaving and returning) -- and any
            // ordering ahead of the scroll-position event -- restores the "safe" state.
            captureState.scrollPosition(CharaDetailCaptureState.factorTabIndex, true);
            // Native may re-emit the probe for the same character (e.g. a settling frame after a switch).
            // Skip an unchanged key so the duplicate check and its error cue fire at most once per character.
            if (_sameFactorKey(probeSelf, _lastProbeKey)) {
              break;
            }
            _lastProbeKey = probeSelf;
            // The threshold depends on the capture's record type; -1 (or any out-of-range value)
            // from native maps to null, which falls back to the default (non-friend-standard) threshold.
            final recordTypeRaw = data['record_type'];
            final recordType = (recordTypeRaw is int && recordTypeRaw >= 0 && recordTypeRaw < RecordType.values.length)
                ? RecordType.values[recordTypeRaw]
                : null;
            final isDuplicate = _ref
                .read(charaDetailRecordStorageLoaderProvider.notifier)
                .reportDuplicateFromFactorProbe(probeSelf, recordType);
            if (!isDuplicate) {
              _scrollReadyEvent.add(_soundEventSequence++);
            }
          }
          break;
        case 'onScrollUpdated':
          {
            final index = data['index'] as int?;
            final progress = (data['progress'] as num?)?.toDouble();
            if (index != null && progress != null) {
              captureState.progress(index, progress);
            }
          }
          break;
        case 'onScrollPosition':
          {
            final index = data['index'] as int?;
            final atTop = data['at_top'] as bool?;
            if (index != null && atTop != null) {
              captureState.scrollPosition(index, atTop);
            }
          }
          break;
        case 'onPageReady':
          {
            _pageReadyEvent.add(_soundEventSequence++);
            final index = data['index'] as int?;
            if (index != null) {
              captureState.progress(index, 1);
            }
          }
          break;
        case 'onCharaDetailStarted':
          captureState.started();
          _lastProbeKey = null;
          break;
        case 'onCharaDetailRestarted':
          // A restart is a mid-scene reset (native inferred a character switch and rebuilt the session
          // without the detail screen closing). The UI resets its capture progress exactly as on a fresh
          // open, and the probe key is cleared so the new character's early duplicate check runs — which
          // is why this shared the `onCharaDetailStarted` case until the message gained a payload.
          //
          // WHAT IT DOES *NOT* DO IS REPORT A FAILURE, and that is a decision rather than an omission: all
          // three of the scraper's reset rules fire legitimately when the player switches character, so a
          // live capture must stay silent here (the switch is the feature working). Only an import counts
          // it, and only through the tally below, which is closed while no import is running.
          //
          // `completed` absent counts as NOT completed, matching the rule `record_info.h` states for this
          // field: err towards noticing a loss rather than towards the silence this change removes.
          videoImportSessionTally.noteDiscardedSession(completed: data['completed'] == true);
          captureState.started();
          _lastProbeKey = null;
          break;
        case 'onCharaDetailFinished':
          if (data['success'] == true) {
            final id = data['id'];
            // Validate at the source: both consumers below are String-typed, so a non-String id would
            // otherwise surface as a late failure in a distant listener.
            if (id is! String) {
              throw ArgumentError.value(id, 'id', 'onCharaDetailFinished expects a String id');
            }
            // `origin` names the session kind that produced this record. Anything other than the
            // import's value — including a missing field, which is what a live capture and any
            // older core send — means live capture, so a message that loses the field keeps its
            // chime rather than losing it. See [CharaDetailRecordCapturedEvent].
            final fromVideoImport = data['origin'] == harvestOriginVideoImport;
            // Retained before the event is emitted, so a store that is mid-build
            // (and therefore not listening) still finds the id when it drains.
            // See [CapturedRecordRetention] for why web is exempt.
            if (!kIsWeb) {
              capturedRecordRetention.retain(id, fromVideoImport: fromVideoImport);
            }
            _charaDetailRecordCapturedEvent.add((id: id, fromVideoImport: fromVideoImport));
            captureState.success(id);
          } else {
            // THE HALF OF THIS MESSAGE THAT USED TO BE PARSED AND THROWN AWAY. `success: false` is the
            // core's single announcement that a session reached a terminal state having produced
            // nothing, from all three of its emitters (the detail screen closed mid-capture, the input
            // ended mid-capture, a stitch that failed), and it is the only one of the three that is a
            // fact about the SESSION rather than a string about the cause.
            //
            // Counted, and nothing else — deliberately. The user-facing report of these endings is the
            // `onError` that native sends immediately after each of them, which already reaches
            // `captureState.fail` and the failure tile; failing the capture state a second time here
            // would either double-report or, worse, overwrite the specific error code with a generic
            // one. What was actually missing is the accounting, because an import's completeness needs
            // to know that a session ended empty, not what killed it.
            //
            // Counting HERE rather than off those `onError` tags is what makes the number right: the
            // tags are three different strings that this side would have to keep in step with C++ by
            // hand, `stitch_failed` is not among the two the design named, and an error tag can arrive
            // for things that are not a session ending at all. One emitter, one count.
            videoImportSessionTally.noteSessionEndedWithoutRecord();
          }
          break;
        case 'onCharaDetailClosed':
          // The detail screen was closed. Drop the retained progress (a completed capture keeps its rings
          // on screen until now) and return to waiting. For an incomplete close, the closed_before_completed
          // error arrives right after this and re-establishes the failure state.
          captureState.reset();
          _lastProbeKey = null;
          break;
        case 'onCharaDetailUpdated':
          final id = data['id'];
          if (id is! String) {
            throw ArgumentError.value(id, 'id', 'onCharaDetailUpdated expects a String id');
          }
          _ref.read(charaDetailRecordRegenerationControllerProvider.notifier).updated(id);
          break;
        case 'onFrameRateReported':
          {
            final fps = (data['fps'] as num?)?.toDouble();
            if (fps != null && !_videoImportRunning) {
              _ref.read(capturingFrameRateProvider.notifier).set(fps);
            }
          }
          break;
        case 'onScreenshotTaken':
          logger.i("path=${data['path']}, result='${data['result']}'");
          _ref.read(latestScreenshotProvider.notifier).set(ScreenshotResult(FilePath(data['path']), data['result']));
          break;
        case 'onDetailCropReported':
          {
            // Both rects must parse or nothing is stored: a half-read report would render a difference
            // against a rect that was never measured. A malformed payload is simply ignored here (no
            // throw), because this display is a refinement and must never cost a capture session.
            final defaultRect = DetailCropRect.fromJson(data['default']);
            final correctedRect = DetailCropRect.fromJson(data['corrected']);
            if (defaultRect != null && correctedRect != null) {
              _ref
                  .read(detailCropReportProvider.notifier)
                  .set(
                    DetailCropReport(
                      defaultRect: defaultRect,
                      correctedRect: correctedRect,
                      latched: data['latched'] == true,
                    ),
                  );
            }
          }
          break;
        case 'onFrameSizeReported':
          {
            final width = (data['size']?['width'] as num?)?.toDouble();
            final height = (data['size']?['height'] as num?)?.toDouble();
            if (width != null && height != null && !_videoImportRunning) {
              _ref.read(capturingFrameSizeProvider.notifier).set(Size(width, height));
            }
          }
          break;
        case 'videoImportStarted':
        case 'videoImportProgress':
        case 'videoImportDone':
          // The Windows runner's import notifications, relayed to the import front end.
          //
          // They ride the same `notify` queue as every message above, deliberately: their FIFO
          // ordering against `onCharaDetailFinished` is what puts an import's last record's merge
          // strictly before the import is told it has ended. Nothing is interpreted here — the
          // front end owns the import's state machine, its inactivity watchdog and the rule that a
          // terminal outcome settles exactly once — so this case forwards the decoded map and stops.
          //
          // Web reaches this dispatch too, and there its `videoImportHandleNativeEvent` is a no-op.
          // That is not a gap: on web the three messages are consumed by `WasmWorkerClient` on the
          // worker port before the relay that feeds this method ever sees them, so an arrival here
          // is impossible rather than merely unexpected. See `video_import.dart`.
          videoImportHandleNativeEvent(data);
          break;
        default:
          throw UnimplementedError(dataType);
      }
    } catch (e, st) {
      logger.w("Failed to handle native message: $message", e, st);
    }
  }

  /// Chains one live harvest's merge onto [_liveMergeChain] so overlapping harvests
  /// (Stage 5 fires one per finished record, plus the final stop sweep) run strictly
  /// sequentially. Called synchronously from `handleNativeMessage`; it only enqueues (no
  /// await), keeping the message dispatch synchronous.
  void _enqueueHarvestedLiveRecords(List<String> ids, {required bool fromVideoImport}) {
    if (ids.isEmpty) {
      return;
    }
    // The origin travels with the batch rather than being read again when the merge finally runs:
    // this chain is unawaited, so an import's last batch is merged after the import state has
    // already settled (see [addFromFileAsync]'s `notifyDuplicate`).
    _liveMergeChain = _liveMergeChain
        .then((_) => _addHarvestedLiveRecords(ids, fromVideoImport: fromVideoImport))
        .catchError((Object _) {});
  }

  /// Merges the web live session's harvested records (already written to OPFS by
  /// `platform_channel_web`) into the record list, one at a time via the web-safe
  /// async loader — the same incremental path a video import uses. Chained through
  /// [_enqueueHarvestedLiveRecords] from the sync `handleNativeMessage`; the store is
  /// loaded first so each add sees the current set (its dedup and inheritance
  /// candidates). Per-record failures are logged and skipped rather than aborting.
  Future<void> _addHarvestedLiveRecords(List<String> ids, {required bool fromVideoImport}) async {
    if (ids.isEmpty) {
      return;
    }
    // Fired unawaited from the sync handleNativeMessage, so wrap the whole body: an unguarded loader rejection
    // would otherwise leak as an unhandled async error (only the per-record add was protected before).
    try {
      await _ref.read(charaDetailRecordStorageLoaderProvider.future);
      final storage = _ref.read(charaDetailRecordStorageLoaderProvider.notifier);
      for (final id in ids) {
        try {
          await storage.addFromFileAsync(id, notifyDuplicate: !fromVideoImport);
        } catch (error, stackTrace) {
          logger.w('Failed to add harvested live record $id', error, stackTrace);
        }
      }
      logger.i('Added ${ids.length} live-captured record(s) to the list');
    } catch (error, stackTrace) {
      logger.e('Failed to merge harvested live records', error, stackTrace);
    }
  }

  Future<void> startCapture() => _command('startCapture', _platformChannel.startCapture());

  /// Stops the live capture session.
  ///
  /// **WHAT THIS DOES TO A RUNNING VIDEO IMPORT IS NOT THE SAME ON BOTH PLATFORMS**
  /// (`.claude/rules/platform-parity.md`), and neither side can adopt the other's answer:
  ///
  ///  * **Web ABORTS the import and lets it end normally.** `handleStopLive` calls
  ///    `stopVideoImportProducer('stopLive')` before it joins. It has no real alternative: there is
  ///    one wasm module, and its teardown (`Module.stop()`) joins the whole pipeline, so a producer
  ///    still pushing into it is exactly the race the teardown discipline exists to prevent.
  ///    Revoking the import is what makes the join safe, and the import still takes its ordinary
  ///    teardown, so its records are kept and it reports one terminal `videoImportDone`.
  ///  * **Windows REFUSES the stop and lets the import run on.** `NativeController::doStopCapture`
  ///    answers `notifyCaptureStopped()` without joining the event loop when an import is running
  ///    and the live producer is not. It can, because the two producers are separate objects there:
  ///    such a stop owns nothing of its own to stop, and the teardown it would perform would tear
  ///    the pipeline out from under the import. A stop issued while a live session really is running
  ///    takes the ordinary path — live capture stays stoppable under every circumstance.
  ///
  /// So this call is not the way to end an import. `cancelVideoImport` is, on both platforms.
  Future<void> stopCapture() => _command('stopCapture', _platformChannel.stopCapture());

  /// Regenerates the record [id] with the current recognizer module.
  ///
  /// A rejection is reported with the wire message native itself uses for a failed regeneration
  /// ([_updateRecordFailurePrefix]), so it reaches [charaDetailRecordRegenerationControllerProvider]
  /// through the same parse the native report goes through. Anything else would leave the batch
  /// waiting forever for a record whose call never left this side.
  Future<void> updateRecord(String id) => _command(
    'updateRecord',
    _platformChannel.updateRecord(id),
    code: '$_updateRecordFailurePrefix$id: the command was rejected before native ran it',
  );

  Future<void> finishUpdate() => _command('finishUpdate', _platformChannel.finishUpdate());

  /// Not a [_command]: the only caller awaits this inside a `try` and turns a failure into a
  /// `ClipboardWriteOutcome` of its own (`clipboard_image_writer_stub.dart`), so the rejection is
  /// already observed — and reported as a clipboard failure rather than a capture one.
  Future<void> copyToClipboardFromFile(FilePath path) => _platformChannel.copyToClipboardFromFile(path);

  Future<void> takeScreenshot(FilePath path) => _command('takeScreenshot', _platformChannel.takeScreenshot(path));

  /// Diagnostic raw-frame probe (web only; a no-op elsewhere). Forwards synchronously, without
  /// awaiting anything first, because the web implementation opens the `getDisplayMedia` picker
  /// and must still hold the tap's transient user activation when it does.
  ///
  /// Not a [_command] either: it answers a value, and its one caller
  /// (`raw_frame_probe_view.dart`) ends its chain in a `catchError` that toasts the probe's own
  /// failure line.
  Future<RawFrameBundle?> buildRawFrameBundle() => _platformChannel.buildRawFrameBundle();

  Future<void> setForceResizeMode(bool enable) {
    // A platform-neutral DELTA over the start config, which each platform merges into its own cached copy.
    // The core reads `frame_resize` once, when the pipeline is built, so the value that matters is the one
    // present at the next session start -- hence the local merge below as well, which keeps the config this
    // controller replays (and native's cached copy) from going stale behind the settings switch.
    final delta = {"frame_resize": frameResizeConfig(enable)};
    nativeConfig["frame_resize"] = frameResizeConfig(enable);
    // Invoked unawaited from a ref.listen callback; handle a native rejection here so it is not lost.
    return _platformChannel.setPlatformConfig(jsonEncode(delta)).catchError(_reportConfigPushFailure);
  }

  /// Turns the detail-crop auto-calibration on or off.
  ///
  /// Travels the same platform-neutral delta path as [setForceResizeMode], and for the same reason: the
  /// core reads `detail_crop_calibration` once, when the pipeline is built, so the value that matters is
  /// the one present at the next session start. The settings row is disabled while capturing precisely
  /// because of that — a mid-session toggle would be silently inert until the next start.
  Future<void> setDetailCropCalibration(bool enable) {
    final delta = {_detailCropCalibrationKey: enable};
    nativeConfig[_detailCropCalibrationKey] = enable;
    if (!enable) {
      // The config delta governs the next pipeline, while a correction can outlive a
      // pipeline in the process-lifetime tracker. Release that current state too so
      // the setting never leaves a stale crop behind until a later session starts.
      final reset = resetDetailCropCalibration();
      final config = _platformChannel.setPlatformConfig(jsonEncode(delta)).catchError(_reportConfigPushFailure);
      return Future.wait([reset, config]);
    }
    return _platformChannel.setPlatformConfig(jsonEncode(delta)).catchError(_reportConfigPushFailure);
  }

  /// Turns the live capture preview on or off at the source.
  ///
  /// A command, not a config delta, and for the same reason [resetDetailCropCalibration] is:
  /// the preference gates a per-frame emission and must take effect mid-session.
  ///
  /// A failure is logged and nothing else. The preview is a refinement — it must never toast,
  /// never reach the `onError` path (which carries the chime and the add-on triggers), and
  /// never touch the capture state. Invoked unawaited from a `ref.listen` callback, so the
  /// rejection is handled here or it is lost.
  Future<void> setCapturePreview(bool enable, bool cropped) {
    return _platformChannel.setCapturePreview(enable, cropped).catchError((Object error, StackTrace stackTrace) {
      logger.w('Failed to push the capture preview state', error, stackTrace);
    });
  }

  /// Drops the core's auto-calibrated detail crop and its latch, so it is measured again from scratch.
  ///
  /// Works mid-session (native only arms a lock-free flag the next frame consumes), which is the whole
  /// point of the control. The locally cached [detailCropReportProvider] is cleared right away rather than
  /// waited on: outside a capture session no frame will arrive to report the release, so the display would
  /// otherwise keep showing — and offering to reset — a correction that no longer exists.
  Future<void> resetDetailCropCalibration() {
    _ref.read(detailCropReportProvider.notifier).set(null);
    return _platformChannel.resetDetailCropCalibration().catchError((Object error, StackTrace stackTrace) {
      // Tips-level by contract: this is a refinement, never a reason to interrupt a capture. Logged and
      // dropped, with no toast and nothing on the onError path (which carries a chime and add-on triggers).
      logger.w('Failed to reset the detail crop calibration', error, stackTrace);
    });
  }
}
