# Native unit tests

Unit tests for the C++ backend, built with the vendored
[doctest](../vendor/doctest/doctest.h) single-header framework.

## Scope

These cover the pure, dependency-light logic that is safe to exercise without the
screen-capture / ONNX / WinRT stack (OpenCV is allowed):

- `condition/test_serializer.cpp` — JSON round-trip (characterization) tests for
  every registered condition/rule pair. This is the same round-trip invariant the
  CLI `build` subcommand asserts at runtime, captured as a standalone regression
  test so it runs without the game assets.
- `condition/test_condition.cpp` — boolean semantics of the composable
  conditions (nullary / nested / parallel; logical and/or/not; empty-list
  identity fold; `findByTag`) and the `rule::Stable` debounce.
- `condition/test_cv_rule.cpp` — the pixel-reading leaf rules (`PointColor`,
  `LineColor`, `LineMeasurer`/`LineLength`, and the state-tracking
  `StableLineLength`), driven by hand-built `CV_8UC3` mats through
  `Frame::fixed`.
- `chara_detail/test_scraping_box.cpp` — the scraping-box directory lifecycle,
  driven through injected `io_util::DirectoryHooks` fakes (no real filesystem).
- `chara_detail/test_scene_context.cpp` — the `CharaDetailSceneContext` scene
  state machine: constructor tag/branch-count validation, `firstMet` enum-order
  tie-breaking, and the frame-timestamp-keyed begin/end debounces and `onIdle`
  close, with the tagged condition tree hand-built from toggled leaves and the
  lifecycle events captured through direct connections.
- `chara_detail/test_scene_stitcher.cpp` — `ScrollAreaStitcher::stitch` (filters a
  directory to the scroll-area fragments and vconcats them, throwing legibly on an
  empty directory) and the safety-critical failure-cleanup path of
  `CharaDetailSceneStitcher::stitch` (a missing base image removes the partial
  output via the injected hook and sends `on_stitch_failed`, keeping the input for
  diagnosis). Fragment reads use real files under the temp directory; directory
  ops are `DirectoryHooks` fakes. The success path is exercised for one property:
  a synthetic record stitched with the shipped configs keeps the factor tab's
  banner at the live frame's row, column, search length and run end
  (`FactorRowReader::findBanner` on both sides; Standard and Friend layouts, units
  540/720/736/1079, four anchor shapes including a re-anchored pane whose
  `base.png` reads back with a smaller unit). What stitched records read as is
  left to the CLI/integration harness.
- `chara_detail/test_scraper_estimators.cpp` — the scroll-offset estimators and the
  stationary-frame catcher. `ScrollBarOffsetEstimator`: thumb margins / position from a
  rendered track (and the no-bar nullopt), and `scrollGuess` — the thumb-move-to-content-
  pixel conversion, its nullopt without a usable pair, dividing by each frame's *own*
  thumb length across a genuine re-scale, keeping the reference length while the thumb is
  bottom-clipped, and the sub-pixel tip refinement (agreeing with the integer guess on
  hard-edged frames, and resolving a move the integer tips round away).
  `ImageOffsetEstimator` is pinned piece by piece, since the estimator is a proposer plus a
  verifier and each half can fail alone: `columnBlockSignature` reducing every row to exact
  block pixel sums over a gapless tiling, storing zero rather than dividing by zero for a block
  with no columns; `blockCrossAccumulate`'s cross-product accumulation being exact and therefore
  independent of the reduction order (checked against three differently-grouped reference
  reductions, plus a positive control that forces the same comparison to disagree once the
  operands leave double's exact-integer range, so the order-independence check is not vacuous)
  and the exactness bounds both it and the signature rely on holding at every tiling geometry
  the product can reach, from the resize band's floor through an absurd 8K;
  `proposeVerticalShifts` ranking the true shift first in
  `overlapScore`'s sign convention (both signs, and zero for a static pair), returning the
  correlation curve's local maxima ranked and truncated to `top_k` rather than a single
  argmax, applying the same overlap floor the verifier does, and proposing nothing when a
  frame carries no vertical structure; `overlapScore` verifying genuine shifts of either sign,
  rejecting wrong ones, and returning no evidence on degenerate inputs; plus `estimate`'s
  no-vertical-structure nullopt and its refusal of a pair whose frames differ in size. The
  two proposer settings the cases run at are read from `ImageOffsetEstimatorConfig{}`, so they
  track the shipped defaults instead of restating them. Which proposal *wins* on real periodic
  content is left to the golden harness — a synthetic image has either a unique answer or no
  right answer at all. `ScrollAreaOffsetEstimator`: delegation, reading scrollbar geometry
  from `scroll_bar_frame` rather than `frame`, the short-circuit before the image matcher, and
  the guess-window veto admitting a near offset while rejecting a far one.
  `StationaryFrameCatcher`: latch on the time threshold, not-yet-ready before it, restart on
  change, self-heal across a resolution change, cropping the latched frame to its target rect,
  the `minimum_color` gate reaching the pixel diff, and measuring a *fraction* of its region
  rather than an absolute amount of change — all keyed on frame timestamps. Driven by
  hand-built `CV_8UC3` mats. Also the **factor tab's head judgment**
  (`scraper_impl::factorHeadReading` / `factorHeadVerdict`) on readings handed in. Behind a
  thumb at the head: the banner row accepted from 1 to `factorHeadLastRow` (the recognizer's
  search window less `banner_window_reserve`) and refused at 0 and one past it, the reserve
  being what refuses that row, and the banner's run having to contain the green sensor's row.
  The thumb's role, stated on the structure: an unreadable thumb is `unknown` and a thumb
  reading `scrolled` is `scrolled` however clearly the header shows the head, with neither the
  banner search nor the green scan taken; a thumb at the head is kept or refused by the header
  (refused by the window without the green scan being taken). Also
  `TopOfContentPolicy` (which way an `unknown` reading falls, both directions) and the one
  shipped thumb threshold (`thumbTopOfContent` refusing the smallest positive top margin),
  and `ScrollableScrapingInterpreter`'s fragment-#0 acceptance driven with a thumb judgment
  handed in: the stationary and motion exits each latching a head and refusing a head start,
  the motion exit asking the judgment about the descriptor it latches (the first frame) and
  not the frame that triggered it.
- `chara_detail/test_scene_scraper.cpp` — `BaseFrameCatcher`, the base-image gate
  layered on top of `StationaryFrameCatcher`: readiness needs both the base region
  stationary AND the green title-bar banner visible on the header scan line for a
  threshold ("snackbar cleared"), the visible-since window restarts when the header
  drops, a backward (non-monotonic) frame timestamp cannot clear the snackbar early
  via unsigned wrap, and once ready a later frame is ignored so the latched image
  survives. Driven by solid `CV_8UC3` frames (simultaneously stationary and in/out of
  the header range). Also the **discard report**: the real `CharaDetailSceneScraper`,
  built from the *shipped* `scene_scraper.json`, driven past the switch dwell so the
  record-type reset rule fires, asserting that the reported session is the one thrown
  away and not the one rebuilt on the same call, that it says it did not complete, and
  that `release()` reports its session without announcing a discard of its own. The
  record-type rule is the one reset rule that needs no image at all; a discard reporting
  `completed == true` is produced by the Rule 3 cases below that complete a whole
  session from synthetic frames and then show a different factor list, and the integration manifest's
  `expect_discarded_incomplete` covers the same bit on real footage. Also the **top-of-content
  wire**: that `on_scroll_position` carries the composite verdict's own word
  (`at_top` / `scrolled` / `unknown`) *unresolved*, because the two front-end consumers
  answer an unreadable frame in opposite directions — a resolve on this side is invisible
  to the records a golden compares. A tab built for a page with **no scroll bar** says
  `at_top` from the structure it was built with, before any sensor and whatever its frames
  show (on the skill, campaign and factor tabs alike, with the factor header missing or
  drawn past its window). A tab not built yet says `unknown` on its first frame — the
  factor tab too, even with its header at the head row, because the thumb is every tab's
  head sensor and the header is asked only behind a thumb at the head. From the second
  frame the factor tab's word comes from its head judgment: a banner anywhere in the window
  (including two rows above the head row) says `at_top`, a banner cut at row 0 or one row
  past the window says `scrolled` although the thumb reads a head, a thumb showing one tip
  pixel says `scrolled` over a banner at the head row, a factor frame with no banner in its
  window under a thumb at the head — scrolled or covered — says `scrolled`, and a built
  factor page whose frame shows neither its thumb nor its header says `unknown` and is not
  judged by Rule 3. The harness's factor
  frames paint that banner (`kFactorHeadRow`, with the rows above it in the harness
  reader's background) because the judgment reads the harness's own `FactorRowReader`.
  **Fragment-#0 acceptance asks the same judgment** (`topOfContent`, handed to every tab's
  interpreter): on the factor tab a banner cut at row 0 is refused as `scrolled` while the
  thumb reads a head, and row 1 is latched; a long list pre-scrolled by 24–27 px, which a
  short thumb still reads as the head, is refused on the stationary and the motion exit
  alike, while the same frames at the head are latched (the motion control's current frame
  already being cut, so judging "now" would refuse it); the skill and campaign tabs still
  accept by the thumb alone (a header-less frame and a cut "header" latched, one tip pixel
  refused as `scrolled`, a vanished thumb refused as `unknown`). Rule 3 judges a factor list
  displaced a few rows inside the window, and a `same` reading takes the displaced frame as
  its witness without a reset. And **which rule watches a captured tab for a
  character switch**: Rule 3, and only Rule 3, whenever the factor tab holds its witness
  (after the tab is captured and after the session completes, keeping the session on a
  same-record reading). No rule watches any other tab, so a captured skill or campaign tab
  at the head of its list is never discarded, in an incomplete session or a completed one,
  and a switch made there after completion is judged by Rule 3 when the factor tab is next
  shown. The factor tab's
  witness is installed by its head latch whether its page scrolls or has no scroll bar
  (the latter arming the probe with `cue_owed == false`), so a factor page with no scroll
  bar that stays at its head is never discarded and a switch on it is judged by Rule 3;
  before its latch the tab holds no witness and nothing reads it. Rule 3's dwell does not
  resume across a frame of another tab.
- `chara_detail/test_factor_header_band.cpp` — the invariant the fine (green "因子"
  header) sensor rests on, measured against real footage: inside the configured probe
  band, the header row is the *only* row of the scroll-area crop that clears
  `green_fraction_threshold`. `factorHeaderTopY` returns the first row that clears it and
  stops, so any other row that could clear it would be returned silently instead. Decodes
  two golden clips (one Player-layout, one Friend-layout with the longest rental-factor
  list) through the shared `VideoLoader` and checks that the cleared rows form a single
  run of header height, with the threshold strictly between the worst non-header row and
  the weakest header row. It is an invariant about game CONTENT, so it is re-measured on
  every run rather than argued once. The clips are gitignored test material, so the case
  reports and continues when they are absent. A second case states `band_start` /
  `band_end` / `green_fraction_threshold` as data with their derivation, because the
  band's width also buys occlusion tolerance that no corpus statistic can observe.
  A third compares the header's crop row across the two layouts, which is what notices
  `friend_common.viewport` moving without the scroll-area rect that is now derived from it.
  A fourth runs the factor tab's head judgment on the production readings (the
  recognizer's `findBanner` on the shipped `recognizer.json`, the green scan
  `firstHeaderGreenRow`, the thumb estimator) over three clips at two anchor units: every
  frame the thumb and the green header place at the head is accepted, counted with its
  denominator, and every banner row those frames show has room on both sides inside the
  window. A fifth decodes `friend_standard_many_rental` and checks that the 46 frames
  where the end-of-list 継承履歴 bar sits inside the banner window (decode order 354..399)
  pass both banner conditions and are refused by the thumb alone, and that no other frame
  of the clip is. A sixth, clip-free, paints the header at ten measured capture geometries
  (units 540–810, re-anchored ones included) and checks that the measured head row, row 1
  and the window's last row are accepted, that the row past it is refused although the
  recognizer still finds the banner there, and that the window is
  `lround(vertical_banner_upper_gap * unit)`. The footage cases report and continue when
  their clips are absent.
- `chara_detail/test_search_helpers.cpp` — `recognizer_impl::searchVertical`
  (`chara_detail_search_helpers.{h,cpp}`):
  downward/upward run scanning, the `max_length` cap, the all-background nullopt, and
  the out-of-bounds start clamp, against hand-built mats; `scanVertical`, the pixel
  form of the same scan (start, unclamped length, hit row), and
  `backgroundResumesAt`, the end of a content run.
- `chara_detail/test_record.cpp` — the `RecordType` axis predicates
  (`isInheritanceOnly` / `isFriend`; pure enum logic) plus the JSON serialization
  contract of the `CharaDetailRecord` tree: a fully populated record survives
  `get`→`to_json`→`get`→`to_json` unchanged and preserves nested values, each optional
  round-trips in both the engaged (value written) and disengaged (key omitted, not
  null) states — including an explicit `null` decoding to `nullopt` — and `RecordType`
  serializes by name with the `_STRICT` variant rejecting an unknown name instead of
  silently mapping it to the first enumerator. This is the same wire contract the
  golden integration test covers end to end, pinned here as a CI-runnable guard that
  needs no clips or ONNX models.
- `cv/test_frame_distributor.cpp` — the `FrameDistributor` fan-out: every frame
  and every `onIdle` signal reaching each registered scene context, verified
  through a fake `SceneContext`.
- `cv/test_frame_stall_watchdog.cpp` — the `FrameStallWatchdog::shouldFire` stall
  debounce (fire once on the transition into a stall, rearm only after frames
  resume), driven with synthetic elapsed durations so the timing logic is
  deterministic without spinning up the poll thread or the real clock.
- `cv/test_prediction_check.cpp` — the inference-output check desktop (`cv/model.h`)
  and web (`native/wasm/wasm_recognizer_models.cpp`) both run before a decoder reads
  a model's outputs: a session one output short refused at load, a wrong element
  type, a vector and an empty output refused per read with the exception type each
  raises, and an out-of-range index refused before the platform is asked to describe
  it. Neither adapter compiles here; the JS half of the web contract (output count at
  load, element count and type per output) is covered by
  `tool/test_web_capture_session.mjs`.
- `util/test_event_util.cpp` — the event plumbing: `bindLeft`/`bindRight` argument
  binding, the queued-connection limit modes (`Discard` drops, `NoLimit` keeps,
  `Block` back-pressures without dropping), and the runner thread's containment of a
  throwing listener. The after-start lifecycle guards trip `assert_` first (see
  below), so only their always-on behavior is reachable.
- `types/` — the geometry/value primitives: `types/test_range.cpp` (inverted-range
  rejection, inclusive `contains`, per-channel `Range<Color>`), `types/test_color.cpp`
  (per-channel `<=`, non-clamping arithmetic, `clamp`, BGR reorder), and
  `types/test_shape.cpp` (rounding direction, `Rect::empty`/`margined`, line
  components, anchor preservation).
- `util/` — `util/test_misc.cpp` (the `monotonicElapsed` clock-skew guard),
  `util/test_stds.cpp` (vacuous-truth `all_of`/`any_of`, `starts_with`,
  `find_transformed_if`, `slice`), and `util/test_json_util.cpp` (`trim`, plus the
  `optional_*`/`extended_*` field read/write templates the `EXTENDED_JSON_TYPE_NDC`
  macro expands to — the omit-a-disengaged-optional vs write-a-value asymmetry, a
  missing or explicitly-null key both decoding to `nullopt`, the non-optional path
  throwing on a missing key, and `decodePath`'s UTF-8 `u8path` conversion).
- `util/test_io_util.cpp` — the byte-level contract of `io_util::read`/`io_util::write`:
  the bytes handed to `write` reach the disk untranslated (no CRLF expansion, no doubled
  CR in text that already holds one) and `read` hands back exactly what is on disk, CR
  included. Each case keeps `io_util` on one side and a raw binary `fstream` on the other,
  because a round trip through both cannot see the defect — the Windows CRT's two newline
  translations are exact inverses, which is how the CLI's own `build` round-trip check
  masked it. Plus the missing-file throw. Tautologically green on POSIX targets, where
  text and binary mode are the same thing.
- `cv/test_frame.cpp` — the `Frame` numeric core: `BGR::difference`, `linspace`,
  `FrameAnchor` coordinate round-trips (incl. the zero-size degenerate guard),
  `colorAt`, line sampling (`isIn`/`isAllIn`/`lengthIn`), and the area diff
  metric (`diffStats`), driven by hand-built `CV_8UC3` mats.
- `cv/test_pane_mode.cpp` — shared one-pane/two-pane candidate geometry across measured frame sizes, including
  `FrameAnchor` equivalence, containment, full-frame boxes, and degenerate inputs.
- `cv/test_pane_mode_latch.cpp` — thread-safe latch/read/release handoff, captured-size matching, replacement,
  idempotent release, and concurrent reader/writer coherence.
- `cv/test_detail_crop_tracker.cpp` — two-candidate calibration, immediate freeze, ambiguity rejection,
  producer-anchor preservation, both release triggers, and evaluation-order independence.
- `core/test_native_api_messages.cpp` — the notification wire contract. The
  `notify*` JSON payloads NativeApi pushes to Dart are built by the pure
  `uma::app::messages` free functions in `src/core/native_api_messages.h` (split
  out of `native_api.h` so the wire contract is stated and tested on its own, apart
  from the pipeline that sends it); each builder's exact `type` tag and keys are
  asserted against a raw-JSON expectation, order-independently.
- `core/test_native_api_pipeline_wiring.cpp` — the real `NativeApi`, constructed and
  started with the shipped `assets/config` against fake predictors: that a pipeline
  start and a session that merely *adopts* a running loop both begin a new run's
  record count, that a stitch failure finishes the attempt it names and reports
  `stitch_failed` against that attempt's `record_id` even after a later attempt was
  announced, that every terminal attempt failure is one finish plus one id-scoped
  error, that a pipeline which fails to build reports the reason and leaves nothing
  running, and that a pipeline builds the factor-tab models exactly once (one
  factor-row reader shared by the scraper and the recognizer). `closed_before_completed`
  and `scrape_failed` are reachable only from inside the scene scraper, so their
  listener body is asserted here but not their attachment.
- `core/test_frame_rate.cpp` — the pure `frameRate` helper in
  `src/core/frame_rate.h` (split out of NativeApi's lap-time listener for the same
  reason as `native_api_messages.h`): the `count * report_interval / span` ratio
  (a full window reads back as the sample count, a doubled span halves it, a
  non-1000 ms window scales), the empty-sample zero, and the division guard against
  a zero or backward-clock (negative) span.
- `util/test_thread_util.cpp` — the `thread_util` concurrency primitives:
  `ThreadBase` start/stop, the idempotent `start()` (no second thread) and `join()`
  (safe before start and on repeat), and `Timer`'s expire vs. `cancel()` latch
  (`on_expired`/`on_canceled` exclusivity, the `hasExpired()` state, and a
  null `on_canceled`), driven on real threads with short real-time waits.
- `chara_detail/test_config.cpp` — characterization round-trip of the shipped
  chara-detail config: `CharaDetailSceneScraperConfig` / `…SceneStitcherConfig` /
  `…RecognizerConfig` (via `EXTENDED_JSON_TYPE_NDC`) and the `scene_context.json`
  condition tree parse stably (`get`→`to_json`→`get`→`to_json` is idempotent), plus
  a missing-key rejection. Unlike the other tests this reads the repo-committed
  config JSON under `assets/config/chara_detail` via the `TEST_ASSET_CONFIG_DIR`
  compile definition CMake injects — a deliberate, narrow exception to the "no game
  assets" scope below (those files are small versioned config, not screenshots or
  ONNX models, and are themselves the contract under test). It also checks that the
  shipped files agree on the one scroll-area rect the scraper crops with, the
  stitcher pastes at and the recognizer reads from.

- `chara_detail/test_factor_change_discriminator.cpp` — the character-switch
  discriminator: a resample/requantisation perturbation of the same factor list is
  not a switch (at every capture scale), a glyph replacement is and survives the
  per-pixel cut, an identical frame never is, a whole-frame brightness drift below
  the cut is not, and a small high-contrast change is rejected by the area bar
  rather than by the cut.
- `chara_detail/fake_predictor_factory.cpp` — not a test: the test target's
  definition of `makePredictor`, which the recognizers' production constructors
  call. The desktop definition (`chara_detail_recognizer_models.cpp`) loads ONNX
  models and is deliberately unlinked; this one loads nothing and returns
  `util/fake_predictor.h` constants (the value-initialized result, confidence 1),
  so the production constructors link and can be built in a test.
- `chara_detail/test_recognizer_wiring.cpp` — the three subscriptions of
  `CharaDetailRecognizer`'s production constructor, built with the fake above and
  the shipped `recognizer.json` over direct connections: a factor probe answers
  once on the completion channel with the limit and cue it was sent; an update
  request for a missing record answers once with `updateRecord failed for
  record_id=…`; the capture input is registered exactly once and its failure
  reports no update error. A capture subscription that calls nothing still passes
  (the capture path reports failure only to the log); the golden suite covers that.
- The recognizers, driven through their injection constructors and the
  `util/fake_predictor.h` stub, so the scan logic is testable with no
  onnxruntime. Each covers its landmark-not-found path, its layout selection and
  the 0-based-to-1-based conversions the record contract requires:
  `chara_detail/test_status_header_recognizer.cpp` (evaluation / status /
  aptitudes, and what an inheritance-only record skips),
  `chara_detail/test_skill_tab_recognizer.cpp` (no skills for inheritance-only; a
  level read only for the first skill of a left+right row),
  `chara_detail/test_factor_recognizer.cpp` (`visibleSelfPrefix`: the missing
  top banner, a fully visible left+right row with a 1-based star, stopping
  before a row whose name or star cell would leave the scroll area, and stopping
  at the window's factor limit without handing the models a cell past it),
  `chara_detail/test_support_card_recognizer.cpp` (no card top leaves the cards
  and `scan_top` untouched; six cards with 1-based ranks),
  `chara_detail/test_family_tree_recognizer.cpp` (the default family when no tree
  top is found, icon/rank mapping plus the rental flag, an out-of-range
  `record_type` clamped to `Standard`, and the legacy icon layout for a tall tree),
  `chara_detail/test_race_recognizer.cpp` (no races on an all-background frame,
  and the 2-line vs 1-line model set chosen by block height with a 1-based
  position), and `chara_detail/test_campaign_recognizer.cpp`
  (`formatTrainedDate`'s valid / not-8-digit / negative-value cases, the untouched
  record when no area bottom is found, and keeping the higher-confidence detection
  when a class is seen twice).
- `core/test_native_api_capture_session.cpp` — `CaptureSessionPolicy`: a start with
  no session open starts one, a same-kind start is acknowledged again rather than
  restarted, a cross-kind start is refused with a reason, a failed pipeline leaves
  no session behind, ending is idempotent and a release by the wrong kind is
  ignored (so one front end's stop button cannot give away another's session),
  plus what the pipeline identity is read from and when a running loop is adopted.
- `core/test_native_api_frame_shaping.cpp` — the NativeApi side of the shaping
  contract: the captured-size-scoped lookup, a snapshot detecting a change across
  producer work, pane generations round-tripping through the canonical JavaScript
  string wire format (and `decodeGeneration` refusing every non-canonical form
  `std::stoull` would accept), and the web-only outward even alignment — containing
  the pane target, holding its invariants over every small valid rectangle, refusing
  malformed and out-of-bounds ones, leaving an odd unlatched capture full-size with no
  copy rectangle, falling back to full pixels when no containing even expansion exists,
  and translating the pane into copied-frame local coordinates otherwise.
- `core/test_native_api_preview.cpp` — the preview emission gate: nothing while the
  preview is off, the packed state's two independent bits, a frame whose pane state
  disagrees with the UI's expectation dropped without consuming the throttle window,
  the first frame of a session never delayed, the 200 ms cadence, the 576x320 box
  defined exactly once, and the fit maths (never upscale, aspect preserved on
  whichever axis binds, a clamp to at least one pixel, a degenerate size returned
  untouched rather than divided by).
- `core/test_pipeline_config.cpp` — `readFrameStallTimeout` and
  `readFrameResizeBand`: the 2000 ms default and the malformed-value fallback, the
  band disabled unless explicitly enabled, **the shipped 540–720 px band pinned as
  a value**, and the legacy unit key warned about rather than silently defaulted
  (in both the enabled and disabled cases).
- `core/test_pipeline_drain.cpp` — the drain barrier: waiting for a producer-side
  stage the core cannot see, joining immediately when every stage is empty, a
  wedged stage reported as a timeout rather than as a normal ending, and the live
  barrier's ordering (silence the producer and the watchdog before reading, wait for
  a record still held, but not on the producer runner's leftovers).
- `core/test_cli_run_report.cpp` — the CLI's end-of-run line and exit code: a clean
  run, a named terminal error turning the exit non-zero, distinct causes staying
  distinguishable, one cause many times as one tag, the discard/loss accounting, the
  unit and input count, the recognized geometry (and a run that forwarded no frame
  reporting a count rather than a zero geometry), an unreadable notification counted
  rather than dropped, and no exit code colliding with ctest's `Skipped`.
- `core/test_forwarded_frame_geometry.cpp` — the per-run frame-geometry range: empty
  when nothing was forwarded, one frame as both bounds, a moving unit widening the
  range instead of replacing it, a fresh start per run, and thread-safe observation.
- `core/test_record_production_counter.cpp` — the per-run record count: each record
  counted once, zero at the start of a run however the previous one ended, surviving
  until the next run begins, and safe across the threads that use it.
- `core/test_factor_switch_verdict_tally.cpp` — `app::FactorSwitchVerdictTally`, the
  per-run count of what the factor tab's character-switch rule concluded (`Same` /
  `Different` / `Empty` / `Unreadable`): a fresh tally reports zero for every verdict,
  four unequal counts stay apart under their own slots (so a conflation -- `Empty`
  folded into `Unreadable`, say -- cannot reproduce all four numbers), a new run
  resets every verdict however the previous one ended, each verdict's tag word is
  distinct and non-empty and matches the four words (`same`/`different`/`empty`/
  `unreadable`) the CLI's run summary keys its line by, and concurrent `note()` calls
  from separate threads (mirroring the scraper runner vs. the CLI's post-drain read)
  lose no count.
- `core/test_frame_flow_counters.cpp` — the two in-flight counters whose difference
  is the resident frame count: the lead-in, a frame counted on each hop it crosses,
  a full drain returning to zero rather than to a residue, reset in both directions,
  the two counters being distinct 4-aligned addresses that stay stable, and no count
  lost under concurrent producers and consumers.
- `core/test_detail_crop_report_throttle.cpp` — the crop-report throttle: the first
  report always passes, a second inside the interval is dropped without restarting
  the window, a change of `latched` bypasses the interval in both directions, and
  reset clears both the timing and the remembered latch state.
- `cv/test_frame_shaper.cpp` — the shared producer-side shaping the parity contract
  is written about: no pane decision means the aspect-ratio anchor and **no**
  snapshot, an unlatched snapshot keeps the full frame in every mode, and each mode's
  anchor (`CropPixels`, `AnchorOnly`, `CopiedRegion`) identifies the pane inside the
  pixels actually sent; plus the refusals — a pane outside the producer's pixels, a
  degenerate pane, an unshaped `CopiedRegion` that is not the whole surface, a pane
  decision that moved during the copy, and a buffer the caller does not solely own.
- `cv/test_decoded_frame_to_bgr.cpp` — the planar-decoder colour conversion:
  agreement with `cv::VideoCapture` to within one unit, 2x2 chroma coverage, an odd
  visible rectangle keeping its trailing row and column, NV12's interleaved plane,
  RGBA reordered rather than converted, an unknown format name refused rather than
  defaulted, the BT.709 reference against a browser's decode, BT.601 remaining the
  default, where the two matrices agree and where their rounding does not, the coarse
  luma ramp's one-unit bound, a buffer that is not exactly one frame refused, and the
  published layout being the one the conversion actually walks.
- `cv/test_media_timestamp.cpp` — the clip clock: zero at the start, whole-millisecond
  pass-through, a mid-stream zero unable to rewind, a negative stamp clamped, NaN and
  infinity refused, an absurd value bounded instead of overflowing, and reset.
- `cv/test_video_loader.cpp` — the offline producer: a host-less loader decoding the
  whole clip exactly as the CLI drives it, emitted frames keeping their pixels while
  the rest decodes, the decoder's buffer forwarded rather than cloned, an attached
  host opened once and told about every frame in order, a cancel predicate stopping at
  frame N, an already-cancelled host emitting nothing, the continuous decoded counter,
  and the planar backend throwing in a build without it. Compiled **without**
  `UMACAPTURE_WITH_PLANAR_DECODER`, matching how the Flutter Windows app builds it.
- `cv/test_video_frame_grabber.cpp` — the single-frame grabber the import-error report
  reads a clip with (header-only and Windows/CLI-only; this is its only compilation):
  the timeline it reports, every requested time returning the frame the clip showed
  then, every frame reachable, out-of-range times clamped rather than refused, the tail
  staying selectable, the grabbed frame being the full decoded image stamped with its
  own media time, determinism for a repeated time, exactness with no seek ladder at
  all, the ladder consulted in order and reporting which rung answered, a useless
  backoff escalating, and the two throw paths the front end classifies.
- `cv/test_detail_crop_calibrator.cpp` — `calibrateDetailCrop`: reconstructing a dialog
  that fills the frame, recovering a mis-anchored client rect (the browser-chrome case),
  placing the band rows from the reconstruction rather than from the caller, tolerating
  a 1 px probe disagreement and riding out one bad column, refusing a caller estimate
  narrow enough to fool the button scan and the window's own border, and each named
  failure (`HeaderStart` / `HeaderMissing` / `HeaderSpread`, the three `Button*`
  counterparts, and the absent 5-stat band).
- `cv/test_ffv1_roundtrip.cpp` — built as its own target (`umacapture_ffv1_tests`,
  which links libav) rather than into `umacapture_tests`: bit-exact pixels and
  reproduced timestamp deltas through record → replay, non-ASCII output paths, and
  replay resolving **no** pane decision — the offline-producer half of the parity
  contract, asserted rather than described.
- `runner/test_method_argument.cpp` — the platform-channel argument decoder:
  `typeName` over every scalar alternative and the null pointer, a string payload
  handed to an argument-taking handler, every non-string payload and a missing
  argument rejected, and anything accepted for a handler that takes none.
- `util/test_error_util.cpp` — the abort-vs-failure classification an exception is
  reported under: `OperationAborted` (and a subclass) as an abort, a bridge timeout as
  a failure **although its message reads like the abort**, an ordinary
  `std::exception` as a failure, and a non-`std` throwable as the unknown-exception
  failure.
- `wasm/test_pane_snapshot_token.cpp` — the wasm wire token (`native/wasm/*.h` is kept
  free of Emscripten includes precisely so it is testable here): the generation-only
  and latched-rectangle spellings, the round trip, a same-generation null→latch and a
  same-generation relatch of a moved rectangle both counting as mismatches, a malformed
  token rejected rather than treated as stale, and a negative field decoding as legal
  syntax that simply does not match.
- `tool/test_stop_file_guard.cpp` — the shared `--stop-file` guard (`../tool/stop_file_guard.h`),
  used by both `capture` and the mimic player: an absent path and an empty regular file are
  accepted, and everything else — a file that holds bytes, a directory, a path that cannot be
  inspected — is refused with its reason rather than removed. The cases that matter most are the
  negative ones: the mistyped path holding bytes has to come back byte-identical, because the paths
  these options are handed every day sit beside recordings that cannot be made again.
- `tool/test_mimic_spec_parse.cpp` — the mimic player's control-channel number parsing
  (`../tool/mimic_player/spec_parse.h`): a token is accepted only when the parser consumed all of
  it, so `sec=2,44`, an empty token and `step abc` are refused instead of becoming the perfectly
  legal timestamp 0.0 / frame 0 that `std::atof` / `std::atoi` report failure as.
- `test_main.cpp` — doctest's generated `main()`, and nothing else. Isolated so doctest
  is not recompiled per test translation unit.

The hand-built mat builders shared across the pixel-level tests (`solid`,
`splitH`, `splitV`) live in [`util/cv_test_helpers.h`](util/cv_test_helpers.h)
(`uma::testutil`), included via the `test/` include root, so a new test reuses the
same conventions instead of copying them.

Every case that decodes a video file (the footage cases in `chara_detail/test_factor_header_band.cpp`, and the
generated-clip fixtures of `cv/test_video_loader.cpp` and `cv/test_video_frame_grabber.cpp`) first calls
`requireFfmpegDecodes` from [`util/video_backend_guard.h`](util/video_backend_guard.h): it fails, naming the
missing `opencv_videoio_ffmpeg*` plugin, when OpenCV would open the file through any backend other than FFmpeg.
The `umacapture_tests` POST_BUILD step places that plugin next to the exe (under its shipped name, which the
Debug `opencv_world` also loads), so a tests-only build needs no other target built beside it.

Since this binary is built Debug, `assert_` aborts rather than being a no-op, so
the assert-guarded negative paths (e.g. `linspace(num < 2)`, mismatched-anchor
point arithmetic, the event-runner's after-start `makeConnection`/`add` guards)
are deliberately not exercised — only the always-on `throw` paths (bounds /
size-mismatch) are.

The test target (`umacapture_tests` in [`../CMakeLists.txt`](../CMakeLists.txt))
links only the sources under test — the header-only primitives above plus
`src/condition/serializer.cpp`, `src/chara_detail/chara_detail_scene_scraper.cpp`,
`src/chara_detail/chara_detail_scene_context.cpp`,
`src/chara_detail/chara_detail_scene_stitcher.cpp`,
`src/chara_detail/chara_detail_search_helpers.cpp`,
`src/chara_detail/chara_detail_recognizer.cpp`, `src/core/native_api.cpp` and
`src/core/native_api_frame_shaping.cpp`, which pull in OpenCV via `cv/frame.h`
but neither ONNX nor WinRT — the recognizer stage's predictors come from
`chara_detail/fake_predictor_factory.cpp` rather than a loaded model. (Their
`log_*` / `vlog_*` calls resolve against the header-only spdlog default logger,
so they need no `logger_util.cpp`.)
This source list is maintained by hand in both `../CMakeLists.txt`
(`TEST_SOURCE_FILES`) and here — keep the two in sync. As the header/.cpp split
progresses, add each newly split `.cpp` and its tests here.

## Build & run

The build is Windows + MSVC only (same toolchain as `umacapture_cli`). The
`umacapture_tests` target links OpenCV, so a fresh checkout must first provision
it with `uv run tool/fetch_deps.py --only opencv` (see the `project-setup`
skill). From a shell where `vcvars64.bat` has been sourced:

```bat
cmake -G Ninja -S . -B cmake-build-debug -DCMAKE_BUILD_TYPE=Debug
cmake --build cmake-build-debug --target umacapture_tests
ctest --test-dir cmake-build-debug --output-on-failure
```

The binary can also be run directly (`cmake-build-debug/umacapture_tests.exe`);
it accepts the standard doctest flags (`--help`, `--test-case=...`, etc.). A
POST_BUILD step copies the matching `opencv_world4130[d].dll` next to it.

## Coverage

Coverage is measured with [OpenCppCoverage](https://github.com/OpenCppCoverage/OpenCppCoverage)
(gcov/lcov do not apply to MSVC). It is not wired into CMake, but the CI
`native-tests` job (`.github/workflows/ci.yml`) runs it after `ctest` and uploads
the HTML + Cobertura report as the `native-coverage` artifact on every PR — a
non-gating, always-on view of which linked `.cpp` lines no test reaches. To run it
locally on the built Debug binary, install it once (e.g.
`choco install opencppcoverage`), then from the `native/` directory:

```bat
OpenCppCoverage --sources native\src --excluded_sources native\vendor ^
  --export_type html:cmake-build-debug\coverage ^
  -- cmake-build-debug\umacapture_tests.exe
```

`--sources native\src` limits the report to backend code (paths are matched as
substrings, so vendored headers and the test TUs are excluded), and the HTML
report lands in `cmake-build-debug\coverage\index.html`. Use it to spot logic in
the linked `.cpp`s that no test reaches.

## Integration tests (golden)

The unit tests above deliberately stop at the ONNX/WinRT boundary. The
integration test in [`integration/`](integration) closes the other end: it drives
the real `umacapture_cli video` over recorded clips and diffs the recognized
`record.json` set against committed goldens, catching regressions in the full
scrape → stitch → recognize pipeline that no unit test can see.

Because it runs the real recognizer, it depends on **local-only assets** that are
not in git:

- the input clips under `testdata/clips/golden/` (`player_standard.mp4`, …), and
- the ONNX models under `sandbox/modules/`.

The goldens themselves (`integration/golden/*.json`) **are** committed — they are
the regression baseline, small deterministic JSON, not screenshots or models. Four
`metadata` fields are stripped before comparison: the three non-deterministic ones
(`record_id`, `trainer_id`, `captured_date`) and `recognizer_version`, which mirrors
the local `sandbox/modules/version_info.json` and moves on every vendor refresh. The
model **version string** is deliberately not part of the contract; what the models
*recognised* still is, so everything that remains after the strip is a deterministic
function of the clip and of the models actually in `sandbox/modules`. The cases are listed in
[`integration/cases.json`](integration/cases.json); a clip that isn't present
locally is skipped, so the manifest may name more clips than any one machine has.

The harness [`integration/run.py`](integration/run.py) is standard-library-only and
run via `uv run`. Point `--cli` at a **Release** build: in a Debug build the
pipeline's `assert_` is live and a violated invariant pops an abort/retry/ignore
dialog that blocks an unattended run.

```bash
# Regenerate goldens after an intended model/pipeline change (review the diff!):
uv run native/test/integration/run.py --update-golden \
  --cli native/cmake-build-release/umacapture_cli.exe

# Verify against the committed goldens:
uv run native/test/integration/run.py \
  --cli native/cmake-build-release/umacapture_cli.exe
```

It exits non-zero on any mismatch, and exits `77` when every selected case was
skipped (no local inputs).

### How much of the suite actually ran

CMake registers **one ctest per case** — `integration_golden.<name>`, read out of
`cases.json` at configure time and guarded on `uv` being on `PATH` — each with
`SKIP_RETURN_CODE 77`:

```bash
ctest --test-dir cmake-build-release -R integration_golden --output-on-failure
ctest --test-dir cmake-build-release -N          # the full expected set
```

The split exists because ctest suppresses the stdout of a test that passes *or*
skips: with a single aggregate test, "11 of 11 goldens ran" and "3 ran, 8 were
skipped" both printed the same `Passed` line, and only `-V` could tell them apart.
Per-case tests move that into the status line ctest always prints — a case with no
clip is its own `***Skipped`, and is named again in the "tests did not run" block.
On a fresh checkout / CI the whole set reports **Skipped**, never Failed.

A partial run stays legal (clips are large and local-only), so it is not turned into
a failure. What *is* a failure is coverage going backwards: the extra
`integration_golden_coverage` test runs no pipeline, only resolves the inputs, and
compares the runnable set against `integration/coverage_baseline.json` — a
gitignored, per-machine high-water mark it writes itself. Losing a case that used
to run fails with the names, and an intended shrink is acknowledged once:

```bash
uv run native/test/integration/run.py --coverage --accept-coverage \
  --cli native/cmake-build-release/umacapture_cli.exe
```

Where the assets never existed the coverage test skips with everything else, so CI
is unaffected. Between the two, `cases.json` states the expected ceiling and the
baseline states what this machine reached.

The mark only ever moves down **on request**. A baseline file that exists but cannot
be read is a failure, not a fresh start: rewriting it from the current set is exactly
how the mark would drop unnoticed, and the message would be indistinguishable from a
first run (measured on the pre-fix code — a baseline truncated mid-write turned the
same lost clip from exit 1 into exit 0 and lowered the mark 3 → 2). An **absent** file
stays a first run, because the baseline is gitignored and every clone legitimately
starts there. Lower a damaged mark deliberately with `--accept-coverage`.

That decision table is itself a ctest, `integration_coverage_selftest`
(`integration/test_run_coverage.py`). `--coverage` decides everything from file
existence, so the self-test drives it against a synthetic manifest inside a
`TemporaryDirectory` — no clips, no models, no cli, and no contact with the real
baseline. It is therefore one of the two integration tests here that are
unconditional and actually run in CI — the other is `integration_check_selftest`
below.

`run.py`'s per-case judge (`check_run`) gets the same treatment for the same reason:
a golden case only exercises a claim against the numbers its own clip happens to
produce, so a claim the judge quietly stopped comparing stays green on every case
whose declaration is right. This is sharpest for `expect_factor_switch_verdicts` (the
four counts `core/test_factor_switch_verdict_tally.cpp` pins the source of): a
declaration that matches the run passes whether or not the judge is still reading it.
[`integration/test_run_check.py`](integration/test_run_check.py) — `integration_check_selftest`
— drives `check_run` against hand-built `CompletedProcess` summaries, no cli or clip
needed: a matching declaration passes; each of the four verdict words disagreeing on
its own is caught by name (so a judge that compared only some of them, summed them, or
folded `empty` into `unreadable`, fails); a summary predating the key, or whose verdict
vocabulary is short or has an extra word, is refused rather than partly read; an
undeclared case asserts nothing about its verdicts either way; and a malformed
declaration (a missing or unknown verdict, a negative/boolean/float count, a list, or
`null`) is refused before any pipeline would run.

The same self-test also drives `check_probe_factors`, the strict `onFactorProbe`
check for `expect_probe_matches_golden_self`: every element the probe sent must agree
with the golden self list, and when the probe line states `below_threshold`, the
golden self list must also be exactly as long as the probe (the number of factors a
probe is cut at lives in `assets/config/chara_detail/scene_scraper.json` as
`self_factor_prefix_length`, not in this script, and never reaches the wire). A probe
line with no `below_threshold` field, or a non-boolean one, is refused rather than
defaulted.

Regenerated goldens are tied to the `sandbox/modules` models — to what they
*predict*, that is, not to the version string, which is stripped (above). When the
models change, rerun `--update-golden`, eyeball the diff, and commit the updated
goldens alongside the model change; a refresh that moves no prediction produces an
empty diff rather than 12 changed version lines.

`native/wasm/check_sources.py`'s own comment/string stripping has its own self-test,
`wasm_check_sources_selftest` ([`../wasm/test_check_sources.py`](../wasm/test_check_sources.py)),
registered next to the two above because it also needs only `uv` and no clip, model or
cli — not because it is part of the golden suite. It drives `strip_comments` and the
constructor/duplicate-instantiation probes that read its output against hand-built
text: a `/*` inside a line comment or a string literal, and a duplicated
`makePredictor<Decoder>` instantiation hidden behind one, are each caught; a
constructor or a duplicate instantiation entirely inside a real comment, an apostrophe
in a line comment, and a string literal containing `//` all stay quiet; and the real
`chara_detail_recognizer_models.cpp` / `wasm_recognizer_models.cpp`
/ `recognizer_prediction.h` still report no drift.

### Dual-decode equivalence (`integration_dual_decode.<name>`)

[`integration/run_dual_decode.py`](integration/run_dual_decode.py) reads the same
manifest and runs each clip **twice** — `video --color_matrix bt601` and
`--color_matrix bt709` — requiring one identical record set. Those flags decode the
clip's own YUV planes and convert them in `src/cv/decoded_frame_to_bgr.h` instead of
letting swscale decide, which is the only way to get a second colour interpretation
out of a decoder that always applies BT.601. A browser applies BT.709 to these clips
too — as its default for *untagged* content, not out of tag fidelity; every clip here
is untagged — so this is the measurement of how much colour shift recognition tolerates.

```powershell
ctest --test-dir cmake-build-release -R integration_dual_decode --output-on-failure
```

Read the two lines it prints per case in order. The `bt601` run is also diffed
against the committed golden — a **control**, since it reaches swscale's pixels
through a different decoder — and a disagreement is reported as `HARNESS`, not as a
colour finding. `replay` cases skip: FFV1 stores BGR0 and applies no matrix.

The ten portrait clips passed under both matrices even when `isHeaderGreen` still
carried a `g >= 180` floor; their header-green probe cleared it on both sides.
`landscape_2pane_ps5` is the case that did not: a 2326x1340 landscape import — a canvas
the size a two-pane browser share produces, carrying **one** pane's content (the detail
dialog in a ~738-wide column, composited from a portrait capture, the rest black; the
non-black bounding box is a single 738x1310 region on every frame, and no pane divider
is present) — whose probe reads G=194 under BT.601 and G=174 under BT.709, so it latched no pane and
produced **zero** records — the failure this suite exists to catch, and the reason it is
not enough for the suite to be green. That case states no `golden` (its clip is a
locally derived transcode, see `cases.json`), so no `integration_golden` ctest is
registered for it and its `bt601`-vs-golden control is absent; its pass line says so.

That clip is derived, not recorded: an FFV1 landscape source is transcoded to the
H.264 4:2:0 shape a real import has. The odd width is cropped because 4:2:0 needs an
even one, and the YUV is written with **BT.601** coefficients and **no** colour tags —
which is what the real-world clips look like, and what makes the two decoders disagree
in the first place: swscale reads untagged HD as BT.601 and gets the original pixels
back, a browser assumes BT.709 for the same bytes and lands ~20 G lower.

```sh
ffmpeg -i testdata/clips/source/ps5_2pane_2327x1340.mkv \
  -vf "crop=2326:1310:0:0,pad=2326:1340:0:30:color=black,\
scale=out_color_matrix=bt601:out_range=tv,format=yuv420p,\
setparams=colorspace=unknown:color_primaries=unknown:color_trc=unknown:range=unknown" \
  -fps_mode passthrough -c:v libx264 -preset medium -crf 12 -an \
  testdata/clips/golden/landscape_2pane_ps5_toppad.mp4
```

The input is the **primary FFV1 screen recording** (2327x1340, 374 frames), kept beside the
other clip sources. It is *pre-correction*: its content sits flush at row 0 with 30 black
rows at the bottom, so the `crop`/`pad` pair above performs the `_toppad` translation
described in the next section inline, rather than reading a separately corrected
intermediate. (An earlier revision of this recipe named a `ps5_2pane_2327x1340_toppad.mkv`
input; no such file exists — the intermediate was not kept.) Verified 2026-08-27: the
command above reproduces the committed clip's geometry and per-row luma exactly
(2326x1340, 374 frames; 0 of 1340 rows differ on frame 0).

#### The `_toppad` correction (2026-08-18)

Both landscape files padded the **wrong edge**. The content sat flush against row 0 with
30 black rows at the **bottom** — a combination a browser window share cannot produce:
the window decoration puts its padding at the **top** and the game content runs to the
frame's bottom edge. The fix is a **pure translation** of those 30 rows from bottom to
top at unchanged frame size (2326x1340, 374 frames); the vacated top rows are filled
**black** rather than with a drawn title bar, which would invent pixels nothing measured
— nothing outside the dialog takes part in recognition. The user found it and decided the
fix. The pre-correction files are left in place untouched; the manifest names the new,
`_toppad`-suffixed ones. The correction was verified per frame: the ancestor's old rows
0..1309 are sha256-identical to the corrected rows 30..1339 on all 374 frames, and a
29-row shift does not match.

### A browser's own pixels (`integration_golden.firefox_landscape_2pane_ps5`)

`--color_matrix bt709` is a *model* of what a browser does, and the model is not exact:
a browser's decoder also rounds its own way. That difference is not academic — it is
the whole margin. The clip above still imported as **zero records** in a real desktop
Firefox 153 after the `g >= 180` floor was gone, because Firefox's conversion left the
header's bottom transition row 3 to 5 units short of `isHeaderGreen`'s then-`g - b >= 120`
(measured 115..117 against swscale BT.601's 128..129). Note where the model stops: the
*same* frame through `in_color_matrix=bt709` reads 121 / 120 / 121 on that row, i.e. it
still clears 120 — by exactly 0 on the worst column — and it is the browser's further
4–5 units of rounding that push it under. That row is soft because the source is 4:2:0
and luma rows 124 and 125 share one chroma sample, not because of anti-aliasing.
The boundary landed one row high, and `DetailCropTracker` refused the reconstructed crop
for reaching outside the frame, so nothing latched — while every `integration_dual_decode`
case stayed green. *Which* edge it reaches outside depends on the material's geometry, so
the numbers below are stated for the `_toppad` files as they stand today; the incident was
originally measured on the pre-correction pair, 30 rows higher (rows 94/95, `top = -1.222`,
refused by `rect.top() >= 0`). Today the one-row-high scan solves a **larger** scale from
its 1152-row landmark gap (737.752 against the correct 737.112), so it comes out at
`top = +28.778`, height 1312, i.e. rect top 29 and **bottom 1341 against a 1340-row frame**
— refused by `rect.bottom() <= size.height()` instead. The correct scan lands its bottom
edge exactly on 1340, which the half-open gate admits. See the `g - b` note in
[`../src/cv/detail_crop_calibrator.h`](../src/cv/detail_crop_calibrator.h).

So the browser's pixels are an asset now, not an anecdote.
`testdata/clips/golden/firefox_landscape_2pane_ps5_toppad.mkv`
carries the 374 frames Firefox 153 handed to the wasm core, recorded losslessly as
FFV1/bgr0 and registered as a `replay` case. **It is that recording with its rows translated
afterwards** (see the `_toppad` note above), not a fresh browser run, so it is not
frame-for-frame what the browser emitted: the browser's rows 0..1309 are preserved
bit-identically at rows 30..1339 — verified per frame on all 374 — and the h264 ringing of
up to 10/255 that sat on the browser's rows 1310..1313, outside the content's bounding box
and outside every probe, is discarded. It is the **only** automated test in the
repo that can see a defect caused by a specific browser's decoder, and it does carry a
committed golden (unlike `landscape_2pane_ps5`): a lossless recording is a frozen
artefact, so its record set is reproducible on any machine holding the file, whereas the
`.mp4` above is regenerated by whatever local `libx264` is installed. The golden is
byte-identical to what `umacapture_cli video --color_matrix bt601` recognizes from the
source clip — the browser must reach the same record the CLI does, which is the actual
contract. **That is a measured fact about the file in place**, not an inherited one; see
"what the harness does and does not say" below for when it was re-measured and how.

It lives in `testdata/clips/golden/`, next to the clips every other case names, rather than
inside the scratch analysis directory it was produced in: `--data-dir` defaults to
`testdata/clips/golden/`, every other manifest entry is a bare filename, and a scratch
analysis directory is exactly the kind of place that gets swept. A machine without the file
skips the case like any other.

**Reproducing the dump** (needed only when the web decode path changes, or for another
browser). It is a three-part harness, and the last part is what makes it trustworthy:

1. Serve the clip and a page over `http://127.0.0.1` (WebCodecs needs a secure context;
   localhost qualifies). The page must decode exactly the way
   [`web/video_import.mjs`](../../web/video_import.mjs) does — same `mediabunny`
   `VideoSampleSink` with `hardwareAcceleration: 'prefer-software'`, `sample.codedWidth/
   codedHeight`, and `sample.copyTo(buf, { format: 'RGBA' })` — and POST each frame's raw
   bytes to the server. Anything else measures the harness, not the product.
2. The server pipes those bytes straight into an encoder, one process for the whole run:
   `ffmpeg -f rawvideo -pix_fmt rgba -s <w>x<h> -framerate 30 -i - -an -c:v ffv1 -level 3
   -pix_fmt bgr0 <out>.mkv`. FFV1/bgr0 in Matroska is precisely what `Ffv1Recorder` writes
   and `Ffv1Reader` accepts, so `replay` consumes the browser's pixels unaltered.
3. **Validate the transport before believing the pixels.** Encode the same frames a second
   time from ffmpeg's own conversion of the source
   (`-vf scale=in_range=limited:in_color_matrix=bt601:out_range=full`) into the same CFR-30
   FFV1, and check that `replay` of *that* reproduces the **record set** `video
   --color_matrix bt601` produces, byte for byte. Without this control, a difference in the
   CFR-30 retiming or the FFV1 round trip is indistinguishable from a colour finding. It was
   run for this file and it matched. **Records is what the comparison compares** — nothing in
   the integration tooling compares images (`run.py` collects `*/record.json` only, and
   `run_dual_decode.py` diffs the same normalised text) — and that is no longer a formality:
   the core's own BT.601 reaches swscale's pixels only to within one unit per channel
   (`cv/decoded_frame_to_bgr.h`'s coarsened luma ramp), so the two runs' image dumps
   (`base.png` / `skill.png` / `factor.png` / `campaign.png`) would differ even where every
   record is identical. Read as a claim about pixels, this control no longer holds.

Firefox is driven unattended over Marionette with a throwaway profile; no geckodriver or
Selenium is involved.

**What the harness does and does not say about the file in place.** The three steps above
were run against the **pre-correction** clip, and the committed replay input is that dump
translated by +30 rows, not a rerun. So step 3's control — the browser's replay and
`video --color_matrix bt601` reaching the same records — was originally established for the
untranslated pixels.

**It has since been re-established for the corrected pair (2026-08-22), directly.** The
committed golden was compared against a fresh `umacapture_cli video --color_matrix bt601
--frame-resize` run over `landscape_2pane_ps5_toppad.mp4`, in the same canonical form
`run.py` compares (`_dumps` over `collect_records`, the volatile metadata keys stripped):
one record each, **identical**, on a run that reported `forwarded_frames=297`,
`anchor_unit 737..737`, no errors. The committed
`integration_golden.firefox_landscape_2pane_ps5` reproduces alongside it. So the sentence
above — the browser must reach the same record the CLI does — states a contract that holds
today, and a red on this case is a **real defect**, not a golden awaiting regeneration.

Two things that check does *not* carry, stated so the next reader does not over-read it.
It compares **records**, which is the whole of what this suite asserts, and deliberately
not images (see the control's own note above). And its `video` half decodes an `.mp4` that
each machine regenerates with its own `libx264`, so the equality is a fact about a
matched pair on one machine rather than something the repository alone can re-derive; the
lossless `.mkv` half is the reproducible one.

What is *also* verified for the file in place is the pixel data itself (bit-identity of
rows 0..1309 to rows 30..1339, per frame, all 374) and its container shape (ffv1 / bgr0 /
2326x1340 / 30 fps / 374 frames / `extradata_size=42`, each matching the original). To get
a dump that is again a browser's own frames end to end, serve
`landscape_2pane_ps5_toppad.mp4` and re-run all three steps.
