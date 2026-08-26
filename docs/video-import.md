# Video import

Feed a **local video file** into the recognition pipeline and harvest the records it contains, on
**web and Windows**. The feature existed on web once (`162a04cc`), was removed wholesale
(`6b85f593`), and is being reintroduced as a first-class capability on both front ends.

This document is the agreed design record: what was decided, why, and which drawbacks were
knowingly accepted. It was written against HEAD `fadec7f` on `feature/wasm-poc`, extended at
`c9663a2` when the colour work below closed open question 3, and extended again when the **Windows
front end landed** — the web path shipped first, so passages that read as "web does X, Windows has
nothing" were rewritten rather than left standing. The Windows work itself is described in
[The Windows path](#the-windows-path-end-to-end), which carries its own provenance warning: it was
written from the source, not from a run.

> Sources. Four read-only investigations under the gitignored `.notes/video-import/`:
> `old-implementation-review.md`, `decode-options-survey.md`, `session-policy-feasibility.md`,
> `decode-ab-comparison.md`. Claims below carry the file:line or the report that establishes them;
> anything unestablished is in [Open questions](#open-questions) and nowhere else.

## Why the feature comes back

The removal commit **never stated a rationale**. Its Summary says what survives ("Live capture and
record regeneration are untouched; so is the native CLI") — a scope statement, not an argument. No
note, no commit and no design document anywhere in the tree argues that live capture covers the
import use cases (`old-implementation-review.md` §0.2, §3.2). The removal was defensible as
hygiene — it deleted a copyleft vendored decoder, an unlicensable test fixture, a second session
owner and the only reachable path to an unbounded queue mode — but it was never a capability
decision.

These are the cases live capture structurally cannot serve. Each follows from code at HEAD, not from
speculation (`old-implementation-review.md` §3.3):

| case | why live capture cannot |
| --- | --- |
| a recording that already exists | it was made before the app was installed, on another device, or by a capture tool |
| a missed capture | live capture harvests only what it saw; a closed tab, a stopped share, a sleeping machine or a `closed_before_completed` loses it permanently. A file can be re-fed any number of times |
| no display-capture capability | `isLiveCaptureSupported` needs `VideoFrame` **and** `getDisplayMedia` **and** `crossOriginIsolated`. Import needs only a decoder and COI. Mobile browsers have no `getDisplayMedia` at all |
| the game is not on this machine | played on a phone or a console-like device, recorded there, imported on a PC |
| reproducing a misrecognition report | a user can send a clip; a live session cannot be re-run. This is also the internal diagnostic value the old `?wasm_selftest=video` route had |
| throughput | an import is paced by the pipeline, not by the clock, and drops nothing. Live capture is pinned to real time and *discards* frames under load by design |

## The decisions

| # | decision |
| --- | --- |
| 1 | Reintroduce video import as a **first-class feature**, not a debug affordance |
| 2 | Web decodes with **WebCodecs `VideoDecoder` + Mediabunny** (option A). Option B2 (`<video>` + `requestVideoFrameCallback`) is rejected |
| 3 | **Both platforms at once.** Windows uses the existing native `VideoLoader` (OpenCV videoio) |
| 4 | **Bundle the OpenCV FFmpeg plugin DLL on Windows**, accepting ~33.8 % growth of the bundled native DLL total, so container coverage matches web |
| 5 | **Record harvesting is isolated by construction** — on web, scoped to the import session rather than gated by UI. Windows has no sweep to isolate and shares the live active root, carrying an explicit `origin` marker instead ([The Windows path](#the-windows-path-end-to-end)) |
| 6 | **Decoder colour differences are tolerated, not eliminated.** Ask for planes so the shared conversion runs where it can, but recognition must survive a frame the browser already converted ([Colour](#colour-two-decoders-one-recognition-result)) |
| 7 | **The import's origin is carried as data on both platforms**, with the same value and the same "absent means live" default. Only the *transport* differs, and only because a platform constraint forces it |

Everything below is the consequence of these, plus the constraints the investigations established.

## Decode on web: option A, and why not B2

Option A is what the removed implementation used: Mediabunny demuxes, the browser's `VideoDecoder`
decodes, the worker pushes every sample. The pin is **mediabunny 1.52.3, MPL-2.0, 1,367,976 B**
(~1.37 MB uncompressed) — `tool/web_deps.json` carries both sha256s and the licence text, and is the
authority for the version and the size, not this paragraph. It sits there with its
`assets/license/mediabunny.txt`; the pin machinery (`tool/fetch_web_deps.py`,
`lib/web_deps_verify.dart`, `tool/check_web_pins.dart`) refuses to build if the licence asset is
missing or null, so the disclosure cannot be skipped.

Option B2 — a hidden `<video>` element clocked by `requestVideoFrameCallback` — was the cheapest
option on paper and is rejected on four grounds, in ascending order of weight
(`decode-ab-comparison.md` §§1–5):

1. **rVFC is lossy by specification.** It fires when a frame is *presented to the compositor*, not
   when it is decoded; the spec says outright that "we might not get a callback for every frame" and
   ships `presentedFrames` as a drop *detector*. Its only speed knob, `playbackRate`, is also the
   knob that destroys its frame yield: presentation is capped at the display refresh, so past roughly
   `refresh_rate / source_fps` the loss is arithmetic. B2's honest speed is 1× realtime.
2. **A hidden tab collapses it, and a merely occluded window counts as hidden.** This repo measured
   it (`.notes/analysis/firefox-live-capture/design-comparison.md`): while `hidden`, rVFC yields
   **0.2 fps on Chromium and 0.5 fps on Firefox**, and both engines flip `visibilityState` to
   `hidden` ~2 s (Chrome) / ~3 s (Firefox) after another window fully covers the browser. Against a
   ~30 fps source that is ~99 % shed. The scraper tolerates shedding to ~83 % with a measured cliff
   at 83–87.5 %, so this is an order of magnitude past the cliff. A multi-minute import is exactly
   when the user goes and does something else.
3. **Containers.** `<video>` cannot open **`.mkv` on Firefox or Safari**, and mkv is OBS's *default*
   recording container. Mediabunny demuxes Matroska on every engine that has WebCodecs. B2 wins only
   on HEVC in Firefox and Safari — a split, not a sweep.
4. **Decisive: determinism.** A presentation-paced producer makes the same file yield different
   results on web and Windows, and different results between two runs on one machine, depending on
   whether the user alt-tabbed. `.claude/rules/platform-parity.md` does not merely require a comment
   for this; it spends its longest paragraph forbidding exactly this class of nondeterminism in
   **offline** producers, because the golden suite consumes those paths as a pure function of the
   input clip. Adopting B2 would mean amending that rule. Adopting A requires no amendment.

Two corrections to earlier framing, both worth keeping: B2's "zero new code, reuse the live path
verbatim" is **not accurate** — both options needed a new snapshot-free wasm export (`pushOfflineFrame`,
see below), so B2 is smaller, not free. And B2 is main-thread-bound forever: there is no `<video>` in
a worker in any engine, so its clock lives permanently on the throttled side of the boundary.

Two improvements over the removed implementation, both cheap:

* **Feature-detect with the strong form.** The old code used `globalContext.has('VideoDecoder')`; the
  live-capture probes at HEAD deliberately use `typeofEquals('function')` because a global can be
  present and `undefined`. Better still, Mediabunny's `canDecodeVideo()` can pre-flight the actual
  clip's codec before the file is read, instead of failing deep in the worker.
* **Do not hold the whole file.** The old path used `BufferSource(arrayBuffer)`, i.e. the entire
  encoded clip resident. A streaming source is the fix (see [Open questions](#open-questions) for
  what is unverified about it), and there was never any size cap anywhere on the path.

## Decode on Windows: `VideoLoader`, plus the FFmpeg plugin DLL

Windows needs no new decoder. `cv::VideoCapture` **already links into the Flutter runner** —
`windows/runner/CMakeLists.txt` does `find_package(OpenCV REQUIRED)` against `windows/opencv/build`
and `opencv_modules.hpp:27` defines `HAVE_OPENCV_VIDEOIO` — and `native/src/cv/video_loader.h` is
header-only and already takes the same `event_util::Sender` that `cli.cpp` hands it. What had to be
built is the *driver* around it — and it deliberately did **not** become a `NativeApi` entry point;
it lives in the Flutter runner, for a reason written out in
[The Windows path](#the-windows-path-end-to-end).

**The FFmpeg plugin DLL is bundled.** OpenCV decodes video through the runtime-loaded plugin
`opencv_videoio_ffmpeg4130_64.dll`. `native/CMakeLists.txt` copies it next to the CLI exe, and
`windows/runner/CMakeLists.txt` now copies it into the app output as well, on its own
`add_custom_command` rather than through `DEPENDENT_DLLS`, because it is the one DLL whose
destination *name* depends on the configuration: OpenCV's plugin loader asks for a name derived from
the `opencv_world` that loaded it, so a Debug build looks for `…_64d.dll`, and the vendored package
ships only the release-named file. The alternative — the built-in Media Foundation backend, zero extra bytes —
**cannot open Matroska**, which is OBS's default container and the format of this project's own test
clips under `.notes/`. Shipping only MSMF would make Windows narrower than web on the single most
likely input.

| | bytes | note |
| --- | ---: | --- |
| `opencv_videoio_ffmpeg4130_64.dll` | 28,578,304 | measured, `windows/opencv/build/x64/vc16/bin/` |
| bundled native DLLs today | ~80.7 MiB | `opencv_world4130.dll` + `onnxruntime.dll` + the CRT set |
| after | ~108 MiB | **+33.8 %**, uncompressed |

That growth is the accepted cost of decision 4. Licensing is already solved and disclosed:
`windows/opencv/build/etc/licenses/ffmpeg-readme.txt` is in the tree and documents the LGPL plugin
arrangement, and `tool/fetch_deps.py` already provisions BtbN LGPL FFmpeg for the CLI.

**The residual gap that cannot be closed.** Even with the plugin bundled, coverage is not identical:
HEVC availability on web is per-browser (broadly available in Chrome, nearly absent in Firefox's
WebCodecs), while the Windows FFmpeg backend handles it broadly. A phone recording in HEVC may
import on Windows and be refused on Firefox. This is a property of the browser, not of the design;
the mitigation is the codec pre-flight above, so the refusal is stated up front rather than
discovered mid-import.

## The producer contract

Video import is an **offline producer** under `.claude/rules/platform-parity.md`, the sibling of the
CLI's `VideoLoader` and `Ffv1Reader`. That fixes three things and they are not negotiable.

**Full frames, default anchor, no pane snapshot.** The rule states the offline contract verbatim:
the offline producers "query nothing: they emit the full decoded frame with the default anchor and
**no pane snapshot**", and `DetailCropTracker::beginFrame` applies the latched pane on the consumer
side for any frame that carries no snapshot. An import runs on a thread that is not the distributor
thread — the same concurrency situation `video_loader.h`'s class comment describes — so a producer
that shaped frames would lose a scheduling-dependent number of them.

**Therefore it must not reuse the live push entry point.** `pushFrameRgba`
(`native/wasm/wasm_api.cpp`) takes nine arguments including an opaque pane-snapshot token, and it
*rejects* a frame whose token is invalid or whose buffer disagrees with the re-derived copy plan.
That export was required and **now exists**: `pushOfflineFrame` is the snapshot-free offline entry
point, and it takes the frame in the decoder's *own* pixel format (`"I420"` / `"NV12"` / `"RGBA"`)
rather than as RGBA, so the YUV→RGB matrix is chosen in the core — see
[Colour](#colour-two-decoders-one-recognition-result) for why that turned out to be the deciding
detail. (`pushFramePng` also qualifies semantically — full frame, no snapshot — but costs a PNG
encode per frame in JS.)

**Two things about that export were added after this section was first written, and both moved a
decision out of JavaScript into the core.** It takes a **seventh argument**, the `PlaneLayout[]`
that `VideoFrame.copyTo` *resolved to* — the caller does not choose the layout, and a copy that
merely places Cr before Cb occupies exactly the same number of bytes as the one the conversion is
about to read, so a byte length cannot see it and the frame would be assembled out of the wrong
planes into a plausible picture. The rule is now stated once as data (`color::tightlyPackedLayout`)
and judged once (`refuseUnreadableLayout` in `native/wasm/wasm_api.cpp`), shared with the error
report's `encodeDecodedFramePng`; the JS re-statement `web/video_import.mjs` used to carry
(`expectedLayout` / `assertTightlyPacked`) is deleted, because one rule with two implementations had
only one of them reading the pixels. And it **returns a verdict rather than a boolean** — the copy
is unreadable, the frame was not accepted, or the frame is in the pipeline — because the caller has
to tell two "not supplied" outcomes apart: an unreadable layout means this build and the user agent
disagree about the copy API, so every remaining frame will fail identically and the import should
stop and say so, while the others are about one frame and leave the import running.

**On Windows the same contract is met without a new entry point, and that asymmetry is a property of
the two front ends' transports rather than a decision.** Web's live push crosses the wasm boundary as
nine loose arguments including an opaque pane-snapshot token, so "no snapshot" needs an export that
does not take one. Windows hands the core a `Frame` object: `NativeApi::updateFrame(frame,
original_size)` is the one entry both of its producers use, and what distinguishes them is what the
`Frame` carries — `windows/runner/window_capturer.h` resolves a pane and carries the snapshot it
resolved, while `native/src/cv/video_loader.h` emits the full decoded frame with the default anchor
and no snapshot, exactly as the CLI's offline producers do (it *is* one of them). The import session
therefore reaches the pipeline through `VideoLoader` unmodified, and `DetailCropTracker::beginFrame`
applies the latched pane on the consumer side, as the rule requires. Read off the code; not exercised
by a run here.

**And it needs a new export *name*.** The worker's compatibility guard is
`if (typeof Module.startCaptureSession !== 'function')` (`web/worker.js`, in
`startCaptureSessionVerdict` — which now tests `startCaptureSessionOfKind` first), which catches a
*missing* export and cannot catch a *changed signature*. Adding a parameter to an existing embind
export would pass the guard against an older pinned `web/wasm/` artifact and then fail — or coerce —
at call time. Give every kind-taking or shape-changing entry point a new name and keep the `typeof`
guard on the new name; that preserves the existing fail-closed behaviour for free.

**Frames carry media time, not arrival time.** Every gate in the pipeline advances on
`Frame::timestamp()` — scene-begin dwell 200 ms, scene-end debounce 1000 ms, the switch/reset
monitors' 250 ms, `StationaryFrameCatcher`'s 200 ms — and `web/worker.js`'s monotonic frame-clock
comment states the invariant from the JS side: no stage counts frames. The live path deliberately re-stamps with
`performance.now()` because Firefox reports `timestamp === 0` for a `VideoFrame` built from a
`<video>`; **the import must opt out of that re-stamping.** With arrival-time stamps a
faster-than-realtime feed compresses those dwells toward zero, so nothing is ever judged stationary
and no scene ever ends. Windows gets this right already: `video_loader.h` stamps `CAP_PROP_POS_MSEC`
through the shared `media::MonotonicMediaClock` (`cv/media_timestamp.h`), which the browser import
uses too; both carry the comment explaining why a clip whose every frame reports 0 is unsupported
rather than worked around, for precisely this reason. The removed web implementation got it right too
(`Math.round(sample.timestamp * 1000)`).

Also unchanged from the rule: `NativeApi::updateFrame(frame, original_size)` receives the **decoded**
size, exactly as `video_loader.h` does (`captured_size = mat.size()`), or the latch oscillates.

## The Windows path, end to end

Written at the same grain as the web path above, and against the code named in each paragraph.
**Provenance warning: none of it has been exercised by a run on the machine this section was written
on.** The stage that produced it was a documentation pass; no app was built, no clip imported, no DLL
listed in an output directory. Every claim below is read off a source file that is named beside it,
and the ones that can only be settled by running are marked *unverified* where they appear. The
on-device stage is what closes them.

### The driver lives in the runner, and `NativeApi` gained no import entry point

`native/src/cv/video_loader.h` is the only thing in the tree that can open a container, and it
reaches OpenCV's videoio — and, for the CLI's `--color_matrix` diagnostic, libav. `native_api.cpp` is
compiled into **both** the wasm build and `windows/runner`, and neither links libav, so an import
entry point on `NativeApi` would break both. Two consequences:

* **The libav planar backend is now behind `UMACAPTURE_WITH_PLANAR_DECODER`**, defined by
  `native/CMakeLists.txt` on the CLI target alone. `video_loader.h` includes
  `planar_video_decoder.h` and compiles `runPlanar` only under that switch; asking for a diagnostic
  matrix in a build without it throws by name rather than failing to link.
* **The driver is `windows/runner/video_import_session.h`**, per front end, exactly as
  `web/video_import.mjs` is web's. What the driver *drives* — the session claim, the pipeline, the
  notify payloads — is shared core. That is the same split the parity rule asks for: the divergence
  is forced by "the wasm build cannot link a demuxer", and it is stated in the class comment.

`VideoLoader` itself gained one optional argument, `std::optional<OfflineRunHost>`, holding a cancel
predicate, an `on_opened(duration_ms)` and an `on_decoded(count, media_ts_ms)`. It is defaulted, so
`cli.cpp` is untouched and `run` / `runBatch` keep their signatures. The predicate is named
`is_cancelled` to match web's `host.isCancelled()` — same concept, same name.

One import run, in order (`VideoImportSession::start` / `run`):

1. Four refusals are made **before the core is asked anything**: already importing, a live capture is
   running, no config has arrived yet, the path does not exist. Each becomes the single terminal
   `videoImportDone` that request gets.
2. A dedicated single-thread runner (`QueueLimitMode::Block`) is built, and its listener calls
   `NativeApi::updateFrame(frame, size)`. **That call's boolean return is the only source of the
   `supplied` / `rejected` counts** — an offline producer that ignores it would report frames the
   pipeline never took.
3. `NativeApi::startCaptureSession(CaptureSessionKind::VideoImport, native_config)`. The config is
   forwarded **verbatim**; the kind is what makes the pipeline `video_mode`, and what makes a
   cross-kind start `Refused` under the core's own mutex.
4. **The container is probed for a video track before a single frame is read** — `cv::VideoCapture`
   is opened and asked for `CAP_PROP_FRAME_WIDTH` / `_HEIGHT`, which is container metadata the
   backend already parsed and answers in well under a millisecond. A non-positive size ends the run
   as `no_video_track` with no decode at all. `grab()` / `read()` are deliberately **not** used as
   the probe: on an audio-only MP4 the FFmpeg backend refuses to open the file, MSMF opens it and
   reports 0 × 0, and a read on that capture never returns — measured with `cdb`, parked inside
   `CvCapture_MSMF::grabVideoFrame` waiting for a video sample that never arrives. Frame *size* and
   not frame *count*, because MSMF reports `CAP_PROP_FRAME_COUNT` as −1 for a perfectly good
   Matroska clip.
5. Decoding runs on the session's own thread, so the caller's `capture_mutex` is released long before
   a minutes-long clip finishes.
6. The run ends on **the CLI's drain barrier** — `cli::offlineDrainBarrier` +
   `runUntilDrainedThenJoin`, including its 5-minute watchdog. The **removed** implementation's
   "≥1 finish and 4 s of native silence" terminator is not resurrected here, and web does not use it
   either: both front ends now end on an exact signal (web on the sample iterator's exhaustion plus
   the teardown's join, Windows on this barrier).
7. `endCaptureSession(CaptureSessionKind::VideoImport)` — by kind, always, so a run cannot release a
   claim it does not hold.
8. Exactly one `videoImportDone`, whatever ended it.

**Step 8 holds even when the run throws, and it takes an explicit boundary to make that true.**
`VideoImportSession::run` *is* the `std::thread` entry, so it has nothing to unwind into: an
exception that escapes it calls `std::terminate` and the process dies with the `VideoImport` claim
still held and the front end still waiting. Only the decode was ever guarded (`runLoader`), because
that is the one failure with a *named* outcome; the probe in step 4, the progress ticks, the drain
barrier of step 6 and the terminal notify itself all sat outside any `try`. The entry is therefore
split in two: `runBody` is the run, and `run` is nothing but the boundary around it, with the same
undo `start` already performs on a half-built start (`rollbackFailedStart`) — release the claim by
kind, join the import runner, join the core loop — followed by the one terminal `videoImportDone`,
reported as `failed` with no `reasonKind` because nothing predicted it. Every teardown step is
individually guarded, so a second throw cannot skip the notify the front end is blocked on. **Exactly
once** is exact rather than best-effort: the "already published" flag is set only after
`notifyVideoImportDone` *returns*, and `NativeApi::notify` swallows anything the notify callback
throws, so a throw out of that call can only have come from building the payload — i.e. from before
anything was published.

**Shutdown is bounded, but only over the decode.** `VideoImportSession::shutdown` waits at most
5 s for the *decode call itself* to answer the cancel and then abandons (detaches) the thread,
because that call is the one part of a run with no bound of its own — a decoder that never returns
previously left a process that survived its own window and needed `taskkill`. Everything after the
decode is bounded by construction (the drain barrier's own watchdog) and is still waited out in
full, so a healthy shutdown is joined exactly as before. When a thread *is* abandoned,
`NativeController` **leaks the session on purpose** (it is held by `unique_ptr` for that reason):
the process is exiting, so the memory goes with it, while destroying an object a live thread still
writes to would not be safe. The probe in step 4 removes the one cause of this that is known and
named; the grace is the insurance for the ones that are not.

### The wire: three payloads on the queue that already existed

**Dart → native**, on the existing method channel, argument as a JSON string because the runner's
dispatcher reads every argument as a `std::string`:

| method | argument |
| --- | --- |
| `startVideoImport` | `{"path":"<utf8 absolute path>"}` |
| `cancelVideoImport` | none |

Both are `static` on `PlatformChannel`, outside the instance surface every cross-platform
`Dart → native` method belongs to, and the
comment at the site says why: the caller is the `video_import.dart` facade, which owns no
`PlatformChannel` instance, and constructing a second one would re-register the method-call handler
and take every `notify` away from `PlatformController`. It also keeps the two out of the
cross-platform instance surface that `platform_channel.dart` declares — web's `PlatformChannel` has
no import method at all, because a browser import never touches the channel. They were the first
members to sit outside that surface and they are **no longer the only ones**: a later, Windows-only
feature added statics of its own on the same argument, so read this as the rule the exception
follows rather than as a roster of which members are static.

**native → Dart**: `videoImportStarted`, `videoImportProgress`, `videoImportDone`, built in
`native/src/core/native_api_messages.h` and published from `NativeApi`. Three things about them are
deliberate:

* **They ride the existing `notify` FIFO, not a queue of their own.** Their ordering against
  `onCharaDetailFinished` is load-bearing: it is what puts the merge of an import's last record
  strictly before the import is told it ended. `windows/runner/platform_channel.h` states that the
  only cross-queue guarantee is "notify first", so a second queue would forfeit exactly this.
* **The type tags carry no `on` prefix and the payload keys are camelCase**, against this file's
  habits, because they are web's tags and web's keys copied verbatim. One protocol, dispatched on one
  set of strings.
* **`matrixConverted` is always `""` on Windows.** The core decodes and converts the clip itself, so
  no third party converted it behind the app's back the way a browser's decoder can. The field is
  kept rather than dropped so Dart can still tell "this build does not report conversions" from
  "nothing was converted".

On the Dart side the three cases in `PlatformController.handleNativeMessage` forward the decoded map
to a **sixth facade member**, `videoImportHandleNativeEvent`. Web's implementation is a no-op, and
that is not a gap: on web those three messages are consumed by `WasmWorkerClient` on the worker port
before the relay that feeds `handleNativeMessage` ever sees them.

`video_import_io.dart` reuses `VideoImportSlots` from `wasm_worker_ops.dart` — VM-pure, despite the
file's name — so both front ends get the same 120 s inactivity watchdog, the same tolerant parsing,
and the same rule that **the terminal outcome settles exactly once and always settles**. (The symbols
belong in `video_import_ops.dart`; moving them touches web files and is its own change.)

### Records: one marker, two transports

Windows writes records to the real file system, into the **same active root live capture uses**, and
announces each one on `onCharaDetailFinished`; the record store's existing capture listener merges
them synchronously, one at a time. Web cannot do that — its harvest sweeps the MEMFS active root
indiscriminately, so an import has to be scoped to a `storage_dir` of its own and its records reach
the store in batches on `onLiveRecordsHarvested`. **That transport difference is forced. The intent
marker is not, and it does not diverge:**

* `onCharaDetailFinished` carries an optional `origin` field whose value is `'video_import'` —
  the same string, from the same vocabulary, that web puts on `onLiveRecordsHarvested.origin`
  (`harvestOriginVideoImport` in `lib/src/core/video_import_ops.dart`).
* **Absence means live**, on both routes. The exceptional, silent case is the one that is marked, so
  a message that loses the field costs an import one extra chime and never costs a live capture a
  missing one.
* **The core derives it from the open session**, in `NativeApi::notifyCharaDetailFinished`, rather
  than taking it from the three call sites — those are pipeline wiring with no idea who asked for the
  capture, while `CaptureSessionPolicy` already holds the fact. Because it is derived in shared code,
  **the wasm build emits the same field with the same meaning**; a record regeneration owns no
  session and therefore reports no origin, which is correct.
* Dart threads it through `_charaDetailRecordCapturedEvent` → `CharaDetailRecordStorage.addFromFile`
  → `add(notifyDuplicate:)`, so **the duplicate chime is suppressed at its source** rather than by a
  window gate. `CapturedRecordRetention` stores the origin alongside each pending id, so a record
  drained after a store rebuild — i.e. merged later than it was announced, which is exactly the case
  the marker exists for — still merges silently.

The state-derived mute in `NotificationLayer._playSound` **stays** as defence in depth; it was not
removed.

`storage_dir` is deliberately **not** scoped for a Windows import. Web's scoping defends its
indiscriminate sweep; Windows has no sweep, and both `addFromFile` and `addFromFileAsync` read
`rootDirectory / id`, so a split root would guarantee "file not found" unless a file-moving layer
were invented for a hazard that does not exist here.

### Refusal kinds, and which of them Windows can reach

`VideoImportReason` is one enum for both front ends. What differs is reachability, and each case's
own doc comment says so.

| kind | Windows | how |
| --- | --- | --- |
| `notAVideo` | reachable | `VideoLoader` throws its one open failure and the FFmpeg backend is present |
| `noVideoTrack` | reachable, **measured** | the container opened and declares a non-positive frame size (`CAP_PROP_FRAME_WIDTH` / `_HEIGHT`), read **before any decode**. A second, weaker net behind it still catches "opened, decoded nothing, declared no frame count either" |
| `codecUnsupported` | reachable, **weak** | opened, declared frames, decoded none. OpenCV exposes no track list and no decoder error, so neither of these two can be established strictly; both degrade to a sentence about the clip |
| `decoderUnavailable` | reachable, meaning reused | the open failed and `videoio_registry` reports no `CAP_FFMPEG` backend, i.e. the plugin DLL is not loadable. *Unverified at runtime:* whether `hasBackend` really answers false when the DLL is absent |
| `workerNotReady` | reachable, meaning reused | a start that arrived before any `setConfig` |
| `alreadyImporting` | reachable | the session's own flag, before the core is asked |
| `captureInFlight` | reachable | the runner's live-producer check, before the core is asked — kept out of the core's `Refused`, which would otherwise be indistinguishable from a pipeline build failure |
| `regenerationInFlight` | reachable | Dart preflight only, exactly as on web; the core cannot judge it |
| `neverStarted` | reachable | `invokeMethod` threw |
| `stalled` | reachable | the shared `VideoImportSlots` watchdog |
| `noRecords` | reachable | not refused by any driver at all: the shared core reclassifies a `completed` verdict carrying `records: 0` into this (`messages::videoImportVerdictOf`), so every front end reaches it identically and none of them decides it |
| `fileUnreadable` | **Windows-only** | see below |
| `pixelFormatUnsupported` | **unreachable** | `cv::VideoCapture` yields BGR 8UC3, so no format is left to refuse |
| `coreOutdated` | **unreachable** | the core is statically linked; there is no pinned artefact to be stale against |
| `unbraked` | **unreachable** | the wasm flow gate is what can lose its brake; Windows' brake is the `Block` queue itself |

**One kind was added: `fileUnreadable` (`'file_unreadable'`).** Web's picker hands the worker a live
`File` handle, so nothing is left to resolve after the dialog closes. Windows crosses the channel with
a *path*, which is a name and not a handle: the file can be moved, renamed, deleted or unplugged in
that window. The session checks it before the core is asked for anything, so this is always a refusal
and never a half-started import.

**That path is UTF-8 the whole way, and it has to be asked for explicitly.** The channel carries
UTF-8, `std::filesystem::u8path` turns it into a wide path, and `exists()` therefore answers about the
real file — but `cv::VideoCapture::open` takes no wide overload, and MSVC's narrow accessors
(`path::string()`, `path::generic_string()`) convert through the system ANSI code page and **throw**
`filesystem_error` for anything the ACP cannot represent. Under ACP 932 that is an ordinary Hangul or
emoji folder name, and the throw was on the import thread, whose entry did not then wrap
`probeVideoTrack` at all — so it reached `std::terminate` and killed the app rather than refusing the
clip. (The entry is an exception boundary now, so the same throw would end as a reported `failed`;
the conversion below is still what makes such a folder *import* rather than merely fail politely.)
`video::capturePathString` (`native/src/cv/video_loader.h`) is the one conversion both the probe and
`VideoLoader::runCapture` now go through: ACP first so that no path which works today changes
backend, UTF-8 only when that throws. Measured under
`.notes/analysis/video-import-windows-parity/acp-probe/`: FFmpeg opens either encoding (its
`win32_open` tries UTF-8 and falls back to ACP), while MSMF widens the bytes naively and accepts only
ASCII or ACP. **The residue**: MSMF is what opens an audio-only MP4 and reports 0 × 0, so under a
name the ACP cannot represent that clip fails to open at all and is refused as `not_a_video` instead
of `no_video_track` — a weaker sentence about the same file, never a wrong one.

The **Japanese wording** of the reused kinds was made platform-neutral rather than duplicated per
platform, which is a knowingly accepted loss of web-specific advice. Every kind that is reachable on
both front ends now names the state and the retry and mentions neither a browser nor a window:
`stalled`, `worker_not_ready` and `decoder_unavailable` (the last of which dropped its «check your
connection» hint, meaningless against a missing plugin DLL). The two lines that still say «reload the
page» are `core_outdated` and `unbraked`, and both are **unreachable on Windows** by the table above,
so the browser wording is correct where it is shown; `unsupported` is likewise a browser-only blocker.

### The file picker

`FilePicker.pickFile` (`package:file_picker`), single selection, `lockParentWindow: true`, filtered
to the container list in `lib/src/core/video_file_dialog_ops.dart`. **That list is not duplicated
per front end: it is one `const` that the browser's `<input accept>` is *derived* from**, so the two
dialogs cannot disagree about which of the user's files the app will open. (When this section was
first written each front end wrote its own list out and the design asked only that they match — a
correct-until-the-next-container arrangement whose omissions are silent, since nothing fails to
compile and no test that does not already know the answer can notice. The dialogs themselves now
live in `video_file_dialog_io.dart` / `video_file_dialog_web.dart` rather than inside the import
legs, because the video-import error report opens the same dialog for the same reason.)

`pickFile` rather
than `pickFiles` because the latter's `allowMultiple` **defaults to true**, which the Windows backend
turns into `OFN_ALLOWMULTISELECT`: a user could rubber-band a folder of recordings and the caller
would silently import the first. `pickFile` also pins `withData: false`.

**`readAsBytes()` is never called, and must never be.** That is the same measurement web's bare
`<input type=file>` choice rests on: a screen recording is routinely gigabytes, so whichever layer
materialises the file is the layer that runs out of memory. Only the path crosses the channel, and
the file is opened exactly once, by `cv::VideoCapture` inside the runner. A dismissed dialog returns
null and the import returns silently to idle, matching web; a dialog that *throws* ends as a failed
import rather than silently, because on Windows the dialog is a plugin (a platform instance that may
not be registered, an isolate, a `comdlg32.dll` lookup) and a silent return would render as a button
that does nothing at all.

### Preview, chimes and UI need no Windows branch

`listenCapturePreview` is platform-agnostic and keys off the import state alone: it opens the
preview's session gate for an import and pushes `cropped = false`, because an offline producer's
frames carry no pane snapshot on either platform. The capture card, the two-state import button, the
merged status block and the per-character tile are all shared widgets that light up as soon as
`videoImportAvailable` is true. *Unverified:* how any of this looks in the running Windows app.

### Stopping: the two front ends choose differently, and the constraint is real

* **Web aborts the import and lets it end normally.** `handleStopLive` calls
  `stopVideoImportProducer('stopLive')` before joining. It has little choice: there is one wasm
  module, and its teardown (`Module.stop()`) joins the whole pipeline, so a producer still pushing
  into it is precisely the race the teardown discipline exists to prevent. Revoking the import is the
  only way to make the join safe.
* **Windows refuses the stop and lets the import continue.** `NativeController::doStopCapture`
  answers `notifyCaptureStopped()` without joining the event loop when an import is running and the
  live producer is not. It can, because the two producers are separate objects: a stop that owns no
  live producer has nothing of its own to stop, and the teardown it would otherwise perform
  (`cli::liveDrainBarrier` joins the loop unconditionally, consulting no claim) is pure collateral
  damage against a pipeline the import is still feeding. Should a live session genuinely be running
  as well, the condition is false and the stop takes its ordinary path — a live capture stays
  stoppable under every circumstance.

The guard is in the runner rather than in a disabled button on purpose: "an import owns the pipeline"
is a fact the process holds, and the handler is reachable from more than the UI.

### What Windows does *not* fix

* **An import started during a record regeneration still discards that regeneration's work**, and it
  is guarded by the Dart preflight alone — on both platforms. The core cannot refuse on the batch's
  behalf: `NativeApi::updateRecord` is fire-and-forget with no completion tracking, and a *batch* is
  a Dart concept in the first place. The preflight is therefore evaluated twice, the second time
  immediately before the path is posted, because a batch can auto-start while the file dialog is open.
* ~~**The "ate every frame, produced zero records" failsafe is still unimplemented**~~ — **closed
  since, in the core, for every front end.** What Windows added at the time was narrower and did not
  close it: a run that decoded *no* frame at all is named (`no_video_track` / `codec_unsupported`)
  instead of reported as a completed import of nothing. The remaining case — decoded every frame,
  produced no record — is now classified by `messages::videoImportVerdictOf`
  (`native/src/core/native_api_messages.h`), which rewrites a `completed` verdict carrying
  `records: 0` into `refused` + `reasonKind: "no_records"` before the payload is built. See
  [Left over from the colour work](#left-over-from-the-colour-work).

## Colour: two decoders, one recognition result

Open question 3 — whether OpenCV/FFmpeg and a browser produce the same pixels, and whether
recognition cares — was measured, and both halves came back "no". What follows is the record of the
answer.

### Why the pixels differ

The CLI decodes through `cv::VideoCapture`, whose FFmpeg backend converts YUV to BGR with
**swscale**, and swscale uses **BT.601 limited range regardless of the stream's colour tags**. A
browser's decoder does not. The tempting one-liner — "the browser honours the stream's BT.709 tag" —
is **not what happens and must not be repeated**: every clip used in this work is *untagged*
(`color_space=unknown`, no `colr` box), and the browser reports `matrix: 'bt709'`,
`fullRange: false` for all of them anyway. It is a **default assumption for untagged content**, not
tag fidelity. The consequence is the same either way: two front ends read different numbers off the
same file.

The shift is roughly **7 mean / 37 max out of 255** over a frame, and about **−20 on G** at the very
pixels the pane calibrator gates on:

| clip | header probe, CLI (swscale BT.601) | same probe, browser (BT.709) |
| --- | ---: | ---: |
| 2326×1340 landscape two-pane | `(9, 194, 105)` | `(4, 176, 101)` |
| 738×1310 portrait | `(14, 219, 123)` | `(8, 199, 118)` |

`isHeaderGreen`'s floor was `g >= 180`. The landscape clip therefore latched no pane in a browser on
**all 374 of its frames** and reported **nothing**: probe columns returning `StartRejected` vote
`VoteOutcome::NoStart`, which becomes `DetailCropStatus::HeaderStart` — the same verdict as "no
dialog is on screen". The failure mode is a silent zero-record import, and that — not the colour
difference itself — is the defect.

### The strategy: tolerate the shift, but still ask for planes

**The goal is not to make the colours agree. It is to make recognition survive their disagreeing.**
Chasing byte equality was stopped here deliberately: the objective the user set is that *both* the
CLI and a differently-coloured decode of the same screen recognise correctly, so "the accepted colour
volume grew" is never the acceptance criterion — "the golden records did not move" is.

It is nevertheless a two-tier arrangement, because a shift not taken is a shift not tolerated:

1. **Ask for planes.** `web/video_import.mjs` configures the decoder with
   `hardwareAcceleration: 'prefer-software'`, so the browser hands back I420 where it can and the
   shared C++ conversion (`native/src/cv/decoded_frame_to_bgr.h`, BT.601, matching swscale to within one
   unit per channel — its limited-range luma ramp is deliberately coarsened, and the records are unmoved)
   is what produces the pixels. It is applied **uniformly on every environment**, desktop and Android
   alike, to keep one path rather than two. On Android it is also what makes planes reachable at all:
   on SOG04 / Chrome for Android 150 the default hardware path returns texture-backed `RGBA` and both
   `copyTo({format:'I420'})` and `copyTo({format:'NV12'})` fail with `NotSupportedError`, while
   `prefer-software` yields `I420` — and is **twice as fast** for this workload (decode + `copyTo`
   over 150 frames: 83.2 → 177.4 fps on the phone, 127.6 → 389.2 fps on desktop Chrome 151). An
   import reads every frame back to the CPU, so a hardware decoder's readback is the dominant cost.
2. **Take an already-converted RGB frame anyway, and say so.** When the browser refuses to hand back
   planes, `coreFormatOf` accepts `RGBA` / `RGBX` / `BGRA` / `BGRX` whatever matrix they came
   through, and returns a third value `matrixNote` (e.g. `BGRX through the bt709 colour matrix`) that
   is logged **once per import** and reported as `videoImportDone.matrixConverted`.

Tier 2 is the part that changed direction mid-flight, and the reasoning is worth keeping. The first
implementation gated RGB on `colorSpace.matrix === 'rgb'` and refused everything else by name, on the
argument that a silent import at the wrong colours is worse than a refusal. Two measurements killed
that:

* **The accepting branch was effectively dead, and the refusal was a functional regression.**
  `matrix === 'rgb'` was never observed from any engine. Desktop Firefox 153 returns `BGRX` with
  `matrix: 'bt709'` under **all three** `hardwareAcceleration` hints, so it went from importing
  (which it did before the format contract existed) to refusing every clip.
* **The colour difference does not change the records.** The dual-decode suite below requires one
  identical record set from BT.601 and BT.709 across every golden clip. Tolerating the shift is the
  point of this whole section, so refusing a shifted frame contradicts it.

So the decision (user's) is: **accept, let the widened predicates carry it, and settle it by
measurement.** If a real clip ever disagrees, the fix is the inverse 3×3 on the web side — not a
return to the refusal. Everything the core genuinely cannot read (4:2:2, 4:4:4, an opaque frame with
no format) is still refused **by name**, which beats a silent zero-record import.

### The three greens, re-sized against measurements

Three colour predicates gate the pane latch, and all three were sized against BT.601 footage only.
They were re-derived from measured pixels — 22 CLI runs, 11 clips × 2 matrices, dumping every
`calibrateDetailCrop` call's probe columns (survey under the gitignored
`.notes/analysis/video-import-colour/`).

| predicate | defined in | before | after |
| --- | --- | --- | --- |
| `isHeaderGreen` | `native/src/cv/detail_crop_calibrator.h` | `b <= 70 && g >= 180 && (g-b) >= 120` | `b ∈ [0,70]`, `g ∈ [125,255]`, `r ∈ [40,200]`, `(g-b) >= 100`, `(g-r) >= 40` |
| factor-tab heading (`factor_header`, `factor_end_green`) | `factorTabGreen()` | `r 83..173, g 177..255, b 0..65` | `r 70..190, g 150..255, b 0..85` |
| title banner (`header_color_range`) | `headerBannerGreen()` | `colorRange({139,221,13}, 44)` = `r 95..183, g 177..255, b 0..57` | `r 70..195, g 150..255, b 0..85` |

The two JSON boxes are **build outputs**: `assets/config/chara_detail/scene_scraper.json` is
generated from `native/tool/builder/chara_detail_scene_scraper_builder.h` by `umacapture_cli build`,
so the builder is what gets edited. Both were written as explicit per-channel `Range<Color>` bounds
rather than `colorRange(centre, delta)`, because the measurement is not symmetric about any centre.

**Why channel differences are the primary discriminator.** An absolute channel level is *precisely*
the quantity a YUV → RGB matrix change moves — about 20 units on G on these very pixels. Any
replacement floor would again be a number measured on one interpretation, so the floor was **removed
rather than lowered**. The measured role split confirms this was not merely aesthetic: `b <= 70` is
what **locates the boundary** (48 on the last header row against 91 on the first canvas row) and has
to stay tight; `g - b` and `g - r` are **landmark identity** tests. Sweeping the BT.601 goldens for
`(status, boundary row)` changes, any floor in [120, 170] produces the identical result the 180 floor
did, i.e. the floor had no discriminating power left — while widening `b` to 80 changes **331**
BT.601 header decisions and fails `integration_golden.player_standard_3`.

**Why an absolute range is nevertheless kept as insurance.** It is the repo's convention: of the 151
absolute `Range<Color>` entries in `assets/config`, **148 constrain all three channels** and none
constrains only some. With the floor gone, `isHeaderGreen` had become the loosest colour predicate in
the tree. So a deliberately loose box was restored on all three channels, sized to be **provably
passive** — checked against all **1,116,018** recorded probe pixels, it changes the verdict on none
of them. `b` gets no second, looser maximum, because `b <= 70` already *is* b's absolute maximum and
anything above it is unreachable dead code.

Each term's margin against the worst pixel actually measured:

| term | measured worst | limit | slack |
| --- | ---: | ---: | --- |
| `b <= 70` | 70 | 70 | **0 — by design**; this is the boundary locator, and its slack is 0–2 whatever value it takes |
| `g >= 125` | 169 | 125 | +44 |
| `r >= 40` | 100 | 40 | +60 |
| `r <= 200` | 142 | 200 | +58 |
| `g - r >= 40` | 52 | 40 | +12 (the matrix itself moves this term by only ~9: 61 BT.601 → 52 BT.709) |
| `g - b >= 100` | 115 | 100 | +15 (a browser's decode moved this term by 13 on those pixels: 8 the matrix, 4–5 its own rounding) |

`g - r` is what stops R from being ignored entirely. The original note said R's *absolute* range
overlaps the canvas and is not usable on its own — which is true and is all it said; the
*difference* is usable, because the header green stands as far above R as above B. An earlier claim
that a "load-bearing header pixel" `(63,185,222)` forbade any `g - r` floor was **wrong and has been
deleted**: that pixel is the gold "S" aptitude glyph, on a losing pane candidate, in a call that is
non-`Ok` either way. It is now pinned as a pixel the predicate must **reject**.

Accepted volume of `isHeaderGreen`, as a fraction of the RGB cube, across the whole edit:

**8.15 %** (original) → **10.94 %** (floor removed) → **7.01 %** (`g - r >= 40` added) → **5.24 %**
(absolute box added) → **5.73 %** (`g - b` 120 → 100). The shipped predicate is **narrower than the
one that caused the incident**, while accepting both interpretations. Over those same 22 runs the
relaxation admitted **no new start pixel anywhere**: the per-clip count of "this is not the dialog"
early-outs is unchanged, except on the landscape clip under BT.709, where 315 scans that *do* show
the dialog stop being turned away.

The other two greens were widened the same way. For the factor-tab heading the measured accepted
pixels are `b 0..59 / g 184..241 / r 114..145`, so the old box left only **+7 on the G floor and +6
on the B ceiling** — far under the ~20-unit matrix swing; the B ceiling stops at 85 because a
"greenish canvas" at B = 96 is what it has to stay clear of. For the title banner the union of both
matrices is `b 0..18 / g 187..235 / r 125..150`, leaving **+10 on the G floor**; it is the thickest
of the three because it is tested with `isAllIn` (every sample on the scan line must pass). What that
one must keep rejecting is the **white save snackbar** that covers the banner (R ≥ 231, G ≥ 229,
B ≥ 234): G overlaps and does nothing, R and B are the discriminating channels, and the new bounds
still leave 36 on R and 149 on B.

### Removing the floor was necessary and not sufficient: `g - b` 120 → 100

With the floor gone, the same landscape clip **still produced zero records** in a real desktop
Firefox 153 — and the exit had moved rather than gone. `isHeaderGreen` now *accepts* the header
(`Ok` on 311 of 345 scanned frames), but 120 cut the header's own bottom **transition** row.

**Every landscape row number below is stated in the corrected `_toppad` geometry**, matching
`detail_crop_calibrator.h`. The material was re-cut on 2026-08-18 (`native/test/README.md`, "the
`_toppad` correction"): its 30 rows of window-decoration padding had been at the *bottom*, which a
browser window share cannot produce, and were translated to the *top*. It is a pure vertical
translation at unchanged frame size, so every landscape row here is the originally measured one
**plus 30**, colours are untouched, and the solved scale is unchanged. Frame 100, all three probe
columns of the accepted pane candidate, transition row y = 124, with a nominal BT.709 conversion of
the same source pixels alongside:

| x | Firefox `(b,g,r)` | `g-b` | swscale BT.709 `(b,g,r)` | `g-b` | swscale BT.601 `(b,g,r)` | `g-b` |
| ---: | --- | ---: | --- | ---: | --- | ---: |
| 524 | `(56,173,120)` | **117** | `(50,171,119)` | 121 | `(55,184,123)` | 129 |
| 818 | `(57,172,117)` | **115** | `(51,171,116)` | **120** | `(56,184,120)` | 128 |
| 892 | `(56,173,120)` | **117** | `(50,171,119)` | 121 | `(55,184,123)` | 129 |

Three to five units short of 120 — and **neither "anti-aliasing" nor "BT.709" is the explanation**.
Both halves of the real one matter, because either alone sizes the limit wrongly.

**Why row 124 is soft: 4:2:0 chroma sharing, not an anti-aliased blend.** The source is `yuv420p`, so
luma rows 124 and 125 **share one chroma sample** — chroma row 62, `U=80 V=110`, midway between the
header's `U=58 V=102` and the canvas's `U=127 V=125` — while luma barely moves across row 124
(`Y = 143 → 147 → 170` on rows 123 / 124 / 125). Row 124 is header *luma* carrying *mixed chroma*,
which is why its G **sinks below both neighbours** (195 → **184** → 211) while B and R rise. A blend
of header and canvas cannot produce that: solving the blend fraction from B leaves a G residual of
−5.6 / −18.5 / **−20.8** on the three columns, where a real blend would ramp every channel
monotonically. Row 125 is the same shared chroma with the *canvas's* luma, i.e. a **bright green
rim** under the header (g = 210..212, *above* the header plateau's own 194..195) rather than canvas
at all; what stops the scan there is `b <= 70` against b = 81..85, exactly as the boundary-locator
note says.

**Why 120 was already lost: it had zero margin against an *ideal* BT.709.** swscale with
`in_color_matrix=bt709` reads **121 / 120 / 121** on that row, so x = 818 cleared the old limit by
exactly **0**. Firefox's decoder then rounds a further **4–5** off (117 / 115 / 117), and that is what
moved the row. The cause is therefore not the choice of BT.709: the matrix spent the entire budget,
and the rounding of whichever decoder implements it was always going to decide the verdict.

Every other term passes on that row (`b <= 70` by 13–14, `g - r` by 12–15, the absolute box passive)
and row 125 is green under none of the three interpretations (b = 81..85), so `b <= 70` was still
locating the boundary correctly; only this one term moved. The chain that turns that into nothing at
all is worth spelling out, because no stage of it reports an error:

`g - b` short on the transition row → **boundary reported at row 124 instead of 125** → the shifted
scan does not merely start a row higher, it solves a **different scale**: `header_y` drops by one
while `button_y` does not, so the landmark gap is 1152 rows instead of 1151 and
`scale = gap / (kButtonBoundaryY − kHeaderBoundaryY)` = **737.752** instead of 737.112. Hence
`top = header_y − kHeaderBoundaryY × scale` = **+28.778** instead of +29.861, under a client height
of 1312 instead of 1310 — and because `DetailCropCalibration::toRect` rounds origin and extent
independently, the candidate lands at top 29 / **bottom 1341 in a 1340-row frame**. →
`DetailCropTracker`'s containment gate `isCropInsideFrame` (`native/src/cv/detail_crop_tracker.h`)
refuses it on `rect.bottom() <= size.height()`, where the correct scan's bottom edge lands exactly on
1340 and is admitted by the half-open rule, on **310 of those 311 frames** → nothing latches →
`onCharaDetailStarted` never fires → **0 records, silently, again**. What arrives at the consumer is
a *shifted* frame, not a rejected one, which is exactly why nothing complained.

*Measured before the material was corrected* — i.e. with those 30 padding rows at the bottom instead
of the top — the same two scans read rows **94 / 95**, `top` came out at **−1.222** against ~0, and
the edge that rejected was `rect.top() >= 0`. The translation moves *which* edge catches it; that it
is caught at all is unchanged.

**100, not 117.** 117 is the largest limit at which that import recovers (118 still yields nothing) —
it is sized to the incident. 100 is sized to the mechanism: the browser's decode moves this term by 13
on those pixels (8 of it the matrix, 4–5 the decoder's own rounding on top of the matrix), so a limit
15 below the worst accepted browser pixel absorbs one further swing of the
size that caused the bug, where 110 would absorb 5. The price was swept the same way the floor was:
over the BT.601 goldens, **110 and 100 change no `calibrateDetailCrop` decision and 90 changes one**,
and since the accepted set only grows as the limit falls, that single sweep covers the whole interval
[100, 120].

### What the browsers actually do

Measured end to end through the production path (`prefer-software`, mediabunny `VideoSampleSink`),
importing four clips and diffing the resulting record against the baseline field by field
(`record_id`, `trainer_id`, `captured_date`, `recognizer_version` excluded as per-install metadata).

| engine | `sample.format` | reported `colorSpace` | result |
| --- | --- | --- | --- |
| Chrome 151, desktop | **I420** | primaries/transfer/**matrix** all `bt709`, `fullRange: false` | 4/4 clips **match** |
| Firefox 153, desktop | **BGRX** (identical under all three hints) | same, **matrix `bt709`** | 4/4 import; 3/4 matched, the landscape one needed `g - b` = 100 |
| Chrome for Android 150 (SOG04) | **I420** | same | 4/4 clips **match**, incl. the 2326×1340 landscape (374 frames, 25.1 s, no memory trouble) |

The clips are `player_standard.mp4`, `friend_standard.mp4`, a locally produced
`player_standard_4_rot90.mp4`, and the 2326×1340 landscape import (the browser survey ran against
`landscape_2pane_ps5.mp4`; the suite now names its geometry-corrected re-cut,
`landscape_2pane_ps5_toppad.mp4` — see `native/test/README.md`). Baselines are the committed
goldens, except the landscape one, whose baseline is `umacapture_cli video --color_matrix bt601`.
Chrome's hint behaviour: `prefer-software` → I420, `no-preference` / `prefer-hardware` → NV12, and
`copyTo({format:'I420'})` is a `NotSupportedError` on both desktop and Android. Removing the hint
altogether on Android returns `RGBA`, which is the counterfactual that proves the shipping code is
really asking for software decode; at the time it was measured, that counterfactual ended in a clean
refusal in 665 ms naming the format and the matrix, where the shipping code now accepts it with a
note instead.

**What these runs do and do not date from.** The Chrome and Android rows were re-confirmed after the
RGB-acceptance change (five consecutive Android runs, ten clips, all matching). **None of them was
re-run after `g - b` moved to 100**: that fix is pinned by replaying Firefox's own recorded frames
through the CLI, not by a fresh live import. Treat a live re-run on all three engines as owed.

> **`colorSpace.matrix` does not track the conversion the browser performed.** This is a trap, and
> the reason the fallback design has to be an unconditional inverse rather than a matrix-keyed one.
> Feeding Firefox 153 the *same* planes re-tagged BT.601 (`h264_metadata=matrix_coefficients=6`, no
> re-encode) makes it produce a record identical to the CLI BT.601 baseline, and moves its frame-0
> pixels to within max 3 of ffmpeg's BT.601 output — yet it **still reports `matrix: 'bt709'`**.
> Branching an inverse 3×3 on `colorSpace.matrix` would therefore double-convert that clip. (Against
> the untagged original, Firefox's frame 0 sits at mean |d| 0.87 / max 33 from ffmpeg BT.601 and mean
> |d| 0.49 / max 12 from BT.709 — i.e. it really is doing BT.709.)

## Session policy: a second session kind

The capture-session claim now lives in the shared core, not in `web/worker.js`:
`CaptureSessionPolicy` in `native/src/core/native_api.h`, reached through
`NativeApi::startCaptureSession` from both front ends. The three verdicts are `Started` /
`AlreadyStarted` / `Refused`.

**Both changes below have landed**; what follows is the record of why they were needed, not work
outstanding. The claim is typed (`CaptureSessionKind`), `startCaptureSession` adopts or rebuilds the
loop through `ensureCaptureLoop`, and the mode is derived from the kind rather than read off the
config (`videoModeOf`, the `video_mode_override` on `capturePipelineIdentity`). The claim state used
to be **one untyped `bool`**, with no notion of *who* held it, and two of its assumptions break with
a second kind (`session-policy-feasibility.md` §2):

* **"A second start is always a duplicate."** It was `if (active) return AlreadyStarted;`. With two
  kinds this is wrong *silently*: an import starting while live capture runs would be told
  `AlreadyStarted`, acknowledge success, and start pushing decoded frames into the live session's
  pipeline. Fix: type the claim (`enum class CaptureSessionKind { Live, VideoImport }`), same kind →
  `AlreadyStarted` unchanged, cross-kind → `Refused` with the mutual-exclusion message, which both
  front ends already relay. This makes live↔import exclusion a genuine core invariant enforced under
  one mutex on both platforms — strictly better than the old web-only JS backstop — and the existing
  `native/test/core/test_native_api_capture_session.cpp` covers it without building a pipeline.
* **"Any running loop is adoptable."** `NativeApi::startEventLoopReportingError`
  (`native/src/core/native_api.cpp`) is a warning-and-no-op while running and carries a
  pre-existing `TODO` saying the loop should be rebuilt when the config changes; `NativeApi` stores
  nothing about the config the running pipeline was built from. A video-mode loop is **not**
  equivalent to a live one, so `startCaptureSession` needs an `ensureLoopFor(kind, config)` step:
  running and matching → adopt, running and mismatching → tear down and rebuild, not running →
  start. This is the old JS `acquireSession`'s adopt/rebuild/start disposition, moved into the core
  where Windows compiles it too — which is what "share, don't port" asks for.

**One gate cannot move into the core.** Record regeneration is a deliberate *passenger* that takes
no session ownership, and `NativeApi::updateRecord` is fire-and-forget with no completion tracking,
so the core has no way to know a regeneration is in flight. Rebuilding the loop under one would tear
the pipeline out from under it. **It stayed outside**, in `resolveVideoImportBlocker`, with its
reason written there as the parity rule requires — and it is the same one gate on both platforms,
consulted twice on each (once before the file dialog opens, once immediately before the clip is
handed over, because a batch can auto-start while the dialog is open). The old code had exactly this
gate and documented a known hole: a
regeneration *batch* leaves its state null between records, so an import landing in the gap was not
refused.

### `video_mode` becomes derived, not sent

`video_mode` is a required top-level config key — `capturePipelineIdentity` (`native_api.h`) reads it
with `config.at("video_mode")`, which throws if it is absent — and it controls exactly two things,
both inside `NativeApi::startPipeline` (`native_api.cpp`):

| | site | effect |
| --- | --- | --- |
| queue limit mode | `queue_limit_mode` | `video_mode ? (NoLimit on wasm / Block on native) : Discard` |
| frame-stall watchdog | `frame_stall_watchdog` | created **only** when `video_mode` is false |

Nothing else branches on it — scroll estimation, scene transitions and dwell/debounce are all driven
by frame timestamps and content.

**The kind implies the mode, in the core.** `CaptureSessionKind::VideoImport` → `video_mode = true`
when the pipeline is built; Dart and JS keep sending exactly what they send today. The alternative —
a per-session config override on the front end — is literally `configWithVideoMode` coming back, and
re-splitting the session policy across two sides is the exact defect `b8614a97` removed. This also
opens the door to `video_mode` ceasing to be a required config key at all and becoming a derived
property; that step is optional.

The history here is the argument for it: `platform_channel_web.dart` once set `video_mode = true`
unconditionally, because import was originally web's *only* frame source. When live capture landed
this was never revisited, so **web live capture ran with no frame-stall watchdog and an unbounded
frame queue for weeks**. A globally pinned mode was a symptom of having only one session type.

### Restoring `video_mode=true` on web is not safe alone

On Emscripten the video branch is `QueueLimitMode::NoLimit` — never blocks, never drops — because
`Block` deadlocks against the MEMFS proxy queue on the module's host thread (the rationale is written
out in `NativeApi::startPipeline`). The old implementation's memory bound was a JS-side parking gate,
`awaitInflightRoom`, holding `forwarded - consumed` below `INFLIGHT_MAX = 8` against two atomic
counters exported from the core.

**Those counters and their exports were deleted in `b8614a97`** — nothing named
`noteFrameForwarded` / `noteFrameConsumed` / `forwardedCounterAddr` / `consumedCounterAddr` exists at
HEAD — so for the length of that branch `NoLimit` stood with no brake of any kind, and this section
was written to say that the two had to come back together or not at all.

**They did come back together.** The gate exists at HEAD as `FrameFlowCounters`
(`native/src/core/frame_flow_counters.h`), a process-lifetime pair the pipeline writes and the front
end reads; `native/wasm/wasm_api.cpp` publishes it to JS by address (`frameFlowEnqueuedAddress` /
`frameFlowDequeuedAddress`); and `web/worker.js` parks the offline producer on `Atomics.waitAsync`
while the resident frame count is at or above `OFFLINE_INFLIGHT_MAX = 8`. A front end that cannot
find those exports **refuses the session** rather than running it unbraked
(`startCaptureSessionVerdict`). The queue mode and the brake are still one decision: deleting either
half re-enters an unbounded, never-dropping queue.

Three details of the rebuild, each answering a defect of the old pair:

* **It counts both frame-path hops, not the scraper's alone.** The difference is the depth of the
  distributor's queue *plus* the scraper's, because both hold whole decoded frames alive. A pair that
  counted only the scraper's hop would read exactly 0 through the entire lead-in, while a hardware
  decoder piled multi-megabyte frames onto the distributor's queue.
* **Only accepted enqueues are counted, and the pair is reset at every teardown**
  (`NativeApi::teardownLocked`, after the runners are joined). The old counters leaked across
  sessions — frames left queued at teardown were never counted as consumed, and the residue
  accumulated until live capture rejected every frame and `awaitInflightRoom` spun forever. The reset
  now sits on every path that destroys a pipeline, on every platform, rather than in the one web
  export that remembered it.
* **It is not `#ifdef`'d to Emscripten.** A hook only web compiles is a hook no native test can
  cover, which is exactly how the previous pair came to be deleted for having "no reader anywhere".

Per `decode-ab-comparison.md` §3.3, `setTimeout`/`setInterval` stay out of the decode loop —
documented background throttling is described entirely in terms of timer wake-ups. The old parking
gate's `await sleep(2)` fallback has accordingly been replaced by `Atomics.waitAsync`, whose timeout
is a safety net against a missed wake rather than a poll interval: every dequeue and every teardown
wakes the address.

### Close the `stopLiveProducer` release window first

`stopLiveProducer` (`web/worker.js`) released the core claim **before** the in-flight frame was
awaited and before `flushHarvestStopped()` called `Module.stop()` and harvested MEMFS.
`self.onmessage` is `async` and explicitly not serialized (the worker documents this at
`configSeqCounter`), so during that window the
core reported no active session while the previous session's pipeline was still up and its records
were still unharvested.

At the time the blast radius was small — the only claimant was `startLive`, and the UI gated it.
**With a second kind it becomes actively harmful**: an import landing in the window gets `Started` rather than
the new cross-kind `Refused`, and because it needs the other queue mode, `ensureLoopFor` would tear
the pipeline down and rebuild it while the live session's just-written records are still sitting in
MEMFS. Windows has no equivalent window: `doStartCapture` and `joinEventLoop` both take
`capture_mutex`, and `endCaptureSession()` is inside the same critical section as the teardown.

**Landed, before the second kind existed.** `stopLiveProducer` conflated two jobs; the real supply
barrier is the worker-local `sessionOwner` (every supply path tests it), not the core claim. The
local owner is nulled first, and `Module.endCaptureSession()` moved to the end of
`flushHarvestStopped`, after the join and the harvest — which `stopVideoImportProducer` now states as
the rule it follows too. `releaseSession` is idempotent.

## Harvesting is isolated by construction

The old implementation's worst incident was not in the decode path. `handleUpdateRecord` left a
record regeneration's MEMFS staging under `/work/storage/chara_detail/active/<id>`; the
batch-ending teardown that normally removed it is skipped while a session runs; and
`harvestAndCleanup()`'s **indiscriminate sweep of that whole active root** — the legitimate exit for
both live and import — then wrote the entire batch back into OPFS as if the session had captured it.
Concretely: deleted records resurrected, `record.json` rewound to pre-regeneration bytes, archived
records restored into the active store. It was fixed at the source (`5678cf84`), but the sweep itself
was left unchanged, so **the hazard is a property of the harvest model and returns with any new
harvest-based import**.

**A UI gate is not the answer and was explicitly rejected as insufficient.** A disabled button is a
UX affordance; it cannot make a sweep pick up only what the session produced.

The mechanism is already there: `directory.storage_dir` is a per-pipeline-start config key
(`NativeApi::startPipeline` derives `stitcher_dir` = `storage_dir/chara_detail/active` from it). An import
session therefore points the core at a **storage root scoped to that import**, and the sweep — which
can stay as indiscriminate as it is — physically cannot see anything the import did not write.
Records move from there into the real store through the existing merge path.

**This is web's rule, and Windows deliberately does not follow it.** Windows writes to a real file
system and has no sweep at all, so there is nothing for a scoped root to defend against — while
splitting the root there would actively break the merge, because both `addFromFile` and
`addFromFileAsync` resolve `rootDirectory / id` against the real active directory. A Windows import
therefore shares live capture's active root and is picked up per record by the store's existing
capture listener. See [The Windows path](#the-windows-path-end-to-end).

**What is reusable, unchanged, at HEAD**: `harvestAndCleanup` and the `harvest`/`stopped` protocol;
`persistPlatformHarvestToOpfs` / `WebRecordPersistence` and the per-record mutation lock;
`parseHarvestedRecordFiles`; and the incremental merge `addFromFileAsync` + `quarantineAsyncUnlocked`,
which live capture already uses. The reintroduction does not rebuild any of it.

## What the pipeline needs from a frame stream

Worth stating because it bounds how much a decode path is allowed to get wrong.

**Nothing in `native/src/` counts frames.** The only adjacency dependency is the scroll offset
estimator's minimum overlap: `overlap_height < minimum_overlap_fraction * height` returns 0 for every
candidate, with `minimum_overlap_fraction = 0.10`
(`ImageOffsetEstimatorConfig` in `chara_detail_scene_scraper.h`; the test is in
`ImageOffsetEstimator::overlapScore`). Past that, `estimate()` returns `nullopt`,
`previous_descriptor` freezes, the anchor stays pinned to content the screen has moved away from, and
nothing re-matches. The tab never reaches `scrollAreaReady()`, and the session is announced as
incomplete when it ends — `closed_before_completed`, whether the detail screen closed inside the clip
or the clip simply ran out with the screen still on it. **One tag covers every ending on purpose.**
The scene end carries no reason: the scraper's `on_closed` listener sends the incomplete-session
event whenever the session was not `ready()` (`chara_detail_scene_scraper.cpp`), and
`native_api.cpp`'s `closed_before_completed_connection` turns that into the single `onError` tag.

**This failure is loud, not silent** — the user sees a capture failure, not a subtly wrong record.
**It was only conditionally loud when this was written, and the condition was the clip, not the front
end.** Only the first of the two endings above was reported for an offline producer: the
frame-timestamp scene-end debounce cannot advance once frames stop arriving, and the stall watchdog
that would otherwise close the scene is built in live mode only (`native_api.cpp`, guarded on
`video_mode`). A clip that ran past the overlap cliff and then simply ended left the session hanging
and emitted nothing at all. `NativeApi::endOfInput()` is what closes that hole — every offline
producer reports the end of its input, and the scene is closed through the same `SceneContext::onIdle`
path the live watchdog drives, producing the same tag — so the statement now holds for both endings
rather than for the clips that happen to return to the list screen. A run that ends with no record
*at all* is additionally reclassified as `refused` / `no_records` instead of as a completion.

That is what makes the measured shed budget usable: a decimation replay with PTS preserved was
byte-identical to the golden up to 1/6 (83 % shed) and failed at 1/8 (87.5 %), and the cliff is the
overlap gate itself. The cliff also **moves with scroll speed**, so a fast flick raises the required
delivery fraction.

The one place where shedding is *not* obviously free: `StationaryFrameCatcher` compares each
delivered frame with the previous delivered one over a millisecond window, so fewer frames means
fewer chances to observe a difference — producing *false stillness* and a degraded base image rather
than a deadlock. That is a silent defect class, and it is an argument for a producer that delivers
every frame rather than one that samples.

## The front end: one card, one control row

The import has **no card and no section of its own.** It is the second way records enter the app, it
drives the same recognition pipeline as live capture, and the two are mutually exclusive — so a
second card asked the user to look in two places for one pipeline's state, and made "which of these
is running?" a question with two answers on screen at once. Everything the import *offers* and
everything it *says* now lives inside the capture control card (`lib/src/gui/capture.dart`,
`lib/src/gui/video_import.dart`). The old explanatory description went with the card. Both halves
render **nothing at all** where the front end has no import path — which now means every target
except web and Windows, since `video_import_io.dart` answers `Platform.isWindows` and the stub
answers a constant false — so such a page is unchanged rather than one empty row longer.

**The control row is the first thing in the card**, and the notices come after it. It holds the two
ways to feed the recognizer side by side: the capture start/stop toggle, and the import's own
two-state button — 「動画ファイルを選択」 while nothing is running, 「中止」 while an import is. One
place to press, in both directions; the cancel fires immediately, with no confirmation step, because
it destroys nothing (the records already recognized are kept, and the rest is recovered by picking
the same file again).

The row's position is not cosmetic. **Nothing that can appear or vanish on its own may sit above a
control the user is aiming at.** The import-blocking notice is exactly that: it arrives when an
import starts and is withdrawn the instant it settles, and it is about 52 px tall. Above the row,
every ending would shift it up by that much. Below the row, the notice's arrival and withdrawal can
only move inert text.

The same principle now also covers the two "something went wrong" links
(the `_ErrorReportLinks` widget, `lib/src/gui/capture.dart`): they sit directly under the control row
and *above* both notices, so a notice's arrival or withdrawal moves only the inert text and the
capability chips beneath it, never the links. They did not start there — they used to live below the
first divider, inside the capability-chip row, where a notice's toggle *did* shift them; one of them
opens a screen-share permission request, so a click aimed at 「中止」 could land on 「キャプチャエラー
報告」 instead the instant an import ended and the layout above it collapsed by that same 52 px. Moving
the links above the notices, in `CaptureControlGroup.build` (`lib/src/gui/capture.dart`), closed that
the same way the control row's own position closes it for itself, and
`test/capture_report_link_order_test.dart` now measures it directly:
both links stay within the band between the control row's bottom and the first divider's top, checked
at two viewports including a 400 px / 200 %-text-scale case that also asserts nothing overflows.

**One status display for both session kinds.** The three progress rings, the status banner and the
import's own lines (clip name, progress bar, inline cancel, and the gates that refuse a new import)
are one block. An import announces itself in the banner rather than beside it, because
`capturingStateProvider` stays false for an import's whole run — it emits no `onCaptureStarted` — and
the "capture is stopped" line would otherwise sit over a running import's progress bar. The two
flanking switch hints are dropped for an import: they are instructions for the game's own left/right
buttons, and nobody is pressing those during a clip recorded minutes or days ago. The bar is media
time over duration; a clip that declares no duration gets an honest indeterminate bar rather than a
percentage invented from a denominator that does not exist. **The running block carries no frame
counts and no phase line** (`VideoImportProgressBlock`): a running total is a number nobody acts on
mid-import, and the counts reach the user where they diagnose something — the `supplied` / `decoded`
hint on the terminal event tile of a refused or failed import.

**An import previews.** The capture preview tile is fed by either kind of session and obeys the one
`capturePreviewEnabledProvider` setting — there is no second switch, so a user who turned the preview
off gets none during an import either. Two details make it work: `listenCapturePreview` opens the
preview's session gate for an import as well as for a live capture (an OR over two writers, one
gate), and it pushes `cropped = false` for an import, because `pushOfflineFrame` builds its `Frame`
with no pane snapshot, so `actual_cropped` is false for every imported frame even after the consumer
side has latched a pane. Sending the live path's `latched` would silence the import's preview from
the first latch onwards.

**Per-character outcomes are stated during an import, as status only.** The import banner stands
where the per-character banner would be, so without this the outcome of every character in a clip was
invisible. Four of the seven statuses are restated underneath it — succeeded, duplicate,
already-captured and failed, the ones that are *facts about the recognized character* — as a quiet,
**non-tappable** tile. The other three (waiting-for-detail, detail-ready, capturing) say only where
the recognizer is inside the character it is on, which is what the rings already show frame by frame.
The **action half of each message is withheld**: every one of those lines is an instruction to a
person at the game ("scroll", "switch with the game's left/right buttons", "open the detail screen
again"), none of it actionable for a recording. The tile is not a link for the sharper reason that
the withheld action half is exactly the line that advertises the tap. Live capture is unchanged: one
tappable banner carrying both halves, and no extra tile.

**Chimes are muted for an import.** The four cues (`standby` / `success` / two `error` sources) are
gated in `NotificationLayer._playSound` rather than in the event dispatch, because the events
themselves must keep flowing — the rings, the status line and the harvest all read them — and because
the duplicate cue is emitted by the record store, not by the platform controller, so a gate in the
controller's `switch` would silence three of the four. The gate is derived from
`VideoImportState.isRunning`, not from a flag this layer raises and lowers, so no ending can leave a
mute stuck on and silence live capture afterwards. Live capture's sounds are untouched.

**The last record of an import is silent too, and not because of that gate.** A state-derived gate
cannot cover it: the harvested records are merged on `PlatformController`'s **unawaited**
`_liveMergeChain`, so an import's final batch — enqueued while the import still runs, executed after
`startVideoImport` has returned — reaches the store once the state has already settled on `finished`.
Measured in Chrome 151, that merge landed ~0.7–0.9 s after "video import completed" and, the record
being a duplicate, played one `error.wav` per import.

The origin therefore travels **with the records** instead of being inferred when the merge runs.
`onLiveRecordsHarvested` carries an `origin` field (`harvestOriginVideoImport` in
`video_import_ops.dart`), set by `WasmWorkerClient` from `_harvestBelongsToVideoImport`
(`isVideoImportRunning` **or** `_stopAwaitsImportTeardown`, which spans the teardown window where the
first has already gone false), relayed by `platform_channel_web`, and turned into
`addFromFileAsync(id, notifyDuplicate: false)` by the controller. Only the *sound* is dropped: the
duplicate still fails the capture state, so the visible status output is unchanged.

Two properties fall out of deciding per record rather than per window. There is no mute to get
stuck — nothing is held open and nothing has to be released, so no failure path can skip a release.
And a live capture cannot be caught by it: `notifyDuplicate` defaults to true, `_stopAwaitsImportTeardown`
is written by `startVideoImport` and by nothing else, and a message that *loses* the field is read as
live. The default direction is deliberate — an extra cue for an import, never a missing one for a
live capture.

**Windows carries the same marker on its own transport.** Its records are announced one at a time on
`onCharaDetailFinished`, which gained the same optional `origin` field with the same value and the
same absent-means-live rule; the core derives it from the open session's kind, so it is stated rather
than inferred, and the controller turns it into `addFromFile(id, notifyDuplicate: false)` — the
synchronous twin of the call above. The desktop merge does happen inside the import's window today,
so the state gate alone would have been enough *at this instant*; the marker exists so that it keeps
being enough after any scheduling change, and so that the retention drain (a merge that runs a store
rebuild later than the announcement) is covered too. See
[The Windows path](#the-windows-path-end-to-end).

**A refused import states its actual cause.** Every refusal used to be answered with one hedged
sentence naming two unrelated causes and committing to neither, while the producer knew exactly which
one applied and said so in English in a log line nobody sees. That knowledge now crosses the boundary
as a value. `web/worker.js`'s protocol comment is the canon for the wire format:
`videoImportDone` carries `reasonKind` alongside `reason`, `''` when there is nothing to narrow, and
`message` stays English prose for the log and for Sentry and is never rendered. A refusal made
*before a session exists* has no `videoImportDone` to carry a field — it travels on the generic
`{type:'error'}` channel, which has no per-operation payload — so its kind is appended to the message
as ` [video_import_reason=<kind>]` and taken back off in `videoImportReasonInText`. **The Windows
runner needs no such tag**: it refuses the same states before it asks the core and still has a
terminal `videoImportDone` to put the kind on, so every refusal there is an ordinary `reasonKind`.

`VideoImportReason` (`lib/src/core/video_import_ops.dart`) enumerates fifteen kinds — fourteen
shared plus Windows' own `file_unreadable` — and its
`wireName` is *also* the translation key (`…video_import.result.reason.<wireName>`) — one vocabulary
rather than two, because the blocker keys' camelCase/snake_case mismatch is what once rendered a raw
translation key at the user. Adding a case means adding a line to `assets/translations/ja.json`,
which `test/video_import_reason_test.dart` requires. A kind that arrives from a **newer** worker than
this build knows about parses as null, and a kind this build knows but `ja.json` does not carry is
caught by comparing the lookup against its own key; both fall back to the outcome kind's generic
line, never to a blank and never to a raw enum name.

Three of them were triggered end to end in Chrome 151 and each produced its own sentence: a
65-byte text file renamed `.mp4` → `not_a_video`; an audio-only MP4 → `no_video_track`; an FFV1
Matroska → `codec_unsupported`. `already_importing` and `capture_in_flight` are no longer reachable
*from this UI* — the two-state button is the cancel while an import runs, and it is disabled while a
capture runs — so they now answer a race or another front end rather than an ordinary click.

## Verification

There is no honest way to claim this feature is covered by the existing suites. Read the coverage
off the logs; do not assume it.

| surface | reachable by |
| --- | --- |
| Windows `VideoLoader` decode | the golden suite already drives it through `umacapture_cli video` — but every case is conditional on local clips under `.notes/` and models under `sandbox/modules/`, and **CI builds no CLI, so all of them skip there** |
| web demux, decode order, timestamps, media-time conversion | Node, in the harness style already in the tree (`tool/test_web_frame_shaping.mjs`, `tool/test_web_live_content.mjs` stub `globalThis.self` and import `web/worker.js`). Mediabunny documents a file-path source for Node |
| the flow-gate arithmetic | Node, pure integer code against a stubbed `Module` |
| the `VideoDecoder` step and `sample.copyTo` | **browser only** |
| the session-kind verdicts | `native/test/core/test_native_api_capture_session.cpp`, no pipeline needed |
| web-only Dart (the **web** facade: the file dialog, the worker client) | `@TestOn('browser')` + `dart test --platform chrome`. CI's browser job runs **an explicit list of file names**, not a glob or an `@TestOn` sweep, so adding a test means editing that line — and a `@TestOn('browser')` file that nobody adds there is simply never run. Today the two files carrying the annotation (`record_mutation_lock_web_test.dart`, `storage_persistence_web_test.dart`) are both named on it, so there is no such gap open. Do **not** try to close one by adding `record_loader_web_test.dart`: it dropped its annotation as unnecessary, `import 'dart:io'`, and runs on the VM with everything else under `flutter test` — moving it to the browser job would fail to compile |
| the **Windows** Dart facade — the wire format going out, the three notifications coming back, the terminal-outcome rule | ordinary `flutter test`, because the io leg is VM-compilable: `video_import_io_test.dart` drives it against a mock method-channel handler through the picker seam (`videoImportPathPicker`; the real dialog would open a modal window on the machine running the suite), and `video_import_native_routing_test.dart` proves the three types are routed by the real `handleNativeMessage` dispatch. **Nothing below the method channel exists on the VM** — that the runner decodes the argument, and that it sends those notifications, is not covered here |
| the desktop origin marker and the synchronous merge it backstops | `notification_sound_capture_origin_test.dart` (an import-origin duplicate is silent, a live-origin one still chimes, an absent field reads as live) and `capture_merge_synchrony_test.dart`, which asserts the merge-inside-the-microtask invariant directly instead of leaving it as prose |
| `VideoLoader`'s cancel predicate and progress/duration hooks | `native/test/cv/test_video_loader.cpp` |
| the notify payload shapes, including the optional `origin` field, the `records` count, the discarded-session payload and the `completed` + `records: 0` → `refused` / `no_records` rewrite | `native/test/core/test_native_api_messages.cpp` |
| the "ran to the end and produced nothing" ending, end to end through the CLI | the three `expect_records: 0` cases in `native/test/integration/cases.json` (`player_standard_factor_only_1`, `player_standard_factor_tiny_scroll_switch`, `_2`), which assert the record count, the announced error tags and the discard count off the CLI's run summary. Conditional on their clips like every other case, and **they are `video` runs of the CLI, so they say nothing about either import driver** |
| the Windows import session itself — refusals, drain, teardown, the DLL actually loading | **nothing automated.** `windows/runner/` is not reached by any suite, and the golden suite drives the CLI, not the app. Hand verification only |
| the import's UI — layout, banner, per-character tile, sound mute, reason lines | ordinary `flutter test`, through the injected seams (`importState` / `available` / `supported`, `NotificationLayer.debugVideoImportState` / `debugPlaySound`) — `capture_control_layout_test.dart`, `capture_status_display_test.dart`, `notification_sound_import_mute_test.dart`, `video_import_reason_test.dart`. The seams are still what makes the UI addressable: they pin one state per case instead of whatever the host platform's facade happens to answer, and on a non-Windows VM the facade is the stub's constant `false` and constant idle, which renders nothing. The tail merge above needs more than a seam, so `notification_sound_harvest_boundary_test.dart` drives the real `handleNativeMessage` dispatch over a real record store and asserts on the real sound sink with the import state already settled |
| recognition under a second YUV → RGB matrix | `integration_dual_decode.<case>` (`native/test/integration/run_dual_decode.py`), one ctest per case |
| one browser's actual pixels | `integration_golden.firefox_landscape_2pane_ps5`, a `replay` case over a lossless recording |

The old implementation had **no automated coverage at all** of the decode loop, the completion
terminator, the parking gate or the session state machine — every verification was a manual browser
playtest, and the one Dart test touched only the OPFS write leg. Do better than that, and when
reporting a manual result, name the engine and the clip.

### The two colour assets, and what each of them cannot see

Both live in `native/test/integration/cases.json`, which is shared by `run.py` (golden records) and
`run_dual_decode.py` (colour equivalence); the CLI subcommand comes from a per-case `mode` field
(`video` / `replay`) rather than from the file extension.

**Dual-decode equivalence** — `integration_dual_decode.<case>` runs `umacapture_cli video` twice over
the same clip, `--color_matrix bt601` and `--color_matrix bt709`, and requires the two record sets to
be **identical**. The control matters as much as the treatment: `--color_matrix bt601` is a different
decoder (libav planes + `cv/decoded_frame_to_bgr.h`) reaching the pixels swscale reaches, so every
case that has a golden also diffs its bt601 run against it and reports a disagreement as `HARNESS`
rather than as a colour finding.

* **It catches** any recognition decision that flips because the same planes were converted with the
  other matrix — which is what the original `g >= 180` incident was. Deliberately red-teamed: with
  the loose absolute box tightened back (g min 125 → 200, r max 200 → 130) the landscape case fails
  while `integration_golden.*` stays green — the same signature as the original defect, and proof
  that the golden suite alone cannot see this class.
* **It does not catch the chroma-interpolation difference.** It converts *the same decoded planes*
  two ways, so it reproduces the **matrix** and nothing else. A browser that hands back RGB has
  already upsampled 4:2:0 chroma with its own filter, where the core upsamples with OpenCV's; nothing
  here measures that. (Android's hardware RGBA differed from the desktop RGB conversion by up to 75
  on colour edges, which is the order of magnitude at stake.)
* **It does not catch a browser's rounding**, either — `--color_matrix bt709` is a *model* of a
  browser. Four to five units of rounding *on top of* the matrix decided the `g - b` bug while every
  dual-decode case stayed green: the nominal matrix alone still cleared the old limit on that row.
* `replay` cases are **skipped with that reason**: FFV1 stores BGR0, there is no YUV → RGB step on
  that path, so there is no matrix to vary. `landscape_2pane_ps5` carries **no golden** on purpose —
  it is a locally derived transcode whose exact pixels depend on the local `libx264`, so it takes
  part in the dual-decode suite only.

**A browser's own pixels** — `integration_golden.firefox_landscape_2pane_ps5` replays 374 frames of
desktop Firefox 153's own decode, recorded losslessly as FFV1/bgr0, and pins the resulting record
against what the CLI recognizes from the same clip under BT.601. Read its provenance exactly: the
file the suite names (`firefox_landscape_2pane_ps5_toppad.mkv`) is that browser dump with its rows
**translated afterwards** by the same +30 as the transcode beside it, not a fresh browser run, so it
is not frame-for-frame what Firefox handed over. What is preserved is the browser's pixel data (the
dump's rows 0..1309 are bit-identical at rows 30..1339, verified per frame on all 374); what is
discarded is h264 ringing outside the content's bounding box and outside every probe. It **does**
carry a committed golden, unlike the transcode beside it, because it is still a frozen artefact: its
pixels are bytes in the file, so the record set is reproducible on any machine holding it.

* **It catches** a defect caused by one specific browser's decoder, rounding included. It is the only
  automated test in the repo that can. At `g - b >= 120` it produces no record at all.
* **It does not catch** anything about another engine, another version, another clip, or another
  machine's Firefox. It is one frozen recording, not a generator; the browsers stay a manual surface.
  It is also blind to small drifts — falsifying `g - b` at 101 reddens only the unit pin in
  `test_detail_crop_calibrator.cpp`, not this case, which is why both guards exist.
* The transport was controlled before the pixels were believed: the same CFR-30 normalisation and
  FFV1 round trip applied to ffmpeg swscale BT.601 pixels replays to a record set byte-identical
  to `video --color_matrix bt601`'s, so the container is not what the case is measuring. Records,
  not pixels: nothing in the integration tooling compares images, and the core's own BT.601 now
  reaches swscale's pixels only to within one unit per channel (the coarsened luma ramp in
  `cv/decoded_frame_to_bgr.h`), so the two runs' image dumps would differ even where every record
  is identical. `native/test/README.md` documents the reproduction.

Note also that touching `native/src`, `native/vendor` or `native/wasm` invalidates the
`tool/web_deps.json` source digest. Every item in this design touches at least one of them, so a
wasm rebuild and repin is a mandatory, non-optional step of the change.

## Accepted drawbacks

Recorded so nobody has to rediscover that they were considered.

* **+1.35 MB of MPL-2.0 JavaScript on web.** File-level copyleft, satisfied by shipping the bundle
  unmodified and hash-pinned with its licence text — which is what the previous vendoring did. Load
  it lazily on first import so users who never import pay nothing at first paint.
* **+33.8 % on the bundled Windows native DLLs** (~80.7 → ~108 MiB uncompressed) to get Matroska.
* **A fast-moving dependency.** Mediabunny shipped 1.50.x within weeks. The pin makes a silent
  upgrade impossible; a deliberate one means re-reading its API.
* **HEVC coverage stays asymmetric** between web engines and Windows. Not closable from here.
* **A second session kind adds a rebuild-on-mismatch concept to the shared core**, where Windows
  compiles it too — and the mismatch is no longer hypothetical there: an import's pipeline is
  `video_mode` and a live capture's is not, so a loop still running for the other mode (a record
  regeneration's, concretely, since a passenger keeps one alive) is rebuilt rather than adopted.
  Read off `capturePipelineIdentity` / `ensureCaptureLoop`; not observed in a run.
* **The import↔regeneration refusal stayed outside the core** on both platforms, i.e. one gate that
  is not a core invariant, with its reason written at the divergence
  (`resolveVideoImportBlocker`). An import started during a regeneration therefore still discards
  that regeneration's work if the preflight is ever bypassed.

From the Windows path specifically:

* **The refusal mapping is only partly verified against real files.** `no_video_track` is now
  measured — an audio-only MP4 opens on MSMF and declares a 0 × 0 frame size, and the pre-decode
  probe turns it away on that — but the *fallback* split between `no_video_track` and
  `codec_unsupported` behind it still rests on the container's declared frame count alone, because
  OpenCV exposes no track list and no decoder error; `decoder_unavailable` rests on
  `videoio_registry::hasBackend(CAP_FFMPEG)` answering false when the plugin DLL is missing, which
  has not been observed. An unrecognised kind degrades to the generic outcome line rather than
  rendering something wrong.
* **The Debug plugin-DLL name is inferred, not observed.** The copy renames to `…_64d.dll` under
  Debug because that is what the CLI was measured to need; the comment at the copy site records that
  only the Release/Profile branch was exercised by a build. Neither branch was re-checked while this
  section was written.
* **The Windows import session has no automated coverage at all**, and the golden suite drives the
  CLI rather than the app. See [Verification](#verification).

From the colour work specifically:

* **An RGB frame is imported on the browser's colours.** Tier 2 above takes a frame the core's own
  conversion never touched, and the dual-decode suite does not cover its chroma interpolation — so
  such an import is one whose record was never *proven*. The mitigation is observability, not
  prevention: one warning per import naming the format and the matrix, plus `matrixConverted` in the
  summary.
* **`b <= 70` and both differences sit on the boundary by design**, with 0–2 units of slack. That is
  what a boundary test looks like, but it means another encoder can still move the boundary by a
  pixel or two. It is still visible in the corpus: `friend_*` reports row 94 under BT.601 and 95
  under BT.709, with identical records.
* **An absolute floor at or below 170 would not be caught by any test.** The corpus does not depend
  on the loose box at all (that is what "provably passive" means), so nothing stops a future change
  from re-introducing a floor in that range and with it the whole class of defect. The lesson is
  pinned in comments and in the falsification record, not in an assertion.
* **The factor-tab and title-banner widenings are preventive, not corrective.** Reverting either one
  turns **nothing** red — measured, both times. They are justified by measured margin (+7 and +10
  against a ~20-unit matrix swing) rather than by an observed failure, and their false-positive risk
  is argued from adjacent measurements rather than disproved: the "greenish canvas at B = 96" that
  bounds the B ceiling was measured on a different screen, and whether such a pixel exists inside the
  factor tab's scroll area is **unverified**. `factor_end_green`'s accepted-pixel sample is thin
  (n = 10 per matrix). For the title banner, the snackbar it must keep rejecting was **not
  re-measured** in this work — "still rejected" is arithmetic against an inherited value — and its
  reject branch is never exercised by the corpus, because `updateUntilReady` stops calling once the
  scan is ready.
* ~~**Relaxing `isCropInsideFrame` was never evaluated.**~~ **Closed by the rounding, not by the
  gate.** `DetailCropCalibration::toRect(frame)` now absorbs exactly one row of the overhang that
  independent rounding of origin and extent can produce, so the candidate above would be pulled back
  to 1340 and adopted. The gate itself is untouched — its own comment calls it mandatory rather than
  defensive, so it still needs an independent measurement before anyone relaxes it. This does **not**
  make the `g - b` limit optional: the shifted scan still solves the wrong scale (737.752), so what
  the rounding buys is a one-row-off geometry instead of silence, and locating the boundary correctly
  remains that term's job.
* **The golden suite never runs Android.** The Android agreement above rests solely on that manual
  stage, on one device and one Chrome build.
* **Both colour assets are conditional**, like every other case: they need their clip under the
  gitignored `.notes/` and the models under `sandbox/modules/`, and CI builds no CLI at all. On a
  machine without the files they skip. Read the coverage off the ctest log.

## Open questions

Unmeasured or unverified. Do not let any of these become an assumption.

1. **Is a WebCodecs decode loop inside a worker throttled in a hidden tab?** Unmeasured, here and in
   any documentation found. Documented throttling is described entirely in terms of JavaScript
   *timer* wake-ups, and this repo measured worker `setInterval(50)` running at exactly 20.0 Hz
   (Chromium) / 19.0 Hz (Firefox) while hidden — both point the right way. But Chromium's own
   blink-dev intent extended timer throttling to dedicated workers, so this is a real single-point
   risk in option A. **Measure it early, on both engines.**
2. ~~**Firefox WebCodecs H.264 decoding of real game recordings is unverified.**~~ **Answered for
   H.264**: desktop Firefox 153 decodes this project's clips and imports all four of them, returning
   `BGRX` under every `hardwareAcceleration` hint and refusing `copyTo({format:'I420'})`. Still open:
   **no codec other than H.264 has ever been tried**, on any engine, and mobile Firefox is untested.
3. ~~**Pixel-level agreement between OpenCV/FFmpeg decoding and browser decoding is unverified.**~~
   **Measured, and the answer was no** — see [Colour](#colour-two-decoders-one-recognition-result).
   The design no longer needs agreement. What remains open is narrower: the **chroma-upsampling**
   difference is reproduced by no test, and a browser's rounding is reproduced only for the one
   Firefox recording that is committed as a replay case.
4. **Whether Mediabunny 1.52.3 accepts a lazily-read source** rather than a full in-memory buffer.
   This decides whether a large clip is importable at all.
5. **The `NoLimit` memory-growth hazard was never sized**, and `OFFLINE_INFLIGHT_MAX = 8` was never
   tuned against a long clip. `web/worker.js` says so of itself: the value is inherited from the
   deleted `INFLIGHT_MAX`, not derived.
6. ~~**The completion criterion is a heuristic with no recorded derivation.**~~ **Answered: the
   heuristic was not kept.** The old terminator was "≥1 finish AND 4 s of native silence", capped at
   300 s. Neither front end has it now. Web falls out of mediabunny's sample iterator, which is
   exhausted only after the last packet is decoded and the decoder flushed, and leaves the rest to
   the teardown's join (`web/video_import.mjs`); Windows ends on the CLI's own drain barrier
   (`cli::offlineDrainBarrier`, 5-minute watchdog). Nothing is waited out and nothing is guessed.
7. ~~**The old path had no cancellation at all**~~ — **cancellation is implemented**: a
   `cancelVideoImport` message, a producer that observes the revocation at every waiting point, and
   the second state of the one import control. Exercised in Chrome 151: pressing 「中止」 mid-clip
   ends the import through the same teardown a completed one takes and reports
   「動画の取り込みを中止しました。認識済みの記録は保存されています。」 with the frame counts. Still
   open from this item: **there is no clip size cap** anywhere on the path.
8. **Whether the four supported forms survive.** *Partly answered.* Three shapes now import end to
   end and match their baseline on Chrome 151, Firefox 153 and Chrome for Android 150: portrait
   (738×1310), a rotated portrait (`rotation=90`, produced locally), and a 2326×1340 **landscape
   two-pane** clip — the shape that exposed both colour defects. The remaining shapes are still
   unexercised by any clip, and a clip's resolution and aspect remain arbitrary and unrelated to the
   browser viewport.
9. ~~**OPFS quota is inspected nowhere in `lib/`.** No `navigator.storage.estimate()`, no
   `persist()` request.~~ **Half of this is now wrong, and it was already wrong when this item was
   last read.** `lib/src/core/fs/storage_persistence_web.dart` calls both
   `navigator.storage.persisted()` and `navigator.storage.persist()`, behind the
   `storage_persistence.dart` conditional export, and `storage_persistence_banner.dart` turns an
   evictable origin into a warning on the capture tab. What is still true is the **quota** half:
   `navigator.storage.estimate()` is called nowhere in `lib/`, so nothing anywhere knows how close
   the origin is to its limit. A single import can mint dozens of records in a minute, so that
   remainder is what import makes hotter.
10. **One unexplained Android hang was observed and never reproduced.** An import froze the worker's
    JS thread right after the first sample on three attempts one evening; a subsequent A/B — five
    consecutive runs, ten clips, including the same thermal/memory state and the same starting
    conditions, and including an overlay of the previous build's `worker.js` + `video_import.mjs` —
    completed every one with a matching record. It is **not** a regression of the RGB-acceptance
    change (whose I420 path differs only by a null field), and the harness was ruled out by mtime and
    by identical request logs. The mechanism is **unidentified**, and a wasm/pthread futex wait is a
    hypothesis, not a measurement. The one hard datum is that ORT session creation took 4.4 s on the
    two hung runs against 1.7–2.1 s on every healthy one.

## Left over from the colour work

* ~~**"Silently zero records" still needs a failsafe.**~~ **Done, in the shared core.** Every defect
  in this section presented the same way: an import that decoded every frame, pushed every frame, and
  reported nothing. Three things now stand between that shape and silence, and they are separate
  because they answer separate questions:
  1. **"Nothing came out" is no longer a completion.** The core counts the records a run produced
     (`NativeApi::recordsProduced`) and `messages::videoImportVerdictOf` rewrites a `completed`
     verdict carrying `records: 0` into `refused` + `reasonKind: "no_records"` *before* the
     `videoImportDone` payload is built. Deciding it there is what makes all three front ends
     classify one run identically instead of each rebuilding the rule; `reason: "completed"` has
     correspondingly narrowed from "the decode loop returned" to "it returned and something came out
     of it", which is the deliberate cost. `refused` rather than `failed` for the same reason
     `no_video_track` is a refusal: nothing malfunctioned, the clip does not contain what an import
     needs — and `refused` is already one of the kinds the capture card gives its event slot to, so
     this needed no new slot.
  2. **A clip that runs out mid-character now says so.** No offline producer could previously close
     an open scene at all, so this case emitted nothing rather than the wrong thing.
     `NativeApi::endOfInput()` — sent once by each offline producer after its last frame, on the
     runner that carried those frames where there is one (the CLI's `recorder`, the Windows session's
     `video_import`), directly on the worker's own thread on web — posts an idle event onto the
     distributor runner, which closes the open scene and announces it as `closed_before_completed`,
     the tag the live stall watchdog already produced for a stalled stream. **The ending is not
     distinguished from a detail screen that was closed on-screen.** A dedicated tag for it was
     designed and then withdrawn: on the import path the tile that would carry it is structurally
     overwritten by the run's own terminal event before a user can read it, and the wording it forced
     onto the shared live path told a live user to re-capture "from the video", where there is no
     video file at all. One tag, one remedy, is the deliberate outcome.
  3. **A run that registered records and still lost a session is not an unqualified success.**
     `onCharaDetailRestarted` carries the **one bit** that says whether the discard cost anything
     (`{completed}`; an absent field reads as *not* completed, erring towards announcing a loss).
     Dart tallies those against the run (`VideoImportSessionTally`), and a completion with
     `records > 0` and a session unaccounted for renders as `result.completed_partial` — the one
     completion that earns the card's event slot. The plain `result.completed` line is **kept** in
     `ja.json` even though the card can never select it: every kind owning a line is what stops a raw
     key reaching the user if the policy ever widens. An ordinary completion is still non-news and
     still records no event. **The cost of keeping it** is that `completed_partial` going missing
     would fall back to `result.completed` and announce a false success — pinned by a named widget
     test rather than by the absence of a line (`videoImportResultKey`,
     `lib/src/core/video_import_ops.dart`).

  **Windows and web inherit all three unchanged**, because all three are decisions of the core rather
  than of a driver. What Windows already had — naming a run that decoded *no* frame — is still the
  narrower, earlier answer and is left in front of this one, since a producer's own classification
  wins over the record count.

  The CLI is covered by the same facts on its own channel: it prints one machine-readable
  `UMACAPTURE_RUN_SUMMARY` line on stderr and returns 0 / 1 / 2 (`native/src/core/cli_run_report.h`),
  and `native/test/integration/cases.json` now carries three zero-record cases that assert the count,
  the announced error tags and the discard count.
* ~~**A refusal's actionable detail does not reach the user.**~~ **Done.** Each refusal now carries a
  `reasonKind` across the wire and the user is shown one translated sentence per cause; the English
  prose stays in the log and in Sentry. See
  [The front end](#the-front-end-one-card-one-control-row). What it did not cover was the failsafe
  above — an import that decodes every frame and produces no record was refused by nobody, so it took
  the completion path — and that is what item 1 above now decides in the core. The two mechanisms are
  the same one from the card's point of view: `no_records` is an ordinary `reasonKind` and gets an
  ordinary translated sentence.

## Two stale comments, since fixed

Both predated this work and both named code that no longer existed. Neither text survives — no
comment under `native/src/core/` claims either thing exists — so this item is closed. (`native_api.h`
does still mention `configWithVideoMode` by name, deliberately and in the past tense, inside the
`videoModeOf` rationale: it is the history that argues for deriving the mode from the kind. Do not
read a grep hit on the name as a reopening.) Kept as a record of what was reported and why:

* `native/src/core/native_api.cpp` — "worker.js currently forces video_mode=false for every web
  session (see `configWithVideoMode`)". The function had been deleted, and this design makes the
  branch reachable again, so the comment had to be rewritten either way. It now describes the
  `NoLimit` branch's real brake (`FrameFlowCounters`).
* `native/src/core/native_api.h` — referred to "the worker's live/import start" when there was no
  import start. There is one again.
