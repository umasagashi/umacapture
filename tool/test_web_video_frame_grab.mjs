// Node coverage for the web front end's VIDEO FRAME GRAB (web/worker.js + web/video_import.mjs): the path the
// import error report pulls one arbitrary frame of a clip out through.
//
// WHAT IS UNDER TEST, and why each property needs a deterministic runner rather than a browser session:
//
//   1. THE CORE RECEIVES THE DECODER'S OWN PIXELS. The frame's own format, the buffer `copyTo` filled and the
//      layout `copyTo` RESOLVED TO are handed to `encodeDecodedFramePng` unmodified. A browser cannot show
//      this: every layout a real UA has produced so far is the tightly packed one, so a re-derived layout and
//      a passed-through layout look identical there. Here the stub answers a layout no arithmetic on this
//      side would ever produce, so an implementation that synthesised one is caught by construction.
//   2. THE REPORT NAMES THE FRAME IT ACTUALLY GOT. `mediaTsMs` comes from the sample, never from the request.
//   3. A QUESTION THE CLIP CANNOT ANSWER IS REFUSED, not answered with some other frame.
//   4. THERE IS NO CANVAS FALLBACK. A core without the PNG export refuses; it does not draw the frame with
//      the browser's colour conversion and call it the recogniser's.
//   5. EVERY QUERY IS ANSWERED EXACTLY ONCE, including the throw path, and the reply is correlated.
//
// WHAT IS STUBBED AND WHAT IS NOT. The mediabunny namespace and the core are stubs, exactly as in
// tool/test_web_video_import.mjs, and for the same reason: neither `VideoDecoder` nor `VideoFrame.copyTo`
// exists in Node, and the vendored bundle is mediabunny's browser build. The production `probeClipTimeline` /
// `grabClipFramePng` and the production worker dispatch are the real ones. What this file therefore CANNOT
// establish is that a real browser's `copyTo` produces the layout the core reads -- that is a browser
// measurement and is recorded under testdata/evidence/video-import-error-report/stage-2b/.

import assert from 'node:assert/strict';
import test from 'node:test';

// web/worker.js is a module worker: it reads `self` at load time. Stand one up before the import.
const posted = [];
globalThis.self = {
  postMessage(message) { posted.push(message); },
  onmessage: null,
  onerror: null,
  onunhandledrejection: null,
};
const { __previewRelayTestHooks, __captureSessionTestHooks, __videoImportTestHooks } =
  await import('../web/worker.js');
const hooks = __videoImportTestHooks();

test.after(() => {
  __previewRelayTestHooks().closeYieldChannel();
  __captureSessionTestHooks().stopDrainLoop();
  hooks.setModuleLoader(null);
});

// ---------------------------------------------------------------------------------------------------------
// Stubs

/// A decoded sample, shaped like mediabunny's VideoSample: `codedWidth`/`codedHeight` are the VISIBLE size,
/// `timestamp` is in SECONDS, and `copyTo` returns the layout it used.
///
/// `fill` writes a recognisable byte pattern so a test can assert that the bytes the core received are the
/// bytes this sample produced, rather than a buffer somebody else allocated.
function makeSample({
  width = 8, height = 4, format = 'I420', rotation = 0, timestamp = 1.5,
  colorSpace = { matrix: 'bt709' }, layout = null, allocation = null, copyThrows = null,
} = {}) {
  const sample = {
    codedWidth: width,
    codedHeight: height,
    format,
    rotation,
    timestamp,
    colorSpace,
    closed: 0,
    copyOptionsSeen: [],
    allocationSize(options) {
      sample.copyOptionsSeen.push(options);
      return allocation ?? (format === 'I420' ? width * height * 3 / 2 : width * height * 4);
    },
    async copyTo(buffer, options) {
      if (copyThrows !== null) throw copyThrows;
      sample.copyOptionsSeen.push(options);
      for (let i = 0; i < buffer.length; i++) buffer[i] = (i * 7 + 13) & 0xff;
      sample.copiedBytes = buffer;
      // THE LAYOUT IS THE UA'S ANSWER, not ours. The default here is deliberately NOT the tightly packed one
      // any arithmetic on the JS side would compute: it is what makes "the layout was passed through"
      // separable from "a layout was produced".
      return layout ?? [{ offset: 1, stride: 3 }, { offset: 5, stride: 7 }, { offset: 11, stride: 13 }];
    },
    close() { sample.closed++; },
  };
  return sample;
}

/// A mediabunny namespace with just the surface these two entry points use.
function makeMediabunny({
  track = {}, sample = null, samples = null, packets = null, sampleThrowsFor = null, frames = null,
} = {}) {
  const state = {
    disposed: 0,
    decoderOptions: [],
    requestedTimes: [],
    computeDurationCalls: 0,
    packetOptions: [],
  };
  const fullTrack = {
    getCodec: async () => 'avc1.640028',
    canDecode: async () => true,
    getFirstTimestamp: async () => 0,
    getDurationFromMetadata: async () => 10,
    computeDuration: async () => { state.computeDurationCalls++; return 10; },
    computePacketStats: async () => ({ averagePacketRate: 30 }),
    ...track,
  };
  const namespace = {
    state,
    ALL_FORMATS: [],
    BlobSource: class { constructor(blob) { this.blob = blob; } },
    Input: class {
      constructor(options) { this.options = options; }
      async getPrimaryVideoTrack() { return track === null ? null : fullTrack; }
      async dispose() { state.disposed++; }
    },
    VideoSampleSink: class {
      constructor(_track, options) { state.decoderOptions.push(options); }
      // The PROBE's one call: it decodes a single frame to learn the size, and needs no neighbour.
      async getSample(seconds) {
        state.requestedTimes.push(seconds);
        if (sampleThrowsFor !== null && state.decoderOptions.length <= sampleThrowsFor) {
          throw new Error('scripted decoder configure failure');
        }
        if (frames !== null) {
          const at = frames.filter((t) => t <= seconds).pop();
          return at === undefined ? null : makeSample({ timestamp: at });
        }
        if (samples !== null) return samples(seconds);
        return sample;
      }
      // `samples(start)` REPRODUCES THE REAL SINK'S RULE, because the grab depends on both halves of it:
      // mediabunny holds back the last sample at or before `start` and yields THAT first, then the rest in
      // presentation order (mediabunny 1.52.3 `mediaSamplesInRange`). So the first yield is the frame
      // displayed at the requested time and the second is its successor -- and a clip whose last frame is the
      // answer yields nothing more, which is how "there is no successor" is a measurement here too.
      //
      // Three scripting modes, in the order a test reaches for them: `frames` (a list of timestamps in
      // seconds, selected by the rule above), `samples(seconds)` (a function answering with one sample or
      // null), or a single `sample`.
      samples(start) {
        state.requestedTimes.push(start);
        const configureFails = sampleThrowsFor !== null && state.decoderOptions.length <= sampleThrowsFor;
        let queue;
        if (frames !== null) {
          let from = 0;
          for (let i = 0; i < frames.length; i++) {
            if (frames[i] <= start) from = i; else break;
          }
          queue = frames.slice(from).map((timestamp) => makeSample({ timestamp }));
        } else {
          const one = samples !== null ? samples(start) : sample;
          queue = one === null || one === undefined ? [] : [one];
        }
        return {
          [Symbol.asyncIterator]() { return this; },
          async next() {
            // A CONFIGURE FAILURE WHERE THE REAL ONE LANDS: out of the iterator, not out of the constructor.
            if (configureFails) throw new Error('scripted decoder configure failure');
            return queue.length === 0
              ? { value: undefined, done: true }
              : { value: queue.shift(), done: false };
          },
          async return() { queue.length = 0; return { value: undefined, done: true }; },
        };
      }
    },
    EncodedPacketSink: class {
      constructor(_track) { this.index = 0; }
      async getFirstPacket(options) {
        state.packetOptions.push(options);
        return packets === null || packets.length === 0 ? null : { ...packets[0], index: 0 };
      }
      async getNextPacket(packet, options) {
        state.packetOptions.push(options);
        const next = packet.index + 1;
        if (packets === null || next >= packets.length) return null;
        return { ...packets[next], index: next };
      }
    },
  };
  return namespace;
}

/// A core exposing only what this path calls. `encodeDecodedFramePng` records every argument verbatim.
function makeCore({ answer = null, omitExport = false } = {}) {
  const calls = [];
  const core = { calls };
  if (!omitExport) {
    core.encodeDecodedFramePng = (bytes, format, width, height, rotation, layout) => {
      calls.push({ bytes, format, width, height, rotation, layout });
      const upright = rotation === 90 || rotation === 270;
      return answer ?? {
        ok: true,
        reason: '',
        message: '',
        png: new Uint8Array([0x89, 0x50, 0x4e, 0x47, width & 0xff, height & 0xff]),
        width: upright ? height : width,
        height: upright ? width : height,
      };
    };
  }
  return core;
}

// ---------------------------------------------------------------------------------------------------------
// Driver

function install({ mediabunny, core }) {
  posted.length = 0;
  hooks.installCore(core);
  hooks.setModuleLoader(mediabunny === null ? null : async () => mediabunny);
}

let nextRequestId = 100;

async function ask(message) {
  const requestId = ++nextRequestId;
  await self.onmessage({ data: { requestId, file: { size: 1234 }, ...message } });
  const replies = posted.filter((m) => typeof m === 'object' && m !== null && m.type === 'videoFrameGrabReply');
  // ONE reply, always, and correlated. Asserted here rather than in one test, so every case below carries it.
  assert.equal(replies.length, 1, 'expected exactly one videoFrameGrabReply, got ' + replies.length);
  assert.equal(replies[0].requestId, requestId);
  posted.length = 0;
  return replies[0];
}

const askProbe = () => ask({ type: 'videoFrameProbe' });
const askGrab = (timeMs) => ask({ type: 'videoFrameGrab', timeMs });

// ---------------------------------------------------------------------------------------------------------
// The grab

test('the core is handed the layout copyTo resolved to, not one this side computed', async () => {
  const sample = makeSample({ layout: [{ offset: 2, stride: 5 }, { offset: 40, stride: 9 }] });
  const core = makeCore();
  install({ mediabunny: makeMediabunny({ sample }), core });

  const reply = await askGrab(1500);
  assert.equal(reply.error, undefined);
  assert.deepEqual(core.calls[0].layout, [{ offset: 2, stride: 5 }, { offset: 40, stride: 9 }]);
});

test('the core is handed the bytes copyTo filled, in the frame\'s own format', async () => {
  const sample = makeSample({ format: 'I420' });
  const core = makeCore();
  install({ mediabunny: makeMediabunny({ sample }), core });

  await askGrab(1500);
  assert.equal(core.calls[0].format, 'I420');
  // The buffer identity is the point: a re-copy, a slice or a re-allocation would all still be "some bytes".
  assert.equal(core.calls[0].bytes, sample.copiedBytes);
  assert.equal(core.calls[0].bytes[0], 13);
  // A YUV frame is copied with NO conversion options at all -- the one shape that works, per coreFormatOf.
  assert.deepEqual(sample.copyOptionsSeen, [undefined, undefined]);
});

test('an RGB frame reaches the core as RGBA through the import\'s own format mapping', async () => {
  // BGRX is what Firefox 153 was measured to hand back, and what the core refuses BY NAME if it is passed
  // through unmapped (stage 2a: `unknownPixelFormat`).
  const sample = makeSample({ format: 'BGRX', layout: [{ offset: 0, stride: 32 }] });
  const core = makeCore();
  install({ mediabunny: makeMediabunny({ sample }), core });

  await askGrab(1500);
  assert.equal(core.calls[0].format, 'RGBA');
  assert.deepEqual(sample.copyOptionsSeen, [{ format: 'RGBA' }, { format: 'RGBA' }]);
});

test('the grab asks the decoder for the requested time and reports the frame it actually got', async () => {
  const sample = makeSample({ timestamp: 9.449800 });
  const mediabunny = makeMediabunny({ sample });
  install({ mediabunny, core: makeCore() });

  const reply = await askGrab(9458);
  // THE REQUEST IS THE MILLISECOND'S UPPER EDGE, not the millisecond. mediabunny keeps the last sample whose
  // start is <= the given SECONDS, while the Windows producer keeps the last frame whose stamp ROUNDS to at
  // most the target; asking just under `T + 0.5` ms is that rule. Asserted as the rule rather than as a
  // literal, because the exact value is the largest double still publishing as 9458.
  assert.equal(mediabunny.state.requestedTimes.length, 1);
  const asked = mediabunny.state.requestedTimes[0];
  assert.equal(Math.round(asked * 1000), 9458, 'the request must still publish as the requested millisecond');
  assert.equal(asked > 9.458, true, 'and it must reach past it, or a frame stamped 9458.4 ms is unreachable');
  // 9450 (the sample's own 9.4498 s, rounded to whole milliseconds as the import rounds), NOT the requested
  // 9458. A report that quoted the request would name a frame the user never saw.
  assert.equal(JSON.parse(reply.json).mediaTsMs, 9450);
});

test('a time below the clip\'s first frame is clamped up to it, as the Windows producer clamps', async () => {
  // MEASURED, not defensive. The probe publishes `firstFrameMs` in whole milliseconds, so a clip whose first
  // frame is at 50.033 ms publishes 50 -- and mediabunny answers null, NOT the first frame, for 50.000.
  // Headless Chrome 151 refused exactly this while Windows answered it; the clamp is what closes that.
  const sample = makeSample({ timestamp: 0.050033 });
  const mediabunny = makeMediabunny({
    track: { getFirstTimestamp: async () => 0.050033 },
    samples: (seconds) => (seconds < 0.050033 ? null : sample),
  });
  install({ mediabunny, core: makeCore() });

  // 50 NO LONGER NEEDS THE CLAMP, and that is the millisecond grid doing its job rather than the clamp being
  // dead: the request for 50 reaches 50.4999... ms, which is already past this clip's 50.033 ms floor.
  const reply = await askGrab(50);
  assert.equal(reply.error, undefined);
  assert.equal(mediabunny.state.requestedTimes[0] > 0.050033, true);
  assert.equal(JSON.parse(reply.json).mediaTsMs, 50);

  // BELOW the floor is what the clamp is for, and it still fires there. Windows clamps the same way
  // (`clampIntoClip`), so both legs answer a below-range request with the first frame rather than nothing.
  mediabunny.state.requestedTimes.length = 0;
  const below = await askGrab(49);
  assert.equal(below.error, undefined);
  assert.deepEqual(mediabunny.state.requestedTimes, [0.050033]);
  assert.equal(JSON.parse(below.json).mediaTsMs, 50);
});

test('the clamp does not move a time that is already inside the clip', async () => {
  const mediabunny = makeMediabunny({
    track: { getFirstTimestamp: async () => 0.050033 },
    sample: makeSample({ timestamp: 9.4498 }),
  });
  install({ mediabunny, core: makeCore() });

  await askGrab(9458);
  assert.equal(mediabunny.state.requestedTimes[0] > 0.050033, true, 'not pulled back to the clip\'s floor');
  assert.equal(Math.round(mediabunny.state.requestedTimes[0] * 1000), 9458);
});

test('a time the clip cannot answer is refused rather than answered with another frame', async () => {
  install({ mediabunny: makeMediabunny({ sample: null }), core: makeCore() });

  const reply = await askGrab(10);
  assert.match(reply.error, /no frame at or before 10 ms/);
  assert.equal(reply.png, undefined);
  assert.equal(reply.json, undefined);
});

test('the clip\'s rotation travels to the core, which rotates after converting', async () => {
  const sample = makeSample({ width: 736, height: 1308, rotation: 90 });
  const core = makeCore();
  install({ mediabunny: makeMediabunny({ sample }), core });

  const reply = await askGrab(1500);
  assert.equal(core.calls[0].rotation, 90);
  // The core reports the ENCODED size, post-rotation, and the reply carries the core's answer rather than
  // the pre-rotation size the sample had.
  assert.deepEqual(
    { width: JSON.parse(reply.json).width, height: JSON.parse(reply.json).height },
    { width: 1308, height: 736 },
  );
});

test('a core that cannot encode a decoded frame refuses instead of falling back to a canvas', async () => {
  install({ mediabunny: makeMediabunny({ sample: makeSample() }), core: makeCore({ omitExport: true }) });

  const reply = await askGrab(1500);
  assert.match(reply.error, /cannot encode a decoded frame/);
  assert.equal(reply.png, undefined);
});

test('a core refusal is carried out verbatim, by its own reason and message', async () => {
  const core = makeCore({
    answer: { ok: false, reason: 'layoutNotTightlyPacked', message: 'the copy\'s layout [...] is not', png: null },
  });
  install({ mediabunny: makeMediabunny({ sample: makeSample() }), core });

  const reply = await askGrab(1500);
  assert.match(reply.error, /layoutNotTightlyPacked/);
  assert.match(reply.error, /is not/);
  assert.equal(reply.png, undefined);
});

test('a throw out of copyTo is answered, and the sample and the demuxer are still released', async () => {
  const sample = makeSample({ copyThrows: new Error('scripted copyTo failure') });
  const mediabunny = makeMediabunny({ sample });
  install({ mediabunny, core: makeCore() });

  const reply = await askGrab(1500);
  assert.match(reply.error, /scripted copyTo failure/);
  assert.equal(sample.closed, 1);
  assert.equal(mediabunny.state.disposed, 1);
});

test('a software decoder is asked for first, and a configure it refuses is retried once', async () => {
  const mediabunny = makeMediabunny({ sample: makeSample(), sampleThrowsFor: 1 });
  install({ mediabunny, core: makeCore() });

  const reply = await askGrab(1500);
  assert.equal(reply.error, undefined);
  assert.deepEqual(mediabunny.state.decoderOptions, [
    { hardwareAcceleration: 'prefer-software' },
    { hardwareAcceleration: 'no-preference' },
  ]);
});

test('a file with no video track is refused by name and never reaches the core', async () => {
  const core = makeCore();
  install({ mediabunny: makeMediabunny({ track: null }), core });

  const reply = await askGrab(1500);
  assert.match(reply.error, /no video track/);
  assert.equal(core.calls.length, 0);
});

test('a codec this browser cannot decode is refused with the codec named', async () => {
  install({
    mediabunny: makeMediabunny({ track: { canDecode: async () => false, getCodec: async () => 'hvc1.1.6' } }),
    core: makeCore(),
  });

  const reply = await askGrab(1500);
  assert.match(reply.error, /hvc1\.1\.6/);
});

// ---------------------------------------------------------------------------------------------------------
// The probe

test('the probe reports the clip\'s own first timestamp, not zero', async () => {
  install({
    mediabunny: makeMediabunny({
      track: { getFirstTimestamp: async () => 0.050033 },
      sample: makeSample(),
      packets: [{ timestamp: 0.050033 }, { timestamp: 0.083366 }],
    }),
    core: makeCore(),
  });

  const timeline = JSON.parse((await askProbe()).json);
  assert.equal(timeline.firstFrameMs, 50);
  assert.equal(timeline.hasMediaTimeline, true);
});

test('the probe reports the DECODED size, rotated the way the core will rotate the pixels', async () => {
  install({
    mediabunny: makeMediabunny({
      sample: makeSample({ width: 736, height: 1308, rotation: 90 }),
      packets: [{ timestamp: 0 }, { timestamp: 0.033 }],
    }),
    core: makeCore(),
  });

  const timeline = JSON.parse((await askProbe()).json);
  assert.deepEqual({ width: timeline.width, height: timeline.height }, { width: 1308, height: 736 });
});

test('a container that states its own duration is not scanned for one', async () => {
  const mediabunny = makeMediabunny({
    track: { getDurationFromMetadata: async () => 18.916 },
    sample: makeSample(),
    packets: [{ timestamp: 0 }, { timestamp: 0.033 }],
  });
  install({ mediabunny, core: makeCore() });

  const timeline = JSON.parse((await askProbe()).json);
  assert.equal(timeline.durationMs, 18916);
  // The scan is a full ranged pass over the packet index of a file that can be gigabytes.
  assert.equal(mediabunny.state.computeDurationCalls, 0);
});

test('a container that states no duration is scanned rather than reported as indeterminate', async () => {
  const mediabunny = makeMediabunny({
    track: { getDurationFromMetadata: async () => null, computeDuration: async () => 39.933 },
    sample: makeSample(),
    packets: [{ timestamp: 0 }, { timestamp: 0.033 }],
  });
  install({ mediabunny, core: makeCore() });

  const timeline = JSON.parse((await askProbe()).json);
  assert.equal(timeline.durationMs, 39933);
});

test('a duration neither stated nor scannable is reported as indeterminate, not as a guess', async () => {
  install({
    mediabunny: makeMediabunny({
      track: {
        getDurationFromMetadata: async () => null,
        computeDuration: async () => { throw new Error('scripted scan failure'); },
      },
      sample: makeSample(),
      packets: [{ timestamp: 0 }, { timestamp: 0.033 }],
    }),
    core: makeCore(),
  });

  const timeline = JSON.parse((await askProbe()).json);
  assert.equal(timeline.durationMs, 0);
});

test('several frames sharing one instant have no media timeline', async () => {
  install({
    mediabunny: makeMediabunny({
      sample: makeSample(),
      packets: [{ timestamp: 0 }, { timestamp: 0 }, { timestamp: 0 }],
    }),
    core: makeCore(),
  });

  const timeline = JSON.parse((await askProbe()).json);
  assert.equal(timeline.hasMediaTimeline, false);
});

test('a single-frame clip still has a media timeline: every T maps to that frame truthfully', async () => {
  // The same judgement the Windows counterpart records (`probed > 1` in video_frame_grabber.h readHead).
  install({
    mediabunny: makeMediabunny({ sample: makeSample(), packets: [{ timestamp: 0.5 }] }),
    core: makeCore(),
  });

  const timeline = JSON.parse((await askProbe()).json);
  assert.equal(timeline.hasMediaTimeline, true);
});

test('the timeline walk reads packet metadata only, never packet payloads', async () => {
  const mediabunny = makeMediabunny({
    sample: makeSample(),
    packets: [{ timestamp: 0 }, { timestamp: 0.033 }],
  });
  install({ mediabunny, core: makeCore() });

  await askProbe();
  assert.ok(mediabunny.state.packetOptions.length > 0);
  for (const options of mediabunny.state.packetOptions) {
    assert.deepEqual(options, { metadataOnly: true });
  }
});

test('a frame rate the container cannot state costs the selector its step and nothing else', async () => {
  install({
    mediabunny: makeMediabunny({
      track: { computePacketStats: async () => { throw new Error('scripted stats failure'); } },
      sample: makeSample(),
      packets: [{ timestamp: 0 }, { timestamp: 0.033 }],
    }),
    core: makeCore(),
  });

  const reply = await askProbe();
  assert.equal(reply.error, undefined);
  assert.equal(JSON.parse(reply.json).fps, 0);
});

test('the probe releases the demuxer and the frame it decoded for the size', async () => {
  const sample = makeSample();
  const mediabunny = makeMediabunny({ sample, packets: [{ timestamp: 0 }, { timestamp: 0.033 }] });
  install({ mediabunny, core: makeCore() });

  await askProbe();
  assert.equal(sample.closed, 1);
  assert.equal(mediabunny.state.disposed, 1);
});

// ---------------------------------------------------------------------------------------------------------
// The millisecond grid and the successor's time
//
// Measured against the real mediabunny in headless Firefox 153 as well; the runs, the clips and the two
// rejected sources for the successor are under testdata/evidence/video-import-error-report/stage-h1-3b/.

/// A clip whose frames sit at 100.4 / 133.4 / 166.4 ms. The .4 is the point: those stamps are PUBLISHED as
/// 100 / 133 / 166, so a request made on the raw-seconds grid (`timeMs / 1000`) selects the PREVIOUS frame
/// whenever a caller re-requests a time the producer itself published.
const OFF_GRID = [0.1004, 0.1334, 0.1664];

const grabJson = async (timeMs) => {
  const reply = await askGrab(timeMs);
  assert.equal(reply.error, undefined, 'the grab must not refuse: ' + reply.error);
  return JSON.parse(reply.json);
};

test('a grab lands on the same millisecond grid as the Windows producer', async () => {
  // Windows keeps a frame iff `llround(POS_MSEC) <= T`. Before this, web compared raw float seconds and
  // answered 100 with the frame BEFORE the one it had just published as 100. Measured in Firefox 153: 30 of
  // 92 frames of a VFR clip and 44 of 92 of a 29.97 fps clip moved.
  install({ mediabunny: makeMediabunny({ frames: OFF_GRID }), core: makeCore() });

  assert.equal((await grabJson(100)).mediaTsMs, 100, 'the frame stamped 100.4 ms IS the frame displayed at 100 ms');
  assert.equal((await grabJson(133)).mediaTsMs, 133);
  assert.equal((await grabJson(166)).mediaTsMs, 166);
});

test('re-requesting a grab\'s own mediaTsMs returns the same frame', async () => {
  // The operation every stepping design performs. Without the grid fix it walked BACKWARDS.
  install({ mediabunny: makeMediabunny({ frames: OFF_GRID }), core: makeCore() });

  for (const asked of [100, 133, 166]) {
    const first = await grabJson(asked);
    assert.equal((await grabJson(first.mediaTsMs)).mediaTsMs, first.mediaTsMs);
  }
});

test('a grab states the time of the frame that follows the one it returned', async () => {
  install({ mediabunny: makeMediabunny({ frames: OFF_GRID }), core: makeCore() });

  assert.equal((await grabJson(100)).nextMediaTsMs, 133);
  assert.equal((await grabJson(133)).nextMediaTsMs, 166);
});

test('the last frame of the clip omits nextMediaTsMs from the reply', async () => {
  // OMITTED, not null and not 0 -- the same absent-means-not-there convention the Windows leg uses, and the
  // fact the forward button is disabled from. It comes from the sample iterator running out, never from the
  // container's duration.
  install({ mediabunny: makeMediabunny({ frames: OFF_GRID }), core: makeCore() });

  const last = await grabJson(166);
  assert.equal('nextMediaTsMs' in last, false, 'the successor key is absent at the tail, not stated as null');
  assert.equal(last.mediaTsMs, 166);
});

test('the stated successor walks the clip once and stops at the end', async () => {
  install({ mediabunny: makeMediabunny({ frames: OFF_GRID }), core: makeCore() });

  const visited = [];
  let t = 100;
  for (let guard = 0; guard < 8; guard++) {
    const g = await grabJson(t);
    visited.push(g.mediaTsMs);
    if (!('nextMediaTsMs' in g)) break;
    t = g.nextMediaTsMs;
  }
  assert.deepEqual(visited, [100, 133, 166], 'every frame once, in order, then a stop');
});

test('the frame before one at M is the ordinary grab at M minus one millisecond', async () => {
  // The asymmetry the successor field exists for: on an integer-millisecond wire the PREDECESSOR needs no
  // field at all, so there is deliberately no `prevMediaTsMs`.
  install({ mediabunny: makeMediabunny({ frames: OFF_GRID }), core: makeCore() });

  assert.equal((await grabJson(133 - 1)).mediaTsMs, 100);
  assert.equal((await grabJson(166 - 1)).mediaTsMs, 133);
});

test('a frame stamped exactly on the half-millisecond is not returned for the millisecond below it', async () => {
  // 29.97 fps puts frames on half-millisecond boundaries on schedule (1501.5 ms here). `llround` rounds a half
  // UP, so Windows keeps a frame iff `ts_ms < T + 0.5`; mediabunny compares with `<=`. Asking for exactly
  // `T + 0.5` made this frame -- which publishes as 1502 -- answer a request for 1501, i.e. a frame starting
  // AFTER the requested time, and the back step then stood still (2 of 92 frames, Firefox 153).
  install({ mediabunny: makeMediabunny({ frames: [1.4683, 1.5015, 1.5349] }), core: makeCore() });

  assert.equal((await grabJson(1502)).mediaTsMs, 1502, 'its own published millisecond still selects it');
  assert.equal((await grabJson(1501)).mediaTsMs, 1468, 'one millisecond earlier is the frame BEFORE it');
  assert.equal((await grabJson(1468)).nextMediaTsMs, 1502);
});

test('a stamp whose scaled milliseconds fall a hair below the half still answers its own published time', async () => {
  // The other side of the same boundary, and why the request is derived with `Math.round` rather than from
  // `T + 0.5`: 0.5005 s scales to 500.49999999999994, so this frame PUBLISHES as 500 while `T + 0.5` for
  // T = 500 is the same double as the stamp itself. A request that stepped strictly below that refused a frame
  // it had just named 500, and `grab(grab(T).mediaTsMs)` walked backwards on exactly this frame.
  install({ mediabunny: makeMediabunny({ frames: [0.4671, 0.5005, 0.5339] }), core: makeCore() });

  const g = await grabJson(500);
  assert.equal(g.mediaTsMs, 500);
  assert.equal((await grabJson(g.mediaTsMs)).mediaTsMs, 500, 'grab(grab(T).mediaTsMs) must be grab(T)');
  assert.equal((await grabJson(499)).mediaTsMs, 467, 'one millisecond earlier is still the frame before it');
});
