/// The pure decisions of the video-import front end, kept apart from it so they can
/// be tested on the VM.
///
/// Everything that actually *runs* an import is per front end: on web it reaches
/// `dart:js_interop`, `package:web` and `WasmWorkerClient`, so no `flutter test` can
/// compile it (the same reason `wasm_worker_ops.dart` and `live_content_freeze.dart`
/// exist), and on Windows it reaches `dart:io`, a file dialog and a method channel. What
/// lives here is everything about an import that is a rule rather than a call into one of
/// those two worlds: which state an import is in, how the producer's terminal reason maps
/// onto an outcome, what fraction of the clip is done, and — most importantly — which
/// blocker forbids starting one right now.
///
/// Both front ends share these rules deliberately. A vocabulary that forked per platform
/// would be a divergence with no platform constraint behind it, which
/// `.claude/rules/platform-parity.md` prohibits; where a value genuinely cannot be reached
/// on one side, that is said on the value itself rather than by giving it a second name.
library;

import '/src/core/video_frame_grab_ops.dart';

/// Where an import is in its life cycle.
///
/// [picking] is deliberately its own phase and deliberately **not** "running": a file
/// dialog owns nothing — no session, no pipeline, no decoder — and a user can sit in one
/// for minutes. (Whether the dialog is modal to the app differs — web appends an
/// `<input type=file>` to its own document, Windows opens `GetOpenFileNameW` with
/// `lockParentWindow: true` — and is beside the point: neither has claimed anything from the core.)
///
/// **What it is not is a licence to run something else meanwhile.** This phase used to argue from
/// exactly that — "treating it as an owned capture session would block live capture for a session
/// that may never start" — and the argument is about what the dialog *owns*, which is not the
/// question the user is asking. The four features of the capture card are mutually exclusive as a
/// product rule, so a dialog that is open is 動画取り込み running: see [CaptureActivity], where the
/// phase reaches every gate as [CaptureActivity.pickingClip] and is told apart from
/// [CaptureActivity.importing] by the sentence it earns rather than by the rule it follows.
enum VideoImportPhase {
  /// No import; the button is offered.
  idle,

  /// The file dialog is open. Nothing has been posted to the worker.
  picking,

  /// A clip was chosen and the worker has been asked to open the session.
  starting,

  /// The session is open and frames are being decoded into the pipeline.
  importing,

  /// A cancel was requested; the producer stops at its next frame boundary.
  cancelling,

  /// The import ended, whatever ended it. [VideoImportState.outcome] says how.
  finished,
}

/// **What the capture card is doing right now — the one place the app answers that question.**
///
/// The card offers four features, and the product rule is that **they are mutually exclusive: at
/// most one of them runs at a time.** 画面キャプチャ (the live-capture toggle), 動画取り込み (the
/// import control), キャプチャエラー報告 and 取り込みエラー報告 (the two links in the capture
/// control group). While any one of them is in progress the other three are unavailable.
///
/// **This is a rule about the product, not a claim about the implementation.** Each control used to
/// justify its own gate with a technical assertion — "the screenshot comes from the capture path",
/// "an import is decoding video through the producer this control needs" — and those assertions
/// pointed in different directions, so the four gates did not agree. Whether something technical
/// stops a control is not the question the user is asking. The rule is the rule, and the gates are
/// derived from it.
///
/// **Why it lives in the core layer rather than beside the capture card that names it.** Three of
/// the four derivations are in `lib/src/gui/capture.dart`, but the fourth — 動画取り込み's own gate,
/// [resolveVideoImportBlocker] — is here, because it is a rule the two front ends share and is asked
/// again outside any widget tree (`VideoImportButton._preflight`). A `lib/src/core` file cannot
/// import a `lib/src/gui` one, so the single piece of data has to sit on this side of that line;
/// the alternative was the fourth gate taking its own parallel booleans, which is exactly the shape
/// that let the gates disagree in the first place.
///
/// **The two report dialogs are not values here, and that is deliberate.** Both open through
/// `CardDialog.show`, and `DialogController` holds exactly one dialog, so a second dialog would
/// *replace* the first rather than join it. While either is up, `DialogLayer`
/// (`lib/src/gui/common.dart`) withdraws the app behind it from **both** input devices: a scrim
/// that swallows taps, and an `ExcludeFocus` that takes the whole page out of focus traversal so
/// Tab cannot walk out of the dialog and Enter cannot fire a control under the scrim. Only the
/// first of those two used to exist, and a scrim alone would have made this paragraph a claim about
/// the pointer dressed up as a claim about everything: the card's exclusivity would then hold for a
/// mouse and break for a keyboard. Their exclusivity is structural on both devices, and a state
/// nothing can observe and nothing can read would only mislead the next reader.
/// `test/capture_exclusive_features_test.dart` measures both halves — it drives a tap and a
/// Tab-then-Enter at a control behind the dialog — because this paragraph is what keeps two of the
/// twelve pairs out of the enum.
///
/// Adding a fifth thing that can run means adding a value here, and every derivation is an
/// exhaustive `switch`, so the compiler names each place that has to decide about it. That is the
/// whole point of the enum: a hand-written list of booleans is how the fourth reason got missed.
enum CaptureActivity {
  /// Nothing is running. Every one of the four features is offered.
  idle,

  /// A live capture session is running. Named first in [resolveCaptureActivity] so that the toggle
  /// keeps offering its STOP half: being unable to end a running capture would be strictly worse
  /// than any overlap it prevents.
  capturing,

  /// 動画取り込み has a native file dialog open and has not posted a clip yet
  /// ([VideoImportPhase.picking]). Distinct from [importing] because the sentence differs — nothing
  /// is being imported yet — not because the rule differs.
  pickingClip,

  /// 動画取り込み is decoding a clip ([VideoImportState.isRunning] — `starting`, `importing` or
  /// `cancelling`).
  importing,
}

/// The one activity that is in progress, in precedence order.
///
/// Precedence matters only for the sentence shown: two of these can hold at once (an open file
/// dialog does not end a live capture), and either would be true.
CaptureActivity resolveCaptureActivity({required bool capturing, required VideoImportState importState}) {
  if (capturing) {
    return CaptureActivity.capturing;
  }
  if (importState.phase == VideoImportPhase.picking) {
    return CaptureActivity.pickingClip;
  }
  if (importState.isRunning) {
    return CaptureActivity.importing;
  }
  return CaptureActivity.idle;
}

/// Why an import may not be started right now.
///
/// Ordered by precedence in [resolveVideoImportBlocker]: the first that applies is the
/// one explained, because a disabled control that does not say why is the defect the
/// removed implementation set out to avoid ("a disabled button is never unexplained").
enum VideoImportBlocker {
  /// This front end has no import path at all — every target except web and Windows.
  /// The UI renders nothing rather than a disabled control — see `video_import_stub.dart`.
  unavailable,

  /// This front end has a path but cannot decode: on web, no `VideoDecoder` or no
  /// cross-origin isolation.
  ///
  /// **Web-only in practice**, and the asymmetry is a real constraint rather than a
  /// shortcut: web's decoder is a property of the browser the page happens to be running
  /// in, so it has to be probed, while the Windows runner links its decoder statically and
  /// a build that has the import path has the decoder. A clip the decoder cannot read is
  /// still refused there, but per clip and as a [VideoImportReason], not as a capability.
  unsupported,

  /// The recognition pipeline is not up yet (`platformControllerProvider` is null).
  notReady,

  /// A live capture session owns the pipeline. The core refuses the cross-kind start
  /// on its own; this only keeps the user from reaching that refusal.
  capturing,

  /// A record regeneration batch is in flight. **This is the one gate the core cannot
  /// hold** — see [resolveVideoImportBlocker].
  regenerating,

  /// A file dialog is already open ([CaptureActivity.pickingClip]).
  ///
  /// A separate value from [importing] only because the sentence differs — nothing is being
  /// decoded yet — and **not** because the rule differs, which is the same split
  /// [CaptureActivity] makes and for the same reason. Before it existed this state was reported
  /// as [importing], so the one control that could actually be looked at while a dialog was open
  /// explained itself with 「動画の取り込み中です。」 — a true-sounding sentence about a decode
  /// that had not started. **A gate naming the wrong running feature is the defect this whole
  /// rule exists to remove**, and it survived because the gate took `isBusy`, a boolean that had
  /// already merged the two states before the resolver could tell them apart.
  picking,

  /// An import is already running. One clip at a time; the worker refuses a second
  /// start rather than acknowledging it, so this keeps the user off that path.
  importing,
}

/// Which blocker (if any) forbids starting an import right now, in precedence order.
///
/// **Two of these are mutual exclusion, and they are not the same kind of gate.**
///
/// [capturing] and [importing] are *courtesy*. Both are genuine invariants of the
/// shared core: `CaptureSessionPolicy` types its claim by kind, so a cross-kind start
/// is `Refused` under the same mutex the Windows runner takes, and a second import is
/// refused rather than re-acknowledged (`web/worker.js`, `handleStartVideoImport`). The
/// UI must therefore never be *relied* on for them — but it must also not let the user
/// walk into a refusal toast, so it gates them anyway.
///
/// [regenerating] is different: **it is the one gate that cannot move into the core,
/// and this function is where it lives.** `docs/video-import.md` records why:
/// `NativeApi::updateRecord` is fire-and-forget with no completion tracking, so the
/// core has no way to know a regeneration is in flight and cannot refuse on its behalf.
/// The worker closes one direction — a regeneration is refused while an import owns the
/// loop (`web/worker.js`, `handleUpdateRecord`) — but the other direction is open by
/// construction: an import points the core at its own `directory.storage_dir`, which is
/// part of the pipeline identity, so starting one **rebuilds the pipeline underneath a
/// running regeneration** and that regeneration silently loses its work. Nothing below
/// the front end can see a batch, because a batch is a Dart concept: it is
/// `CharaDetailRecordRegenerationController`'s progress, and the worker's own
/// `updateState` is null between two records of the same batch (the documented hole the
/// removed implementation had). So the refusal has to be made here, where the batch is
/// visible, and it has to be re-evaluated at the moment the start is posted rather than
/// only when the button was built — a batch auto-starts after a module update, which is
/// exactly the kind of thing that can begin while the file dialog is open.
///
/// Per `.claude/rules/platform-parity.md` this comment is the divergence's stated
/// reason, at the divergence.
///
/// **[activity] is the exclusivity rule, and it arrives as one value rather than as two booleans.**
/// This gate used to take `capturing` and `importing` separately, resolved at the call site from
/// `capturingStateProvider` and `VideoImportState.isBusy` — the same two facts
/// [resolveCaptureActivity] answers, read a second time and combined a second way. That is how the
/// four gates came to disagree, and it is why the answer here is an exhaustive `switch` over the
/// one value: a fifth thing that can run cannot reach this file without the compiler asking what an
/// import should do about it.
///
/// **The activity is answered before [regenerating], and the one reachable overlap is unchanged.**
/// A live capture ranked above a regeneration before this and still does. The pair
/// "an import is decoding *and* a batch is running" is unreachable in both directions — each
/// refuses to start while the other runs — and the pair "a file dialog is open *and* a batch is
/// running" is genuinely reachable (a batch auto-starts after a module update) but reaches this
/// function only from the control's own build, where both sentences are true and the dialog is the
/// nearer one. **It never reaches the pre-flight that way**: an import posting its clip is not
/// blocked by its own dialog, so `VideoImportButton._preflight` resolves the activity with its own
/// state left out, and the regeneration gate this function exists for is answered exactly as before.
VideoImportBlocker? resolveVideoImportBlocker({
  required bool available,
  required bool supported,
  required bool controllerReady,
  required CaptureActivity activity,
  required bool regenerating,
}) {
  if (!available) {
    return VideoImportBlocker.unavailable;
  }
  if (!supported) {
    return VideoImportBlocker.unsupported;
  }
  if (!controllerReady) {
    return VideoImportBlocker.notReady;
  }
  final byActivity = switch (activity) {
    CaptureActivity.idle => null,
    CaptureActivity.capturing => VideoImportBlocker.capturing,
    CaptureActivity.pickingClip => VideoImportBlocker.picking,
    CaptureActivity.importing => VideoImportBlocker.importing,
  };
  if (byActivity != null) {
    return byActivity;
  }
  if (regenerating) {
    return VideoImportBlocker.regenerating;
  }
  return null;
}

/// The `…video_import.blocked.<key>` translation key for [blocker].
///
/// An explicit, exhaustive switch rather than `blocker.name`, because the two vocabularies
/// do not agree: the enum is camelCase and the translation file is snake_case, so
/// `VideoImportBlocker.notReady` looked up `blocked.notReady`, which is not a key
/// `ja.json` defines. easy_localization renders a missing key **as the key**, so the
/// blocker tile and the button tooltip showed the literal
/// `pages.capture.video_import.blocked.notReady` to every user for the whole window in
/// which the pipeline is still starting — an ordinary path on every web page load, not an
/// edge case. Exhaustive so that a new blocker cannot be added without being given a line.
String videoImportBlockerKey(VideoImportBlocker blocker) => switch (blocker) {
  VideoImportBlocker.unavailable => 'unavailable',
  VideoImportBlocker.unsupported => 'unsupported',
  VideoImportBlocker.notReady => 'not_ready',
  VideoImportBlocker.capturing => 'capturing',
  VideoImportBlocker.regenerating => 'regenerating',
  VideoImportBlocker.picking => 'picking',
  VideoImportBlocker.importing => 'importing',
};

/// Re-evaluates [resolveVideoImportBlocker] at the moment it is called.
///
/// A closure rather than a value, and that is the whole point: the blockers live in
/// Riverpod state the core layer cannot read, and the one that matters most
/// ([VideoImportBlocker.regenerating]) can become true *after* the button was built —
/// while the user is standing in the file dialog. The import path therefore calls this
/// twice: once before opening the dialog, once immediately before the clip is posted.
typedef VideoImportPreflight = VideoImportBlocker? Function();

/// How an import ended.
enum VideoImportOutcomeKind {
  /// The clip's samples ran out; every frame the pipeline accepted was processed.
  completed,

  /// The user cancelled; the producer stopped at a frame boundary.
  cancelled,

  /// The clip (or this browser) cannot be imported: no video track, an undecodable
  /// codec, a session the core refused. An ordinary app state, not a bug.
  refused,

  /// Something threw. The worker has already reported the failure itself.
  failed,
}

/// The ONE NAMED CAUSE behind a [VideoImportOutcomeKind.refused] or
/// [VideoImportOutcomeKind.failed] ending, when there is one.
///
/// **Why this exists.** [VideoImportOutcomeKind] has four values and the UI had one translated
/// line per value, so every refusal — a 65-byte text file renamed to `.mp4`, an HEVC recording
/// this browser cannot decode, a start refused because a record regeneration is running — was
/// answered with a single hedged sentence that named two unrelated causes and committed to
/// neither. The worker knew exactly which one applied and said so, in English, in a log line the
/// user never sees. This carries that knowledge to the front end as a value instead of prose:
/// the worker's message stays in [VideoImportOutcome.message] for the log and for Sentry, and
/// what reaches the user is one Japanese sentence per case
/// (`pages.capture.video_import.result.reason.<wireName>`).
///
/// [wireName] is the discriminator as it crosses the boundary, and it is also the translation
/// key — one vocabulary rather than two, because the blocker keys' camelCase/snake_case mismatch
/// is what rendered a raw translation key at the user once already (see
/// [videoImportBlockerKey]). Adding a case therefore means adding a line to `ja.json`, which
/// `video_import_reason_test.dart` requires; a case that arrives from a *newer* worker than this
/// build knows about parses as null and takes the generic line, never a blank or an enum name.
enum VideoImportReason {
  // --- refused, by the decode driver, after the session opened (web/video_import.mjs) ---
  /// The file is not a media container the demuxer recognises at all.
  notAVideo('not_a_video'),

  /// A container that parsed, with no video track in it.
  ///
  /// Windows names it from a weaker signal, because OpenCV never lists the tracks: the container
  /// opened, declared no frames at all, and yielded none.
  noVideoTrack('no_video_track'),

  /// The decoder cannot read the track's codec: WebCodecs on web (HEVC on Firefox, FFV1, …), and on
  /// Windows a container that declares frames and whose FFmpeg backend then produces none.
  codecUnsupported('codec_unsupported'),

  /// The decoder handed back a pixel format the core cannot read (4:2:2, 4:4:4, no format).
  ///
  /// Web-only: `cv::VideoCapture` converts every clip to BGR 8UC3 before the core sees it, so there
  /// is no format left for the Windows path to refuse.
  pixelFormatUnsupported('pixel_format_unsupported'),

  /// The decoder itself is missing, so no clip at all could be read: the mediabunny bundle could not
  /// be fetched on web (offline, a proxy, an extension), and on Windows the FFmpeg videoio backend is
  /// not loadable (the plugin DLL is absent beside the executable).
  decoderUnavailable('decoder_unavailable'),

  // --- refused before a session existed (web/worker.js, tagged into the error message; the Windows
  // runner refuses the same states before it asks the core, and carries them as an ordinary
  // `videoImportDone.reasonKind` because it has a terminal message to put them on) ---
  /// A record regeneration is in flight; starting an import would rebuild the pipeline under it.
  regenerationInFlight('regeneration_in_flight'),

  /// Another import already owns the event loop.
  alreadyImporting('already_importing'),

  /// A live capture session owns the pipeline (the core's cross-kind refusal).
  captureInFlight('capture_in_flight'),

  /// This core build is missing an export the import needs; the page is running stale wasm.
  ///
  /// Web-only: the Windows runner is statically linked against the core it was built with, so
  /// there is no separately pinned artefact for it to be out of step with.
  coreOutdated('core_outdated'),

  /// The worker had not finished initialising. Guarded on the Dart side too, so it is close to
  /// unreachable in practice; named rather than hedged because it is trivially distinguishable.
  ///
  /// Reused verbatim by the Windows runner for the same situation — a start that arrived before any
  /// config did (`windows/runner/video_import_session.h`) — so the translated line names the state
  /// rather than the browser it was first written for.
  workerNotReady('worker_not_ready'),

  // --- refused before a session existed, by the Windows runner only ---
  /// The picked file is gone, or cannot be opened.
  ///
  /// **Windows-only by construction, and the only kind that is.** Web's picker hands the worker a
  /// live `File` handle, so between the dialog closing and the decode starting there is nothing left
  /// to resolve — the browser keeps the reference and mediabunny reads through it. Windows crosses
  /// the method channel with a *path*, which is a name rather than a handle: the user can move,
  /// rename, delete or unplug the file in that window, and a network or removable volume can simply
  /// stop answering. `windows/runner/video_import_session.h` checks it before the core is asked for
  /// anything, so this is a refusal and never a half-started import.
  fileUnreadable('file_unreadable'),

  // --- decided by the shared core, after the run ---
  /// The import ran to the end and the recognizer produced **no record at all**.
  ///
  /// Neither the clip nor the decoder was refused — every frame was decoded and fed in, and nothing
  /// came out the other side, which is what a recording of the wrong screen, or one that never rests
  /// on the detail screen long enough, looks like from here. Before this existed such a run reported
  /// `reason: "completed"` and the card fell silent, so the user was told nothing whatsoever.
  ///
  /// **Named by the core, on every front end** (`native_api_messages.h`,
  /// `videoImportVerdictOf`): a `completed` verdict with `records: 0` is rewritten to
  /// `refused` + this kind before the payload is built, so no front end can present it as a success
  /// and none of them re-derives the rule. That is also why nothing on this side computes it from
  /// [VideoImportOutcome.records] — the count is here to say *how much* an import produced, not to
  /// re-decide what the core already classified.
  ///
  /// A refusal rather than a failure, for the same reason `no_video_track` is one: nothing
  /// malfunctioned, the clip simply does not contain what an import needs.
  noRecords('no_records'),

  // --- endings decided on this side ---
  /// The start never left this side (the post itself threw). See `VideoImportSlots.release`.
  neverStarted('never_started'),

  /// A running import fell silent for `videoImportProgressTimeout` — a worker the browser killed
  /// under memory pressure posts nothing at all, so this is the only report of it.
  ///
  /// Reachable on **both** front ends, because the watchdog is the shared `VideoImportSlots`
  /// rather than anything web-side, so its translated line names the state and the retry and
  /// mentions neither a browser nor a window — the same neutralisation `worker_not_ready` and
  /// `decoder_unavailable` got, and for the same reason.
  stalled('stalled'),

  /// The core stopped publishing its frame-flow counters mid-import, so the producer lost its
  /// only brake and was stopped. Not a refusal: the clip was importing when it happened.
  ///
  /// Web-only: the unbounded `NoLimit` queue that needs a JS-side flow gate exists on Emscripten
  /// alone. The Windows import runner's queue is `Block`, so the brake is the queue itself and
  /// cannot go missing.
  unbraked('unbraked');

  const VideoImportReason(this.wireName);

  /// The discriminator on the wire, and the `result.reason.<…>` translation key.
  final String wireName;
}

/// Parses a [VideoImportReason] off the wire, or null when there is none to parse.
///
/// Null — not a `.unknown` case — for an absent, empty or unrecognised discriminator, because
/// "there is nothing more specific to say" and "this build does not know what the worker said"
/// deserve the same answer: the generic line for the outcome kind. A `.unknown` case would have
/// to be given a translated sentence of its own, which could only be that same generic line
/// under a second key.
VideoImportReason? videoImportReasonOf(Object? wireName) {
  if (wireName == null) {
    return null;
  }
  final name = wireName.toString();
  for (final reason in VideoImportReason.values) {
    if (reason.wireName == name) {
      return reason;
    }
  }
  return null;
}

/// The tag a worker-side **start** refusal carries inside its error message, opened here.
///
/// A start refused before a session exists is reported on the worker's generic `{type:'error'}`
/// channel, which has no per-operation payload: the client cannot attribute an error to an
/// operation from the message alone (that is `scopeWorkerFailure`'s guess), and what it hands the
/// operation it settles is the message string. A field on that post would be dropped one layer
/// later, so the discriminator travels inside the text and is taken back out here — see
/// `videoImportReasonTag` in `web/worker.js`, which is the other half of this pair and must be
/// kept in step with it.
final RegExp _videoImportReasonTag = RegExp(r'\[video_import_reason=([a-z_]+)\]');

/// The reason tagged into [text] (a worker error message, however it was wrapped), or null.
VideoImportReason? videoImportReasonInText(String text) =>
    videoImportReasonOf(_videoImportReasonTag.firstMatch(text)?.group(1));

/// Maps the worker's `videoImportDone.reason` onto an outcome.
///
/// `unbraked` — the core stopped publishing its frame-flow counters mid-import, so the
/// producer lost its only brake — is folded into [VideoImportOutcomeKind.failed]: it is
/// not a refusal (the session had already started) and there is nothing the user can do
/// about it that differs from any other failure. The worker reports it separately for
/// diagnosis; the UI has one thing to say.
VideoImportOutcomeKind videoImportOutcomeKind(String reason) => switch (reason) {
  'completed' => VideoImportOutcomeKind.completed,
  'cancelled' => VideoImportOutcomeKind.cancelled,
  'refused' => VideoImportOutcomeKind.refused,
  _ => VideoImportOutcomeKind.failed,
};

/// One `videoImportProgress` report: [decoded] and [supplied] are frame counts (a
/// [supplied] below [decoded] means the pipeline refused frames), [mediaTimeMs] is the
/// container's presentation time of the last frame and [durationMs] the clip's declared
/// duration.
///
/// **The worker always sends both as numbers, and sends `0` for a duration the container
/// does not declare** (`web/video_import.mjs` initialises `durationMs` to 0 and only
/// raises it); it never omits either field. The types stay nullable purely as parse
/// tolerance for a field that is absent or non-numeric, and `null` and `0` therefore mean
/// the same thing here — "not known" — which is exactly how [videoImportFraction] reads
/// them.
typedef VideoImportProgress = ({int decoded, int supplied, int? mediaTimeMs, int? durationMs});

/// The fraction of the clip processed, or null when it cannot be known.
///
/// Media time over duration, both from the container — **not** a frame count, because
/// nothing tells the producer in advance how many frames a clip has. A clip that
/// declares no duration (a growing recording, a container the demuxer cannot measure)
/// reports `durationMs: 0` until a background scan lands one, so this returns null and
/// the UI shows an indeterminate bar rather than a number it made up. **The denominator
/// legitimately changes once**, mid-import, when that scan lands; nothing here is
/// cumulative, so each report is answered on its own terms.
///
/// Clamped, and not defensively: mediabunny documents a container's declared duration as
/// possibly approximate, so an under-declaring clip really does report a last frame past
/// its own end, and an unclamped bar would overrun.
double? videoImportFraction(VideoImportProgress? progress) {
  if (progress == null) {
    return null;
  }
  final duration = progress.durationMs;
  final mediaTime = progress.mediaTimeMs;
  if (duration == null || mediaTime == null || duration <= 0) {
    return null;
  }
  return (mediaTime / duration).clamp(0.0, 1.0);
}

/// The chara-detail sessions that ended during one import **without producing a record**, split by
/// how they ended.
///
/// Deliberately **not** called "lost characters". What the core states on the wire is that a session
/// ended and produced nothing; whether that cost the user a character it cannot know, and neither can
/// this side. A spurious mid-scene reset (the defect class `c69eba6` narrowed but did not close)
/// produces a discard whose character is then re-captured successfully a second later, and a reset
/// that happens after the last character was already registered leaves an empty session behind that
/// ends the same way. Both count here. So this is evidence that something did not come out whole,
/// which is exactly as strong a claim as the wire supports.
///
/// * [discarded] — `onCharaDetailRestarted` whose `completed` was not true: a session thrown away
///   mid-run before it had handed a record to the stitcher. **Absence of the field counts as not
///   completed**, which is the direction `record_info.h` asks readers to err in: towards announcing
///   a loss rather than towards the silence this whole change removes.
/// * [unfinished] — `onCharaDetailFinished` with `success` not true: a session that reached a
///   terminal state having produced nothing. Three causes reach it, all from the core's single
///   emitter: the detail screen closed mid-capture, the input ended mid-capture, and a stitch that
///   failed. It is **not** capped at one per run — a stitch failure can happen to any session — which
///   is why it is counted here rather than inferred as "the tail, if any".
///
/// The two are disjoint and together exhaust the sessions that produced nothing: a discard that had
/// already completed is not counted here and goes on to be announced as a finish (successful, or
/// unfinished if its stitch fails), and a discard that had not completed handed the stitcher nothing,
/// so no finish for it ever arrives.
typedef VideoImportSessionCounts = ({int discarded, int unfinished});

/// No session ended empty (also what an ending that never ran a pipeline reports).
const VideoImportSessionCounts videoImportNoSessionLoss = (discarded: 0, unfinished: 0);

/// Counts [VideoImportSessionCounts] for the import that owns the pipeline right now.
///
/// **Why this is a tally on the side rather than a field of the terminal message.** The two facts an
/// import's completeness needs arrive on different wires and cannot be joined anywhere else: the
/// record count rides `videoImportDone`, which on web is consumed by `WasmWorkerClient` on the worker
/// port and never reaches `PlatformController.handleNativeMessage` at all, while the session events
/// (`onCharaDetailRestarted`, `onCharaDetailFinished`) ride the pipeline's notify relay and reach
/// only that dispatch, on both platforms. So the dispatch counts into here and
/// [VideoImportSlots.settle] — the one door every ending of every front end passes through — reads
/// them back out onto the outcome. One rule, both platforms, no per-platform reconstruction.
///
/// **The gate is this object's own, and that is what keeps live capture out.** Counting runs only
/// between [beginRun] (`VideoImportSlots.arm`, i.e. an import claiming the client's slots) and
/// [endRun] (its settle). Every discard and every empty finish a *live* capture produces — and a
/// live session produces one per legitimate character switch — arrives while `_counting` is false and
/// is dropped. Making the caller test "is an import running?" instead would put that gate at each
/// call site, where a new site added later simply would not have it.
///
/// Process-level and mutable for the same reason `video_import_io.dart`'s `_slots` and `_state` are:
/// there is exactly one import at a time per process, and its client state belongs to the process,
/// not to a widget tree.
class VideoImportSessionTally {
  bool _counting = false;
  int _discarded = 0;
  int _unfinished = 0;

  /// Whether an import is currently having its sessions counted.
  bool get isCounting => _counting;

  /// The counts so far, without ending the run. For tests and diagnosis.
  VideoImportSessionCounts get counts => (discarded: _discarded, unfinished: _unfinished);

  /// Starts counting a new import, from zero.
  ///
  /// Zeroing here rather than at [endRun] alone is what makes an abandoned run (a settle that never
  /// arrived, a front end torn down mid-import) cost the *next* import nothing.
  void beginRun() {
    _counting = true;
    _discarded = 0;
    _unfinished = 0;
  }

  /// Stops counting and returns the run's totals, leaving the tally empty.
  ///
  /// Safe to call when no run is open — it answers [videoImportNoSessionLoss] — because the settle it
  /// is called from is itself idempotent and reached by endings that never armed anything.
  VideoImportSessionCounts endRun() {
    final result = counts;
    _counting = false;
    _discarded = 0;
    _unfinished = 0;
    return result;
  }

  /// One `onCharaDetailRestarted`: a session was thrown away and rebuilt.
  ///
  /// A discard of a session that had already produced its record loses nothing and is not counted —
  /// that is the ordinary two-character clip, and the field exists so an import does not have to
  /// report it as a loss.
  void noteDiscardedSession({required bool completed}) {
    if (!_counting || completed) {
      return;
    }
    _discarded++;
  }

  /// One `onCharaDetailFinished` that reported `success: false`.
  void noteSessionEndedWithoutRecord() {
    if (!_counting) {
      return;
    }
    _unfinished++;
  }
}

/// The one tally, read by [VideoImportSlots] and written by `PlatformController.handleNativeMessage`.
final VideoImportSessionTally videoImportSessionTally = VideoImportSessionTally();

/// How an import ended, with the counts the worker's terminal message carried.
class VideoImportOutcome {
  const VideoImportOutcome({
    required this.kind,
    this.decoded = 0,
    this.supplied = 0,
    this.rejected = 0,
    this.records = 0,
    this.durationMs = 0,
    this.matrixConverted = '',
    this.sessions = videoImportNoSessionLoss,
    this.message = '',
    this.blocker,
    this.reason,
  });

  final VideoImportOutcomeKind kind;

  /// The one named cause behind this ending, when the producer knew one. Null for a normal
  /// ending, and null for a cause this build does not recognise — both take [kind]'s own line.
  final VideoImportReason? reason;

  /// The gate that refused this import, when the refusal was made *here* rather than by
  /// the worker — i.e. by the second [VideoImportPreflight] call, after the file dialog
  /// closed. Null for every ending that reached the worker.
  ///
  /// Carried so the result tile can say the same thing the gate's own tile says, and the
  /// same thing the worker would have said: the worker refuses a start during a
  /// regeneration with "video import refused: a record regeneration is in flight", while
  /// the generic [VideoImportOutcomeKind.refused] line has to hedge between an
  /// undecodable clip and a busy pipeline. When the gate knows which one it is, hedging
  /// is inventing a second explanation for a state that already has one.
  final VideoImportBlocker? blocker;

  /// Frames the decoder produced.
  final int decoded;

  /// Frames the pipeline accepted. Below [decoded] when it refused some.
  final int supplied;

  /// Frames the pipeline refused (no running pipeline at the moment of the push).
  final int rejected;

  /// How many records the recognition run produced, as the **core** counted them. `0` when the
  /// producer stated no count — an ending that never ran a pipeline, or a core older than the field.
  ///
  /// **Nothing on this side ever asserts "this import produced nothing" from this number**, which is
  /// what makes the missing-count case need no separate value. An import that produced nothing is
  /// classified by the core, which rewrites that verdict to `refused` +
  /// [VideoImportReason.noRecords] before the payload is built; this is a *quantity*, and its only
  /// two readers ([videoImportIsPartial] and the `completed_partial` line it selects) both require it
  /// to be **positive** before they say anything at all. So an absent count and a genuine zero take
  /// the same, silent path — which is the behaviour a nullable field bought at the price of a null
  /// branch in every consumer.
  final int records;

  /// The clip's duration in milliseconds as the **producer that decoded it** stated it, or `0` for
  /// indeterminate.
  ///
  /// The same number on both front ends by construction: Windows reads it with
  /// `VideoLoader::durationMsOf` (`windows/runner/video_import_session.h`, `host.on_opened`) and web
  /// takes the container's own duration (`web/video_import.mjs`), which is also what the frame
  /// grabber's probe reports for the same file (`native/src/cv/video_frame_grabber.h`,
  /// `web/video_import.mjs` `probeClipTimeline`). That shared definition is what makes it usable as
  /// evidence that a clip a user later picks for a report **is** the clip this import ran on — see
  /// [resolveImportReportCorrelation].
  ///
  /// It has always crossed both wires (`native_api_messages.h` `videoImportDone`,
  /// `web/worker.js`); until this field existed the Dart side parsed the message and dropped it.
  final int durationMs;

  /// The colour conversion the producer had to accept before the core saw the pixels, in the
  /// producer's own words, or `''` for "nothing was converted".
  ///
  /// **Web-only in practice and empty on Windows on purpose**, which is exactly why it is carried
  /// rather than derived: the Windows core decodes and converts the clip itself, so there is no
  /// third party to have converted it behind the app's back, while a browser's decoder can hand back
  /// samples in a matrix the core did not ask for. Dropping the field on either side would leave this
  /// layer unable to tell "this build does not report conversions" from "nothing was converted", and
  /// an accepted browser conversion leaves no other trace at all (`native_api_messages.h` states the
  /// same rule from the C++ end).
  ///
  /// **Not to be confused with the `matrixConverted` on the frame-grab wire** (`web/worker.js`,
  /// `handleVideoFrameGrabRequest`): that one describes the single frame a report attaches, this one
  /// describes the run. They are different measurements of different pixels.
  final String matrixConverted;

  /// The sessions that ended during this import without producing a record. See
  /// [VideoImportSessionCounts] for what each number does and does not claim.
  final VideoImportSessionCounts sessions;

  /// The failure detail, for the log; empty on a normal ending. Never shown verbatim
  /// to the user — it is English and developer-worded, and what the user is shown is the
  /// translated line [reason] (or, failing that, [kind]) selects.
  ///
  /// **Written by a producer this side does not own, and published to Sentry as `import.message`**
  /// by [buildImportErrorReportScope]. On Windows it is an exception's `what()` relayed verbatim
  /// (`windows/runner/video_import_session.h` wraps a throw as `"the video import thread threw: "` +
  /// `what()`), and the very decoder that opens the clip builds one of those out of the path it
  /// failed on (`native/src/cv/video_loader.h`, `"Failed to open: " << narrow_path`). Whether the
  /// `what()` three layers down quotes the user's file is therefore not a fact this side can check,
  /// so **each front end passes this through [withMessage] + `withoutSecrets` before it reaches
  /// [VideoImportState]** — see `video_import_io.dart` and `video_import_web.dart`. By the time a
  /// value of this class is observable, the redaction has already happened.
  final String message;

  /// This outcome with [sessions] replaced — how [VideoImportSlots.settle] joins the tally it
  /// collected during the run to the ending it is settling.
  ///
  /// **Every field has to be repeated here and the compiler will not say so**, because they all
  /// carry defaults: a field added to the class and forgotten in this list is silently zeroed on the
  /// one copy every settled import passes through, and the zero then reads as a measurement.
  ///
  /// **So the list is checked by a machine that counts the fields for itself.**
  /// `test/video_import_report_fields_test.dart` reads this file, enumerates the fields
  /// [VideoImportOutcome] declares, and fails when any one of them is missing from the named
  /// arguments below — and it fails again if it enumerates nothing, so a parser that stopped
  /// matching cannot pass by finding no fields to check. A test rather than a compile error because
  /// the two ways to make the compiler count are both closed here: making the parameters `required`
  /// costs every call site its defaults (there are more than twenty, most of them naming one field),
  /// and holding the wire fields in a nested object cannot be done from a `const` constructor —
  /// measured, `invalid_constant` on an object creation in a const initializer list — while
  /// `const VideoImportOutcome(...)` is what several call sites and fixtures use.
  ///
  /// The same test also pins that every field reaches [buildImportErrorReportScope], or is named in
  /// its exclusion list with a reason. Those are the two places a field can be silently lost.
  VideoImportOutcome withSessions(VideoImportSessionCounts sessions) => VideoImportOutcome(
    kind: kind,
    decoded: decoded,
    supplied: supplied,
    rejected: rejected,
    records: records,
    durationMs: durationMs,
    matrixConverted: matrixConverted,
    sessions: sessions,
    message: message,
    blocker: blocker,
    reason: reason,
  );

  /// This outcome with [message] replaced — how each front end redacts the producer's sentence
  /// before it can be observed, published or logged. See [message] for why it needs redacting.
  ///
  /// The redaction itself is done by the caller rather than in here, because the strings that must
  /// not travel are the caller's: Windows holds the clip's **absolute path** as well as its leaf,
  /// web holds only the leaf (a browser `File` has no directory to leak), and neither fact is
  /// reachable from this file. This class would also have to import `app_logger.dart` for
  /// `withoutSecrets`, which would drag the Sentry SDK into the one file here that is deliberately
  /// pure (its single import is `video_frame_grab_ops.dart`).
  ///
  /// **Carries every field, for the same reason [withSessions] does and with the same machine
  /// checking it**: every parameter is defaulted, so a field added to the class and forgotten here
  /// is silently zeroed rather than rejected by the compiler. `video_import_report_fields_test.dart`
  /// enumerates the copy methods off this source and checks each one, so this list is covered by
  /// the same guard without being named in it.
  VideoImportOutcome withMessage(String message) => VideoImportOutcome(
    kind: kind,
    decoded: decoded,
    supplied: supplied,
    rejected: rejected,
    records: records,
    durationMs: durationMs,
    matrixConverted: matrixConverted,
    sessions: sessions,
    message: message,
    blocker: blocker,
    reason: reason,
  );

  /// Sessions that began during this import and produced nothing, however they ended.
  int get sessionsWithoutRecord => sessions.discarded + sessions.unfinished;
}

/// Whether this import **registered something and still left a session unaccounted for**.
///
/// The predicate, stated once, because getting it wrong is silent in both directions: a run reported
/// as a clean success when a character went missing, or a warning shown for a run where nothing did.
/// Three conditions, and each excludes a case the other two do not:
///
/// 1. **[VideoImportOutcomeKind.completed].** Every other kind already has its own line, and each of
///    them explains the shortfall better than this would: a run with no records at all is
///    [VideoImportReason.noRecords], a cancel is the user's own doing (and its partial result is the
///    point, not a defect), and a failure says so.
/// 2. **A positive record count.** The line this selects names that count, so there has to be one to
///    name. Zero cannot occur together with `completed` when the count was actually taken — the core
///    reclassifies that run as a refusal — so what this term really excludes is the run whose count
///    never reached this side at all (an older core; on web a wasm artifact pinned separately from
///    the page). "Some of an unknown number is missing" is not a sentence anyone can act on, and the
///    zero those endings carry keeps it unsaid.
/// 3. **At least one session that produced nothing.**
///
/// What this is NOT is a count of lost characters; see [VideoImportSessionCounts]. Whether it earns a
/// sentence, and what that sentence says, is the front end's decision.
bool videoImportIsPartial(VideoImportOutcome outcome) =>
    outcome.kind == VideoImportOutcomeKind.completed && outcome.records > 0 && outcome.sessionsWithoutRecord > 0;

/// The `…video_import.result.<key>` translation key for [outcome].
///
/// [VideoImportOutcome.reason] wins when there is one, because it is strictly the more specific
/// statement of the same ending: `result.refused` has to hedge across every way a clip can be
/// turned away, and `result.reason.not_a_video` does not. An outcome with no reason — a normal
/// completion, a cancellation, or a cause this build does not recognise — falls back to the
/// kind's own line, which is exactly what every ending showed before reasons existed.
///
/// **`completed_partial` is the one key that is not a kind and not a reason**, and it has to be
/// resolved here rather than by the producer: whether a run left a session unaccounted for is
/// [VideoImportOutcome.sessions], which is joined onto the outcome on this side (the two facts
/// arrive on different wires — see [VideoImportSessionTally]), so no `reasonKind` can ever carry it.
///
/// **`ja.json` carries a line for all four kinds, including the one that cannot be reached.** The
/// `completed` line is unreachable through the card and was so before this change: the only completed
/// outcome the card records is a partial one (`_eventfulImportOutcomeKinds`, and the predicate over
/// it), so a plain completion never asks for a sentence. It is kept anyway, because the alternative
/// is a hole in an exhaustive vocabulary — every kind has a name here, and a name with no line
/// renders as the raw key the moment anything reaches it.
///
/// The cost of keeping it is that `completed_partial` going missing would fall back to it and
/// announce a false success, which is exactly the report this change exists to stop. That is
/// therefore pinned by a named test rather than by the absence of a line: `capture_event_test.dart`
/// asserts that a partial ending renders its counts and its request to check.
String videoImportResultKey(VideoImportOutcome outcome) {
  final reason = outcome.reason;
  if (reason != null) {
    return 'reason.${reason.wireName}';
  }
  if (videoImportIsPartial(outcome)) {
    return 'completed_partial';
  }
  return outcome.kind.name;
}

/// The whole observable state of the import front end.
///
/// Immutable and platform-neutral, so the desktop stub can hold a constant one and the
/// web implementation can publish it through a `ValueNotifier` the capture page listens
/// to — the same shape `capture_capability.dart` uses for the live-supply notices.
class VideoImportState {
  const VideoImportState({required this.phase, this.fileName, this.progress, this.outcome});

  /// Nothing has happened yet (and, on desktop, never will).
  static const VideoImportState idle = VideoImportState(phase: VideoImportPhase.idle);

  final VideoImportPhase phase;

  /// The chosen clip's name, for the progress line. Null before a pick.
  final String? fileName;

  /// The most recent progress report, or null before the first one.
  final VideoImportProgress? progress;

  /// How the last import ended, once [phase] is [VideoImportPhase.finished].
  final VideoImportOutcome? outcome;

  /// Whether an import **owns the pipeline** right now.
  ///
  /// A statement about the pipeline and no longer a gate on its own. [VideoImportPhase.picking] is
  /// excluded because a file dialog claims nothing from the core — which is still true and is still
  /// what this term is for — but it is **not** the reason a control is offered or withdrawn: that
  /// is [CaptureActivity], which keeps the two apart as [CaptureActivity.pickingClip] and
  /// [CaptureActivity.importing] and withdraws the other three features under both. This getter
  /// used to be read as if the two questions were one, and the answer to the second one was wrong.
  bool get isRunning =>
      phase == VideoImportPhase.starting || phase == VideoImportPhase.importing || phase == VideoImportPhase.cancelling;

  /// Whether the import control itself should be inert — [isRunning] plus the open
  /// file dialog, which must not be opened twice.
  bool get isBusy => isRunning || phase == VideoImportPhase.picking;

  /// Whether a cancel may still be offered.
  bool get isCancellable => phase == VideoImportPhase.starting || phase == VideoImportPhase.importing;

  /// The determinate progress fraction, or null for an indeterminate bar.
  double? get fraction => videoImportFraction(progress);

  VideoImportState copyWith({
    VideoImportPhase? phase,
    String? fileName,
    VideoImportProgress? progress,
    VideoImportOutcome? outcome,
  }) {
    return VideoImportState(
      phase: phase ?? this.phase,
      fileName: fileName ?? this.fileName,
      progress: progress ?? this.progress,
      outcome: outcome ?? this.outcome,
    );
  }
}

/// The clip's **container**, taken from its file extension: `'mp4'`, `'mkv'`, `'webm'`, … — or `''`
/// when the name has no extension at all.
///
/// **This is what a report says about the clip's identity instead of its name.** A user's own file
/// names can carry their real name, an employer, a client, a case number — anything a person puts in
/// a folder — so the name itself does not travel (see [buildImportErrorReportScope]). What is
/// actually diagnostic about it is the container, and that is a closed vocabulary rather than
/// free text.
///
/// **A suffix that is not container-shaped is reported as `'other'` rather than passed through**,
/// which is the whole reason this is a function and not `name.split('.').last`. `Report for Dr.
/// Tanaka` has a "extension" of `` `Tanaka` ``, and forwarding it would put back exactly the
/// disclosure this rule removes — by accident, on the reports of the users least likely to be
/// running a screen recorder's default file name. So the answer is constrained to what a container
/// suffix can look like (1-5 ASCII alphanumerics) and everything else is answered with a value that
/// states its own uselessness instead of guessing.
String reportClipContainer(String clipName) {
  final dot = clipName.lastIndexOf('.');
  if (dot < 0 || dot == clipName.length - 1) {
    return '';
  }
  final suffix = clipName.substring(dot + 1).toLowerCase();
  return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(suffix) ? suffix : 'other';
}

/// Whether the clip a user picked for an import-error report is the clip the last import ran on —
/// and, when it is not, which check said so.
///
/// **This exists because the report dialog always asks for a file.** It has no handle on "the clip
/// you just imported" (deliberately: retaining one would mean keeping a path or a `File` alive
/// between an import and a report), so "the most recent import result" and "the video in this
/// report" are two independent facts. Attaching the first to the second without checking would put
/// *another clip's* decode counters, duration and colour note on a report about this one — a
/// diagnosis sent looking for a failure that happened to a different file.
enum ImportReportCorrelation {
  /// Both checks passed: the report may carry the import's result.
  matched('matched'),

  /// No import has finished in this session, so there is no result to attach.
  noFinishedImport('no_finished_import'),

  /// An import finished, but on a differently named file.
  clipNameDiffers('clip_name_differs'),

  /// The names agree, but at least one side states no duration, so the second check cannot run.
  ///
  /// Treated as "no correspondence" rather than "close enough", because the direction to fail in is
  /// the one that omits evidence rather than the one that invents it.
  durationUnknown('duration_unknown'),

  /// The names agree and both durations are known, and they are different files.
  durationDiffers('duration_differs');

  const ImportReportCorrelation(this.wireName);

  /// How this reads on the report. Snake case, like every other key on it.
  final String wireName;
}

/// Decides [ImportReportCorrelation] for [clipName] / [clipDurationMs] against [state].
///
/// **Two checks, both from data the two sides already state independently, and fail-closed.**
///
/// 1. **The file's leaf name.** `VideoImportState.fileName` is the leaf of the path the user picked
///    for the import (`video_import_io.dart` `_fileNameOf`, `video_import_web.dart` the `File`'s own
///    name), and [ClipFrameSource.name] is the leaf of the one they picked for the report. Neither
///    is a full path, so this cannot distinguish two same-named files in two directories on its own.
///    **Both stay on this machine**: comparing them is the only use either name has, and neither
///    reaches the report — see [buildImportErrorReportScope].
/// 2. **The duration the two producers measured.** That is what closes the gap the name leaves open:
///    the import's number and the report probe's number come from the *same definition* on each
///    platform — `VideoLoader::durationMsOf` on Windows, the container's declared duration on web —
///    so for one file they agree exactly, and two different recordings agreeing to the millisecond
///    as well as sharing a name is not a coincidence worth designing around.
///
/// **What it deliberately does not do is guess.** A clip whose container states no duration, and an
/// import that ended before it ever opened the file (a blocker, an unreadable path) or came from a
/// core too old to report one, both answer [ImportReportCorrelation.durationUnknown] and the report
/// carries the clip's own attributes only. That is a false negative — the user loses import counters
/// on a report that could have had them — and it is the side to be wrong on: the opposite error is a
/// report that quietly describes a different video.
ImportReportCorrelation resolveImportReportCorrelation({
  required VideoImportState state,
  required String clipName,
  required int clipDurationMs,
}) {
  final outcome = state.outcome;
  if (state.phase != VideoImportPhase.finished || outcome == null) {
    return ImportReportCorrelation.noFinishedImport;
  }
  if (state.fileName != clipName) {
    return ImportReportCorrelation.clipNameDiffers;
  }
  if (clipDurationMs <= 0 || outcome.durationMs <= 0) {
    return ImportReportCorrelation.durationUnknown;
  }
  if (outcome.durationMs != clipDurationMs) {
    return ImportReportCorrelation.durationDiffers;
  }
  return ImportReportCorrelation.matched;
}

/// Everything an import-error report puts on the Sentry event beside the PNG and the user's note:
/// [context] is one structured block, [tags] are the few strings worth filtering an issue list by.
typedef ImportErrorReportScope = ({Map<String, dynamic> context, Map<String, String> tags});

/// What a report writes where a producer stated no value.
///
/// **A string and not `null`, and that is a measurement rather than a preference.** The design this
/// replaces wrote the key with a `null` value so that "this producer does not report it" could not
/// be mistaken for "this side forgot to carry it" — which is why the keys below are written
/// unconditionally in the first place. On the first real event this feature ever filed (measured on
/// 2026-08-21 by pulling the stored event back out of Sentry) **every null-valued context key was
/// gone**: all five of the `frame` block's, and `import.blocker` with them, while the *empty string*
/// on `import.matrix_converted` arrived intact, and a walk over the whole stored event found no
/// null-valued key in any of its thirteen contexts. Null is dropped somewhere between
/// `Scope.setContexts` and the stored event; from the reader's seat it does not matter which side
/// dropped it, because an absent key and a key this side never wrote look exactly alike. The
/// distinction existed only on this machine.
///
/// The value is chosen to be unmistakable in both directions:
///
/// * it is **not a number**, so it cannot be read as one of the measurements it stands in for
///   (`frame.width`, `frame.rotation`, `frame.seek_backoff_ms`, …) — the failure a `0` default
///   produced, and the one those fields were made nullable to end;
/// * it is **not the empty string**, which is already a *different* statement on
///   `matrix_converted`: "this producer reports conversions, and converted nothing";
/// * it is lower case and contains a space, which no producer's vocabulary does — pixel formats
///   (`'I420'`, `'NV12'`), outcome kinds and reason wire names are all single tokens — so it cannot
///   collide with something a producer actually said.
const String reportValueNotStated = 'not stated';

/// [context] with every null replaced by [reportValueNotStated], at any depth.
///
/// **A sweep rather than a `?? reportValueNotStated` written at each key.** The defect being
/// repaired is a value going missing in silence, and a per-key table is the shape that lets the next
/// one go missing: seven of the `frame` block's keys and two of the `import` block's are nullable
/// today, each for a reason that names a producer, and a leg added later brings more. Written this
/// way, the block above stays a plain statement of what the report says and *whether a value
/// survives the trip* is answered once, in one place, for every key there will ever be.
///
/// Lists are walked for the same reason maps are: nothing puts one on a report today, and a rule
/// that only holds for the shapes that exist today stops holding the day another one is added.
Map<String, dynamic> statedReportContext(Map<String, dynamic> context) => <String, dynamic>{
  for (final entry in context.entries) entry.key: _statedReportValue(entry.value),
};

dynamic _statedReportValue(dynamic value) => switch (value) {
  null => reportValueNotStated,
  final Map<String, dynamic> nested => statedReportContext(nested),
  final List<dynamic> items => items.map(_statedReportValue).toList(),
  _ => value,
};

/// Builds [ImportErrorReportScope] for one finished report.
///
/// Pure, and separated from the send for that reason: what a report *says* is the part that can be
/// wrong in a way nobody notices, so it is decided here where a test can read it, and
/// `captureImportError` only puts it on the wire.
///
/// **The clip's own attributes are always present; the import's result is present only when
/// [resolveImportReportCorrelation] says the two describe the same file.** `import.correlation`
/// states which it was, on every report, so an absent result reads as "this could not be tied to an
/// import" rather than as "no import ever ran".
///
/// **[clipName] is read and never published.** It is the correlation's first check, and it is also
/// the one thing here that is written by the user rather than measured by a decoder, so what the
/// `clip` block carries is the clip's *attributes* — container, duration, size, frame rate, where
/// its first frame sits, whether it has a usable timeline — and not the string a person typed. See
/// [reportClipContainer]. Comparing a name and sending it are different acts, and only the first is
/// needed to know which import a report belongs to.
///
/// The frame block quotes [GrabbedVideoFrame.mediaTsMs] first: it is the frame that is actually
/// attached, and [GrabbedVideoFrame.requestedMs] is beside it only so the pair can be compared. The
/// rest of that block describes **the pixels in the attachment** — the size, layout, rotation and
/// colour conversion the grab reported — which is a different measurement from the identically named
/// one in the `import` block, and is why the two live under different keys rather than in one
/// flattened bag.
///
/// **No key on the returned context carries a null**, however silent the producer was: the whole map
/// goes through [statedReportContext] on the way out, because a null-valued context key does not
/// survive to Sentry at all and an unreported value has to reach the reader as something they can
/// see. The tags are a different case and are left as they are — a tag is a filter over an issue
/// list, so an absent tag narrows nothing while a `not stated` bucket would invite someone to filter
/// on it as if it were a state an import can be in.
ImportErrorReportScope buildImportErrorReportScope({
  required String clipName,
  required GrabbedVideoFrame frame,
  required VideoFrameTimeline timeline,
  required VideoImportState importState,
}) {
  final correlation = resolveImportReportCorrelation(
    state: importState,
    clipName: clipName,
    clipDurationMs: timeline.durationMs,
  );
  // Null unless the correlation held. Written as one nullable local rather than as a bool beside
  // the outcome so that "the result may be attached" and "here is the result" cannot come apart:
  // there is no expression in this function that reads the outcome without this check.
  final matched = correlation == ImportReportCorrelation.matched ? importState.outcome : null;
  return (
    // Every null below leaves this function as [reportValueNotStated]; see [statedReportContext] for
    // the measurement that makes that necessary rather than tidy.
    context: statedReportContext(<String, dynamic>{
      'clip': <String, dynamic>{
        // The container, never the name. See [reportClipContainer].
        'container': reportClipContainer(clipName),
        'duration_ms': timeline.durationMs,
        'first_frame_ms': timeline.firstFrameMs,
        'fps': timeline.fps,
        'width': timeline.width,
        'height': timeline.height,
        'has_media_timeline': timeline.hasMediaTimeline,
      },
      'frame': <String, dynamic>{
        'media_ts_ms': frame.mediaTsMs,
        'requested_ms': frame.requestedMs,
        'seek_backoff_ms': frame.seekBackoffMs,
        'decoded_frames': frame.decodedFrames,
        // WHAT THE ATTACHED PIXELS ARE, as the producer that decoded them stated it. Written
        // unconditionally, including when the value is null (Windows states none of these five):
        // an omitted key cannot be told apart from a field this side forgot to carry, which is the
        // exact defect being repaired here, one wire over. **A null does not reach the reader as a
        // null** — Sentry drops null-valued context keys, measured on a real event — so
        // [statedReportContext] turns it into [reportValueNotStated] on the way out, and that
        // string is what says "this producer does not report it".
        'width': frame.width,
        'height': frame.height,
        'format': frame.format,
        'rotation': frame.rotation,
        // The conversion accepted for THIS FRAME. `import.matrix_converted` below is the conversion
        // accepted during the run; they are different pixels and may legitimately disagree.
        'matrix_converted': frame.matrixConverted,
      },
      'import': <String, dynamic>{
        'correlation': correlation.wireName,
        if (matched != null) ...<String, dynamic>{
          'outcome': matched.kind.name,
          // Both are absent far more often than not — a normal ending names no reason, and every
          // ending that reached the worker was refused by no gate — and both therefore leave here
          // as [reportValueNotStated] rather than as a null the reader would never see. "The gate
          // named no blocker" and "this side lost the blocker" are the two readings the key exists
          // to keep apart, and only one of them can be told from an absent key.
          'reason': matched.reason?.wireName,
          'blocker': matched.blocker?.name,
          'decoded': matched.decoded,
          'supplied': matched.supplied,
          'rejected': matched.rejected,
          'records': matched.records,
          'duration_ms': matched.durationMs,
          // The two fields the wire has always carried and this side used to drop. Empty means the
          // producer converted nothing; see [VideoImportOutcome.matrixConverted] for why an empty
          // string and an absent field are not the same statement. THE RUN's conversion — every
          // frame the recogniser saw — as opposed to `frame.matrix_converted` above, which is the
          // one frame this report attaches and was grabbed separately, later.
          'matrix_converted': matched.matrixConverted,
          'sessions_discarded': matched.sessions.discarded,
          'sessions_unfinished': matched.sessions.unfinished,
          // THE ONE FREE-TEXT VALUE ON THIS REPORT, and the only one written by something outside
          // this app. It is published as the front end stored it, which is **already redacted**:
          // both legs put the producer's sentence through `withoutSecrets` before it reaches
          // [VideoImportState], because they are the only layers that hold the path and the leaf to
          // redact with. Doing it here instead would leave the directory behind — this function is
          // given [clipName] and never a path — and `C:\Users\<person>\` is exactly the fragment
          // that identifies the user. See [VideoImportOutcome.message].
          'message': matched.message,
        },
      },
    }),
    tags: <String, String>{
      'report.kind': 'video_import',
      'video_import.correlation': correlation.wireName,
      if (matched != null) 'video_import.outcome': matched.kind.name,
      if (matched != null) 'video_import.reason': ?matched.reason?.wireName,
    },
  );
}

/// The `origin` a record-bearing message carries when the records it names were produced by a
/// **video import** rather than by a live capture.
///
/// The two sessions publish through the same sink and the same relay, so without this the
/// receiving side cannot tell them apart — and it has to, because an import must play no cue for
/// any of its records while a live capture must keep the cue for all of its own. Reading the
/// import's *state* instead cannot answer it: the merge of an import's last record runs after
/// that state has settled (see `CharaDetailRecordStorage.addFromFileAsync`).
///
/// **One marker, two transports, and only the transport is a divergence**
/// (`.claude/rules/platform-parity.md`). Web puts it on `onLiveRecordsHarvested`, because its
/// harvest sweeps the MEMFS active root indiscriminately and an import must therefore be scoped
/// to a `storage_dir` of its own, from which records arrive in batches. Windows puts it on
/// `onCharaDetailFinished`, because its recognizer writes each record straight into the real
/// active root and announces it one at a time — there is no sweep to defend against, and a split
/// root would only break the merge, which resolves `rootDirectory / id`. The value, the meaning
/// and the fail-open direction are identical on both; what differs is per batch versus per
/// record, which is the granularity each transport already had. On Windows the field is derived
/// in the shared core from the open session's kind (`NativeApi::notifyCharaDetailFinished`), so
/// it is stated rather than inferred — and so the wasm build states it too.
///
/// Absence means live. An older relay, or a message that loses the field, therefore keeps its
/// chime rather than losing it: the failure this defaults towards is an extra cue for an import,
/// never a missing one for a live capture.
const String harvestOriginVideoImport = 'video_import';
