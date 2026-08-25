// Node coverage for the video-import DEMUX half, against the real vendored mediabunny bundle
// (web/wasm/mediabunny/mediabunny.mjs, pinned in tool/web_deps.json).
//
// tool/test_web_video_import.mjs drives the same production loop over a stubbed mediabunny namespace, so it
// says nothing about whether the real library is being used correctly. This file closes that half: it MUXES a
// clip with mediabunny, hands it back through a real `Blob` and mediabunny's own `BlobSource`, and runs
// web/video_import.mjs's real decode loop over it.
//
// HOW WEBCODECS IS AVOIDED. Node has no VideoDecoder, but mediabunny takes a registered `CustomVideoDecoder` in
// its place, so everything except the browser's decoder is the real thing: the container parse, the packet
// order, the sample timestamps, `VideoSampleSink`'s iteration and flush, and `VideoSample.copyTo` into RGBA.
// The fake decoder turns each packet into a solid-colour sample whose first byte identifies the packet, which is
// what lets the assertions below tie a decoded frame back to the byte that was muxed.
//
// WHAT THIS STILL CANNOT REACH: the browser's own VideoDecoder (so codec support, hardware paths and B-frame
// reordering), and a real clip's pixels. Those are browser-only, exactly as docs/video-import.md says.
//
// SKIPPED, NOT FAILED, when the bundle is absent: web/wasm/ is gitignored and provisioned from the pins
// (tool/fetch_web_deps.py), so a fresh clone that has not provisioned yet must not go red here.
//
// BUT A RUN IN WHICH NOTHING RAN MUST NOT EXIT 0 WHERE THAT GREEN IS READ AS COVERAGE. Every test here is
// gated on the same bundle, so "the bundle is absent" and "no test ran" are the same state, and node exits 0
// for both -- the exit code cannot separate "all passed" from "tested nothing". CI runs this AFTER the
// provisioning step, and the provisioning step is skipped on a web-deps cache hit, so a cache restored with an
// incomplete web/wasm would report a green step covering the ONLY non-stub demux coverage there is. Under CI
// the absence is therefore a hard failure rather than a line in a log nobody reads.

import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';

import { decodeClipIntoPipeline, IMPORT_CANCELLED, IMPORT_COMPLETED } from '../web/video_import.mjs';

const bundlePath = new URL('../web/wasm/mediabunny/mediabunny.mjs', import.meta.url);
const havePinnedBundle = fs.existsSync(bundlePath);
const skip = havePinnedBundle
  ? false
  : 'web/wasm/mediabunny/mediabunny.mjs is absent; run tool/fetch_web_deps.py to provision it';
// `CI` is set by GitHub Actions (and by every other runner) and by nothing on a developer's machine, so this
// is the fresh-clone exemption and its one exception, expressed in the only place that knows both.
if (skip && process.env.CI) {
  throw new Error(`${skip} -- refusing to exit 0 having run no test at all`);
}
const mediabunny = havePinnedBundle ? await import(bundlePath.href) : null;

// The fake decoder. `vp8` is the codec used below because Matroska and MP4 both accept encoded packets whose
// payload is not a real bitstream, which is what lets this file mux a clip without an encoder; the decoder never
// looks at the payload beyond its first two bytes.
//
// IT EMITS WHAT A REAL DECODER EMITS, INCLUDING A VISIBLE RECT. A coded frame is padded out to the codec's
// macroblock alignment and the picture is the sub-rectangle mediabunny reports as `visibleRect`; a stub that
// omits it gets `{left: 0, top: 0, coded...}` filled in and makes the padded/visible distinction structurally
// unreachable, which is exactly the assertion gap this closes. `visiblePadding` is how a test asks for a coded
// plane larger than the picture: the plane is (width + pad) x (height + pad) and the visible rect is the
// picture, so anything that copied the coded rect comes back with a skirt of the wrong colour.
//
// THE VISIBLE OFFSET IS DELIBERATELY 0 HERE, and that is a property of mediabunny rather than a shortcut.
// Measured against this pinned bundle: for a BUFFER-backed VideoSample -- which is what a custom decoder
// produces, and the only backing Node can have -- `copyTo` honours `visibleRect`'s width and height but starts
// at the coded origin regardless of `left`/`top`. The offset is therefore only meaningful on the VideoFrame
// backing a browser gives, where the UA applies it, and it stays browser-only exactly like the decoder itself
// (see the header). Asserting an offset here would assert mediabunny's behaviour, not this repo's.
if (mediabunny) {
  class ScriptedVideoDecoder extends mediabunny.CustomVideoDecoder {
    static supports(codec) { return codec === 'vp8'; }
    init() { ScriptedVideoDecoder.decoded = 0; }
    decode(packet) {
      ScriptedVideoDecoder.decoded++;
      const pad = ScriptedVideoDecoder.visiblePadding;
      const codedWidth = this.config.codedWidth;
      const codedHeight = this.config.codedHeight;
      // Solid colour = the packet's own marker byte, so a decoded frame can be tied back to what was muxed.
      // Byte 0 is not the marker: it carries the VP8 frame-type bit the muxer really parses (see muxClip).
      const pixels = new Uint8Array(codedWidth * codedHeight * 4).fill(packet.data[1]);
      // The padding is painted a colour no packet ever carries, so a copy that took the coded rect is not merely
      // the wrong SIZE -- it comes back with bytes that identify where they came from.
      if (pad > 0) {
        for (let y = 0; y < codedHeight; y++) {
          for (let x = 0; x < codedWidth; x++) {
            if (x < codedWidth - pad && y < codedHeight - pad) continue;
            pixels.fill(0xfe, (y * codedWidth + x) * 4, (y * codedWidth + x) * 4 + 4);
          }
        }
      }
      this.onSample(new mediabunny.VideoSample(pixels, {
        format: 'RGBX',
        codedWidth,
        codedHeight,
        visibleRect: { left: 0, top: 0, width: codedWidth - pad, height: codedHeight - pad },
        timestamp: packet.timestamp,
        duration: packet.duration,
      }));
    }
    flush() {}
    close() {}
  }
  ScriptedVideoDecoder.decoded = 0;
  // Set per test. The decoder wrapper overwrites whatever rotation a sample is constructed with, using the
  // TRACK's -- so a rotation test has to put it in the container, not here (see muxClip).
  ScriptedVideoDecoder.visiblePadding = 0;
  mediabunny.registerDecoder(ScriptedVideoDecoder);
  globalThis.__scriptedDecoder = ScriptedVideoDecoder;
}

/// Muxes `count` frames at `fps` into a Matroska clip and returns its bytes. Frame i carries the marker byte
/// `i + 1`, which the fake decoder above paints across the whole frame.
///
/// BYTE 0 IS NOT FREE. The muxer reads the VP8 uncompressed header to decide for itself whether a frame is a
/// keyframe (bit 0 clear) -- writing a marker there produced a clip whose first frame looked like an
/// interframe, so the sink found no keyframe to start from and yielded nothing at all, silently. The marker
/// therefore lives in byte 1.
///
/// `rotation` forces the MP4 container, because WebM carries no rotation metadata at all -- mediabunny's own
/// muxer refuses it ("WebM does not support video rotation metadata"). Matroska stays the default because it is
/// OBS's default recording container and therefore the likeliest real input.
///
/// `appendOnly` IS HOW A CLIP THAT DECLARES NO DURATION IS PRODUCED, and it is the container's own mechanism
/// rather than a doctored file: mediabunny writes the Segment Duration element by seeking back to it at
/// finalize, and `appendOnly` is its switch for a muxer that cannot seek back, so the element is simply never
/// written (measured: `getDurationFromMetadata()` returns 1.2 for the default form and `null` for this one).
/// That is the shape of a Matroska recording that was streamed or was interrupted before it was finalised --
/// the case the whole background-scan path exists for, and the one no test could reach while every clip here
/// declared its duration.
async function muxClip({ count, fps = 10, width = 8, height = 4, padding = 0, rotation = 0,
  appendOnly = false }) {
  const { Output, WebMOutputFormat, Mp4OutputFormat, BufferTarget, EncodedVideoPacketSource, EncodedPacket }
    = mediabunny;
  const format = rotation ? new Mp4OutputFormat() : new WebMOutputFormat({ appendOnly });
  const output = new Output({ format, target: new BufferTarget() });
  const source = new EncodedVideoPacketSource('vp8');
  output.addVideoTrack(source, rotation ? { frameRate: fps, rotation } : { frameRate: fps });
  await output.start();
  for (let i = 0; i < count; i++) {
    const payload = new Uint8Array(Math.max(4, padding));
    payload[0] = i === 0 ? 0 : 1;
    payload[1] = (i + 1) & 0xff;
    const packet = new EncodedPacket(payload, i === 0 ? 'key' : 'delta', i / fps, 1 / fps);
    await source.add(packet, i === 0
      ? { decoderConfig: { codec: 'vp8', codedWidth: width, codedHeight: height } }
      : undefined);
  }
  await output.finalize();
  return output.target.buffer;
}

/// A Blob that records how it was read. `slice` is the ranged read mediabunny's BlobSource issues; a whole-file
/// `arrayBuffer()` is what the REMOVED implementation did (it read the entire clip into memory before the worker
/// ever saw it) and is what must not happen here.
class ObservedBlob extends Blob {
  constructor(parts) {
    super(parts);
    this.sliceCalls = 0;
    this.wholeFileReads = 0;
  }

  slice(...args) {
    this.sliceCalls++;
    return super.slice(...args);
  }

  arrayBuffer() {
    this.wholeFileReads++;
    return super.arrayBuffer();
  }
}

/// The worker's side of the decode driver's contract, recorded rather than acted on.
function makeHost(overrides = {}) {
  const pushes = [];
  const progress = [];
  let roomCalls = 0;
  return {
    pushes,
    progress,
    roomCalls: () => roomCalls,
    host: {
      loadModule: async () => mediabunny,
      isCancelled: () => false,
      awaitRoom: async () => { roomCalls++; return true; },
      pushFrame: (pixels, format, width, height, rotation, mediaTsMs) => {
        pushes.push({
          format,
          width,
          height,
          rotation,
          mediaTsMs,
          marker: pixels[0],
          length: pixels.length,
          // Every distinct byte value in the frame. One entry means a solid frame of exactly that colour, which
          // is how "no padding came along for the ride" is asserted without carrying every pixel.
          colours: [...new Set(pixels.filter((_, i) => i % 4 === 0))].sort((a, b) => a - b),
        });
        return true;
      },
      onProgress: (info) => progress.push(info),
      log: () => {},
      ...overrides,
    },
  };
}

test('a real Matroska clip demuxes, decodes and reaches the pipeline with its own media timestamps',
  { skip }, async () => {
    const blob = new ObservedBlob([await muxClip({ count: 12 })]);
    const recorder = makeHost();

    const outcome = await decodeClipIntoPipeline(blob, recorder.host);

    assert.equal(outcome.reason, IMPORT_COMPLETED);
    assert.equal(outcome.decoded, 12);
    assert.equal(outcome.supplied, 12);
    assert.equal(outcome.rejected, 0);
    // MEDIA TIME, read out of the container rather than off the clock: 10 fps is 100 ms apart, and the loop
    // above ran as fast as Node could turn it over.
    assert.deepEqual(recorder.pushes.map((p) => p.mediaTsMs),
      [0, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100]);
    // IN ORDER, one frame per muxed packet, none skipped and none repeated -- the marker byte is the packet's.
    assert.deepEqual(recorder.pushes.map((p) => p.marker), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
    // Full frames at the clip's own geometry, tightly packed RGBA.
    assert.deepEqual([...new Set(recorder.pushes.map((p) => p.width + 'x' + p.height))], ['8x4']);
    assert.deepEqual([...new Set(recorder.pushes.map((p) => p.length))], [8 * 4 * 4]);
    // The container's declared duration is the progress denominator, not an estimate from the frame count.
    assert.equal(outcome.durationMs, 1200);
    assert.equal(recorder.progress[0].durationMs, 1200);
    assert.equal(recorder.progress[recorder.progress.length - 1].decoded, 12);
    // The gate is consulted once per frame, before the frame is copied -- the pacing contract, against a real
    // sample iterator rather than a scripted one.
    assert.equal(recorder.roomCalls(), 12);
  });

test('the real bundle reports a matrix-free colour space for the RGB frames this producer accepts', { skip },
  async () => {
    // THE ONE CLAIM THE ACCEPT SIDE OF coreFormatOf'S RGB BRANCH RESTS ON: a sample that never went through a
    // YUV matrix says so, as `colorSpace.matrix === 'rgb'`. That is what separates an RGBA copy that is a
    // channel reorder from one that is a colour conversion the core cannot undo -- and it is a fact about THIS
    // library, so the stubbed harness (which fills the field in itself, from the same rule) cannot check it.
    // If a future bundle stopped filling it in, every RGB import would be refused rather than silently
    // mis-coloured, and this test is what names the reason.
    const rgb = new mediabunny.VideoSample(new Uint8Array(8 * 4 * 4),
      { format: 'RGBX', codedWidth: 8, codedHeight: 4, timestamp: 0 });
    try {
      assert.equal(rgb.colorSpace.matrix, 'rgb');
      assert.equal(rgb.colorSpace.fullRange, true);
    } finally {
      rgb.close();
    }
    // ...and a 4:2:0 sample is NOT reported that way, which is the half that makes the check discriminating
    // rather than a constant. (The core converts these itself, so what its matrix says does not gate them.)
    const yuv = new mediabunny.VideoSample(new Uint8Array(8 * 4 + 2 * 4 * 2),
      { format: 'I420', codedWidth: 8, codedHeight: 4, timestamp: 0 });
    try {
      assert.equal(yuv.colorSpace.matrix, 'bt709');
    } finally {
      yuv.close();
    }
  });

test('the clip stays a Blob and is read through the source, never materialized as one buffer', { skip },
  async () => {
    // THE DEFECT THIS REPLACES. The removed implementation called `readAsBytes` on the whole file and
    // transferred the resulting ArrayBuffer into the worker, so a multi-gigabyte clip was resident before
    // decoding even began. Here the Blob itself reaches the demuxer, and BlobSource reads it through
    // `slice(pos).stream()` behind its own bounded cache.
    //
    // BE EXACT ABOUT WHAT THIS PROVES: that THIS repo's code never converts the file to a buffer. It does NOT
    // measure mediabunny's memory ceiling -- how far its ReadOrchestrator prefetches is its own affair (it
    // defaults to an 8 MB cache), and a Node Blob is backed by memory anyway, so no byte count taken here would
    // say anything about a real file on disk.
    const blob = new ObservedBlob([await muxClip({ count: 30, padding: 4096 })]);
    const recorder = makeHost();

    const outcome = await decodeClipIntoPipeline(blob, recorder.host);

    assert.equal(outcome.decoded, 30, 'the clip really was decoded through this path');
    assert.equal(blob.wholeFileReads, 0, 'nothing may read the clip as one whole-file buffer');
    assert.equal(blob.sliceCalls > 0, true, 'the source must read it through the Blob\'s own ranged surface');
  });

test('the picture is what reaches the pipeline, not the padded coded plane', { skip }, async () => {
  // Against the REAL library this time: `sample.codedWidth/codedHeight` are getters over `visibleRect`, and
  // `allocationSize()` / `copyTo()` default to the same rectangle -- so the producer, which passes no `rect` at
  // all, gets the picture. A producer that reached for the coded plane instead would push a 12x8 frame with a
  // skirt of 0xfe, which is a geometry no live session can produce and pixels that are not picture content.
  const decoder = globalThis.__scriptedDecoder;
  decoder.visiblePadding = 4;
  try {
    const blob = new ObservedBlob([await muxClip({ count: 3, width: 12, height: 8 })]);
    const recorder = makeHost();

    const outcome = await decodeClipIntoPipeline(blob, recorder.host);

    assert.equal(outcome.decoded, 3);
    assert.deepEqual([...new Set(recorder.pushes.map((p) => p.width + 'x' + p.height))], ['8x4'],
      'the visible picture, not the 12x8 coded plane');
    assert.deepEqual([...new Set(recorder.pushes.map((p) => p.length))], [8 * 4 * 4]);
    assert.deepEqual(recorder.pushes.map((p) => p.colours), [[1], [2], [3]],
      'each frame must be solid its own marker: a 0xfe anywhere is padding that was copied');
  } finally {
    decoder.visiblePadding = 0;
  }
});

test('a clip whose container declares a rotation carries that angle to the core', { skip }, async () => {
  // PARITY (.claude/rules/platform-parity.md). The CLI's offline producer auto-rotates -- OpenCV's videoio
  // VideoCaptureBase initialises autorotate(true) and applies the metadata rotation in retrieveFrame, and
  // native/src/cv/video_loader.h never turns it off -- while mediabunny treats rotation as metadata on the
  // copyTo path and WebCodecs ignores it by specification. The turn itself now happens in the core, after the
  // colour conversion (native/wasm/wasm_api.cpp pushOfflineFrame), so what this file can settle is the half
  // only a REAL container round trip can: that the angle survives the mux and reaches the push, which is a
  // property of mediabunny (its decoder wrapper stamps the TRACK's rotation onto every sample) rather than
  // something this repo can stipulate.
  for (const rotation of [90, 180, 270]) {
    const blob = new ObservedBlob([await muxClip({ count: 2, rotation })]);
    const recorder = makeHost();

    const outcome = await decodeClipIntoPipeline(blob, recorder.host);

    assert.equal(outcome.decoded, 2, 'rotation ' + rotation);
    assert.deepEqual([...new Set(recorder.pushes.map((p) => p.rotation))], [rotation], 'rotation ' + rotation);
    // The UNROTATED geometry and the full frame: turning it here would swap the axes on 90 and 270, and the
    // core would then turn it a second time.
    assert.deepEqual([...new Set(recorder.pushes.map((p) => p.width + 'x' + p.height))], ['8x4'],
      'rotation ' + rotation + ': the producer must not turn the frame itself');
    assert.deepEqual([...new Set(recorder.pushes.map((p) => p.length))], [8 * 4 * 4], 'rotation ' + rotation);
    assert.deepEqual(recorder.pushes.map((p) => p.marker), [1, 2], 'rotation ' + rotation);
  }
});

// --- THE BACKGROUND DURATION SCAN, against a clip that really declares no duration ------------------------------
//
// `computeDuration()` resolves the LAST packet, i.e. a walk over the whole file for a container that declares
// nothing, so the producer starts it WITHOUT AWAITING IT and lets it upgrade the progress denominator whenever it
// lands. Two claims sit in that comment that only the real library can settle, and until now every clip in this
// file declared a duration -- so the scan never ran at all here and both claims were stubbed assertions about a
// stub: that CONCURRENT READS ON ONE BlobSource ARE SAFE (the walk runs against the same `Input` the sample
// iterator is draining), and that `input.dispose()` IS WHAT STOPS THE READS when the import ends first.

test('a real packet walk runs concurrently with the sample iterator and upgrades the denominator', { skip },
  async () => {
    // THE CLIP DECLARES NOTHING (appendOnly, see muxClip), so this is the first case in the tree where the
    // production code's un-awaited `computeDuration()` actually walks a real file while `sink.samples()` reads
    // the same source. What has to come out unharmed is the SAMPLE WALK: every frame, in order, at its own media
    // timestamp -- a shared reader that served one consumer's position to the other would show up as a gap, a
    // repeat or a reordering here, and nowhere else.
    const blob = new ObservedBlob([await muxClip({ count: 60, appendOnly: true })]);
    const recorder = makeHost({
      // A real macrotask per frame, which is what the flow gate's park is in production: it hands the walk the
      // turns it would get in a worker instead of letting one synchronous loop starve it.
      awaitRoom: async () => { await new Promise((resolve) => setTimeout(resolve, 0)); return true; },
    });

    const outcome = await decodeClipIntoPipeline(blob, recorder.host);

    // 1. THE METADATA CALL REALLY FOUND NOTHING. The pre-first-frame progress is the proof: it is posted from the
    //    declared value alone, so a 0 here is the container's silence and not the scan being slow.
    assert.equal(recorder.progress[0].durationMs, 0, 'the clip must genuinely declare no duration');
    // 2. THE SAMPLE WALK IS UNDISTURBED by the concurrent one.
    assert.equal(outcome.reason, IMPORT_COMPLETED);
    assert.equal(outcome.decoded, 60);
    assert.equal(outcome.supplied, 60);
    assert.deepEqual(recorder.pushes.map((p) => p.marker), Array.from({ length: 60 }, (_, i) => i + 1));
    assert.deepEqual(recorder.pushes.map((p) => p.mediaTsMs), Array.from({ length: 60 }, (_, i) => i * 100));
    assert.deepEqual([...new Set(recorder.pushes.map((p) => p.width + 'x' + p.height))], ['8x4']);
    // 3. AND THE WALK LANDED, mid-import, upgrading the denominator every later progress message reads.
    assert.equal(outcome.durationMs, 6000, 'the background scan must resolve the real duration');
    assert.equal(recorder.progress[recorder.progress.length - 1].durationMs, 6000);
    assert.equal(blob.wholeFileReads, 0, 'and neither reader may materialize the clip as one buffer');
  });

test('a cancel disposes the Input, and that is what ends the walk it left running', { skip }, async () => {
  // THE SECOND CLAIM. The producer starts the walk and never cancels it, because mediabunny exposes no abort for
  // one; what it relies on instead is the `input.dispose()` in its own `finally`. That is only assertable while
  // the walk is STILL RUNNING when the import ends, which needs a clip whose walk is long and whose first frame
  // is not: 20,000 blocks in a quarter of a megabyte, cancelled at frame one.
  //
  // The witness is mediabunny's OWN wording. The abandoned walk does not resolve and does not hang -- it rejects
  // with "Input has been disposed.", which names the mechanism rather than inferring it, and the producer's
  // rejection handler is what keeps that from reaching onunhandledrejection.
  const rejections = [];
  const onUnhandled = (reason) => rejections.push(reason);
  process.on('unhandledRejection', onUnhandled);
  try {
    const blob = new ObservedBlob([await muxClip({ count: 20000, appendOnly: true })]);
    const logs = [];
    let pushed = 0;
    const recorder = makeHost({ isCancelled: () => pushed >= 1, log: (m) => logs.push(m) });
    recorder.host.pushFrame = () => { pushed++; return true; };

    const outcome = await decodeClipIntoPipeline(blob, recorder.host);

    assert.equal(outcome.reason, IMPORT_CANCELLED);
    assert.equal(outcome.decoded, 1, 'the cancel must not wait for the walk');
    assert.equal(outcome.durationMs, 0, 'and the walk must still have been unresolved when it did');

    // The rejection arrives after the import has already returned, which is the whole point of not awaiting it.
    // WAITED FOR, NOT SLEPT THROUGH: the settlement line is the event, so the loop ends on the turn it is
    // written and the bound is the failure path -- a walk that never settles reddens by name instead of being
    // read as one that settled quietly.
    const settlementsSoFar = () => logs.filter((m) => m.includes('duration') && !m.includes('scanning for it'));
    const deadline = performance.now() + 5000;
    while (settlementsSoFar().length === 0) {
      assert.equal(performance.now() < deadline, true, 'the abandoned walk never settled at all');
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
    // "Exactly once" is an assertion of ABSENCE, so it is not read on the turn the first line lands: twenty
    // further turns of the loop give a second one -- queued behind the first -- the chance to appear.
    for (let turn = 0; turn < 20; turn++) {
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
    const settlements = settlementsSoFar();
    assert.equal(settlements.length, 1, 'the abandoned walk must settle exactly once');
    assert.match(settlements[0], /Input has been disposed/,
      'disposing the Input is what ends the walk -- not a timeout, and not the walk finishing');
    assert.deepEqual(rejections, [], 'and the producer, not the worker\'s last resort, is what handles it');
  } finally {
    process.off('unhandledRejection', onUnhandled);
  }
});

test('a cancel stops a real sample iterator mid-clip', { skip }, async () => {
  // Breaking out of a `for await` calls the async generator's return(), and whether mediabunny's sink actually
  // stops decoding there is a property of mediabunny, not of this repo's code -- so it is asserted against the
  // real one. The decoder's own call count is the witness: it must stop climbing.
  //
  // THE WINDOW IS MEASURED, NOT PICKED. "The count stopped climbing" is an assertion of absence, and an absence
  // observed over a duration nobody derived says nothing: too short a window on a loaded machine passes whether
  // the sink stopped or had merely not got round to the next packet. So the positive control comes first --
  // the same clip, the same decoder, this machine, this moment -- and what it measures is how long the sink
  // needs to pull all 40 packets. A sink that ignored the break would have had time to drain the entire clip,
  // four times over, inside the window the cancelled run then waits out.
  const decoder = globalThis.__scriptedDecoder;

  const controlRecorder = makeHost();
  const controlStart = performance.now();
  const control = await decodeClipIntoPipeline(new ObservedBlob([await muxClip({ count: 40 })]),
    controlRecorder.host);
  const fullDrainMs = performance.now() - controlStart;
  assert.equal(control.decoded, 40, 'the control must drive the decoder through the whole clip');
  assert.equal(decoder.decoded, 40, 'and the counter this test reads must be what moved while it did');
  assert.equal(fullDrainMs > 0, true, 'a window built on an unmeasured interval would bound nothing');

  const blob = new ObservedBlob([await muxClip({ count: 40 })]);
  // The cancel is keyed off the recorder's OWN tally rather than off a replacement `pushFrame`: a stub written
  // here would restate the host contract, and a stub that restated it wrongly would keep recording -- silently
  // mislabelled -- for whoever next asserts on `pushes`. `makeHost` already speaks the production signature.
  const recorder = makeHost();
  recorder.host.isCancelled = () => recorder.pushes.length >= 5;

  const outcome = await decodeClipIntoPipeline(blob, recorder.host);
  const decodedAtStop = decoder.decoded;
  // Polled through, not slept through: every turn is another chance for a sink that did not stop to decode one
  // more packet, and a breach is caught on the turn it happens rather than at the end of a nap.
  const deadline = performance.now() + 4 * fullDrainMs;
  while (performance.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(decoder.decoded, decodedAtStop, 'the sink must stop pulling packets once the loop breaks');
  }

  assert.equal(outcome.reason, IMPORT_CANCELLED);
  assert.equal(outcome.decoded, 5, 'the loop must stop at the first frame after the cancel, not at the clip end');
  assert.equal(decoder.decoded, decodedAtStop, 'the sink must stop pulling packets once the loop breaks');
  assert.equal(decoder.decoded < 40, true, 'a cancel that let the whole clip decode cancelled nothing');
  // And the five it did push are the FIRST five, whole: a cancel truncates the walk, it does not reorder or
  // reshape what already went through. This is also what keeps `pushes` honest -- a recorder wired to a
  // different signature than the producer calls would land the marker, size and stamp in the wrong fields here.
  assert.deepEqual(recorder.pushes.map((p) => p.marker), [1, 2, 3, 4, 5]);
  assert.deepEqual(recorder.pushes.map((p) => p.mediaTsMs), [0, 100, 200, 300, 400]);
  assert.deepEqual([...new Set(recorder.pushes.map((p) => p.width + 'x' + p.height))], ['8x4']);
  assert.deepEqual([...new Set(recorder.pushes.map((p) => p.length))], [8 * 4 * 4]);
});
