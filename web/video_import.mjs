// Video import: the web front end's OFFLINE frame producer.
//
// This module owns everything that knows about a container and a codec -- demuxing with mediabunny, decoding
// with the browser's WebCodecs VideoDecoder (which mediabunny's VideoSampleSink drives), and handing each
// decoded sample's own tightly packed I420 planes to the core's offline push entry point. It owns NO
// session state: `web/worker.js` takes the core's capture-session claim, supplies the flow gate and the push,
// and decides when this producer is cancelled. Keeping the split there is what lets the whole decode loop be
// driven from Node with a stubbed decoder (tool/test_web_video_import.mjs) while the session lifecycle stays
// under the tests that already cover it.
//
// THE PRODUCER CONTRACT (.claude/rules/platform-parity.md). Video import is an offline producer, the web
// sibling of the CLI's VideoLoader and Ffv1Reader, so it:
//
//   * resolves NO pane decision and carries NO pane snapshot. It emits the full decoded frame with the default
//     anchor and lets DetailCropTracker::beginFrame apply the latched pane on the consumer side. That is why it
//     must not reuse the live push (pushFrameRgba takes a snapshot token); it calls pushOfflineFrame.
//   * copies each frame IN ITS OWN PIXEL FORMAT and applies no colour conversion of its own. WebCodecs converts
//     with BT.709 -- its DEFAULT for the untagged clips this app is given, not tag fidelity, and the reported
//     `colorSpace.matrix` is not usable as a branch either (Firefox 153 reports `bt709` even for a stream it
//     decoded as BT.601; see native/src/cv/decoded_frame_to_bgr.h) -- while
//     cv::VideoCapture's FFmpeg backend converts every clip with BT.601 limited range regardless of its tags --
//     so an RGBA copy of a YUV frame has already diverged from the CLI before the core sees it, by 18 units of
//     G at the very probe pane detection gates on. Converting in the core (cv/decoded_frame_to_bgr.h) is what
//     makes the two offline producers agree on pixel values -- to within one unit per channel, since that
//     header's limited-range luma ramp is deliberately coarsened -- and not merely on geometry. See
//     coreFormatOf for which formats that leaves readable, why a browser that hands back RGB is nevertheless
//     taken rather than refused, and how the fact that it did is made observable instead of silent.
//   * ASKS FOR A SOFTWARE DECODER, because that is what makes the point above reachable at all on a phone.
//     See DECODER_OPTIONS below.
//   * stamps every frame with MEDIA time taken from the sample's own presentation timestamp, never with arrival
//     time. Every gate in the pipeline advances on Frame::timestamp() -- the 200 ms scene-begin dwell, the
//     1000 ms scene-end debounce, StationaryFrameCatcher's 200 ms -- so a faster-than-realtime feed stamped
//     with performance.now() compresses all of them toward zero and no scene ever ends. The live path
//     deliberately re-stamps (Firefox reports timestamp === 0 for a VideoFrame built from a <video>); an
//     import deliberately does not. Windows does the same thing with CAP_PROP_POS_MSEC (cv/video_loader.h).
//   * passes the DECODED size to the core, which for an unshaped frame is the frame's own size.
//
// WHY THE VISIBLE RECT AND NOT THE CODED ONE. A coded frame is padded out to the codec's macroblock alignment;
// those rows and columns are not picture content and no other producer ever sees them (OpenCV's VideoCapture
// hands the CLI the visible frame, and a live capture surface has no coded padding at all). Copying the visible
// rect is therefore not a shaping step -- it is what "the full decoded frame" means for a compressed clip.
//
// AND WHY NO `rect` OPTION IS PASSED TO SAY SO. mediabunny already expresses the whole VideoSample copy API in
// VISIBLE coordinates: `sample.codedWidth` / `codedHeight` are getters that return `visibleRect.width/height`,
// and `allocationSize()` / `copyTo()` default their rectangle to exactly that. Passing one explicitly is both
// unnecessary and a shape trap -- `sample.visibleRect` is {left, top, width, height} while `options.rect` is
// validated as {x, y, width, height}, so handing the former to the latter silently copies from origin (0,0) on
// a clip whose visible offset is not zero, and passing {x: left, ...} instead makes the buffer-backed path
// reject the rect as out of bounds (it bounds-checks against the VISIBLE size). Omitting it is the only form
// that is correct on both backings, because it hands the offset to whoever owns the pixels: in a browser the
// VideoFrame, whose own default rect is its visibleRect.
//
// ROTATION IS REPORTED, NOT APPLIED. The clip's clockwise rotation travels to the core with every frame and is
// applied there, after the colour conversion -- see pushOfflineFrame in native/wasm/wasm_api.cpp for why
// it must happen at all (cv::VideoCapture auto-rotates and neither mediabunny nor VideoFrame.copyTo does) and
// why it must happen after the conversion rather than on the planes (4:2:0 chroma is shared by a 2x2 block, so
// rotating the planes re-pairs luma with chroma half a sample away from where OpenCV's rotate does).
//
// MEMORY: the file is read through mediabunny's BlobSource, which issues range reads against the Blob, so a
// multi-gigabyte clip is never resident. The removed implementation read the whole file into an ArrayBuffer on
// the Dart side and transferred it; that is the defect this replaces, and it is also why there is no byte-size
// cap here: the memory argument for one is gone, and the time argument is answered by cancellation rather than
// by a threshold nobody could derive.

// The vendored bundle (tool/web_deps.json pins mediabunny 1.52.3, MPL-2.0). Resolved against this module's own
// URL rather than passed in from Dart, because the worker, this module and web/wasm/ are copied into the build
// output with their relative layout intact -- so there is nothing for Dart to tell us that we do not already
// know, and one fewer message field to keep in sync.
const MEDIABUNNY_URL = new URL('./wasm/mediabunny/mediabunny.mjs', import.meta.url).href;

// LAZY, AND MEMOIZED. The bundle is ~1.3 MB of JavaScript that a user who never imports a clip must not pay for
// at first paint, so it is reached through `import()` at the first import and not by a static import. The memo
// is dropped on failure so a load that failed for a transient reason (an interrupted fetch) can be retried by
// starting another import, rather than being remembered as broken for the lifetime of the worker.
//
// (What a failed load MEANS is decided at the call site in decodeClipIntoPipeline, not here, so that the Node
// harness's substitute loader is classified by the same line the real one is.)
let mediabunnyPromise = null;
export function loadMediabunny() {
  if (mediabunnyPromise === null) {
    mediabunnyPromise = import(MEDIABUNNY_URL).catch((e) => {
      mediabunnyPromise = null;
      throw e;
    });
  }
  return mediabunnyPromise;
}

// How often a progress message is posted, in milliseconds of WALL clock. A message per decoded frame would be
// tens of thousands of postMessages for a long clip -- the import is deliberately not paced by the clock, so a
// hardware decoder produces them far faster than any UI can render -- and the main thread is the side that can
// least afford them. Compared against a clock this side samples; nothing here schedules a timer (see the
// no-timer note in worker.js's flow gate).
const PROGRESS_INTERVAL_MS = 250;

// THE DECODER THIS PRODUCER ASKS FOR, and the one it settles for.
//
// WHY SOFTWARE IS THE REQUEST. A hardware decoder is free to hand back whatever surface format its silicon
// produced, and on Chrome for Android it hands back frames that have ALREADY been through the browser's YUV
// matrix. Measured on SOG04 / Chrome for Android 150.0.7871.186 with this app's own clips (736x1308 H.264, no
// colour tags): the default (hardware-preferring) configuration yields `format: 'RGBA'` with
// `colorSpace.matrix === 'bt709'`, and neither `copyTo({format: 'I420'})` nor `copyTo({format: 'NV12'})` can
// ask for the planes back -- both fail with `NotSupportedError: allocationSize: This pixel format conversion
// is not supported.` There is no way from there to the pixels the CLI sees; the conversion has already
// happened. `hardwareAcceleration: 'prefer-software'` yields tightly packed `I420` on the same device and the
// same clip, which is exactly what coreFormatOf wants.
//
// AND IT IS ALSO FASTER HERE, which is the opposite of the usual expectation and worth recording so nobody
// "optimises" it back. Decode + copyTo over 150 frames, same device, same clip: 83.2 fps hardware-preferring
// against 177.4 fps software; desktop Chrome 151, 127.6 fps against 389.2 fps. An import reads every frame
// back to the CPU, and a hardware decoder's readback is the cost that dominates -- so the copy this producer
// must make is precisely what makes the hardware path the slow one.
//
// "PREFER" IS NOT "GUARANTEE". The flag is a hint: a UA may configure a hardware decoder anyway, and a UA may
// also refuse the configuration outright (the spec allows `configure` to fail for a config
// `isConfigSupported` accepted, and `hardwareAcceleration` is part of the config). Both are handled --
// the refusal by the one retry below, and a hardware decoder that answered the hint with a converted frame by
// coreFormatOf, which refuses it by name rather than importing the wrong colours.
const DECODER_OPTIONS = Object.freeze({ hardwareAcceleration: 'prefer-software' });
// The retry, used ONCE and only for a decoder that could not be configured at all. Deliberately
// `no-preference` rather than `prefer-hardware`: the point is to let the UA pick whatever it can actually
// configure, not to swing to the opposite hint.
const FALLBACK_DECODER_OPTIONS = Object.freeze({ hardwareAcceleration: 'no-preference' });

// Why an import ended. `completed` is the only one that means the clip was fully processed.
export const IMPORT_COMPLETED = 'completed';
export const IMPORT_CANCELLED = 'cancelled';
// The flow gate reported that the core publishes no frame-flow counters, i.e. there is no brake. Unreachable in
// production -- startCaptureSessionVerdict refuses an offline session against such a core before the claim is
// even taken -- so reaching it means the module was swapped underneath a running import.
export const IMPORT_UNBRAKED = 'unbraked';

// WHY EVERY REFUSAL CARRIES A KIND AND NOT JUST A MESSAGE. The messages below are English, developer-worded and
// written for a log; the user gets a Japanese line, and the only line the UI could show for all of them at once
// was a hedge ("an unsupported format, or another operation is running") that named neither. So each refusal
// carries a STABLE DISCRIMINATOR alongside its prose: the worker relays it on `videoImportDone.reasonKind`, and
// Dart maps it to one translated sentence per kind (lib/src/core/video_import_ops.dart, `VideoImportReason`).
// The prose stays exactly where it was -- the log, the worker console and the outcome's `message` field -- and is
// never rendered.
//
// Adding a refusal therefore means adding a constant here, an enum case in `VideoImportReason` and a line in
// `assets/translations/ja.json`. Forgetting the last two is not fatal: an unknown kind degrades to the generic
// result line, which is what the user saw for every refusal before this existed.
export const REFUSED_DECODER_UNAVAILABLE = 'decoder_unavailable';
export const REFUSED_NOT_A_VIDEO = 'not_a_video';
export const REFUSED_NO_VIDEO_TRACK = 'no_video_track';
export const REFUSED_CODEC_UNSUPPORTED = 'codec_unsupported';
export const REFUSED_PIXEL_FORMAT = 'pixel_format_unsupported';

// Thrown for the conditions a user can act on (a file with no video track, a codec this browser cannot decode),
// as opposed to a bug. The worker relays these through `failExpected`, so they do not become Sentry issues.
export class VideoImportRefused extends Error {
  constructor(kind, message) {
    super(message);
    this.name = 'VideoImportRefused';
    this.expected = true;
    // The discriminator the UI translates. Read by reportVideoImportDone (web/worker.js) and by nothing else.
    this.kind = kind;
  }
}

// Decodes `blob` end to end and pushes every frame into the recognition pipeline through `host`.
//
// `host` is the worker's side of the split, and every one of its members is there because this module must not
// know about it:
//   * `pushFrame(pixels, format, width, height, rotation, mediaTsMs, layout)` -> whether the frame entered the
//     pipeline. `layout` is what `copyTo` resolved to, forwarded unchanged: the core, not this module, decides
//     whether the decoder laid the planes out the way the conversion reads them. A layout it cannot read is a
//     THROW out of `pushFrame` rather than a `false`, because it is a statement about the copy API this whole
//     clip will keep making, not about one frame.
//   * `awaitRoom()` -> parks until the core's frame path has room; false means the core publishes no counters,
//     i.e. there is no brake at all and this import must stop rather than run an unbounded queue. It also
//     returns early -- and still true -- once `isCancelled()` holds, because the park's only other exit is the
//     pipeline dequeuing, and a pipeline being torn down never does. What it reports is therefore "a brake
//     existed", not "room was found", and the `isCancelled()` check on the far side of it is what turns an early
//     return into the cancelled outcome.
//   * `isCancelled()` -> whether the worker has revoked this producer (a cancel message, or a teardown).
//   * `onProgress(info)`, `log(message)`.
//   * `loadModule()` (optional) -> the mediabunny namespace; overridden only by the Node harness.
//   * `now()` (optional) -> the wall clock used for progress throttling only.
//
// Returns { reason, decoded, supplied, rejected, durationMs, lastMediaTsMs }. Throws only for a genuine
// failure; a cancellation is a return value, because it is an outcome and not an error.
export async function decodeClipIntoPipeline(blob, host) {
  const now = host.now ?? (() => performance.now());
  const loadModule = host.loadModule ?? loadMediabunny;

  // A FAILED LOAD IS A REFUSAL, NOT A BUG. Being lazy is exactly what makes this fetch fail for ordinary,
  // user-actionable reasons -- the tab went offline between first paint and the first import, or an extension or
  // a corporate proxy blocked the request -- so letting it through as a failure would file a Sentry issue per
  // attempt for a condition the user, not this code, has to resolve. Nothing else this function does depends on
  // anything but the bundle, so there is no other meaning a throw from here can have. The cause is kept in the
  // message; only the classification changes.
  let mediabunny;
  try {
    mediabunny = await loadModule();
  } catch (e) {
    throw new VideoImportRefused(REFUSED_DECODER_UNAVAILABLE, 'the video decoding library could not be loaded ('
      + describe(e) + '); check the connection and try the import again');
  }
  const { Input, ALL_FORMATS, BlobSource, VideoSampleSink } = mediabunny;

  // Constructed BEFORE the first cancellation check, and every exit below is inside the try that disposes it.
  // The alternative -- checking first and constructing after -- leaves one exit (a cancel that landed during the
  // module load) on which nothing is disposed, which is precisely the leak the cancel path has to avoid.
  // CONSTRUCTION IS PART OF THE FORMAT PROBE, so it is inside the refusal classification too. mediabunny defers
  // the actual sniffing to the first read, but `new Input` is where an argument it cannot make sense of is
  // rejected, and neither end of that is a bug in this app.
  let input;
  try {
    input = new Input({ formats: ALL_FORMATS, source: new BlobSource(blob) });
  } catch (e) {
    throw asRefusalIfUnsupportedFormat(e, blob);
  }
  let decoded = 0, supplied = 0, rejected = 0;
  let durationMs = 0, lastMediaTsMs = 0;
  // The route the frames took, empty unless some frame reached the core through a browser colour conversion.
  // See coreFormatOf: such a frame is accepted, but the fact that it was must not be invisible, so it travels
  // out with the summary as well as into the log.
  let matrixConverted = '';
  // One reusable scratch buffer, sized on demand. Safe because exactly one frame is in flight at a time:
  // pushFrame copies the bytes into the wasm heap synchronously (embind's convertJSArrayToNumberVector) and has
  // returned before the next sample is copied in. The live path needs TWO buffers only because it compares
  // consecutive frames in place; an import compares nothing, and it no longer rotates on this side either.
  let planes = null;
  try {
    if (host.isCancelled()) return summary(IMPORT_CANCELLED, 0, 0, 0, 0, 0, matrixConverted);
    // THE `track === null` CHECK BELOW IS NOT THE ONLY WAY A NON-VIDEO FILE ARRIVES, and assuming it was is what
    // made "the user picked a PDF" a Sentry issue. `null` means "a container we understand, with no video track
    // in it"; a file that is not a media container at all never gets that far -- this is the call that sniffs the
    // format, and mediabunny answers an unrecognised one by THROWING UnsupportedInputFormatError. Both are the
    // same ordinary, user-actionable situation (docs/video-import.md), so both take the refusal channel.
    let track;
    try {
      track = await input.getPrimaryVideoTrack();
    } catch (e) {
      throw asRefusalIfUnsupportedFormat(e, blob);
    }
    if (track === null || track === undefined) {
      throw new VideoImportRefused(REFUSED_NO_VIDEO_TRACK, 'this file contains no video track');
    }
    // ASYNC GETTERS THROUGHOUT, never the same-named properties. mediabunny keeps `track.codec`, `.rotation`,
    // `.codedWidth/Height` and `.displayWidth/Height` as DEPRECATED synchronous getters that route through
    // `requireSync`, which THROWS ("... is deprecated and not available synchronously for this track") whenever
    // the track's backing resolves that field asynchronously -- which is exactly what a hydrating or delegating
    // backing does. Such a throw is not an app state, so it would surface as a failure and a Sentry issue for a
    // perfectly ordinary clip. The `get*()` forms are the supported ones and never throw for that reason.
    const codecName = await describeCodec(track);
    // PRE-FLIGHT THE CODEC, before a single packet is decoded. mediabunny asks the browser whether it can
    // configure a decoder for this track's actual codec, so an HEVC phone recording on Firefox is refused up
    // front with a message naming the codec, instead of failing deep in the decode loop after the user has
    // waited. (docs/video-import.md: HEVC coverage is per-engine and cannot be closed from here.)
    if (!(await track.canDecode())) {
      throw new VideoImportRefused(REFUSED_CODEC_UNSUPPORTED,
        'this browser cannot decode the clip\'s video codec (' + codecName + ')');
    }
    // The DENOMINATOR the front end renders against, read from the container's own metadata rather than
    // estimated from a frame count. Guarded: a failure must cost the import its progress bar and nothing else.
    //
    // METADATA FIRST, AND THE SCAN NEVER ON THE CRITICAL PATH. `computeDuration()` resolves the LAST packet's
    // timestamp, which for a container that declares no duration means mediabunny reading its way to the end of
    // the file -- a full ranged-read pass over the clip, proportional to its size, before the first frame is
    // decoded. Matroska from OBS is routinely such a container, and a multi-gigabyte one is the ordinary case
    // rather than the exotic one. Awaiting it here cost twice over: the import produced nothing until the scan
    // finished, and a `stop` or a `cancel` delivered into the scan waited it out -- the worker joins this
    // producer before Module.stop(), so every later teardown queued behind that join for the whole pass.
    //
    // `getDurationFromMetadata()` is mediabunny's cheap answer (the container's own duration element, no packet
    // walk) and returns null when the file does not carry one. When it does not, the scan is STARTED AND NOT
    // AWAITED: it upgrades `durationMs` if and when it lands, every progress message reads the field as it
    // stands, and until then progress is reported as counts -- which is the fallback the message protocol
    // already documents. Cancellability alone would have been the weaker fix: mediabunny exposes no abort for
    // the walk, so the reads would still run to completion; only nobody would be waiting for them. Here nobody
    // waits AND `input.dispose()` in the `finally` below is what stops the reads.
    //
    // Neither call can block on a live stream (the "resolves once the live stream ends" caveat on both): a
    // BlobSource is a finite byte range, so `skipLiveWait` has nothing to skip.
    try {
      const declared = await track.getDurationFromMetadata();
      durationMs = (typeof declared === 'number' && Number.isFinite(declared) && declared > 0)
        ? Math.round(declared * 1000) : 0;
    } catch (e) {
      host.log('video import: reading the clip\'s declared duration failed (' + describe(e) + ')');
    }
    if (durationMs === 0) {
      // Deliberately not assigned to anything: nothing may await this, and both settlements are handled here so
      // a rejection cannot reach self.onunhandledrejection. A result that arrives after the import has already
      // ended writes a field nobody reads again, which is why it needs no cancellation of its own.
      track.computeDuration().then(
        (seconds) => {
          if (typeof seconds !== 'number' || !Number.isFinite(seconds) || seconds <= 0) return;
          durationMs = Math.round(seconds * 1000);
          host.log('video import: the clip declared no duration; a background scan resolved it as '
            + durationMs + ' ms');
        },
        (e) => {
          host.log('video import: the clip declares no usable duration (' + describe(e) + '); progress will be '
            + 'reported as a frame count only');
        },
      );
    }
    // THE CODED SIZE, which is what this producer pushes (rotated below when the clip says so) -- deliberately
    // not `displayWidth/Height`, which are rotation- AND pixel-aspect-adjusted and would therefore print a
    // geometry no frame on this path ever has, for exactly the rotated clips the line is most needed for.
    const trackRotation = await track.getRotation();
    const codedWidth = await track.getCodedWidth();
    const codedHeight = await track.getCodedHeight();
    host.log('video import: ' + codecName + ' ' + codedWidth + 'x' + codedHeight
      + (trackRotation ? ' rotated ' + trackRotation + ' degrees clockwise on the way in' : '')
      + ', duration ' + (durationMs > 0 ? durationMs + ' ms' : 'not declared; scanning for it in the background'));
    if (host.isCancelled()) return summary(IMPORT_CANCELLED, decoded, supplied, rejected, durationMs, 0, matrixConverted);
    // Posted before the first frame so the UI can render a determinate bar from the outset -- when the container
    // declared a duration. When it did not, this one carries `durationMs: 0` and a later message upgrades it (see
    // the background scan above); a bar that changes shape once is the price of not delaying every frame of the
    // import behind a full pass over the file.
    host.onProgress({ decoded: 0, supplied: 0, mediaTimeMs: 0, durationMs });

    let lastProgressAt = now();
    let reason = IMPORT_COMPLETED;
    // Whether the sink ever handed this producer a sample. It is the line between "the decoder could not be
    // configured" and "the decoder ran"; see the retry below for why that line and not a count of frames.
    let anySampleYielded = false;
    // SEQUENTIAL, NO SEEKING AND NO THINNING. Every decoded sample is supplied, in order: the scroll estimator
    // needs a minimum inter-frame overlap and StationaryFrameCatcher compares consecutive DELIVERED frames, so
    // sampling the clip would degrade a base image silently rather than fail loudly (docs/video-import.md).
    const runDecodeLoop = async (decoderOptions) => {
      const sink = new VideoSampleSink(track, decoderOptions);
      for await (const sample of sink.samples()) {
        anySampleYielded = true;
        try {
          // A FAST PATH, NOT THE BARRIER: it only saves a cancelled import one pointless park at the gate below.
          // The check AFTER the park is the one that decides the outcome, and removing this line alone changes
          // no result -- which is exactly what the falsification pass found, so do not read it as a second
          // guarantee.
          if (host.isCancelled()) { reason = IMPORT_CANCELLED; break; }
          // THE BRAKE, awaited BEFORE the copy rather than after the push, so a full pipeline also stops this
          // side allocating the next frame's pixels. An import runs the core's video-mode queue, which on
          // Emscripten is QueueLimitMode::NoLimit -- it never blocks and never drops -- so this park is the only
          // thing bounding memory (see awaitOfflineFrameRoom in worker.js).
          if (!(await host.awaitRoom())) { reason = IMPORT_UNBRAKED; break; }
          // THE BARRIER, and the only one. The gate can hold this frame indefinitely, and it hands a revoked
          // producer back early precisely so this line can decide the outcome -- so a cancel delivered into the
          // park is answered here rather than with one more push. Deleting this check does not merely lose a
          // millisecond of latency: it loses the cancel.
          if (host.isCancelled()) { reason = IMPORT_CANCELLED; break; }

          // VISIBLE dimensions: mediabunny's `codedWidth/codedHeight` on a SAMPLE are getters over `visibleRect`,
          // and the default copy rectangle is the same thing (see the header note on why no `rect` is passed).
          const width = sample.codedWidth;
          const height = sample.codedHeight;
          // THE FRAME'S OWN FORMAT, resolved per sample. A decoder is free to change it mid-clip in principle,
          // and it costs one lookup to not care. `copyOptions` is either `undefined` -- copy whatever the frame
          // already is -- or the one conversion that costs nothing; see coreFormatOf.
          const { format, copyOptions, matrixNote } = coreFormatOf(sample.format, sample.colorSpace);
          // ONCE PER IMPORT, NOT ONCE PER FRAME. `matrixNote` is non-null for every frame of such a clip, and
          // a warning per frame would be tens of thousands of postMessages -- the same reason progress is
          // throttled. The first one is kept for the summary so the outcome message carries it too: a warning
          // that only exists in a log line nobody collected is not an observable path.
          if (matrixNote !== null && matrixConverted === '') {
            matrixConverted = matrixNote;
            host.log('video import: this browser\'s video decoder handed the app ' + matrixNote
              + ', so the clip\'s colours are the browser\'s conversion and not the one the app\'s recognition '
              + 'was measured against; importing anyway -- report this if the clip yields no records');
          }
          const size = sample.allocationSize(copyOptions);
          if (planes === null || planes.length !== size) planes = new Uint8Array(size);
          // THE LAYOUT `copyTo` RESOLVED TO, carried to the core UNCHANGED and not judged here. The core reads
          // the buffer as tightly packed planes; whether this one is that is the core's question, and it is
          // answered in one place for both wasm entry points (wasm_api.cpp's refuseUnreadableLayout, over
          // color::tightlyPackedLayout). This module used to re-state the packing rule in JS, back when
          // pushOfflineFrame took no layout at all -- two implementations of one rule, of which only one reads
          // the pixels. Synthesising a layout here instead of forwarding the UA's answer would be the same
          // defect wearing a different hat.
          const layout = await sample.copyTo(planes, copyOptions);
          // MEDIA TIME. `sample.timestamp` is the presentation time in SECONDS; the core takes whole
          // milliseconds and clamps the sequence monotonic itself (cv/media_timestamp.h), so rounding here is
          // the whole conversion.
          const mediaTsMs = Math.round(sample.timestamp * 1000);
          decoded++;
          lastMediaTsMs = mediaTsMs;

          // ROTATION, reported rather than applied (see the header note). Every sample carries it -- the decoder
          // wrapper stamps the track's rotation onto each one -- so it is read per sample and not hoisted out of
          // the loop.
          const rotation = sample.rotation ?? 0;
          if (host.pushFrame(planes, format, width, height, rotation, mediaTsMs, layout)) supplied++;
          else rejected++;

          const at = now();
          if (at - lastProgressAt >= PROGRESS_INTERVAL_MS) {
            lastProgressAt = at;
            host.onProgress({ decoded, supplied, mediaTimeMs: mediaTsMs, durationMs });
          }
        } finally {
          // Every exit closes the sample, including the `break`s above and a throw from copyTo. A VideoSample
          // holds a decoded frame (a GPU or system-memory allocation the GC does not account for), and the
          // decoder stops producing once too many are outstanding -- so leaking one stalls the import.
          sample.close();
        }
      }
    };

    // ONE RETRY, AND ONLY FOR A DECODER THAT NEVER RAN. `prefer-software` is a hint the UA may reject outright,
    // and a rejected `configure` surfaces here as a throw out of the sample iterator (mediabunny routes the
    // VideoDecoder error callback into the iterator's out-of-band error) -- indistinguishable, at the throw
    // site, from a corrupt clip. `anySampleYielded` is what tells them apart: a sink that never yielded a
    // sample never decoded anything, so re-running the whole clip on a decoder the UA will accept costs one
    // configure and can push no frame twice. Once a sample HAS been yielded the decoder demonstrably works,
    // whatever went wrong afterwards is about the clip's pixels rather than about which implementation decoded
    // them, and a retry would re-push every frame already supplied. So that case rethrows.
    //
    // A CANCEL IS NOT RETRIED EITHER: the producer has been revoked, and starting a second decode under a
    // revoked session is exactly the push-after-teardown the worker's join exists to prevent.
    //
    // AND A CANCEL IS NOT A FAILURE. It is asked FIRST, before `anySampleYielded`, and it RETURNS rather
    // than rethrowing, because this module's contract is that "a cancellation is a return value, because it
    // is an outcome and not an error" (see the note on this function) -- and that used to hold only for the
    // `break` paths. A throw that arrives while the session is already revoked took the other limb: the
    // branch that exists to STOP THE RETRY also rethrew, the worker classifies a throw with no `expected`
    // flag as `'failed'` (web/worker.js), and the client files a report for it. So a user who pressed cancel
    // was told the import broke, and a deliberate user action produced a Sentry issue with no defect behind
    // it. The teardown throwing here is not hypothetical in this bundle: mediabunny's `iterator.return()` is
    // not inert -- it closes an already-yielded sample and makes the next call throw "VideoSample is closed"
    // (see the note in `firstTwoSamplesAt`).
    //
    // The exception is not swallowed, it is DEMOTED: it goes to the log, which is a breadcrumb on any report
    // this session does file, so a teardown that throws for a real reason is still visible -- it just no
    // longer decides the outcome of an import the user had already ended.
    //
    // WHY THE PRE-FLIGHT ABOVE IS LEFT ALONE. `track.canDecode()` takes no arguments in this bundle
    // (mediabunny 1.52.3) -- it probes the track's own decoder config with no `hardwareAcceleration` in it --
    // so it CANNOT be made to agree with the config the sink builds; mediabunny's own VideoSampleSink calls the
    // same argument-less `canDecode()` before configuring. Matching the two would mean reimplementing the probe
    // against the global `VideoDecoder` here, which is browser-only and would make this branch unreachable from
    // the Node harness. The pre-flight therefore keeps the question it can actually answer -- "can this browser
    // decode this CODEC at all", the refusal that names the codec -- and the accelerator hint is answered by
    // this retry instead.
    // THE DEMOTION IS ONE FUNCTION BECAUSE IT HAS TWO SITES. Both decode loops can throw after the session has
    // been revoked, and the cause described above -- `iterator.return()` closing an already-yielded sample --
    // has nothing to do with which decoder options the loop was configured with, so it lands the same way in
    // the retry. The retry used to sit in the `catch` rather than in a `try`, which left it as the one path
    // out of this function that still turned a cancellation into a failure and a Sentry report; a second copy
    // of the branch would only have moved the drift, so both sites ask the same function instead.
    const demoteIfCancelled = (e) => {
      if (!host.isCancelled()) {
        return false;
      }
      host.log('video import: the decode threw after the import had been cancelled (' + describe(e)
        + '); reporting the cancellation rather than a failure');
      reason = IMPORT_CANCELLED;
      return true;
    };

    try {
      await runDecodeLoop(DECODER_OPTIONS);
    } catch (e) {
      if (!demoteIfCancelled(e)) {
        if (anySampleYielded) {
          throw e;
        }
        host.log('video import: a software video decoder could not be configured (' + describe(e)
          + '); retrying with the browser\'s own choice of decoder');
        try {
          await runDecodeLoop(FALLBACK_DECODER_OPTIONS);
        } catch (retryError) {
          if (!demoteIfCancelled(retryError)) {
            throw retryError;
          }
        }
      }
    }
    // DETERMINISTIC COMPLETION. Falling out of the loop means mediabunny's sample iterator was exhausted, which
    // happens only after the last packet has been decoded AND the decoder has been flushed -- so every frame the
    // clip contains has been pushed. There is nothing to guess and nothing to wait out. The removed
    // implementation had no such signal and terminated on "at least one record finished, then four seconds of
    // native silence", capped at 300 s, so a clip that produced no records waited the full cap.
    // What is still to come after this -- the pipeline draining the frames already queued, and the records it
    // writes -- is the JOIN's job, and the join is what the worker's teardown does next (Module.stop() = flush).
    //
    // NO `decoded === 0` RECLASSIFICATION HERE, unlike the Windows driver, which turns a run that opened a track
    // and decoded nothing into a refusal (windows/runner/video_import_session.h). The divergence is the
    // demuxer's, not a policy difference (.claude/rules/platform-parity.md asks for the constraint by name):
    // OpenCV's FFmpeg backend exposes NO track list and NO decoder error, so Windows cannot ask whether the clip
    // has a video track or whether this machine can decode it, and its only remaining signal after the fact is
    // the container's declared frame count -- which is why that branch calls itself weak on purpose. mediabunny
    // answers both questions BEFORE a packet is read (`getPrimaryVideoTrack`, `track.canDecode()` above), so on
    // this side the same two causes are already refused by name -- no_video_track, codec_unsupported -- and a
    // post-hoc guess from a frame count would only be able to restate them less accurately.
    // What is left over -- a track that opened, declared a size and decoded to nothing for some third reason --
    // produces no record, and "an import that produced no record is not a completion" is decided once, in the
    // core, for all three front ends (native_api_messages.h videoImportVerdictOf). So the case is covered, by the
    // net that is common to every platform rather than by a second, weaker one built only here.
    host.onProgress({ decoded, supplied, mediaTimeMs: lastMediaTsMs, durationMs });
    return summary(reason, decoded, supplied, rejected, durationMs, lastMediaTsMs, matrixConverted);
  } finally {
    // Releases the reader and any decoder mediabunny built, on every exit -- completion, cancellation, refusal
    // and throw alike. A `break` out of a `for await` already calls the iterator's return(), which stops the
    // sink; this closes the Input that owns the source.
    try {
      await input.dispose();
    } catch (e) {
      host.log('video import: disposing the demuxer failed (' + describe(e) + ')');
    }
  }
}

// Decides how a decoded sample is copied and what the core is told it is receiving, or REFUSES the clip by
// name. Returns `{ format, copyOptions }`: the name the core parses, and the options handed to
// `allocationSize` / `copyTo` -- `undefined` meaning "copy the frame exactly as it is".
//
// WHY A YUV FRAME IS COPIED WITH NO OPTIONS AT ALL, which is the one shape that works. `VideoFrame.copyTo`'s
// `format` selects a CONVERSION, and the only conversions it offers are the RGB ones -- so it cannot be used
// to ask for I420, not even from a frame that already is I420. Measured against Chrome 148: "copyTo() doesn't
// support explicit copy to non-RGB formats. Remove format parameter to use VideoFrame's pixel format." (The
// spec's own step list is the same shape, and mediabunny's buffer-backed reimplementation is more permissive
// than the browser here, which is exactly why this had to be measured in one.) Omitting the option is
// therefore not a shortcut: it is the only way to get the decoder's own pixels, and it is also what makes the
// NV12 a hardware decode path routinely produces readable at all.
//
// THE RGB FOUR ARE TAKEN WHATEVER MATRIX THEY CAME THROUGH, and the third member of the returned triple --
// `matrixNote` -- is what keeps that from being a silent decision. A frame the decoder produced AS RGB, with
// `colorSpace.matrix === 'rgb'`, went through no YUV matrix at all: the copy is a channel reorder and an alpha
// fill, there is nothing for the two offline producers to disagree about, and `matrixNote` is null. A frame
// that reports a YUV matrix (or reports none) HAS been converted by the browser, is taken anyway, and carries
// a note the caller logs once and reports in the import summary.
//
// WHY IT USED TO BE A REFUSAL. "The decoder produced RGB" does not imply "no matrix was applied", and reading
// it that way was a live defect on Android. Measured on SOG04 / Chrome for Android 150.0.7871.186 against this
// app's own clips (736x1308 H.264, no colour tags): the hardware decoder reports `format: 'RGBA'` with
// `colorSpace` = primaries bt709, transfer bt709, MATRIX BT709, fullRange false. Those pixels are a BT.709
// limited-range conversion of the stream's YUV, which is not what cv::VideoCapture hands the CLI (BT.601
// limited, regardless of tags), and no copyTo can undo it -- `copyTo({format:'I420'})` and
// `copyTo({format:'NV12'})` both fail with NotSupportedError there. So the branch was gated on
// `matrix === 'rgb'` and everything else was refused by name, on the argument that a silent import at the
// wrong colours is worse than a refusal.
//
// WHY IT IS AN ACCEPTANCE AGAIN. Two measurements, in this order:
//
//   * The gate was refusing frames NO UA ever escapes. `matrix === 'rgb'` has not been observed from any
//     browser: desktop Chrome 151 and Chrome for Android 150 both report `bt709` (with `prefer-software` they
//     report it on I420 planes, so they never reach this branch), and desktop Firefox 153 hands back `BGRX`
//     with `matrix: 'bt709'` under all three `hardwareAcceleration` hints, with `copyTo({format:'I420'})`
//     refused. The accepting branch was therefore effectively dead and Firefox could not import at all -- a
//     regression against the implementation before the gate, which took BGRX and imported fine.
//   * The colour difference the gate was protecting against does not change the records. The native suite now
//     runs every golden clip twice, once converted BT.601 and once BT.709, and requires ONE identical record
//     set (`integration_dual_decode.<case>`, native/test/integration/run_dual_decode.py); it is green across
//     all 11 golden clips plus the two landscape panes. The green predicates the pane latch gates on were
//     widened against measured pixels for exactly this. Tolerating the shift is the point, not a side effect.
//
// WHAT IS STILL NOT COVERED, and why the note exists rather than nothing. The dual-decode test converts the
// SAME decoded planes two ways, so it reproduces the matrix difference and not the CHROMA INTERPOLATION
// difference: a browser that hands back RGB has already upsampled 4:2:0 chroma with its own filter, where the
// core upsamples with OpenCV's. Nothing here measures that, so an import that came through this branch is one
// the recognition record was never proven against -- hence a warning the user and a bug report can both see,
// naming the format and the matrix. If a real clip ever disagrees, the fix is the inverse 3x3 (BT.709 -> BT.601)
// on this side, not a return to the refusal.
//
// EVERYTHING ELSE IS STILL A REFUSAL AND NOT A FALLBACK. 4:2:2 and 4:4:4 samples, and an opaque frame that
// reports no format at all, are formats the core cannot read at all -- pushOfflineFrame parses exactly "I420",
// "NV12" and "RGBA" (native/wasm/wasm_api.cpp) -- and reaching RGBA from them would mean asking copyTo for a
// conversion that is not guaranteed to exist. Naming the format that could not be read beats a silent
// zero-record import.
function coreFormatOf(sampleFormat, colorSpace) {
  if (sampleFormat === 'I420' || sampleFormat === 'NV12') {
    return { format: sampleFormat, copyOptions: undefined, matrixNote: null };
  }
  if (sampleFormat === 'RGBA' || sampleFormat === 'RGBX' || sampleFormat === 'BGRA' || sampleFormat === 'BGRX') {
    const matrixFree = colorSpace !== null && colorSpace !== undefined && colorSpace.matrix === 'rgb';
    return {
      format: 'RGBA',
      copyOptions: { format: 'RGBA' },
      matrixNote: matrixFree ? null : (sampleFormat + ' through ' + describeMatrix(colorSpace)),
    };
  }
  throw new VideoImportRefused(REFUSED_PIXEL_FORMAT,
    'this browser decoded the clip into a pixel format the app cannot read without '
    + 'changing its colours (' + (sampleFormat ?? 'an opaque frame that reports no format') + '); '
    + 'try re-encoding the clip as 8-bit 4:2:0 H.264');
}

// Names the colour matrix in the note above. A UA that reported none is said so in words rather than as
// `null`, because the message's whole job is to be readable by the person who has to act on it.
function describeMatrix(colorSpace) {
  const matrix = colorSpace === null || colorSpace === undefined ? null : colorSpace.matrix;
  return (matrix === null || matrix === undefined)
    ? 'a colour matrix it did not report' : 'the ' + matrix + ' colour matrix';
}

// Names the track's codec for the log line and, more importantly, for the codec refusal -- the ONE message a user
// gets that says why their clip was rejected.
//
// `getCodec()` answers `null` for a codec mediabunny does not MODEL, which is not the same thing as a codec it
// cannot find: an FFV1 Matroska recording (this project's own `capture --record` output) demuxes perfectly and
// reports `null`, so the refusal read "this browser cannot decode the clip's video codec (null)" and named
// nothing. The container's own codec identifier is precisely what mediabunny failed to map onto a WebCodecs name,
// so it is the identifier worth reporting -- and it is enough for a user to search, or for a bug report to be
// actionable.
//
// Never throws: a message that cannot be built must not turn a refusal into a failure.
async function describeCodec(track) {
  try {
    const codec = await track.getCodec();
    if (typeof codec === 'string' && codec.length > 0) return codec;
  } catch (e) {
    /* fall through to the container's own id */
  }
  try {
    if (typeof track.getInternalCodecId === 'function') {
      const internal = await track.getInternalCodecId();
      if (internal !== null && internal !== undefined && String(internal).length > 0) {
        return String(internal) + ', not a codec this browser exposes';
      }
    }
  } catch (e) {
    /* fall through to the generic name */
  }
  return 'unrecognised codec';
}

// Classifies a throw out of the format probe. `UnsupportedInputFormatError` means "this is not a media container
// I know", which is an ordinary user-actionable state (they picked a PDF, a screenshot, a truncated download) and
// not a bug -- so it takes the refusal channel and stays out of Sentry. Anything else is left as it is: a demuxer
// throwing for some other reason is exactly what a failure report is for.
//
// Matched on `name` rather than with `instanceof`, deliberately. The class is exported by the bundle, but this
// module is also driven with a stubbed mediabunny namespace (tool/test_web_video_import.mjs) and, in a browser,
// against a bundle reached through a dynamic `import()` -- so identity is the one property that is not reliably
// available, while the name is set by the constructor itself and is.
function asRefusalIfUnsupportedFormat(error, blob) {
  if (!error || error.name !== 'UnsupportedInputFormatError') return error;
  return new VideoImportRefused(REFUSED_NOT_A_VIDEO, 'this file is not a video the app can read (' + blob.size
    + ' byte(s); its format was not recognised); pick a recording made by a screen or game capture app');
}

function summary(reason, decoded, supplied, rejected, durationMs, lastMediaTsMs, matrixConverted) {
  return { reason, decoded, supplied, rejected, durationMs, lastMediaTsMs, matrixConverted };
}

function describe(e) {
  return e && e.message ? e.message : String(e);
}

// ---------------------------------------------------------------------------------------------------------
// ONE FRAME OUT OF A CLIP, for the import error report.
//
// WHY THIS LIVES IN THE IMPORT MODULE and not in a file of its own. The report's whole premise is that the
// pixels the developer receives are the pixels this front end's recogniser saw, so the frame has to come out
// of THE SAME DECODER the import runs -- the same mediabunny bundle, the same `hardwareAcceleration` request,
// the same `coreFormatOf` mapping, the same refusal vocabulary. Anything that re-implemented the open would
// be a second decoder configuration that could drift from this one silently, which is exactly the failure the
// report exists to diagnose. So the two entry points below reuse `openClip`, `coreFormatOf`, `describeCodec`
// and `asRefusalIfUnsupportedFormat`, and add nothing of their own to that list.
//
// THE CONTRACT THEY IMPLEMENT is stated once, on the Dart side, in lib/src/core/video_frame_grab_ops.dart, and
// it does not vary by platform: a grab at time T returns *the frame a player would be showing at T*, i.e. the
// last frame whose media timestamp is at or before T. mediabunny's `VideoSampleSink.getSample(T)` is defined
// as "the sample whose presentation interval contains T" and was measured to satisfy exactly that over 4800
// random reads across twelve clips and both containers: never a sample starting after T. Windows reaches the
// same sentence through cv::VideoCapture (native/src/cv/video_frame_grabber.h); only the demuxer differs.
//
// THE COLOUR CONVERSION IS THE CORE'S, NOT THE BROWSER'S. `host.encodePng` is the worker's binding for the
// wasm export `encodeDecodedFramePng`, which runs `color::decodedFrameToBgr` -- the conversion
// `pushOfflineFrame` runs -- and then `cv::imencode(".png", ...)`. Nothing here draws to a canvas: a canvas is
// a colour-managed surface whose output is sRGB by declaration, so `sample.draw()` would put the reported
// frame through a second, different conversion and document pixels the pipeline never had.
//
// THE PLANE LAYOUT IS NOT CHECKED HERE, deliberately, and neither is it on the import path above: both hand
// the core the layout `copyTo` resolved to and let it refuse a mismatch by name (`layoutNotTightlyPacked`,
// with both layouts printed). Re-checking on this side would put the browser's layout in front of a JS twin
// instead of in front of the code that reads the bytes, which is the one comparison worth making.

// How many packets `computePacketStats` is allowed to walk for the nominal frame rate. A sample, not the
// clip: the number is only ever a step size for a selector, and reading the whole packet index of a
// multi-gigabyte recording to refine a hint nobody converts into a frame number would cost the probe more
// than the decode does.
const FPS_PACKET_SAMPLE = 100;

// How long `probeClipTimeline` will wait for a duration the container did not declare before answering
// without one. `computeDuration()` resolves the LAST packet's timestamp, which for such a container means
// mediabunny reading its way to the end of the file -- a full ranged pass proportional to its size, on
// exactly the shape (Matroska out of OBS, routinely multi-gigabyte) the import path calls the ordinary case
// rather than the exotic one. The import refuses to await that scan at all; the probe cannot go that far,
// because a selector has no "later" in which to upgrade a bound -- but it can refuse to wait FOREVER, which
// is the half of the import's argument that does apply here.
//
// The fallback is not a degraded guess: 0 already means INDETERMINATE on this wire and the shared ops layer
// renders it as an unbounded control (lib/src/core/video_frame_grab_ops.dart), so an over-budget scan costs
// the selector its maximum and nothing else. The scan itself is not cancellable -- mediabunny exposes no
// abort for the walk -- so this stops the WAIT, and `input.dispose()` in the outer `finally` is what stops
// the reads, which is precisely how the import path handles the same object.
//
// The number is a judgement, and the constraint it is judged against is the caller's: the client bounds the
// whole query at 120 s (`_videoFrameGrabTimeout`, lib/src/core/wasm_worker_client.dart) and fails the report
// dialog outright when it expires. A budget an order of magnitude below that leaves the parts of the probe
// whose answers CANNOT be degraded -- above all the decode, which is what proves the clip decodes at all --
// the rest of the allowance, and turns "the dialog produced nothing for two minutes and then failed" into
// "the dialog answered, with an unbounded control".
const PROBE_DURATION_SCAN_BUDGET_MS = 10000;

// Runs `start()` and awaits it for at most `budgetMs`, answering null when it neither settles in time nor
// settles successfully. Both endings are logged with `what`, so a report carries which of the two happened.
//
// A THUNK RATHER THAN A PROMISE, so a producer that throws synchronously -- before it has a promise to
// return -- is the same null as one that rejects, and the caller keeps its single answer instead of needing
// a `try` around the bounded call as well as inside it.
//
// The losing promise is NOT abandoned unhandled: its rejection is consumed by the handler attached here, so
// a scan that fails after the budget has already elapsed cannot reach `self.onunhandledrejection`. The timer
// is cleared on every exit, so nothing keeps an event loop alive past the answer.
function withBudget(start, budgetMs, host, what) {
  let timer = null;
  const expiry = new Promise((resolve) => {
    timer = setTimeout(() => {
      host.log('video frame grab: ' + what + ' exceeded its ' + budgetMs + ' ms budget; answering without it');
      resolve(null);
    }, budgetMs);
  });
  const settled = (async () => start())().then(
    (value) => value,
    (e) => {
      host.log('video frame grab: ' + what + ' failed (' + describe(e) + ')');
      return null;
    },
  );
  return Promise.race([settled, expiry]).finally(() => {
    if (timer !== null) clearTimeout(timer);
  });
}

/// Thrown when the clip opened and decoded but could not answer for this particular time. Distinct from
/// `VideoImportRefused` (which is about the FILE and is reused verbatim) because it is about the REQUEST.
export class VideoFrameGrabFailed extends Error {
  constructor(message) {
    super(message);
    this.name = 'VideoFrameGrabFailed';
    this.expected = true;
  }
}

// Opens `blob`, resolves its primary video track and pre-flights the codec, classifying every failure the way
// an import classifies it. Returns the mediabunny namespace as well, so the caller does not load it twice.
// The caller owns `input` and must dispose it; every throw out of here has disposed it already.
async function openClip(blob, host) {
  const loadModule = host.loadModule ?? loadMediabunny;
  let mediabunny;
  try {
    mediabunny = await loadModule();
  } catch (e) {
    throw new VideoImportRefused(REFUSED_DECODER_UNAVAILABLE, 'the video decoding library could not be loaded ('
      + describe(e) + '); check the connection and try again');
  }
  const { Input, ALL_FORMATS, BlobSource } = mediabunny;
  let input;
  try {
    input = new Input({ formats: ALL_FORMATS, source: new BlobSource(blob) });
  } catch (e) {
    throw asRefusalIfUnsupportedFormat(e, blob);
  }
  try {
    let track;
    try {
      track = await input.getPrimaryVideoTrack();
    } catch (e) {
      throw asRefusalIfUnsupportedFormat(e, blob);
    }
    if (track === null || track === undefined) {
      throw new VideoImportRefused(REFUSED_NO_VIDEO_TRACK, 'this file contains no video track');
    }
    const codecName = await describeCodec(track);
    if (!(await track.canDecode())) {
      throw new VideoImportRefused(REFUSED_CODEC_UNSUPPORTED,
        'this browser cannot decode the clip\'s video codec (' + codecName + ')');
    }
    return { mediabunny, input, track, codecName };
  } catch (e) {
    await disposeQuietly(input, host);
    throw e;
  }
}

async function disposeQuietly(input, host) {
  try {
    await input.dispose();
  } catch (e) {
    host.log('video frame grab: disposing the demuxer failed (' + describe(e) + ')');
  }
}

// Runs `attempt(decoderOptions)` with the software request, and once more with the UA's own choice if the
// first THREW. The same rule the import's decode loop uses and for the same reason: a `configure` the UA
// refuses outright surfaces as a throw indistinguishable from a corrupt clip, and one frame either way costs
// one configure. Unlike the import there is nothing to re-push, so there is no `anySampleYielded` half to
// the condition -- a single-frame attempt either threw or it did not.
//
// THE CONDITION IS "IT THREW", NOT "IT PRODUCED NOTHING", and this doc used to say the latter. The two are
// not the same: an attempt that RETURNS null (mediabunny answering that no sample sits at the requested
// time) is a statement about the clip and not about the decoder, and it is deliberately not retried -- both
// callers turn that null into their own named refusal. The code has always tested the throw; it was the
// sentence that was borrowed from the import loop, where "produced nothing" has a second meaning.
//
// THE LOG DOES NOT NAME A CAUSE IT HAS NOT ESTABLISHED. It used to assert "a software video decoder could
// not be configured", which is the hypothesis this retry EXISTS to test and is wrong for every other reason
// a decode can throw -- and the log is the artefact the error report is filed to produce. It now states what
// happened (attempt 1 of 2 failed, with its message) and what is being done about it, so the first error --
// the one that is usually the real one, since only the second propagates -- survives in a report as an
// observation rather than as a diagnosis.
async function withDecoderRetry(attempt, host, what) {
  try {
    return await attempt(DECODER_OPTIONS);
  } catch (e) {
    // NOT RETRIED WHEN THIS MODULE RAISED IT. `expected === true` is the flag `VideoImportRefused` and
    // `VideoFrameGrabFailed` carry and the same one the worker classifies replies by, so this asks "did the
    // producer already decide what this is?" rather than listing error types -- a class added later is
    // covered by carrying the flag, which it has to do anyway to be reported as a refusal. No such error is
    // thrown inside an `attempt` today; the guard is here so that the retry's condition is the decoder
    // question it claims to be, and cannot quietly start re-running a clip that was already refused by name.
    if (e && e.expected === true) throw e;
    host.log('video frame grab: attempt 1 of 2 at ' + what + ' failed (' + describe(e)
      + '); retrying with the browser\'s own choice of decoder instead of the software request');
    return await attempt(FALLBACK_DECODER_OPTIONS);
  }
}

// Whether the clip's frames carry ADVANCING media time, i.e. whether "the frame displayed at T" is a question
// this file can answer at all.
//
// Walks encoded packets rather than decoding, because the timestamps are the container's and a decode adds
// nothing to them. Metadata only, so no packet payload is read. The walk stops at the FIRST packet whose
// timestamp differs from the first one's, which for every ordinary clip is packet two; only a genuinely flat
// clip is walked to its end, which is what the Windows counterpart does as well (it decodes the whole clip;
// `readHead` in native/src/cv/video_frame_grabber.h).
//
// A SINGLE-PACKET CLIP IS TRUE, not false, and that is the same judgement the Windows side records: one frame
// has nothing to advance to and every T maps to it truthfully. Only several frames sharing one instant is the
// shape no seek can address.
async function clipTimestampsAdvance(mediabunny, track) {
  const { EncodedPacketSink } = mediabunny;
  const sink = new EncodedPacketSink(track);
  const first = await sink.getFirstPacket({ metadataOnly: true });
  if (first === null || first === undefined) {
    return false;
  }
  let current = first;
  let seen = 1;
  for (;;) {
    const next = await sink.getNextPacket(current, { metadataOnly: true });
    if (next === null || next === undefined) {
      break;
    }
    seen++;
    if (next.timestamp > first.timestamp) {
      return true;
    }
    current = next;
  }
  return seen === 1;
}

// The clip's time axis, as the decoder that will be asked for its frames reports it. Shaped for
// `videoFrameTimelineFromWire` (lib/src/core/video_frame_grab_ops.dart); every field is measured, none assumed.
export async function probeClipTimeline(blob, host) {
  const { mediabunny, input, track, codecName } = await openClip(blob, host);
  try {
    // NARROWED ONCE, AND THE NARROWED VALUE IS THE ONLY ONE USED -- the shape `grabClipFramePng` already
    // uses for the same call. This used to narrow for the number it REPORTS and hand the raw one to
    // `getSample()` below, so a container that answered null/NaN was reported as first frame 0 ms and then
    // selected with null: the decoder's own error decided the outcome instead of this module's vocabulary,
    // and a mediabunny-internal message is a *failure* (a Sentry issue) rather than a translated refusal.
    //
    // NOT ZERO FOR EVERY CLIP: .notes/player_standard*.mp4 starts at 50.033 ms, and mediabunny answers null
    // for any request below a clip's first timestamp -- measured, so this is the selector's floor and not a
    // nicety.
    let firstTimestamp = 0;
    try {
      const stated = await track.getFirstTimestamp();
      if (typeof stated === 'number' && Number.isFinite(stated)) firstTimestamp = stated;
    } catch (e) {
      host.log('video frame grab: the clip states no first timestamp (' + describe(e) + ')');
    }
    const firstFrameMs = Math.round(firstTimestamp * 1000);

    // THE CONTAINER'S OWN DURATION FIRST, which is the number the Windows leg reports and the number this
    // front end's own import progress bar starts from -- the selector's maximum and the progress bar must not
    // disagree about the same file. `computeDuration()` is the fallback and it is a full ranged pass over the
    // packet index, which is why the import deliberately does not await it; a selector has no "later" in
    // which to upgrade a bound, so this one does await it, and only when the container stated nothing.
    // 0 survives both failures and means INDETERMINATE, which the shared ops layer renders as an unbounded
    // control rather than a wrong one.
    let durationMs = 0;
    try {
      const declared = await track.getDurationFromMetadata();
      if (typeof declared === 'number' && Number.isFinite(declared) && declared > 0) {
        durationMs = Math.round(declared * 1000);
      }
    } catch (e) {
      host.log('video frame grab: reading the clip\'s declared duration failed (' + describe(e) + ')');
    }
    if (durationMs === 0) {
      // BOUNDED, and the bound is the point -- see PROBE_DURATION_SCAN_BUDGET_MS. Failure and expiry both
      // arrive here as null and both leave `durationMs` at 0, which is the indeterminate answer this
      // function already documents.
      const scanned = await withBudget(
        () => track.computeDuration(), PROBE_DURATION_SCAN_BUDGET_MS, host, 'scanning the clip for a duration');
      if (typeof scanned === 'number' && Number.isFinite(scanned) && scanned > 0) {
        durationMs = Math.round(scanned * 1000);
      }
    }

    // A STEP SIZE, NEVER A TIME-TO-FRAME CONVERSION (see the ops contract). Guarded so a container that
    // cannot state one costs the selector its step and nothing else.
    let fps = 0;
    try {
      const stats = await track.computePacketStats(FPS_PACKET_SAMPLE);
      const rate = stats === null || stats === undefined ? 0 : stats.averagePacketRate;
      if (typeof rate === 'number' && Number.isFinite(rate) && rate > 0) {
        fps = rate;
      }
    } catch (e) {
      host.log('video frame grab: the clip states no usable frame rate (' + describe(e) + ')');
    }

    // THE SIZE OFF A DECODED FRAME, not off the container, because that is what the Windows leg reports and
    // because decoding one frame is also the only honest way to say the clip decodes at all. Rotation is
    // applied to the REPORTED size for the same reason: cv::VideoCapture auto-rotates, so the io leg's
    // decoded size is already the rotated one, and the core rotates this path's pixels too (after the colour
    // conversion) -- a selector that showed the unrotated size would disagree with the PNG it is about to get.
    const sample = await withDecoderRetry(
      async (options) => new mediabunny.VideoSampleSink(track, options).getSample(firstTimestamp),
      host,
      'the probe',
    );
    if (sample === null || sample === undefined) {
      throw new VideoFrameGrabFailed('the clip\'s first frame (' + firstFrameMs + ' ms) did not decode');
    }
    let width = 0;
    let height = 0;
    let rotation = 0;
    try {
      width = sample.codedWidth;
      height = sample.codedHeight;
      rotation = sample.rotation ?? 0;
    } finally {
      sample.close();
    }
    const upright = rotation === 90 || rotation === 270;

    const hasMediaTimeline = await clipTimestampsAdvance(mediabunny, track);
    host.log('video frame grab: ' + codecName + ' ' + width + 'x' + height
      + (rotation ? ' rotated ' + rotation + ' degrees clockwise' : '')
      + ', first frame ' + firstFrameMs + ' ms, duration '
      + (durationMs > 0 ? durationMs + ' ms' : 'not stated')
      + (hasMediaTimeline ? '' : ', NO advancing media time'));
    return {
      firstFrameMs,
      durationMs,
      fps,
      width: upright ? height : width,
      height: upright ? width : height,
      hasMediaTimeline,
    };
  } finally {
    await disposeQuietly(input, host);
  }
}

// The largest double strictly below `x`, for `x` finite and positive. Used to turn mediabunny's `<=` on
// seconds into the `<` the millisecond grid needs; see the request comment in `grabClipFramePng`. Bit-pattern
// arithmetic because JavaScript has no `nextafter`: for a positive finite double, decrementing the IEEE-754
// bit pattern by one steps to the next representable value below it.
const DOUBLE_BITS = new DataView(new ArrayBuffer(8));
function justBelow(x) {
  DOUBLE_BITS.setFloat64(0, x);
  DOUBLE_BITS.setBigUint64(0, DOUBLE_BITS.getBigUint64(0) - 1n);
  return DOUBLE_BITS.getFloat64(0);
}

// The time to ask mediabunny for, in seconds, so that it selects the frame the WINDOWS producer would select
// for the same integer millisecond `timeMs`.
//
// The rule being reproduced is Windows': a frame is kept iff its stamp ROUNDED TO A MILLISECOND is at or
// before the target (native/src/cv/media_timestamp.h stamps with `llround(POS_MSEC)`;
// video_frame_grabber.h compares those integers). mediabunny cannot be asked in milliseconds -- it selects
// "the last sample whose start is <= the given timestamp" comparing raw float seconds -- so this returns the
// LARGEST second value whose own published millisecond is still `timeMs`, derived with the very rounding this
// file publishes by. That last part is what makes it self-consistent rather than merely close: `T + 0.5` and
// `Math.round(ts * 1000)` can disagree by an ulp on a stamp that lands on a half-millisecond, and a request
// derived from the first would refuse a frame the second names `T`. Stepping back off the boundary with the
// publishing function itself removes the disagreement by construction.
//
// The loop terminates and cannot run long: `Math.round(x * 1000)` is monotone in `x`, and it already equals
// `timeMs` at `timeMs / 1000`, which is below every start value here. Measured on real clips it runs zero or
// one time.
function grabRequestSeconds(timeMs) {
  let seconds = (timeMs + 0.5) / 1000;
  while (Math.round(seconds * 1000) > timeMs) {
    seconds = justBelow(seconds);
  }
  return seconds;
}

// The frame displayed at `seconds` AND the one that follows it, from one decode pass.
//
// `VideoSampleSink.samples(start)` yields, first, the last sample whose start is at or before `start` -- the
// same frame `getSample(start)` answers with, by the same code (mediabunny.mjs, `mediaSamplesInRange`: a
// sample at or before `start` is held back and pushed once a later one arrives) -- and then the rest of the
// track IN PRESENTATION ORDER. So the second yield is the successor, with no epsilon anywhere and no second
// seek: the decoder is already positioned and the packet after the answer is already queued.
//
// WHY NOT THE TWO CHEAPER SOURCES. Measured in headless Firefox 153 against a 92-frame VFR clip and a
// 92-frame B-frame clip (.notes/analysis/video-import-error-report/stage-h1-3b):
//   * `sample.timestamp + sample.duration` names a time for the LAST frame too (3083 ms on a clip that ends
//     at 3050), so it cannot say "there is no successor" without falling back on the container's duration --
//     which is the inference this whole component exists to refuse. It was also off by one millisecond on a
//     stamp near a half-millisecond boundary.
//   * `EncodedPacketSink.getNextPacket` is documented as DECODE order and measured as such: 85 of 92 frames
//     of the B-frame clip got the wrong successor, while the B-frame-free clip got 92 of 92 right. A source
//     that is correct exactly until the user's phone emits B-frames is worse than one that is never used.
// The iterator was right on 92 of 92 in both clips and returned nothing after the last frame.
//
// Returns `{ sample, nextMediaTsMs }`; `sample` is null when the clip answered nothing at all, and
// `nextMediaTsMs` is null when the answer is the clip's last frame. The caller owns `sample`.
async function firstTwoSamplesAt(mediabunny, track, seconds, decoderOptions) {
  const sink = new mediabunny.VideoSampleSink(track, decoderOptions);
  const iterator = sink.samples(seconds)[Symbol.asyncIterator]();
  const first = await iterator.next();
  if (first.done) {
    return { sample: null, nextMediaTsMs: null };
  }
  const sample = first.value;
  let second;
  try {
    second = await iterator.next();
  } catch (e) {
    sample.close();
    throw e;
  }
  if (second.done) {
    // NO `iterator.return()` ON THIS BRANCH, and that is measured, not tidiness. mediabunny pushes the clip's
    // LAST sample to the queue from its flush path without clearing its own `lastSample` reference to it, and
    // `return()` closes `lastSample` -- so returning the exhausted iterator closes the very frame it just
    // yielded, and the next `allocationSize` throws "VideoSample is closed". Observed on every tail grab in
    // Firefox 153 before this branch existed. Nothing is leaked by skipping it: an iterator that reported
    // `done` has already flushed its decoder and holds an empty queue.
    return { sample, nextMediaTsMs: null };
  }
  try {
    return { sample, nextMediaTsMs: Math.round(second.value.timestamp * 1000) };
  } finally {
    second.value.close();
    // Terminates the pipeline and closes what the iterator still holds. Safe for `sample` here: the second
    // yield set mediabunny's `firstSampleQueued`, which drops its `lastSample` alias to the first.
    await iterator.return();
  }
}

// The frame displayed at `timeMs`, encoded to PNG BY THE CORE. Returns
// `{ png, width, height, mediaTsMs, nextMediaTsMs, format, rotation, matrixNote, layout }`; `png` is the
// Uint8Array the wasm export produced and `width`/`height` are the ENCODED image's, post-rotation. `layout` is
// the plane layout `copyTo` RESOLVED TO, carried out unchanged -- it is what the core was asked to read the
// buffer by, so a bug report about unreadable pixels can quote the UA's actual answer rather than a
// re-derivation of it. `nextMediaTsMs` is null when the answer is the clip's last frame; see
// lib/src/core/video_frame_grab_ops.dart for why the successor is the one neighbour a producer must state.
export async function grabClipFramePng(blob, timeMs, host) {
  const { mediabunny, input, track } = await openClip(blob, host);
  try {
    // CLAMPED UP TO THE CLIP'S FIRST TIMESTAMP, exactly as the Windows producer's `clampIntoClip` does
    // (native/src/cv/video_frame_grabber.h), and this is a MEASURED requirement rather than a defensive one.
    // mediabunny answers `null` -- not the first frame -- for any time strictly below `getFirstTimestamp()`,
    // and the probe reports that timestamp in whole milliseconds: `.notes/player_standard_2.mp4` starts at
    // 50.033 ms, so the probe publishes 50 and a selector sitting on its own minimum asked for 50.000, which
    // is below 50.033. Measured in headless Chrome 151: that request was refused while Windows answered the
    // identical one with the first frame. Below the first frame the first frame is the only truthful answer,
    // and `mediaTsMs` is what says which frame came back -- the mechanism the shared contract already names
    // for an out-of-range request. The upper end needs no counterpart: mediabunny clamps past the end to the
    // last frame by itself (measured across six containers).
    let firstTimestamp = 0;
    try {
      const stated = await track.getFirstTimestamp();
      if (typeof stated === 'number' && Number.isFinite(stated)) firstTimestamp = stated;
    } catch (e) {
      host.log('video frame grab: the clip states no first timestamp (' + describe(e) + ')');
    }
    // HALF A MILLISECOND LATE, TO LAND ON THE SAME MILLISECOND GRID AS THE WINDOWS PRODUCER. Divergence in
    // the request, not in the contract, and the browser constraint that forces it is this: mediabunny selects
    // "the last sample whose start is <= the given timestamp" by comparing RAW FLOAT SECONDS inside its own
    // sink (mediabunny.mjs, `mediaSamplesInRange`), and nothing this app can pass makes it compare integer
    // milliseconds instead. The Windows producer stamps a frame with `llround(POS_MSEC)` and compares that
    // INTEGER against the integer target (native/src/cv/media_timestamp.h, video_frame_grabber.h), i.e. it
    // keeps a frame iff `ts_ms < T + 0.5`. Asking mediabunny for `(T + 0.5) / 1000` seconds reproduces that
    // rule exactly, so the same T selects the same frame on both legs.
    //
    // This is a PREREQUISITE for stepping, not a nicety: a frame at 133.4 ms is published as 133 by both
    // legs, and `timeMs / 1000` made web answer 133 with that frame's PREDECESSOR -- so re-requesting an
    // answer's own `mediaTsMs` walked backwards. Measured before and after in headless Firefox 153: 30 of 92
    // frames of a VFR clip and 44 of 92 of a 29.97 fps clip were non-idempotent under
    // `grab(grab(T).mediaTsMs)` on the old grid, and 0 of 92 on this one
    // (.notes/analysis/video-import-error-report/stage-h1-3b).
    //
    // A stamp exactly on a half-millisecond is not exotic: 29.97 fps produces them on schedule (500.5 /
    // 1501.5 / 2502.5 ms), and `grabRequestSeconds` above is what keeps those frames on the grid. Measured
    // with the naive `(timeMs + 0.5) / 1000` in Firefox 153: the frame stamped 1501.5 ms publishes as 1502 and
    // still answered a request for 1501 -- a frame starting AFTER the requested time, which breaks the
    // contract sentence and with it the `grabAt(M - 1)` derivation the back step is built on (2 of 92 frames).
    //
    // What is still not identical, stated rather than papered over: the two legs compute a frame's stamp in
    // different arithmetic (mediabunny holds seconds and this file scales by 1000; OpenCV reports
    // milliseconds directly), so a stamp within one ulp of a half-millisecond can round to different integers
    // on the two platforms. Measured: 1501.5 ms publishes as 1502 on both, 500.5 ms as 500 here and 501 there.
    // Nothing in a request can reach that -- it is decided before either side compares anything -- and it
    // affects which integer NAMES the frame, never which frame a given integer selects on its own platform.
    const seconds = Math.max(grabRequestSeconds(timeMs), firstTimestamp);
    const { sample, nextMediaTsMs } = await withDecoderRetry(
      async (options) => firstTwoSamplesAt(mediabunny, track, seconds, options),
      host,
      'the grab',
    );
    // NOT AN EMPTY ANSWER, and after the clamp above this is a statement about the FILE rather than about the
    // request: the clip stopped answering for a time inside its own range. Refusing names it; inventing a
    // frame here would be the "a report that names a frame the user never saw" outcome.
    if (sample === null || sample === undefined) {
      throw new VideoFrameGrabFailed('no frame at or before ' + timeMs + ' ms could be decoded');
    }
    try {
      // VISIBLE dimensions -- `codedWidth`/`codedHeight` on a mediabunny SAMPLE are getters over
      // `visibleRect`, and the default copy rectangle is the same thing. See the header note on why no `rect`
      // option is passed on either path.
      const width = sample.codedWidth;
      const height = sample.codedHeight;
      const { format, copyOptions, matrixNote } = coreFormatOf(sample.format, sample.colorSpace);
      if (matrixNote !== null) {
        host.log('video frame grab: this browser\'s video decoder handed the app ' + matrixNote
          + ', so the reported frame carries the browser\'s colour conversion and not the core\'s');
      }
      const planes = new Uint8Array(sample.allocationSize(copyOptions));
      const layout = await sample.copyTo(planes, copyOptions);
      // ROTATION IS REPORTED, NOT APPLIED, exactly as on the import path: the core rotates after the colour
      // conversion, because 4:2:0 chroma is shared by a 2x2 block and rotating the planes would re-pair luma
      // with chroma half a sample away from where OpenCV's rotate does.
      const rotation = sample.rotation ?? 0;
      const mediaTsMs = Math.round(sample.timestamp * 1000);
      const answer = host.encodePng(planes, format, width, height, rotation, layout);
      if (answer === null || answer === undefined || answer.ok !== true) {
        // The core's own reason and message, carried verbatim. Every one of them is about THIS copy -- an
        // unknown format name, a layout that is not the one the conversion walks, a byte count that does not
        // match -- and the core is the side that knows, so restating them here would be a second list.
        const reason = answer && answer.reason ? answer.reason : 'unknown';
        const detail = answer && answer.message ? answer.message : 'the core returned no answer';
        throw new Error('video frame grab: the core refused the decoded frame (' + reason + '): ' + detail);
      }
      return {
        png: answer.png,
        width: answer.width,
        height: answer.height,
        mediaTsMs,
        nextMediaTsMs,
        format,
        rotation,
        matrixNote,
        layout,
      };
    } finally {
      // A VideoSample holds a decoded frame the GC does not account for. Closed on every exit, including a
      // throw out of copyTo or out of the core.
      sample.close();
    }
  } finally {
    await disposeQuietly(input, host);
  }
}
