// Node coverage for the web worker's VIDEO IMPORT session (web/worker.js + web/video_import.mjs): what the
// session does around the decoder, which is everything the browser is worst at demonstrating.
//
// The four properties under test, and why each needs a deterministic runner rather than a playtest:
//
//   1. THE START TAKES OWNERSHIP BEFORE IT AWAITS ANYTHING (property 3 of the worker's session rule). An import
//      is the handler that rule was written against: it wants to await a demuxer and a decoder, and a `stop`
//      delivered into that window would tear down a session the handler is midway through opening. Here the
//      window is held open by hand -- the module loader is a promise this file resolves -- so the race is not a
//      matter of milliseconds.
//   2. THE PRODUCER IS PACED BY THE CORE'S FLOW GATE. An import runs QueueLimitMode::NoLimit, which never blocks
//      and never drops, so the park is the only bound on memory. A browser shows a gate that does not park as a
//      tab that dies on a long clip, and nothing before that.
//   3. CANCELLATION STOPS IT PROMPTLY AND LEAVES NOTHING BEHIND. The removed implementation had no cancel at all.
//   4. COMPLETION IS DETERMINISTIC: the sample iterator running out, not a quiet window. The removed
//      implementation waited for "one record finished, then four seconds of silence", capped at 300 s.
//
// WHAT IS STUBBED AND WHAT IS NOT. The mediabunny namespace is stubbed here, so this file drives the real decode
// loop over a scripted clip; tool/test_web_video_demux.mjs drives the same loop over the REAL vendored bundle and
// a real Blob. Neither reaches the browser's VideoDecoder or VideoFrame.copyTo -- those are browser-only.

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
const sessionHooks = __captureSessionTestHooks();
const hooks = __videoImportTestHooks();

test.after(() => {
  __previewRelayTestHooks().closeYieldChannel();
  sessionHooks.stopDrainLoop();
  hooks.setModuleLoader(null);
  hooks.setNow(null);
});

/// A stub core with the exports an import session needs: the typed claim, the two frame-flow counters over a
/// real SharedArrayBuffer (so the gate runs its real Atomics.waitAsync path), and the offline push.
///
/// `pushOfflineFrame` BUMPS THE ENQUEUED COUNTER, exactly as NativeApi::updateFrame's accepted send does.
/// That is what makes the pacing tests real rather than a mock of themselves: nothing here dequeues unless a
/// test says so, so a producer with no brake runs away and a braked one parks.
///
/// `drainBarrier` MODELS THE PIPELINE'S TAIL, which is the whole reason this stub is not just a recorder of
/// calls. In the core, the last record of a clip is stitched and recognized AFTER the producer has run out of
/// samples, so the teardown has to wait for `isPipelineDrained()` before joining. Here that is scripted: the
/// barrier answers `false` for `drainPolls` polls, writes `tailRecord` on the poll that finally answers `true`,
/// and `stop()` records whether it was called while the barrier still said busy. A teardown that does not wait
/// therefore loses the record AND leaves a witness saying so.
///
/// `records` IS SCRIPTED, NOT SIMULATED, and the default is 1 on purpose. Nothing here recognizes anything, so
/// there is no honest way to derive a record count from the frames a test pushes; what the count has to model is
/// the ONE thing the worker depends on -- the core's rule that a `completed` run which produced nothing is a
/// refusal (native_api_messages.h videoImportVerdictOf). So the ordinary clip is given "it produced something",
/// which is what every test here that asserts `completed` means by it, and the empty case is asked for by name
/// (`records: 0`). `finishRecord` adds to it, so a record the pipeline only hands over during the drain -- the
/// `tailRecord` seam below -- is counted only if someone waited for it, exactly as the real counter behaves.
///
/// `endOfInput` and `videoImportVerdict` are also the two exports the session now REFUSES to run without, so
/// leaving them off (`terminalExports: false`) is how that gate is exercised.
function makeCore({ counters = true, offlinePush = true, acceptFrames = true, autoDrain = false,
  memfs = null, drainExport = true, drainPolls = 0, tailRecord = null, preview = false,
  terminalExports = true, records = 1, onEndOfInput = null, refuseLayout = false } = {}) {
  let activeKind = null;
  let running = false;
  let pollsSeen = 0;
  let recordsProduced = records;
  // The preview slot, modelled the way LivePreviewPolicy fills it: `updateFrame` may leave a frame behind,
  // and `takePreviewFrame` empties the slot. The ENABLE GATE is the core's -- with the preview off nothing is
  // ever placed in the slot -- which is exactly the OFF guarantee the worker relies on instead of re-deriving.
  let previewEnabled = false;
  let previewPending = null;
  let previewStates = [];
  const calls = [];
  const pushes = [];
  // The config JSON each start was given, verbatim. The isolation rests on WHAT THE CORE WAS TOLD -- everything
  // else (where the sweep looks, where a finished record is read from) is only a consequence of it, so a test
  // that watched the harvest alone could not tell an isolated import from one that swept a filtered shared root.
  const startConfigs = [];
  const heap = new Int32Array(new SharedArrayBuffer(8));
  const start = (kind) => {
    if (activeKind !== null) {
      if (activeKind === kind) return { verdict: 'alreadyStarted', message: '' };
      calls.push('startCaptureSession:refused');
      return {
        verdict: 'refused',
        message: 'startCapture refused: ' + kind + ' cannot start while ' + activeKind
          + ' is running (they are mutually exclusive)',
      };
    }
    calls.push('startCaptureSession');
    activeKind = kind;
    running = true;
    return { verdict: 'started', message: '' };
  };
  const core = {
    calls,
    pushes,
    startConfigs,
    // The messages the drain loop relays, and the seam a finished record is announced through.
    queued: [],
    HEAP32: heap,
    isActive: () => activeKind !== null,
    activeKind: () => activeKind,
    isRunning: () => running,
    startCaptureSession: (configJson) => { startConfigs.push(configJson); return start('live'); },
    startCaptureSessionOfKind: (kind, configJson) => { startConfigs.push(configJson); return start(kind); },
    // The `directory` block of the LAST start, parsed. This is the statement of where the pipeline may write.
    startDirectory: () => JSON.parse(startConfigs[startConfigs.length - 1]).directory,
    // Writes one finished record where the pipeline running under the last start's config would write it
    // (native_api.cpp derives stitcher_dir = storage_dir/chara_detail/active), and announces it exactly as the
    // recognizer does. Nothing here knows about the worker's roots: it reads the storage_dir it was GIVEN, so a
    // worker that scoped nothing would have this write into the shared root.
    finishRecord(recordId, names = ['record.json']) {
      const dir = core.startDirectory().storage_dir + '/chara_detail/active/' + recordId;
      memfs.mkdirp(dir);
      for (const name of names) memfs.fs.writeFile(dir + '/' + name, new Uint8Array([recordId.charCodeAt(0)]));
      // Both halves of what the real core does at this moment: the announcement, and the increment of the run's
      // record count. They are one site there too (NativeApi::notifyCharaDetailFinished), which is what stops
      // "a record was produced" and "the front end was told so" from coming apart.
      recordsProduced++;
      core.queued.push(JSON.stringify({ type: 'onCharaDetailFinished', id: recordId, success: true }));
    },
    /// The count as it stands, for tests that assert what the verdict was read from rather than only its answer.
    recordsProduced: () => recordsProduced,
    // A RECORD REGENERATION's two entry points, and the only reason this stub has them: a regeneration is the one
    // passenger that starts a pipeline of its own (startLoop -> Module.init) without taking the session claim, so
    // the tests that put an import and a regeneration in each other's way need it to be distinguishable from a
    // session start. `updates` is the witness for "a regeneration actually ran", which is what tells a refusal
    // apart from a gate that let it through.
    updates: [],
    init: (configJson) => { calls.push('init'); startConfigs.push(configJson); running = true; },
    updateRecord: (recordId) => { calls.push('updateRecord'); core.updates.push(recordId); },
    endCaptureSessionOfKind: (kind) => {
      calls.push('endCaptureSession');
      if (activeKind === kind) activeKind = null;
    },
    endCaptureSession() { calls.push('endCaptureSession'); activeKind = null; },
    stop() {
      calls.push('stop');
      // THE WITNESS. A join that lands while the pipeline still holds work is exactly the defect: the real
      // stop() raises the inference abort, so the record on the recognizer is dropped and never written.
      if (pollsSeen < drainPolls) core.stoppedWhileBusy = true;
      running = false;
    },
    // Polls the teardown actually made, and whether any join beat the barrier.
    drainPollsSeen: () => pollsSeen,
    stoppedWhileBusy: false,
    drainMessages: () => { const out = core.queued; core.queued = []; return out; },
    // Without a `memfs` the harvest sweeps an empty filesystem: what matters for most tests here is WHEN it
    // runs, not what it finds. The isolation tests pass a real in-memory FS instead, because for those what it
    // finds -- and what it leaves alone -- is the whole property.
    FS: memfs === null
      ? { readdir: () => [], stat: () => ({ mode: 0 }), isDir: () => false, unlink() {}, rmdir() {} }
      : memfs.fs,
    // Hop 1 out (FrameDistributor::update), the only thing that can lower the resident count here.
    noteDistributed: () => { Atomics.add(heap, 1, 1); Atomics.notify(heap, 1); },
    residentFrames: () => Atomics.load(heap, 0) - Atomics.load(heap, 1),
  };
  if (drainExport) {
    core.isPipelineDrained = () => {
      if (!running) return true;
      if (pollsSeen >= drainPolls) return true;
      pollsSeen++;
      if (pollsSeen >= drainPolls && tailRecord !== null) {
        // The record the pipeline was still carrying. It exists ONLY because someone waited.
        core.finishRecord(tailRecord);
      }
      return pollsSeen >= drainPolls;
    };
  }
  if (terminalExports) {
    // THE END-OF-CLIP SIGNAL. The real one posts an idle event that closes a chara-detail scene still open, which
    // is how a truncated clip becomes an announced failure instead of a silent one; here the effect is scripted by
    // `onEndOfInput` so a test can put the resulting notification into the core's queue and watch WHERE it comes
    // out relative to the terminal message.
    core.endOfInput = () => {
      calls.push('endOfInput');
      if (onEndOfInput !== null) onEndOfInput(core);
    };
    // THE CORE'S CLASSIFICATION, modelled rather than mocked: this is videoImportVerdictOf, and it has to be, or
    // the tests would only be asserting that the worker relays whatever it is handed. A producer's own naming of
    // the ending wins -- only `completed` is rewritten -- and the count travels out with it.
    core.videoImportVerdict = (reason, reasonKind) => {
      calls.push('videoImportVerdict');
      if (reason === 'completed' && recordsProduced <= 0) {
        return { reason: 'refused', reasonKind: 'no_records', records: 0 };
      }
      return { reason, reasonKind, records: recordsProduced };
    };
  }
  if (counters) {
    core.frameFlowEnqueuedAddress = () => 0;
    core.frameFlowDequeuedAddress = () => 4;
  }
  if (preview) {
    core.previewStates = previewStates;
    core.setPreviewEnabled = (enabled, cropped) => {
      previewStates.push({ enabled, cropped });
      previewEnabled = enabled;
      if (!enabled) previewPending = null;
    };
    core.takePreviewFrame = () => {
      const frame = previewPending;
      previewPending = null;
      return frame === null ? null : frame;
    };
  }
  if (offlinePush) {
    // THE VERDICT IS A NUMBER, as the real export's is: -1 "this copy is laid out in a way I cannot read",
    // 0 "not accepted", 1 "in the pipeline". The stub does NOT judge `layout` itself -- deciding whether a
    // layout is the tightly packed one is precisely the rule that now lives in the core alone
    // (color::isTightlyPackedLayout, exercised by name in native/test/cv/test_decoded_frame_to_bgr.cpp), and a
    // second implementation of it here would put the thing under test back into the test. `refuseLayout` says
    // "the core said no" and the assertions are about what the worker and the producer do with that answer.
    core.pushOfflineFrame = (pixels, format, width, height, rotation, mediaTsMs, layout) => {
      // The bytes are copied into the wasm heap synchronously by embind, so the producer is free to reuse its
      // scratch buffer afterwards; this stub therefore has to copy too, or every recorded push would alias the
      // same buffer and the timestamps would be the only thing it proved. `planes` is that copy, and it is what
      // makes the COPY ORIGIN assertable rather than only the geometry (see makeSample). `layout` is recorded
      // for the same reason: what the producer owes the core is the UA's own answer, unaltered.
      pushes.push({ format, width, height, rotation, mediaTsMs, first: pixels[0], length: pixels.length,
        planes: Array.from(pixels), layout });
      if (refuseLayout) return -1;
      // Emitted from INSIDE the push, as NativeApi::updateFrame emits from inside its own send: the slot can
      // only hold this frame's preview once the frame has been handed over, which is what makes WHERE the
      // worker drains it a real question rather than a formality.
      if (previewEnabled) previewPending = { width, height, bgra: new Uint8Array(4 * 2 * 4) };
      if (!acceptFrames) return 0;
      Atomics.add(heap, 0, 1);
      // `autoDrain` models a pipeline that keeps up: the frame is consumed as fast as it arrives, so the gate
      // never parks. Tests that are not about pacing use it so a clip longer than the limit still finishes.
      if (autoDrain) core.noteDistributed();
      return 1;
    };
  }
  return core;
}

/// An in-memory filesystem with Emscripten's FS surface, for the isolation tests below.
///
/// A REAL ONE, not a recorder of calls. The property under test is that an import CANNOT REACH a directory --
/// which is a statement about what `readdir` returns and what survives a teardown, and a stub that answered
/// every readdir with `[]` would pass whether or not the isolation existed. So directories are directories here:
/// `readdir` lists only immediate children, `rmdir` refuses a non-empty one, and a path that was never created
/// throws exactly as MEMFS does.
const DIR_MODE = 0o040755;
const FILE_MODE = 0o100644;
function makeMemfs() {
  const nodes = new Map([['/', { dir: true }], ['/work', { dir: true }]]);
  const parentOf = (path) => path.slice(0, path.lastIndexOf('/')) || '/';
  const nodeAt = (path) => {
    const node = nodes.get(path);
    if (node === undefined) throw new Error('ENOENT: ' + path);
    return node;
  };
  const fs = {
    mkdir(path) {
      if (nodes.has(path)) throw new Error('EEXIST: ' + path);
      nodeAt(parentOf(path));
      nodes.set(path, { dir: true });
    },
    readdir(path) {
      if (!nodeAt(path).dir) throw new Error('ENOTDIR: ' + path);
      const prefix = path.endsWith('/') ? path : path + '/';
      const names = [];
      for (const candidate of nodes.keys()) {
        if (candidate === path || !candidate.startsWith(prefix)) continue;
        const rest = candidate.slice(prefix.length);
        if (rest.includes('/')) continue;
        names.push(rest);
      }
      return ['.', '..', ...names];
    },
    stat: (path) => ({ mode: nodeAt(path).dir ? DIR_MODE : FILE_MODE }),
    isDir: (mode) => mode === DIR_MODE,
    unlink(path) {
      if (nodeAt(path).dir) throw new Error('EISDIR: ' + path);
      nodes.delete(path);
    },
    rmdir(path) {
      if (!nodeAt(path).dir) throw new Error('ENOTDIR: ' + path);
      if (fs.readdir(path).length > 2) throw new Error('ENOTEMPTY: ' + path);
      nodes.delete(path);
    },
    writeFile(path, data) {
      nodeAt(parentOf(path));
      nodes.set(path, { dir: false, data });
    },
    // A fresh buffer per read, exactly as FS.readFile gives one: collectFiles TRANSFERS what it gets back, so a
    // view onto the stored bytes would be detached and the next read of the same file would come back empty.
    readFile: (path) => new Uint8Array(nodeAt(path).data),
  };
  const mkdirp = (path) => {
    let built = '';
    for (const part of path.split('/').filter(Boolean)) {
      built += '/' + part;
      if (!nodes.has(built)) nodes.set(built, { dir: true });
    }
  };
  return {
    fs,
    mkdirp,
    seedFile(path, byte = 1) { mkdirp(parentOf(path)); fs.writeFile(path, new Uint8Array([byte])); },
    has: (path) => nodes.has(path),
    paths: () => [...nodes.keys()].sort(),
  };
}

/// A stub of the mediabunny namespace, scripting one clip. Only the four names the decode driver actually uses
/// are provided, so a driver that reached for a fifth would fail here rather than silently work in Node and
/// break in a browser.
///
/// `events` records the lifecycle in order: this is how "the reader was disposed" and "every sample was closed"
/// are asserted, which is the half of cancellation that leaks rather than hangs.
function makeMediabunny(spec) {
  const events = [];
  const opened = [];
  // The decoder options every sink was constructed with, in order. This is the whole record of WHICH DECODER
  // the producer asked for, and of how many times it asked.
  const sinkOptions = [];
  class BlobSource {
    constructor(blob) { events.push('blobSource'); this.blob = blob; }
  }
  class Input {
    constructor(options) { events.push('input'); this.options = options; }
    async getPrimaryVideoTrack() {
      // A FILE THAT IS NOT A MEDIA CONTAINER AT ALL. mediabunny sniffs the format on this call and answers an
      // unrecognised one by throwing, so it never reaches the `track === null` check the driver used to treat as
      // the only non-video case.
      if (spec.unsupportedFormat) {
        const error = new Error('Input has an unsupported or unrecognizable format.');
        error.name = 'UnsupportedInputFormatError';
        throw error;
      }
      return spec.track === undefined ? makeTrack(spec) : spec.track;
    }
    // `disposeGate` HOLDS THE DRIVER OPEN AFTER ITS OUTCOME IS ALREADY `completed`. The real `input.dispose()` is
    // an await on the last line of the decode driver, so a `stop` delivered into it finds a producer whose
    // outcome is a completion and takes its ending over anyway. That is the one shape in which a HEALTHY import
    // can reach the teardown-owned ending, and therefore the only way to test that it is not reported as empty.
    async dispose() { events.push('dispose'); if (spec.disposeGate) await spec.disposeGate(); }
  }
  class VideoSampleSink {
    // THE OPTIONS ARE VALIDATED HERE THE WAY THE REAL CONSTRUCTOR VALIDATES THEM (mediabunny 1.52.3,
    // `validateVideoSinkDecoderOptions`), so a producer that passed a misspelled accelerator hint fails in this
    // harness instead of being silently ignored here and rejected only in a browser.
    constructor(track, decoderOptions = {}) {
      if (!decoderOptions || typeof decoderOptions !== 'object') {
        throw new TypeError('decoderOptions must be an object.');
      }
      const accelerations = ['no-preference', 'prefer-hardware', 'prefer-software'];
      if (decoderOptions.hardwareAcceleration !== undefined
        && !accelerations.includes(decoderOptions.hardwareAcceleration)) {
        throw new TypeError('decoderOptions.hardwareAcceleration, when provided, must be one of '
          + accelerations.join(', ') + '.');
      }
      this.track = track;
      this.decoderOptions = decoderOptions;
      sinkOptions.push(decoderOptions.hardwareAcceleration ?? null);
      events.push('sink:' + (decoderOptions.hardwareAcceleration ?? 'default'));
    }
    async * samples() {
      // A CONFIGURE FAILURE, WHERE THE REAL ONE LANDS. `VideoDecoder.configure` reports an unsupported-but-valid
      // config through the decoder's error callback, and mediabunny turns that into the sample iterator's
      // out-of-band error -- so what the producer sees is a throw out of `for await`, before any sample, and
      // NOT a rejection from `new VideoSampleSink`. Scripting it anywhere else would test a shape the browser
      // never produces.
      const failFor = spec.configureFailsFor ?? [];
      if (failFor.includes(this.decoderOptions.hardwareAcceleration ?? null)) {
        events.push('configureFailed:' + (this.decoderOptions.hardwareAcceleration ?? 'default'));
        throw new Error('Decoding error: unsupported configuration');
      }
      let yielded = 0;
      for (const item of spec.samples) {
        if (spec.beforeSample) await spec.beforeSample(item);
        events.push('yield:' + item.timestamp);
        yield makeSample(item, events, opened);
        yielded++;
        // A decoder that ran and then broke, which is the case a retry must NOT take: the frames already
        // yielded have been pushed, so decoding the clip a second time would push them again.
        if (spec.failAfterSamples !== undefined && yielded >= spec.failAfterSamples) {
          events.push('decodeFailed');
          throw new Error('Decoding error: the bitstream went bad');
        }
      }
      events.push('exhausted');
    }
  }
  return { module: { Input, ALL_FORMATS: ['stub'], BlobSource, VideoSampleSink }, events, opened, sinkOptions };
}

/// A track shaped the way mediabunny's InputVideoTrack really is: the metadata is reached through the ASYNC
/// getters, and the same-named plain properties are the DEPRECATED ones that route through `requireSync`.
///
/// THE DEPRECATED GETTERS THROW HERE, with mediabunny's own wording, because that is what they do for any track
/// whose backing resolves the field asynchronously (a delegating or hydrating backing) -- and a stub that
/// answered them would let the production code use a property that blows up on a perfectly ordinary clip, turning
/// an import into a `fail()` and a Sentry issue. A stub cannot be neutral about this: either it reproduces the
/// throw or it hides it.
function makeTrack(spec) {
  const deprecated = (name, asyncName) => {
    throw new Error(`'${name}' is deprecated and not available synchronously for this track. `
      + `Use the preferred '${asyncName}()' instead.`);
  };
  return {
    // `null` is a REAL answer, not a stub shortcut: mediabunny returns it for a codec it does not model (FFV1
    // in Matroska demuxes perfectly and reports null), which is what made the refusal message name nothing.
    getCodec: async () => (spec.codec === undefined ? 'avc' : spec.codec),
    getInternalCodecId: () => spec.internalCodecId ?? null,
    getRotation: async () => spec.rotation ?? 0,
    getCodedWidth: async () => spec.width ?? 4,
    getCodedHeight: async () => spec.height ?? 2,
    canDecode: async () => spec.canDecode !== false,
    // THE TWO DURATION CALLS ARE DIFFERENT COSTS, and the stub keeps them apart because the production code
    // depends on the difference. `getDurationFromMetadata` reads the container's own duration element and
    // returns null when there is none; `computeDuration` resolves the LAST packet, i.e. a full ranged-read pass
    // over the file for a container that declares nothing -- which Matroska from OBS routinely is. A stub that
    // answered both identically would let the scan go back onto the critical path unnoticed.
    getDurationFromMetadata: async () => {
      if (spec.durationCalls) spec.durationCalls.push('metadata');
      return spec.declaresDuration === false ? null : (spec.durationSeconds ?? 1);
    },
    computeDuration: async () => {
      if (spec.durationCalls) spec.durationCalls.push('scan');
      if (spec.beforeDurationScan) await spec.beforeDurationScan();
      return spec.scannedDurationSeconds ?? spec.durationSeconds ?? 1;
    },
    get codec() { return deprecated('codec', 'getCodec'); },
    get rotation() { return deprecated('rotation', 'getRotation'); },
    get codedWidth() { return deprecated('codedWidth', 'getCodedWidth'); },
    get codedHeight() { return deprecated('codedHeight', 'getCodedHeight'); },
    get displayWidth() { return deprecated('displayWidth', 'getDisplayWidth'); },
    get displayHeight() { return deprecated('displayHeight', 'getDisplayHeight'); },
  };
}

/// The samples a synthetic CODED I420 frame holds. Every value encodes the frame AND the coded position it sits
/// at, so a copy that started at the wrong origin changes the bytes rather than only the geometry -- and the
/// three planes use different mixes so a plane written in the wrong order is not self-consistent.
function codedLuma(item, x, y) {
  return ((item.fill ?? 1) * 37 + x * 3 + y * 29) & 0xff;
}

function codedCb(item, x, y) {
  return ((item.fill ?? 1) * 11 + x * 5 + y * 17) & 0xff;
}

function codedCr(item, x, y) {
  return ((item.fill ?? 1) * 23 + x * 7 + y * 13) & 0xff;
}

/// One decoded sample, shaped the way mediabunny really shapes one. `timestamp` is in SECONDS, exactly as
/// mediabunny reports it, so the ms conversion in the driver is under test rather than assumed.
///
/// THREE THINGS HERE ARE THE LIBRARY'S ACTUAL SHAPE AND NOT AN INVENTION, because getting them wrong is precisely
/// how the padded/visible distinction became untestable:
///
///   * `visibleRect` is {left, top, width, height} -- every branch of mediabunny's VideoSample constructor writes
///     those four names. It is NOT {x, y, ...}, which is the shape `copyTo`'s `options.rect` is validated as; the
///     two are deliberately different and handing one to the other copies from origin (0, 0) in silence.
///   * `codedWidth` / `codedHeight` on a SAMPLE are getters that return `visibleRect.width/height`, not the
///     padded coded size. The padded size is reachable only through the pixel data.
///   * `allocationSize()` and `copyTo()` DEFAULT their rectangle to the visible one.
///
/// `copyTo` models the VideoFrame backing, which is what production runs on: mediabunny forwards the options
/// untouched to `VideoFrame.copyTo` for such a sample, so `rect` is in CODED coordinates and its absence means
/// the visible rect.
/// The byte count of a tightly packed frame, i.e. what the core's decodedFrameByteCount answers.
function frameSize(format, width, height) {
  if (format === 'RGBA' || format === 'RGBX' || format === 'BGRA' || format === 'BGRX') return width * height * 4;
  return width * height + 2 * (((width + 1) >> 1) * ((height + 1) >> 1));
}

/// mediabunny's OWN default colour space for a sample it was not given one for, copied from the bundle's
/// VideoSample constructor (1.52.3): an RGB format is filled in as `matrix: 'rgb'` full range, and every other
/// format as BT.709 limited. That default is not a convenience here -- it is what makes the RGB branch of
/// coreFormatOf assertable, because "the frame reports rgb" and "the frame reports a YUV matrix" have to be two
/// different sample shapes rather than one shape and an assumption. A test that wants the Android shape (RGBA
/// pixels carrying a BT.709 matrix) states it with `colorSpace` explicitly.
function defaultColorSpace(format) {
  if (format === 'RGBA' || format === 'RGBX' || format === 'BGRA' || format === 'BGRX') {
    return { primaries: 'bt709', transfer: 'iec61966-2-1', matrix: 'rgb', fullRange: true };
  }
  return { primaries: 'bt709', transfer: 'bt709', matrix: 'bt709', fullRange: false };
}

function makeSample(item, events, opened) {
  // `in` rather than `??`, because `null` is a real WebCodecs answer (an opaque frame) and must be
  // representable here rather than collapsing onto the default.
  const sampleFormat = 'format' in item ? item.format : 'I420';
  const codedWidth = item.codedWidth ?? item.width ?? 4;
  const codedHeight = item.codedHeight ?? item.height ?? 2;
  const visible = item.visibleRect ?? { left: 0, top: 0, width: codedWidth, height: codedHeight };
  const region = (options) => {
    const rect = options === undefined ? undefined : options.rect;
    if (rect === undefined) return { left: visible.left, top: visible.top, ...visible };
    return {
      left: rect.x ?? 0,
      top: rect.y ?? 0,
      width: rect.width ?? codedWidth,
      height: rect.height ?? codedHeight,
    };
  };
  const sample = {
    timestamp: item.timestamp,
    rotation: item.rotation ?? 0,
    codedWidth: visible.width,
    codedHeight: visible.height,
    visibleRect: visible,
    format: sampleFormat,
    // `in` again: a test may state `colorSpace: null` to model a UA that reported none at all.
    colorSpace: 'colorSpace' in item ? item.colorSpace : defaultColorSpace(sampleFormat),
    allocationSize: (options) => { const r = region(options); return frameSize(sampleFormat, r.width, r.height); },
    // THE SAME RULE THE REAL copyTo ENFORCES: a format may be named only when it is the frame's own, or when
    // it is one of the RGB four. Naming any other one is a NotSupportedError -- which is exactly why the
    // producer cannot simply ask every decoder for I420, and why a stub that served any format on request
    // would make that constraint untestable.
    //
    // The returned PlaneLayout array is the DEFAULT one -- tightly packed planes -- which is what the producer
    // verifies before every push.
    async copyTo(target, options) {
      const wanted = options === undefined || options.format === undefined ? sampleFormat : options.format;
      if (wanted !== sampleFormat && !['RGBA', 'RGBX', 'BGRA', 'BGRX'].includes(wanted)) {
        throw new Error('NotSupportedError: Invalid destination format.');
      }
      const r = region(options);
      const chromaWidth = (r.width + 1) >> 1;
      const chromaHeight = (r.height + 1) >> 1;
      let i = 0;
      if (wanted === 'RGBA') {
        for (let y = 0; y < r.height; y++) {
          for (let x = 0; x < r.width; x++) {
            target[i++] = codedLuma(item, r.left + x, r.top + y);
            target[i++] = codedCb(item, r.left + x, r.top + y);
            target[i++] = codedCr(item, r.left + x, r.top + y);
            target[i++] = 255;
          }
        }
        return [{ offset: 0, stride: r.width * 4 + (item.padLayout ? 4 : 0) }];
      }
      for (let y = 0; y < r.height; y++) {
        for (let x = 0; x < r.width; x++) target[i++] = codedLuma(item, r.left + x, r.top + y);
      }
      if (wanted === 'NV12') {
        for (let y = 0; y < chromaHeight; y++) {
          for (let x = 0; x < chromaWidth; x++) {
            target[i++] = codedCb(item, (r.left >> 1) + x, (r.top >> 1) + y);
            target[i++] = codedCr(item, (r.left >> 1) + x, (r.top >> 1) + y);
          }
        }
        // `padLayout` models a decoder that aligned a stride, which is the failure the producer must catch.
        return [
          { offset: 0, stride: r.width + (item.padLayout ? 4 : 0) },
          { offset: r.width * r.height, stride: chromaWidth * 2 },
        ];
      }
      for (const plane of [codedCb, codedCr]) {
        for (let y = 0; y < chromaHeight; y++) {
          for (let x = 0; x < chromaWidth; x++) target[i++] = plane(item, (r.left >> 1) + x, (r.top >> 1) + y);
        }
      }
      return [
        { offset: 0, stride: r.width + (item.padLayout ? 4 : 0) },
        { offset: r.width * r.height, stride: chromaWidth },
        { offset: r.width * r.height + chromaWidth * chromaHeight, stride: chromaWidth },
      ];
    },
    close() { events.push('close:' + item.timestamp); opened.splice(opened.indexOf(item), 1); },
  };
  opened.push(item);
  return sample;
}

function deliver(message) {
  return self.onmessage({ data: message });
}

/// Drains macrotask turns until the worker has gone QUIET, so "still parked" means parked rather than merely
/// not resumed yet.
///
/// THE WINDOW IS DERIVED FROM THE RUN, NOT PICKED. Several `settle()` calls below back an assertion of
/// ABSENCE -- "the producer pushed no further frame", "no second session was opened" -- and an absence
/// observed over a window nobody derived says nothing: a producer that had simply not been scheduled yet
/// reads exactly like one correctly parked at the flow gate. Nor can the window be a count of turns written
/// down here, because the paths it waits out hop through real macrotasks -- worker.js's MessageChannel
/// `macrotaskYield` (web/worker.js), its `setInterval` drain, and the `Atomics.waitAsync` the offline
/// flow gate parks on -- so how many turns they take is a property of web/worker.js that moves the day
/// someone adds a hop. A literal here would stop reaching the end of the path with nothing to say so, which
/// is the one change this helper exists to keep covering.
///
/// The positive control is the worker's own voice. `posted` is everything it emits, and every step of an
/// import goes through it (`videoImportStarted`, `videoImportProgress`, `harvest`, `liveRecord`, `stopped`,
/// `videoImportDone`, plus the `log` line each path writes on the way). So a producer that did NOT park --
/// the failure these assertions exist to be able to see -- announces itself as it runs on, and announcing is
/// what keeps this loop turning. The loop stops only once the worker has been silent for at least as many
/// turns as it was busy, so the quiet has to hold for as long as the activity took to establish it.
///
/// [settleFloorTurns] is a FLOOR, not the bound. Five turns is the only drain this suite is known green on,
/// so quiescence is required in addition to it rather than instead of it; shrinking the floor would be a
/// separate measurement, and nobody has made it.
///
/// [settleTurnCap] is a FAILURE path in the sense `wall-clock-discipline.md` means: a worker still emitting
/// after that many turns is a live-lock to report, not something to wait out.
const settleFloorTurns = 5;
const settleTurnCap = 2000;

async function settle() {
  let turns = 0;
  let quiet = 0;
  let emitted = posted.length;
  // `turns - quiet` is the turn the worker was last heard on, so `quiet < turns - quiet` reads "it has been
  // silent for less time than it spent talking".
  while (turns < settleFloorTurns || quiet === 0 || quiet < turns - quiet) {
    if (turns >= settleTurnCap) {
      throw new Error('settle(): the worker was still posting after ' + turns + ' macrotask turns');
    }
    await new Promise((resolve) => setTimeout(resolve, 0));
    turns++;
    if (posted.length === emitted) {
      quiet++;
    } else {
      emitted = posted.length;
      quiet = 0;
    }
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/// Fails LOUDLY instead of hanging. Several tests below assert that something completes without the pipeline
/// ever draining a frame, and the defect they are written against is an unbounded wait -- so a plain `await`
/// would hang the whole run (and, because the worker's teardowns are serialized on one queue, wedge every test
/// after it) rather than reddening the one test that is wrong. node:test's own `timeout` cannot substitute: it
/// abandons the test but leaves the worker in the state that hung.
async function within(ms, promise, what) {
  let timer = null;
  const guard = new Promise((resolve, reject) => {
    timer = setTimeout(() => reject(new Error('timed out after ' + ms + ' ms: ' + what)), ms);
  });
  try {
    return await Promise.race([promise, guard]);
  } finally {
    clearTimeout(timer);
  }
}

/// Waits for an EVENT, not for a duration. The predicate is re-read every macrotask turn, so the wait ends on
/// the turn the thing being waited for actually happens instead of at the end of a nap sized by guesswork; a
/// fixed sleep pays its whole length every run and still fails on a loaded machine that needed one more tick.
/// `boundMs` is the FAILURE path only -- a mechanism that stopped firing reddens here, by name.
async function until(predicate, boundMs, what) {
  const deadline = performance.now() + boundMs;
  while (!predicate()) {
    assert.equal(performance.now() < deadline, true, 'timed out after ' + boundMs + ' ms: ' + what);
    await sleep(0);
  }
}

/// A stand-in for the File the main thread posts. Duck-typed on purpose: the handler accepts anything with the
/// range-read surface, which is what mediabunny's BlobSource needs.
const clip = (size = 1024) => ({ size, slice: () => ({}) });

function postedTypes() {
  return posted
    .map((m) => (typeof m === 'string' ? JSON.parse(m).type : m.type))
    .filter((t) => t !== 'log');
}

function postedOfType(type) {
  return posted
    .map((m) => (typeof m === 'string' ? JSON.parse(m) : m))
    .filter((m) => m.type === type);
}

/// The config Dart sends: the MEMFS working roots the worker mounted at setup, exactly as
/// `WasmWorkerClient` rewrites `directory.*` before `init`. It is the thing a scoped session overrides and a
/// live session must receive untouched, so it is written out here rather than left implicit.
const INIT_CONFIG = Object.freeze({
  video_mode: false,
  directory: Object.freeze({ storage_dir: '/work/storage', temp_dir: '/work/temp', modules_dir: '/work/modules' }),
});

/// Installs a core and a scripted clip, and delivers the config the session start needs.
async function arrange(core, spec) {
  posted.length = 0;
  hooks.installCore(core);
  const mediabunny = makeMediabunny(spec);
  hooks.setModuleLoader(async () => mediabunny.module);
  await deliver({ type: 'setInitConfig', config: INIT_CONFIG });
  return mediabunny;
}

const ticks = (n) => Array.from({ length: n }, (_, i) => ({ timestamp: i / 10, fill: i + 1 }));

// --- completion, timestamps and the frame contract -----------------------------------------------------------

test('a clip runs to the end of its samples and ends the session itself', async () => {
  const core = makeCore();
  const mb = await arrange(core, { samples: ticks(3), durationSeconds: 0.3 });

  await deliver({ type: 'startVideoImport', file: clip() });

  // COMPLETION IS THE ITERATOR RUNNING OUT. `exhausted` is recorded by the stub only after the last sample was
  // yielded, and the driver returns immediately afterwards -- no quiet window, no cap, and nothing that would
  // make a clip yielding zero records wait any longer than one yielding many.
  assert.equal(mb.events.includes('exhausted'), true);
  const done = postedOfType('videoImportDone');
  assert.equal(done.length, 1, 'exactly one terminal message per import');
  assert.equal(done[0].reason, 'completed');
  assert.equal(done[0].decoded, 3);
  assert.equal(done[0].supplied, 3);
  assert.equal(done[0].rejected, 0);

  // And the session ended through the ordinary teardown: the loop was joined, the records harvested, and the
  // claim handed back -- in that order, exactly as a live stop does it.
  assert.deepEqual(core.calls,
    ['startCaptureSession', 'endOfInput', 'stop', 'endCaptureSession', 'videoImportVerdict']);
  assert.equal(core.isActive(), false);
  assert.equal(hooks.session(), null);
  assert.deepEqual(postedTypes(),
    ['videoImportStarted', 'videoImportProgress', 'videoImportProgress', 'harvest', 'stopped', 'videoImportDone']);
});

test('frames carry MEDIA time and the full visible rect, not arrival time', async () => {
  // THE INVARIANT THE WHOLE FEATURE RESTS ON (docs/video-import.md). Every gate in the pipeline advances on the
  // frame timestamp -- the 200 ms scene-begin dwell, the 1000 ms scene-end debounce, StationaryFrameCatcher's
  // 200 ms -- so a producer stamping arrival time compresses all of them toward zero and no scene ever ends.
  // These samples are 100 ms apart in MEDIA time and are decoded as fast as Node runs, so an arrival-time stamp
  // would show up as three timestamps within a millisecond of each other.
  const core = makeCore();
  await arrange(core, { samples: [{ timestamp: 0 }, { timestamp: 0.1 }, { timestamp: 2.5 }] });

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.deepEqual(core.pushes.map((p) => p.mediaTsMs), [0, 100, 2500]);
  // Full frame, at the clip's own size: an offline producer shapes nothing, so what the core receives is the
  // decoded frame and the byte length that goes with it.
  assert.deepEqual(core.pushes.map((p) => p.width + 'x' + p.height), ['4x2', '4x2', '4x2']);
  // I420, so 4*2 luma plus two 2x1 chroma planes -- a third of what the same frame cost as RGBA, and the
  // browser's colour conversion is not in it.
  assert.deepEqual(core.pushes.map((p) => p.length), [12, 12, 12]);
});

test('the visible rect is what is copied, at its own origin, not the padded coded rect', async () => {
  // A coded frame is padded out to the codec's macroblock alignment, and those rows are not picture content --
  // no other producer ever sees them (OpenCV hands the CLI the visible frame). Copying the coded rect would feed
  // recognition a frame with a black skirt and a geometry no live session can produce.
  //
  // THE ORIGIN IS THE HALF THAT USED TO BE UNTESTABLE. A visible rect is an offset AND a size, and copying the
  // right SIZE from the wrong ORIGIN is the failure mode a size-only assertion cannot see -- it is what handing
  // mediabunny's {left, top, width, height} to a `rect` option validated as {x, y, width, height} does, silently,
  // on every clip whose visible offset is not zero. The synthetic pixels carry their coded coordinates, so the
  // first copied pixel names the origin the copy actually started from.
  // The offset is EVEN on both axes, which is not a weakening of the test but the only offset an I420 copy can
  // have: a chroma sample spans a 2x2 luma block, so a rectangle cannot start half way through one.
  const core = makeCore();
  const item = { timestamp: 0, codedWidth: 16, codedHeight: 16, visibleRect: { left: 4, top: 2, width: 9, height: 5 } };
  await arrange(core, { samples: [item] });

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.equal(core.pushes.length, 1);
  const pushed = core.pushes[0];
  assert.equal(pushed.width, 9);
  assert.equal(pushed.height, 5);
  assert.equal(pushed.length, frameSize('I420', 9, 5));
  assert.equal(pushed.planes[0], codedLuma(item, 4, 2), 'the copy must start at the VISIBLE origin (4, 2)');
  // ...and end at its far corner, so the whole rectangle is the visible one and not a same-sized window
  // somewhere else in the padded plane.
  assert.equal(pushed.planes[9 * 5 - 1], codedLuma(item, 4 + 8, 2 + 4));
  // The chroma planes follow the same rectangle, at its own chroma origin -- a luma plane copied from the right
  // place with chroma taken from (0, 0) is a frame with the right shapes in the wrong colours.
  assert.equal(pushed.planes[9 * 5], codedCb(item, 2, 1));
  assert.equal(pushed.planes[9 * 5 + 5 * 3], codedCr(item, 2, 1));
});

test('a frame the pipeline refuses is counted rather than mistaken for a processed one', async () => {
  // updateFrame drops a frame silently when no pipeline is running. An importer that believed the push always
  // succeeded would report a complete import of a session that had ended, so the two are counted apart.
  const core = makeCore({ acceptFrames: false });
  await arrange(core, { samples: ticks(2) });

  await deliver({ type: 'startVideoImport', file: clip() });

  const done = postedOfType('videoImportDone')[0];
  assert.equal(done.decoded, 2);
  assert.equal(done.supplied, 0);
  assert.equal(done.rejected, 2);
  assert.equal(done.reason, 'completed');
});

// --- the capture preview -------------------------------------------------------------------------------------
//
// An import shows the SAME preview a live capture shows, and for the same reason: an import that fails has to be
// able to show where it failed. The core already emits for any producer (NativeApi::updateFrame is where the
// preview is decided, whatever pushed the frame), so what these hold down is the one thing this side owns --
// that the import path DRAINS the slot. It did not, for the whole first life of the feature: the pull existed
// only in processLiveFrame, so an import produced preview frames in the core that nothing ever collected.

test('an import drains the core preview slot, so its frames reach the page', async () => {
  const core = makeCore({ autoDrain: true, preview: true });
  await arrange(core, { samples: ticks(3), durationSeconds: 0.3 });
  // The standing preference, relayed verbatim. `cropped: false` is what an import's frames actually are --
  // the offline push carries no pane snapshot -- and Dart is what decides that (platform_controller.dart).
  await deliver({ type: 'preview', enabled: true, cropped: false });

  await deliver({ type: 'startVideoImport', file: clip() });

  const frames = postedOfType('previewFrame');
  assert.equal(frames.length, 3, 'the slot is drained after every push, not once per progress report');
  assert.deepEqual(frames.map((f) => f.width + 'x' + f.height), ['4x2', '4x2', '4x2']);
  // Relayed, not re-derived: the worker forwards the pair it was given and takes no preview decision of its own.
  assert.deepEqual(core.previewStates, [{ enabled: true, cropped: false }]);
  assert.equal(postedOfType('videoImportDone')[0].reason, 'completed');
});

test('an import with the preview turned off produces none, and pays nothing for it', async () => {
  // The OFF guarantee is the CORE's: with the preview disabled LivePreviewPolicy's enable gate fails before a
  // pixel is touched, so the slot stays empty and the drain is one null check per frame. The point of asserting
  // it here is that the import path must not have grown a preview of its own that ignores the preference.
  const core = makeCore({ autoDrain: true, preview: true });
  await arrange(core, { samples: ticks(3), durationSeconds: 0.3 });
  await deliver({ type: 'preview', enabled: false, cropped: false });

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.deepEqual(postedOfType('previewFrame'), []);
  assert.deepEqual(core.previewStates, [{ enabled: false, cropped: false }]);
  assert.equal(postedOfType('videoImportDone')[0].reason, 'completed');
});

test('an import on a core that predates the preview exports still runs', async () => {
  // web/wasm/ is pinned and refreshed separately, so the drain has to degrade to a preview that never appears
  // rather than to a TypeError once per decoded frame.
  const core = makeCore({ autoDrain: true });
  await arrange(core, { samples: ticks(2) });
  await deliver({ type: 'preview', enabled: true, cropped: false });

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.deepEqual(postedOfType('previewFrame'), []);
  assert.equal(postedOfType('videoImportDone')[0].reason, 'completed');
  assert.equal(postedOfType('videoImportDone')[0].supplied, 2);
});

// --- rotation ------------------------------------------------------------------------------------------------

/// The samples a synthetic coded I420 frame holds, in the order the core reads them: Y, then Cb, then Cr.
function expectedPlanes(item, width, height) {
  const chromaWidth = (width + 1) >> 1;
  const chromaHeight = (height + 1) >> 1;
  const out = [];
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) out.push(codedLuma(item, x, y));
  for (const plane of [codedCb, codedCr]) {
    for (let y = 0; y < chromaHeight; y++) for (let x = 0; x < chromaWidth; x++) out.push(plane(item, x, y));
  }
  return out;
}

test('a rotated clip reports its rotation to the core and turns nothing itself', async () => {
  // PARITY, not cosmetics (.claude/rules/platform-parity.md). The CLI's offline producer reads through
  // cv::VideoCapture, whose FFmpeg backend auto-rotates by default -- OpenCV's VideoCaptureBase initialises
  // autorotate(true) and applies the metadata rotation in retrieveFrame, and native/src/cv/video_loader.h never
  // turns it off. Neither mediabunny nor WebCodecs does anything of the sort on the copyTo path: rotation is
  // metadata there. So without the step the same phone recording would decode upright on Windows and sideways
  // on web -- a divergence between two offline producers the rule treats identically.
  //
  // WHAT IS ASSERTED HERE IS THAT THE STEP IS DEFERRED, not skipped. The turn happens in the core, after the
  // colour conversion, because 4:2:0 chroma is shared by a 2x2 block and rotating the planes would re-pair luma
  // with chroma half a sample away from where OpenCV's rotate does (native/wasm/wasm_api.cpp
  // pushOfflineFrame). So what leaves this module is the decoded frame at its own size, with the angle
  // alongside it.
  for (const degrees of [0, 90, 180, 270]) {
    const core = makeCore({ autoDrain: true });
    const item = { timestamp: 0, codedWidth: 3, codedHeight: 2, rotation: degrees, fill: 7 };
    await arrange(core, { samples: [item], rotation: degrees, width: 3, height: 2 });

    await deliver({ type: 'startVideoImport', file: clip() });

    assert.equal(core.pushes.length, 1, 'rotation ' + degrees);
    assert.equal(core.pushes[0].rotation, degrees, 'rotation ' + degrees + ': reported angle');
    // The UNROTATED size and the UNROTATED planes: a producer that turned the frame here would swap these on
    // 90 and 270, and the core would then turn it a second time.
    assert.equal(core.pushes[0].width, 3, 'rotation ' + degrees + ': width');
    assert.equal(core.pushes[0].height, 2, 'rotation ' + degrees + ': height');
    assert.deepEqual(core.pushes[0].planes, expectedPlanes(item, 3, 2), 'rotation ' + degrees + ': planes');
  }
});

test('a frame is copied in its own pixel format, and the core is told which', async () => {
  // THE COLOUR CONVERSION MUST NOT BE THE BROWSER'S. WebCodecs converts with BT.709 -- its default for the
  // untagged clips this app is given, not tag fidelity, and the reported matrix is `bt709` regardless of what
  // it actually did -- while cv::VideoCapture converts every clip as BT.601 limited
  // regardless -- G = 176 against G = 194 at the probe isHeaderGreen gates on, i.e. no latch and no records.
  // So the frame is copied untouched and converted in the core (native/src/cv/decoded_frame_to_bgr.h).
  //
  // WHICH IS WHY THE FORMAT CANNOT BE PINNED TO I420: copyTo converts to the RGB formats and to nothing else,
  // so a hardware decoder's NV12 frame cannot be ASKED for as I420. The producer takes what the frame is.
  for (const [format, expected] of [['I420', 'I420'], ['NV12', 'NV12'], ['RGBX', 'RGBA'], ['BGRA', 'RGBA']]) {
    const core = makeCore({ autoDrain: true });
    const item = { timestamp: 0, codedWidth: 4, codedHeight: 2, format, fill: 3 };
    await arrange(core, { samples: [item] });

    await deliver({ type: 'startVideoImport', file: clip() });

    assert.equal(core.pushes.length, 1, format);
    assert.equal(core.pushes[0].format, expected, format + ': the format named to the core');
    assert.equal(core.pushes[0].length, frameSize(expected, 4, 2), format + ': byte length');
    // The luma plane is byte-identical to the coded plane for the two YUV layouts, so nothing rewrote it on
    // the way; for the RGB ones the first pixel is the packed triple.
    assert.equal(core.pushes[0].planes[0], codedLuma(item, 0, 0), format + ': first sample');
  }
});

test('a format the app cannot read without changing its colours is refused by name', async () => {
  // 4:2:2, 4:4:4 and an opaque frame could only be copied through an RGB conversion -- i.e. through the
  // browser's colour matrix, which is the divergence this path exists to remove. A named refusal beats a
  // silent zero-record import, so this is an app state and not a bug.
  for (const format of ['I422', 'I444', null]) {
    const core = makeCore({ autoDrain: true });
    await arrange(core, { samples: [{ timestamp: 0, codedWidth: 4, codedHeight: 2, format }] });

    await deliver({ type: 'startVideoImport', file: clip() });

    assert.equal(core.pushes.length, 0, String(format));
    const done = postedOfType('videoImportDone').at(-1);
    assert.equal(done.reason, 'refused', String(format));
    assert.match(done.message, /pixel format the app cannot read/, String(format));
  }
});

// The measured shape of a browser that hands back RGB pixels it has already run a YUV matrix over: Chrome for
// Android 150 (SOG04, hardware decoder) reports it on `RGBA`, desktop Firefox 153 reports it on `BGRX` under
// every `hardwareAcceleration` hint there is.
const CONVERTED_RGB_COLOR_SPACE = Object.freeze(
  { primaries: 'bt709', transfer: 'bt709', matrix: 'bt709', fullRange: false });

test('an RGB frame that already went through a YUV matrix is ACCEPTED -- this test was inverted deliberately',
  async () => {
    // WHY THIS ASSERTION IS THE OPPOSITE OF THE ONE IT REPLACES. The earlier version required such a frame to
    // be REFUSED by name, on the argument that a silent import at the browser's colours is worse than a
    // refusal. Two measurements retired that argument, in this order:
    //
    //   * The accepting branch (`colorSpace.matrix === 'rgb'`) is not reachable from any browser measured:
    //     desktop Chrome 151 and Chrome for Android 150 report `bt709` (on I420 planes, so they never reach
    //     the RGB branch at all), and desktop Firefox 153 reports `BGRX` + `bt709` under all three
    //     `hardwareAcceleration` hints, with `copyTo({format: 'I420'})` refused. The refusal therefore did not
    //     protect Firefox from a bad import; it stopped Firefox importing at all, which the implementation
    //     before the gate did not.
    //   * The colour difference no longer changes the records. The native suite now decodes every golden clip
    //     twice, BT.601 and BT.709, and requires ONE identical record set
    //     (`integration_dual_decode.<case>`, native/test/integration/run_dual_decode.py); it is green over all
    //     11 golden clips and the two landscape panes, against green predicates that were re-sized from
    //     measured pixels for exactly this.
    //
    // So the frame is taken. What is NOT retired is the observability requirement the refusal used to satisfy
    // for free -- see the next test, which is the half of this pair that keeps the import from being silently
    // wrong again.
    //
    // The three shapes below are the three answers a UA can give that are NOT a positive "no matrix": the
    // measured Chrome-for-Android / Firefox one, a UA that named no matrix, and one that reported no colour
    // space at all. All three are accepted alike -- an unstated matrix is treated as a stated YUV one, which
    // is the conservative direction now that acceptance is the outcome either way.
    for (const [what, colorSpace] of [
      ['the measured converted shape', CONVERTED_RGB_COLOR_SPACE],
      ['a UA that named no matrix', { primaries: 'bt709', transfer: 'bt709', matrix: null, fullRange: false }],
      ['a UA that reported no colour space', null],
    ]) {
      for (const format of ['RGBA', 'RGBX', 'BGRA', 'BGRX']) {
        const core = makeCore({ autoDrain: true });
        const item = { timestamp: 0, codedWidth: 4, codedHeight: 2, format, colorSpace, fill: 3 };
        await arrange(core, { samples: [item] });

        await deliver({ type: 'startVideoImport', file: clip() });

        const where = what + ' / ' + format;
        const done = postedOfType('videoImportDone').at(-1);
        assert.equal(done.reason, 'completed', where);
        assert.equal(core.pushes.length, 1, where + ': the frame reaches the core');
        // Named to the core as RGBA whatever the four it arrived as, because that is the one RGB layout
        // pushOfflineFrame parses (native/wasm/wasm_api.cpp).
        assert.equal(core.pushes[0].format, 'RGBA', where + ': the format named to the core');
        assert.equal(core.pushes[0].length, frameSize('RGBA', 4, 2), where + ': byte length');
      }
    }
  });

test('an accepted browser colour conversion is OBSERVABLE: a warning once, and a field on the outcome',
  async () => {
    // THE HALF OF THE PAIR THAT REPLACES THE REFUSAL. The defect the refusal was introduced for was never
    // "the colours differ" on its own -- it was that they differed with no refusal, no warning and no failure,
    // so a zero-record import looked like the app simply recognising nothing. Accepting the frame gives that
    // silence back unless the fact travels out, so it does: once into the worker log, naming the format and
    // the matrix, and once onto `videoImportDone` as `matrixConverted`, which is the form a bug report or a
    // Sentry breadcrumb can actually carry.
    const core = makeCore({ autoDrain: true });
    await arrange(core, {
      samples: [0, 1, 2].map((i) => ({
        timestamp: i * 0.1, codedWidth: 4, codedHeight: 2, format: 'BGRX', colorSpace: CONVERTED_RGB_COLOR_SPACE,
      })),
    });

    await deliver({ type: 'startVideoImport', file: clip() });

    const done = postedOfType('videoImportDone').at(-1);
    assert.equal(done.reason, 'completed');
    assert.equal(done.decoded, 3);
    // The FORMAT and the MATRIX are both named: "RGB happened" is not actionable, "BGRX through bt709" is.
    assert.match(done.matrixConverted, /BGRX/, 'the outcome names the format');
    assert.match(done.matrixConverted, /bt709/, 'the outcome names the matrix');
    const warnings = postedOfType('log').filter((m) => /colours are the browser's conversion/.test(m.msg));
    // ONCE, not once per frame. Every frame of such a clip carries the note, and a log line per frame would be
    // the same postMessage flood the progress throttle exists to avoid.
    assert.equal(warnings.length, 1, 'exactly one warning for a three-frame clip');
    assert.match(warnings[0].msg, /BGRX/, 'the warning names the format');
    assert.match(warnings[0].msg, /bt709/, 'the warning names the matrix');
  });

test('an import that involved no browser colour conversion says so, with an empty field and no warning',
  async () => {
    // The negative half: the note must distinguish, or it is just a banner. A YUV frame (what both Chromes
    // hand back under `prefer-software`) and an RGB frame that positively states `matrix: 'rgb'` are both
    // matrix-free as far as this producer is concerned, so neither may raise it.
    for (const [what, item] of [
      ['I420', { timestamp: 0, codedWidth: 4, codedHeight: 2, format: 'I420' }],
      ['NV12', { timestamp: 0, codedWidth: 4, codedHeight: 2, format: 'NV12' }],
      // mediabunny's own default for an RGB sample it was given no colour space for: `matrix: 'rgb'`.
      ['a matrix-free RGBA', { timestamp: 0, codedWidth: 4, codedHeight: 2, format: 'RGBA' }],
    ]) {
      const core = makeCore({ autoDrain: true });
      await arrange(core, { samples: [item] });

      await deliver({ type: 'startVideoImport', file: clip() });

      const done = postedOfType('videoImportDone').at(-1);
      assert.equal(done.reason, 'completed', what);
      assert.equal(done.matrixConverted, '', what + ': no conversion to report');
      assert.equal(postedOfType('log').filter((m) => /colours are the browser's conversion/.test(m.msg)).length,
        0, what + ': no warning');
    }
  });

// --- which decoder the producer asks for -----------------------------------------------------------------------

test('the producer asks for a SOFTWARE decoder, because a hardware one hands back converted pixels', async () => {
  // Not a performance tweak -- a correctness one, and the measurement is in video_import.mjs's DECODER_OPTIONS
  // note. On Chrome for Android the default (hardware-preferring) configuration produces RGBA that has already
  // been through BT.709, and no `copyTo` can ask for the planes back; `prefer-software` produces tightly packed
  // I420 on the same device and the same clip. (It is also 2.1x faster there and 3.0x faster on the desktop,
  // because an import reads every frame back to the CPU and a hardware decoder's readback is what dominates.)
  const core = makeCore({ autoDrain: true });
  const mb = await arrange(core, { samples: ticks(2) });

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.deepEqual(mb.sinkOptions, ['prefer-software'],
    'exactly one sink, asking for software -- not the default, and not asked twice');
  assert.equal(postedOfType('videoImportDone')[0].decoded, 2);
});

test('a decoder that cannot be configured is retried ONCE with the browser\'s own choice, and the clip imports',
  async () => {
    // `prefer-software` is a HINT, and a UA is allowed to reject the configuration outright -- which surfaces
    // here as a throw out of the sample iterator, because mediabunny routes the VideoDecoder error callback
    // into the iterator's out-of-band error. The pre-flight cannot see it coming: `track.canDecode()` takes no
    // arguments in this bundle, so it probes the track's own config with no accelerator hint in it and answers
    // for a decoder the sink is not going to build. The retry is what closes that gap, and it must be a retry
    // and not a refusal: refusing here would deny the import on a browser that can perfectly well decode the
    // clip, merely not the way this producer asked first.
    const core = makeCore({ autoDrain: true });
    const mb = await arrange(core, { samples: ticks(3), configureFailsFor: ['prefer-software'] });

    await deliver({ type: 'startVideoImport', file: clip() });

    assert.deepEqual(mb.sinkOptions, ['prefer-software', 'no-preference'],
      'the software decoder is asked for first, and the fallback lets the UA choose rather than swinging to '
      + 'prefer-hardware');
    const done = postedOfType('videoImportDone')[0];
    assert.equal(done.reason, 'completed', 'the import must succeed, not be refused');
    assert.equal(done.decoded, 3, 'and every frame of the clip must arrive exactly once');
    assert.equal(core.pushes.length, 3);
    assert.deepEqual(core.pushes.map((p) => p.mediaTsMs), [0, 100, 200]);
  });

test('a decoder that fails after it has produced frames is NOT retried, so no frame is pushed twice', async () => {
  // THE LINE THE RETRY IS DRAWN ON, and why it is "did the sink ever yield a sample" rather than "did the
  // import fail". A sink that yielded a frame demonstrably configured a decoder; whatever broke afterwards is
  // about the clip's bitstream, not about which implementation decoded it. Re-running the clip from the start
  // would re-push every frame already supplied -- duplicate records for one clip, which recognition has no way
  // to tell from a genuine second appearance.
  const core = makeCore({ autoDrain: true });
  const mb = await arrange(core, { samples: ticks(5), failAfterSamples: 2 });

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.deepEqual(mb.sinkOptions, ['prefer-software'], 'one sink only: a decoder that ran is not re-chosen');
  assert.deepEqual(core.pushes.map((p) => p.mediaTsMs), [0, 100], 'and the frames it did produce arrive once');
  const done = postedOfType('videoImportDone')[0];
  assert.equal(done.reason, 'failed', 'a bitstream that went bad is a failure, not a refusal');
  assert.match(postedOfType('error')[0].msg, /bitstream went bad/);
});

test('a fallback decoder that also fails is reported, not retried again', async () => {
  // The retry is a single step, not a loop: a browser that can configure neither is a real failure and has to
  // be said so, rather than costing the user a decode attempt per accelerator value.
  const core = makeCore({ autoDrain: true });
  const mb = await arrange(core, {
    samples: ticks(3),
    configureFailsFor: ['prefer-software', 'no-preference'],
  });

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.deepEqual(mb.sinkOptions, ['prefer-software', 'no-preference'], 'two attempts, and no third');
  assert.equal(core.pushes.length, 0);
  const done = postedOfType('videoImportDone')[0];
  assert.equal(done.reason, 'failed');
  // The session is still handed back in full, so a failed configure does not cost the worker its claim.
  assert.deepEqual(core.calls,
    ['startCaptureSession', 'endOfInput', 'stop', 'endCaptureSession', 'videoImportVerdict']);
  assert.equal(hooks.session(), null);
});

test('the plane layout copyTo resolved to reaches the core unchanged', async () => {
  // WHO JUDGES THE LAYOUT, asserted from the producer's side. `VideoFrame.copyTo` RESOLVES TO the layout it
  // used -- the caller does not choose it -- so the only thing this module owes the core is that answer,
  // verbatim. It used to owe a verdict as well, computed from a JS copy of the core's packing rule; the rule
  // now exists once, in the core, and a producer that re-derived or "corrected" a layout here would be hiding
  // from the core the very thing it has to judge. `padLayout` makes the stub report a layout no packing rule
  // would produce, which is exactly the case a producer must NOT quietly normalise away.
  const core = makeCore({ autoDrain: true });
  await arrange(core, { samples: [{ timestamp: 0, codedWidth: 4, codedHeight: 2, padLayout: true }] });

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.equal(core.pushes.length, 1);
  // The stub's own answer for a 4x2 I420 frame with a padded luma stride: offsets untouched, stride 4 + 4.
  assert.deepEqual(core.pushes[0].layout,
    [{ offset: 0, stride: 8 }, { offset: 8, stride: 2 }, { offset: 10, stride: 2 }]);
});

test('a layout the core refuses stops the import rather than shearing it into the pipeline', async () => {
  // A stride padded out to a hardware decoder's alignment is not a visibly broken frame: the core would read
  // each row a few bytes early, so the picture shears progressively down the frame and the chroma drifts out of
  // step with the luma. That is the most expensive way for a wire-format mismatch to present itself.
  //
  // The core refuses it (that judgement is native/test/cv/test_decoded_frame_to_bgr.cpp's, by name), and what
  // is under test HERE is the worker's answer to a refusal: a NEGATIVE verdict means this code and the user
  // agent disagree about the copy API, so every remaining frame would fail identically. Stopping is the honest
  // outcome, and a `failed` -- not a user-actionable `refused` -- is the honest classification. The three
  // samples are what make "stopped" different from "the clip ended".
  const core = makeCore({ autoDrain: true, refuseLayout: true });
  await arrange(core, { samples: ticks(3) });

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.equal(core.pushes.length, 1, 'the second frame is never copied, let alone pushed');
  const done = postedOfType('videoImportDone')[0];
  assert.equal(done.reason, 'failed');
  assert.match(postedOfType('error')[0].msg, /tightly packed planes/);
});

// --- pacing --------------------------------------------------------------------------------------------------

test('the producer parks at the flow gate instead of decoding the clip as fast as it can', { timeout: 5000 },
  async () => {
    // An import builds the pipeline with video_mode = true, and on Emscripten that is QueueLimitMode::NoLimit --
    // never blocks, never drops. Nothing downstream bounds it, so this park IS the memory bound. The core stub
    // dequeues nothing until this test says so, so a producer that ignored the gate would push all 20 frames.
    const core = makeCore();
    const max = sessionHooks.offlineInflightMax();
    await arrange(core, { samples: ticks(20) });

    const importing = deliver({ type: 'startVideoImport', file: clip() });
    try {
      // THE HOLD BELOW IS MEASURED, NOT PICKED, in the shape test_web_video_demux.mjs uses: the positive
      // control comes first and is this machine, this moment. `rampMs` is how long the producer took to
      // decode and push `max` frames -- so a producer that ignored the gate would have had time to push
      // another four times that many inside the window the parked run is then held through. A fixed 120 ms
      // said nothing: on a loaded machine it can be shorter than one push, and the assertion passes because
      // nothing had got round to happening yet.
      const rampStart = performance.now();
      await settle();
      const rampMs = performance.now() - rampStart;
      assert.equal(core.pushes.length, max,
        'the producer must stop exactly at the limit, not one frame past it and not at a count of its own');
      assert.equal(core.residentFrames(), max);
      assert.equal(rampMs > 0, true, 'a window built on an unmeasured interval would bound nothing');
      // Polled through rather than slept through: every turn is another chance for a producer that did not
      // park to push one more frame, and a breach is caught on the turn it happens rather than at the end of
      // a nap.
      const deadline = performance.now() + 4 * rampMs;
      while (performance.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 0));
        assert.equal(core.pushes.length, max, 'and it must STAY parked while the pipeline drains nothing');
      }

      // The pipeline takes four frames off the distributor's queue; the producer wakes and pushes exactly four
      // more before parking again. This is the property a gate that resumed on any wake at all would fail.
      for (let i = 0; i < 4; i++) core.noteDistributed();
      await settle();
      assert.equal(core.pushes.length, max + 4);
    } finally {
      // Drain the rest so the import can finish; leaving it parked would keep the claim and wedge later tests.
      for (let i = 0; i < 40; i++) core.noteDistributed();
      await importing;
    }
    assert.equal(postedOfType('videoImportDone')[0].decoded, 20);
    assert.equal(core.isActive(), false);
  });

test('a core that stops publishing counters mid-import stops the producer rather than running unbraked',
  async () => {
    // Unreachable in production -- the claim's door refuses an offline kind whose counters are missing before a
    // session can be opened -- so reaching it means the module was swapped underneath a running import. The
    // producer must stop, because the queue it is feeding never blocks and never drops.
    const core = makeCore();
    let swapped = false;
    await arrange(core, {
      samples: ticks(6),
      beforeSample: () => {
        if (swapped) return;
        swapped = true;
        hooks.installCore(makeCore({ counters: false }));
      },
    });

    await deliver({ type: 'startVideoImport', file: clip() });

    const done = postedOfType('videoImportDone')[0];
    assert.equal(done.reason, 'unbraked');
    assert.equal(done.decoded, 0, 'not one frame may be pushed once the brake is gone');
    assert.equal(postedTypes().includes('error'), true, 'and it is reported, not swallowed');
  });

// --- cancellation --------------------------------------------------------------------------------------------

test('a cancel stops the producer promptly and releases the session exactly once', { timeout: 5000 }, async () => {
  const core = makeCore();
  const max = sessionHooks.offlineInflightMax();
  const mb = await arrange(core, { samples: ticks(50) });

  const importing = deliver({ type: 'startVideoImport', file: clip() });
  try {
    await settle();
    assert.equal(core.pushes.length, max, 'parked at the gate, which is where a cancel has to work');
    assert.equal(hooks.session() !== null, true);

    deliver({ type: 'cancelVideoImport' });
    // Released so the parked gate can observe the cancel; the point is that it stops HERE and not at frame 50.
    for (let i = 0; i < max; i++) core.noteDistributed();
    await importing;
  } finally {
    for (let i = 0; i < 60; i++) core.noteDistributed();
  }

  const done = postedOfType('videoImportDone')[0];
  assert.equal(done.reason, 'cancelled');
  // EXACT, not merely "fewer than 50". The cancel landed while the producer was parked at the gate, so the very
  // next thing it does after being woken must be to notice the cancel -- not to push the frame it was waiting
  // for. An off-by-one here is the difference between a cancel that stops the producer and one that lets it
  // through one more time per park.
  assert.equal(done.decoded, max, 'a woken producer must re-check the cancel before pushing, not after');
  // NOTHING LEFT BEHIND: the sample the loop was holding is closed, the demuxer is disposed, and the iterator
  // was told to stop (the stub records `exhausted` only when it ran to the end, which a cancel must not reach).
  assert.equal(mb.opened.length, 0, 'every sample the loop touched must be closed, cancel or not');
  assert.equal(mb.events.includes('dispose'), true, 'the reader must be disposed on the cancel path too');
  assert.equal(mb.events.includes('exhausted'), false);
  // ...and the session is given back through the ordinary teardown, exactly once.
  assert.deepEqual(core.calls,
    ['startCaptureSession', 'endOfInput', 'stop', 'endCaptureSession', 'videoImportVerdict']);
  assert.equal(core.isActive(), false);
  assert.equal(hooks.session(), null);
  assert.equal(sessionHooks.claimedKind(), null);
});

// --- cancellation AT A GATE THE PIPELINE NEVER OPENS ------------------------------------------------------------
//
// The tests above cancel a parked producer and then DRAIN the core so the park can end on its own terms. That is
// the friendly case and it says nothing about the unfriendly one. The gate's loop has exactly one natural exit --
// the core dequeuing -- and the moment the pipeline stops dequeuing (which is what a pipeline being torn down
// does) that exit never comes. A park with no second exit turns a cancel into a permanent hang, and because the
// worker chains every teardown on one queue, that hang is not confined to the import: the teardown joining the
// producer never returns, every LATER teardown waits behind it forever, and every later start degrades into a
// session with no producer. So: nothing below drains a single frame.

test('a cancel reaches a producer parked at a gate the pipeline never opens', { timeout: 10000 }, async () => {
  const core = makeCore();
  const max = sessionHooks.offlineInflightMax();
  const mb = await arrange(core, { samples: ticks(50) });

  const importing = deliver({ type: 'startVideoImport', file: clip() });
  await settle();
  assert.equal(core.pushes.length, max, 'the producer must be parked at the gate before the cancel is delivered');

  deliver({ type: 'cancelVideoImport' });
  await within(3000, importing, 'the cancelled producer never left the flow gate');

  // NOT ONE FRAME WAS DEQUEUED. That is the whole point: the park ended because the session was revoked, not
  // because the pipeline made room, so the queue is still exactly as full as it was when the cancel landed.
  assert.equal(core.residentFrames(), max, 'the park must end on the revocation, not on the queue draining');
  assert.equal(core.pushes.length, max, 'and a woken producer must not push the frame it was waiting to push');
  const done = postedOfType('videoImportDone');
  assert.equal(done.length, 1);
  assert.equal(done[0].reason, 'cancelled');
  // The session was given back in full, so the worker is usable afterwards.
  assert.deepEqual(core.calls,
    ['startCaptureSession', 'endOfInput', 'stop', 'endCaptureSession', 'videoImportVerdict']);
  assert.equal(hooks.session(), null);
  assert.equal(sessionHooks.claimedKind(), null);
  assert.equal(sessionHooks.teardownsInFlight(), 0);
  assert.equal(mb.opened.length, 0, 'the sample the producer was holding must still be closed');
  assert.equal(mb.events.includes('dispose'), true);
});

test('a stop delivered to a producer parked at that gate tears down, and does not wedge every later teardown',
  { timeout: 10000 }, async () => {
    // THE SAME PARK, ENTERED THROUGH THE TEARDOWN PATH, which is the worse of the two: `stop` cannot reach
    // `Module.stop()` -- the one thing that would reset the counters and wake the gate -- until it has joined the
    // producer parked on those very counters. If the park is not cancellable that is a closed circle, and it
    // takes the whole worker with it rather than just this import.
    const core = makeCore();
    const max = sessionHooks.offlineInflightMax();
    await arrange(core, { samples: ticks(50) });

    const importing = deliver({ type: 'startVideoImport', file: clip() });
    await settle();
    assert.equal(core.pushes.length, max, 'the producer must be parked at the gate before the stop is delivered');

    const stopping = deliver({ type: 'stop' });
    await within(3000, Promise.all([importing, stopping]), 'the stop never joined the parked producer');

    assert.equal(core.residentFrames(), max, 'nothing dequeued: the park ended on the teardown revoking it');
    // THE VERDICT COMES BEFORE THE JOIN ON THIS PATH ONLY, and that is the shape rather than an accident: the
    // teardown owns `stop`, so the producer's own handler reports its ending as soon as it has one. It reads the
    // verdict there only because this core answers `isPipelineDrained()` -- see the empty-import tests for the
    // case where it does not and the count is left unstated instead of guessed at.
    assert.deepEqual(core.calls,
      ['startCaptureSession', 'endOfInput', 'videoImportVerdict', 'stop', 'endCaptureSession']);
    assert.equal(core.isActive(), false);
    assert.equal(hooks.session(), null);
    assert.equal(hooks.inFlight(), false);
    assert.equal(sessionHooks.teardownsInFlight(), 0, 'the teardown queue must be idle, not parked forever');
    const done = postedOfType('videoImportDone');
    assert.equal(done.length, 1, 'the import still reports exactly one terminal message when a stop ended it');
    assert.equal(done[0].reason, 'cancelled');

    // AND THE WORKER IS STILL USABLE. A teardown that never returned would leave `teardownQueueTail` pending for
    // the lifetime of the worker, so this second, ordinary import is what distinguishes "the stop finished" from
    // "the stop was abandoned and the assertions above happened to hold anyway".
    const second = makeCore({ autoDrain: true });
    await arrange(second, { samples: ticks(3) });
    await within(3000, deliver({ type: 'startVideoImport', file: clip() }), 'a later start was wedged');
    assert.deepEqual(second.calls,
      ['startCaptureSession', 'endOfInput', 'stop', 'endCaptureSession', 'videoImportVerdict']);
    assert.equal(postedOfType('videoImportDone')[0].reason, 'completed');
  });

test('a teardown that ended an import ends it ONCE: no second stop, harvest or stopped', { timeout: 10000 },
  async () => {
    // The producer's own handler must not queue an ending for a session a teardown already took over. The reason
    // is DUPLICATION, not deadlock: the promise the teardown joins is the decode driver's, which settles as soon
    // as the decode loop returns, so a second teardown queued from the handler simply runs afterwards and repeats
    // Module.stop(), the MEMFS sweep and `stopped` -- reporting the end of a session the front end has already
    // been told ended. Counted rather than pattern-matched, because a duplicate is a COUNT going from one to two.
    const core = makeCore();
    await arrange(core, { samples: ticks(50) });

    const importing = deliver({ type: 'startVideoImport', file: clip() });
    await settle();
    const stopping = deliver({ type: 'stop' });
    await within(3000, Promise.all([importing, stopping]), 'the stop never joined the parked producer');
    // Let anything the handler might have queued behind the teardown actually run before counting.
    await settle();
    await settle();

    assert.equal(core.calls.filter((c) => c === 'stop').length, 1, 'Module.stop() must be called exactly once');
    assert.equal(core.calls.filter((c) => c === 'endCaptureSession').length, 1);
    assert.equal(postedTypes().filter((t) => t === 'stopped').length, 1, 'exactly one `stopped` per session');
    assert.equal(postedTypes().filter((t) => t === 'harvest').length, 1, 'exactly one harvest per session');
    assert.equal(postedOfType('videoImportDone').length, 1);
    assert.equal(sessionHooks.teardownsInFlight(), 0);
  });

test('a cancel with no import running is a logged no-op', async () => {
  const core = makeCore();
  await arrange(core, { samples: [] });
  deliver({ type: 'cancelVideoImport' });
  await settle();
  assert.deepEqual(core.calls, []);
  assert.deepEqual(postedTypes(), []);
});

// --- the start path: ownership before setup ------------------------------------------------------------------

test('a stop delivered while the import is still setting up joins it and ends the session once', async () => {
  // PROPERTY 3 OF THE WORKER'S SESSION RULE, and the reason it exists. The handler is parked on the module load
  // -- a real await that yields to the task queue, i.e. exactly the window `handleStartLive` never opens -- and
  // a `stop` is delivered into it. Because ownership was taken BEFORE that await, the teardown can see the
  // producer, revoke it and join it; had the handler awaited first, the teardown would have found nothing and
  // `Module.stop()` would have run under a producer that was about to start pushing.
  const core = makeCore();
  posted.length = 0;
  hooks.installCore(core);
  const mb = makeMediabunny({ samples: ticks(5) });
  let releaseLoad;
  hooks.setModuleLoader(() => new Promise((resolve) => { releaseLoad = () => resolve(mb.module); }));
  await deliver({ type: 'setInitConfig', config: { video_mode: false } });

  const importing = deliver({ type: 'startVideoImport', file: clip() });
  let stopping = Promise.resolve();
  try {
    await settle();
    assert.equal(hooks.session() !== null, true, 'the session must exist before the setup finishes');
    assert.equal(hooks.inFlight(), true, 'and the producer must be joinable');
    assert.equal(core.calls.filter((c) => c === 'stop').length, 0);

    stopping = deliver({ type: 'stop' });
    await settle();
    // The teardown is parked on the producer, which is parked on the module load: nothing has been joined yet.
    assert.equal(sessionHooks.teardownsInFlight(), 1);
    assert.deepEqual(core.calls, ['startCaptureSession'], 'the loop must not be joined under a live producer');
    assert.equal(core.isActive(), true, 'nor the claim handed back');
  } finally {
    releaseLoad();
    await importing;
    await stopping;
  }

  // The producer noticed it had been revoked and pushed nothing; the teardown then joined, harvested and
  // released -- once.
  assert.deepEqual(core.pushes, []);
  // Teardown-owned ending, so the verdict is read before the join -- see the parked-producer test above.
  assert.deepEqual(core.calls,
    ['startCaptureSession', 'endOfInput', 'videoImportVerdict', 'stop', 'endCaptureSession']);
  assert.equal(core.isActive(), false);
  assert.equal(hooks.session(), null);
  const done = postedOfType('videoImportDone');
  assert.equal(done.length, 1, 'the import still reports one terminal message when a stop ended it');
  assert.equal(done[0].reason, 'cancelled');
  assert.equal(mb.events.includes('dispose'), true);
});

// --- refusals ------------------------------------------------------------------------------------------------

test('an import is refused by the CORE while a live session is running', async () => {
  const core = makeCore();
  await arrange(core, { samples: ticks(3) });
  await deliver({ type: 'startLive' });
  assert.equal(sessionHooks.sessionOwner(), 'live');
  const callsBefore = core.calls.length;

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.equal(hooks.session(), null, 'no import session may exist');
  assert.deepEqual(core.pushes, []);
  assert.equal(core.calls[callsBefore], 'startCaptureSession:refused');
  const errors = postedOfType('error');
  assert.equal(errors.length, 1);
  assert.match(errors[0].msg, /mutually exclusive/);
  assert.equal(errors[0].expected, true, 'a mutual-exclusion refusal is an app state, not a Sentry issue');
  // The live session is untouched by the refusal.
  assert.equal(sessionHooks.sessionOwner(), 'live');
  assert.equal(core.activeKind(), 'live');

  sessionHooks.setLiveFrameInFlight(null);
  await deliver({ type: 'stopLive' });
});

test('a second startVideoImport is REFUSED, because acknowledging it would discard the user\'s clip',
  { timeout: 10000 }, async () => {
    // WHERE AN IMPORT PARTS COMPANY WITH `startLive`. A live start carries no payload, so re-acknowledging a
    // duplicate gives the caller exactly what it asked for. An import start carries a CLIP, and the running
    // session is decoding a different one -- so an acknowledgement would drop `message.file` on the floor, post
    // `videoImportStarted` for an import that never began, and leave the caller waiting for a second
    // `videoImportDone` that can never arrive. A request that cannot be served has to be refused so the clip can
    // be re-offered.
    const core = makeCore();
    const max = sessionHooks.offlineInflightMax();
    const mb = await arrange(core, { samples: ticks(50) });

    const importing = deliver({ type: 'startVideoImport', file: clip() });
    await settle();
    const running = hooks.session();
    assert.equal(running !== null, true);
    const inputsBefore = mb.events.filter((e) => e === 'input').length;

    await deliver({ type: 'startVideoImport', file: clip(2048) });

    const errors = postedOfType('error');
    assert.equal(errors.length, 1);
    assert.match(errors[0].msg, /already running/);
    assert.equal(errors[0].expected, true, 'a duplicate request is an app state, not a Sentry issue');
    // ACKNOWLEDGED NOWHERE. One import started, so there is exactly one `videoImportStarted` -- the running
    // import's -- and the second clip was never opened.
    assert.equal(postedTypes().filter((t) => t === 'videoImportStarted').length, 1);
    assert.equal(mb.events.filter((e) => e === 'input').length, inputsBefore,
      'the refused request must not open a demuxer over the clip it could not serve');
    // ...and the running import is untouched: same session object, same producer, same counters.
    assert.equal(hooks.session(), running);
    assert.equal(hooks.inFlight(), true);
    assert.equal(core.pushes.length, max);

    deliver({ type: 'cancelVideoImport' });
    await within(3000, importing, 'the running import must still be cancellable after a refused duplicate');
    assert.equal(postedOfType('videoImportDone').length, 1, 'still exactly one terminal message, for one import');
  });

test('an import is refused outright on a core with no frame-flow counters', async () => {
  const core = makeCore({ counters: false });
  await arrange(core, { samples: ticks(3) });

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.equal(hooks.session(), null);
  assert.deepEqual(core.calls, [], 'the core must not be asked to open a session it cannot brake');
  assert.match(postedOfType('error')[0].msg, /no frame-flow counters/);
});

test('the teardown waits for the pipeline to drain, so the clip\'s LAST record survives', { timeout: 10000 },
  async () => {
    // THE DEFECT THIS EXISTS FOR, reproduced in the small. In a browser: the producer finished, the teardown ran
    // straight into Module.stop(), the stitcher was still writing and the recognizer had not yet dequeued the
    // record -- "recognize aborted ... inference bridge is stopping". The harvest shipped the stitch output and
    // no record.json, and the import reported success, because the counts it reports are FRAME counts and could
    // not disagree. Ten of the eleven golden clips are single-record, so the feature produced nothing at all for
    // them behind a green tile.
    //
    // `drainPolls` is what makes the window here as wide as it is in a browser: the barrier says busy three
    // times, and the tail record exists only from the poll that finally says drained.
    const memfs = makeMemfs();
    const core = makeCore({ autoDrain: true, memfs, drainPolls: 3, tailRecord: 'tail-record-id' });
    await arrange(core, { samples: ticks(3), durationSeconds: 0.3 });

    await deliver({ type: 'startVideoImport', file: clip() });

    assert.equal(core.drainPollsSeen(), 3, 'the teardown must poll the barrier until the core says drained');
    assert.equal(core.stoppedWhileBusy, false, 'the loop must not be joined while a stage still holds work');
    // ...and the record the wait bought is what actually reaches Dart. Asserting the join order alone would pass
    // for a teardown that waited and then swept before the record was written.
    assert.deepEqual(importedRecordIds(), ['chara_detail/active/tail-record-id/record.json']);
    assert.equal(postedOfType('videoImportDone')[0].reason, 'completed');
    assert.deepEqual(core.calls,
      ['startCaptureSession', 'endOfInput', 'stop', 'endCaptureSession', 'videoImportVerdict']);
  });

test('a pipeline that never drains ends the import loudly instead of wedging the worker', { timeout: 20000 },
  async () => {
    // The barrier is a positive condition, not a quiet window, so a stage that wedges would park the teardown
    // forever. The timeout is the watchdog for that and nothing else: it falls through to exactly the behaviour
    // every import had before the barrier existed (stop() aborts the bridge and joins), and it says so.
    const core = makeCore({ autoDrain: true, drainPolls: Number.MAX_SAFE_INTEGER });
    await arrange(core, { samples: ticks(2) });
    hooks.setDrainTimeoutMs(50);
    try {
      await deliver({ type: 'startVideoImport', file: clip() });
    } finally {
      hooks.setDrainTimeoutMs(null);
    }

    const errors = postedOfType('error');
    assert.equal(errors.length, 1);
    assert.match(errors[0].msg, /did not drain within/);
    assert.equal(errors[0].expected, undefined, 'a wedged pipeline is a genuine failure, not an app state');
    // The session still ends: the claim is handed back and the import gets its one terminal message.
    assert.deepEqual(core.calls,
      ['startCaptureSession', 'endOfInput', 'stop', 'endCaptureSession', 'videoImportVerdict']);
    assert.equal(hooks.session(), null);
    assert.equal(postedOfType('videoImportDone').length, 1);
  });

test('an import is refused on a core that cannot report when the pipeline has drained', async () => {
  // Fail-closed for the same reason the missing offline push is: an import on such a core is not degraded, it
  // silently discards its last record on every run and reports success anyway.
  const core = makeCore({ drainExport: false });
  await arrange(core, { samples: ticks(3) });

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.equal(hooks.session(), null);
  assert.deepEqual(core.calls, []);
  assert.match(postedOfType('error')[0].msg, /predates Module\.isPipelineDrained/);
});

test('an import is refused on a core that predates the offline push export', async () => {
  // Checked BEFORE the claim is taken: the alternative is a TypeError once per decoded frame inside the loop,
  // or a silent `false` per frame that looks exactly like a pipeline rejecting the clip.
  const core = makeCore({ offlinePush: false });
  await arrange(core, { samples: ticks(3) });

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.equal(hooks.session(), null);
  assert.deepEqual(core.calls, []);
  assert.match(postedOfType('error')[0].msg, /predates Module\.pushOfflineFrame/);
});

test('a clip with no video track, and one this browser cannot decode, are refused as app states', async () => {
  for (const [spec, pattern] of [
    [{ samples: [], track: null }, /no video track/],
    [{ samples: [], canDecode: false, codec: 'hevc' }, /cannot decode/],
  ]) {
    const core = makeCore();
    await arrange(core, spec);

    await deliver({ type: 'startVideoImport', file: clip() });

    const errors = postedOfType('error');
    assert.equal(errors.length, 1);
    assert.match(errors[0].msg, pattern);
    assert.equal(errors[0].expected, true);
    assert.equal(postedOfType('videoImportDone')[0].reason, 'refused');
    // A refusal happens AFTER the claim is taken (ownership comes before setup), so it has to give the claim
    // back through the same teardown -- otherwise every later import would be answered as a duplicate.
    assert.deepEqual(core.calls,
      ['startCaptureSession', 'endOfInput', 'stop', 'endCaptureSession', 'videoImportVerdict']);
    assert.equal(core.isActive(), false);
    assert.equal(hooks.session(), null);
  }
});

test('a file that is not a video at all is refused, not reported as a failure', async () => {
  // `track === null` only covers "a container I understand, with no video track in it". A PDF, a screenshot or a
  // truncated download never gets that far: the format probe throws UnsupportedInputFormatError, which used to
  // sail past the null check as an ordinary throw -- so picking the wrong file in a file dialog was a FAILURE,
  // and a Sentry issue, for a case docs/video-import.md calls user-actionable.
  const core = makeCore();
  await arrange(core, { samples: [], unsupportedFormat: true });

  await deliver({ type: 'startVideoImport', file: clip() });

  const errors = postedOfType('error');
  assert.equal(errors.length, 1);
  assert.equal(errors[0].expected, true, 'a file the user picked by mistake must not reach Sentry');
  assert.match(errors[0].msg, /not a video the app can read/);
  assert.equal(postedOfType('videoImportDone')[0].reason, 'refused');
  assert.deepEqual(core.calls,
    ['startCaptureSession', 'endOfInput', 'stop', 'endCaptureSession', 'videoImportVerdict']);
});

test('a codec refusal names the codec even when mediabunny does not model it', async () => {
  // The refusal message is the ONLY place the user learns why the clip was rejected, and for an FFV1 recording
  // -- which this project's own `capture --record` produces -- getCodec() answers null, so the message read
  // "... video codec (null)" and named nothing at all. The container's own codec id is exactly what mediabunny
  // failed to map, so that is what the message falls back to.
  const core = makeCore();
  await arrange(core, { samples: [], canDecode: false, codec: null, internalCodecId: 'V_MS/VFW/FOURCC' });

  await deliver({ type: 'startVideoImport', file: clip() });

  const errors = postedOfType('error');
  assert.equal(errors.length, 1);
  assert.equal(errors[0].expected, true);
  assert.match(errors[0].msg, /cannot decode/);
  assert.match(errors[0].msg, /V_MS\/VFW\/FOURCC/);
  assert.doesNotMatch(errors[0].msg, /\(null\)/);
});

test('a decode bundle that will not load is refused, not failed', async () => {
  // The bundle is loaded LAZILY, at the first import -- which is precisely what makes this fetch fail for
  // ordinary, user-actionable reasons: the tab went offline between first paint and the first import, or an
  // extension or a proxy blocked the request. Reporting that as a failure would file a Sentry issue per attempt
  // for a condition only the user can resolve, so it takes the `expected` channel like any other app state, and
  // the underlying cause is kept in the message rather than thrown away.
  const core = makeCore();
  await arrange(core, { samples: [] });
  hooks.setModuleLoader(async () => { throw new Error('NetworkError when attempting to fetch resource'); });

  await deliver({ type: 'startVideoImport', file: clip() });

  const errors = postedOfType('error');
  assert.equal(errors.length, 1);
  assert.equal(errors[0].expected, true, 'a bundle that will not load is an app state, not a Sentry issue');
  assert.match(errors[0].msg, /could not be loaded/);
  assert.match(errors[0].msg, /NetworkError/, 'the underlying cause must survive the reclassification');
  assert.equal(postedOfType('videoImportDone')[0].reason, 'refused');
  // ...and the claim is handed back through the ordinary teardown, so the retry the message suggests can work.
  assert.deepEqual(core.calls,
    ['startCaptureSession', 'endOfInput', 'stop', 'endCaptureSession', 'videoImportVerdict']);
  assert.equal(hooks.session(), null);
});

test('a start with no Blob is refused before the claim is taken', async () => {
  const core = makeCore();
  await arrange(core, { samples: [] });

  await deliver({ type: 'startVideoImport', file: null });

  assert.deepEqual(core.calls, []);
  assert.equal(hooks.session(), null);
  assert.match(postedOfType('error')[0].msg, /must be a Blob\/File/);
});

// --- progress ------------------------------------------------------------------------------------------------

test('progress is throttled to a wall-clock interval, with one before the first frame and one after the last',
  async () => {
    // A message per decoded frame is tens of thousands of postMessages for a long clip -- the import is
    // deliberately not paced by the clock, so a decoder outruns any UI -- and the main thread is the side that
    // can least afford them. The clock is stubbed so the throttle is asserted exactly rather than raced.
    let clock = 0;
    hooks.setNow(() => clock);
    try {
      const core = makeCore({ autoDrain: true });
      await arrange(core, {
        samples: ticks(10),
        durationSeconds: 2,
        // 100 ms of wall clock per decoded frame: with a 250 ms throttle that is one message every third frame.
        beforeSample: () => { clock += 100; },
      });

      await deliver({ type: 'startVideoImport', file: clip() });

      const progress = postedOfType('videoImportProgress');
      // The first carries the DENOMINATOR and no frames yet, so the UI can render a determinate bar from the
      // outset instead of changing shape once decoding starts.
      assert.deepEqual(progress[0], {
        type: 'videoImportProgress', decoded: 0, supplied: 0, mediaTimeMs: 0, durationMs: 2000,
      });
      // The last reports the whole clip, and is emitted unconditionally so a fast clip still ends at 100%.
      const last = progress[progress.length - 1];
      assert.equal(last.decoded, 10);
      assert.equal(last.mediaTimeMs, 900);
      assert.equal(last.durationMs, 2000);
      // Throttled in between: 10 frames at 100 ms with a 250 ms interval is 3 intermediate messages, not 10.
      assert.equal(progress.length, 5, 'expected first + 3 throttled + last');
      assert.deepEqual(progress.slice(1, -1).map((p) => p.decoded), [3, 6, 9]);
    } finally {
      hooks.setNow(null);
    }
  });

test('a clip that declares no duration still reports progress as counts', async () => {
  // Both duration calls fail: that must cost the import its progress bar and nothing else.
  const core = makeCore();
  await arrange(core, {
    samples: ticks(2),
    track: {
      getCodec: async () => 'vp9',
      getRotation: async () => 0,
      getCodedWidth: async () => 4,
      getCodedHeight: async () => 2,
      canDecode: async () => true,
      getDurationFromMetadata: async () => null,
      computeDuration: async () => { throw new Error('no duration element'); },
    },
  });

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.equal(postedOfType('videoImportProgress')[0].durationMs, 0);
  assert.equal(postedOfType('videoImportDone')[0].reason, 'completed');
  assert.equal(core.pushes.length, 2);
});

// --- HARVEST ISOLATION -----------------------------------------------------------------------------------------
//
// THE INCIDENT THESE ARE WRITTEN AGAINST (docs/video-import.md; .notes/video-import/old-implementation-review.md).
// `harvestAndCleanup` sweeps a storage root indiscriminately and Dart writes everything it ships into the real
// record store. A record regeneration once left its staging directory under that same root, and the sweep wrote
// the whole batch back as though the session had captured it: deleted records resurrected, `record.json` rolled
// back to its pre-regeneration bytes, archived records re-materialised in the active store. The source of that
// particular leftover was fixed; THE SWEEP WAS NOT, so the hazard belongs to the harvest model and returns with
// any new harvest-based session.
//
// A UI GATE WAS EXPLICITLY REJECTED as the answer: a disabled button cannot make a sweep pick up only what the
// session produced. So the assertions below are not "the import did not select the leftover" -- they are that
// the import was never given a name for it: the core is told a storage root of the import's own, and the same
// value is what the sweep enumerates.
//
// `LEFTOVER` stands for anything that can be sitting under the shared root when an import runs: a record
// regeneration's staging dir, a previous live session's unharvested record, or a partially written one.
const LEFTOVER = 'leftover-record-id';
const LEFTOVER_FILE = '/work/storage/chara_detail/active/' + LEFTOVER + '/record.json';

/// A memfs seeded exactly as a worker that has done a regeneration (or a live session) leaves it.
function memfsWithLeftover() {
  const memfs = makeMemfs();
  memfs.mkdirp('/work/storage');
  memfs.mkdirp('/work/temp');
  memfs.mkdirp('/work/modules');
  memfs.seedFile(LEFTOVER_FILE, 0xee);
  // A temp fragment too: the sweep also CLEARS temp_dir, and clearing the shared one would delete a
  // regeneration's or a live session's scraping fragments out from under it.
  memfs.seedFile('/work/temp/chara_detail/fragment.png', 0xef);
  return memfs;
}

function importedRecordIds() {
  return postedOfType('harvest')
    .flatMap((m) => m.files.map((f) => f.path))
    .concat(postedOfType('liveRecord').flatMap((m) => m.files.map((f) => f.path)));
}

test('an import runs on a storage root of its own, and the shared root is not reachable from it', async () => {
  const memfs = memfsWithLeftover();
  const core = makeCore({ autoDrain: true, memfs });
  // Read WHILE the import runs: the teardown puts the roots back to the shared ones, so afterwards there is
  // nothing left to compare the core's config against.
  let runningRoots = null;
  await arrange(core, {
    samples: ticks(3),
    // The pipeline writes its record while the clip is being decoded, into the storage_dir it was GIVEN.
    beforeSample: (item) => {
      if (item.timestamp !== 0) return;
      runningRoots = hooks.pipelineRoots();
      core.finishRecord('imported-record-id');
    },
  });

  await deliver({ type: 'startVideoImport', file: clip() });

  // 1. WHAT THE CORE WAS TOLD. The override is applied where the verdict is taken, so the pipeline physically
  //    cannot write outside it -- and `modules_dir` is deliberately NOT scoped (the models are mounted once).
  const directory = core.startDirectory();
  assert.notEqual(directory.storage_dir, '/work/storage');
  assert.notEqual(directory.temp_dir, '/work/temp');
  assert.match(directory.storage_dir, /^\/work\/import\/\d+\/storage$/);
  assert.match(directory.temp_dir, /^\/work\/import\/\d+\/temp$/);
  assert.equal(directory.modules_dir, '/work/modules');

  // 2. AND THE SWEEP READS THE SAME VALUE. Not a parallel copy that could drift: the roots the worker published
  //    for the running pipeline are the ones it handed the core.
  assert.equal(runningRoots.storage, directory.storage_dir);
  assert.equal(runningRoots.temp, directory.temp_dir);
  // ...and they are handed back when the session ends, so nothing later inherits a deleted directory.
  assert.equal(hooks.pipelineRoots(), hooks.sharedRoots());

  // 3. THE LEFTOVER WAS NEITHER SHIPPED...
  const shipped = importedRecordIds();
  assert.equal(shipped.some((p) => p.includes(LEFTOVER)), false,
    'a leftover under the shared root must not reach Dart through an import');
  assert.deepEqual(shipped, ['chara_detail/active/imported-record-id/record.json']);
  // ...NOR TOUCHED. "Not swept" is only half of it: the sweep also DELETES what it harvested and clears temp,
  // and a sweep aimed at the shared root would have destroyed both of these on its way out.
  assert.equal(memfs.has(LEFTOVER_FILE), true, 'the leftover must survive the import untouched');
  assert.equal(memfs.has('/work/temp/chara_detail/fragment.png'), true,
    'the shared temp dir belongs to whoever is using it, not to the import');

  // 4. And the path it DID ship is relative to the scoped root, i.e. in the same storage-relative form a live
  //    harvest uses -- otherwise Dart rejects every file as being outside the active record layout.
  assert.equal(postedOfType('videoImportDone')[0].reason, 'completed');
});

test('the scoped area is removed on completion, on cancellation and on failure', { timeout: 20000 }, async () => {
  // ALL THREE EXITS, in one test so a fourth cannot be added without noticing that this list is the contract.
  // `scopes` collects the root each import ran on, read off the worker while the import is still open.
  const scopes = [];

  // (a) COMPLETION.
  {
    const memfs = memfsWithLeftover();
    const core = makeCore({ autoDrain: true, memfs });
    await arrange(core, {
      samples: ticks(2),
      beforeSample: (item) => {
        if (item.timestamp !== 0) return;
        scopes.push(hooks.pipelineRoots().scope);
        core.finishRecord('completed-record');
      },
    });
    await deliver({ type: 'startVideoImport', file: clip() });
    assert.equal(postedOfType('videoImportDone')[0].reason, 'completed');
    assertScopeGone(memfs, scopes[0], 'completion');
  }

  // (b) CANCELLATION, from a producer parked at the flow gate -- the state a real cancel lands in.
  {
    const memfs = memfsWithLeftover();
    const core = makeCore({ memfs });
    await arrange(core, { samples: ticks(50) });
    const importing = deliver({ type: 'startVideoImport', file: clip() });
    await settle();
    scopes.push(hooks.pipelineRoots().scope);
    core.finishRecord('cancelled-record');
    deliver({ type: 'cancelVideoImport' });
    await within(3000, importing, 'the cancelled import never ended');
    assert.equal(postedOfType('videoImportDone')[0].reason, 'cancelled');
    assertScopeGone(memfs, scopes[1], 'cancellation');
  }

  // (c) FAILURE: the decode driver throws, so the session ends without ever reaching the sample loop.
  {
    const memfs = memfsWithLeftover();
    const core = makeCore({ memfs });
    await arrange(core, { samples: [], track: null });   // no video track: a refusal raised inside the driver
    await deliver({ type: 'startVideoImport', file: clip() });
    assert.equal(postedOfType('videoImportDone')[0].reason, 'refused');
    // Read after the fact: this import never reached a sample, so the scope has to be taken from the sequence.
    assert.equal(hooks.pipelineRoots(), hooks.sharedRoots(), 'the roots must be back to the shared ones');
    assertNoScopesLeft(memfs, 'failure');
  }

  assert.equal(new Set(scopes).size, scopes.length, 'no two imports may share a scoped root');
});

/// Asserts that `scope` is gone whole, that nothing else under /work/import survived either, and that the shared
/// root came through untouched.
function assertScopeGone(memfs, scope, exit) {
  assert.equal(typeof scope, 'string', exit + ': the import must have had a scoped root at all');
  assert.equal(memfs.paths().some((p) => p === scope || p.startsWith(scope + '/')), false,
    exit + ': the scoped area must be removed whole, files and directories alike');
  assertNoScopesLeft(memfs, exit);
}

function assertNoScopesLeft(memfs, exit) {
  const strays = memfs.paths().filter((p) => p.startsWith('/work/import/') && p.split('/').length > 4);
  assert.deepEqual(strays, [], exit + ': no scoped content may outlive the import');
  assert.equal(memfs.has(LEFTOVER_FILE), true, exit + ': the shared root must be untouched');
  assert.equal(memfs.has('/work/temp/chara_detail/fragment.png'), true, exit + ': and so must the shared temp');
}

test('a start the core refuses leaves no scoped area behind', async () => {
  // The scope is created BEFORE the start (the core may write into it while building the pipeline), so a start
  // the core refuses is the one exit with no teardown to clean up after it. A leak here would accumulate one
  // directory per refused import for the lifetime of the page.
  const memfs = memfsWithLeftover();
  const core = makeCore({ memfs });
  await arrange(core, { samples: ticks(3) });
  await deliver({ type: 'startLive' });
  assert.equal(sessionHooks.sessionOwner(), 'live');

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.match(postedOfType('error')[0].msg, /mutually exclusive/);
  assertNoScopesLeft(memfs, 'a refused start');
  // The LIVE session's roots survive the refused import: nothing about a refusal may re-aim the running session.
  assert.equal(hooks.pipelineRoots(), hooks.sharedRoots());

  sessionHooks.setLiveFrameInFlight(null);
  await deliver({ type: 'stopLive' });
});

test('live capture keeps the shared roots and its config is forwarded byte for byte', async () => {
  // The other half of the isolation, and the one a regression would be silent about: the scoping seam must not
  // rewrite anything for the kind that has always used the shared roots. Asserted on the exact JSON, because
  // "the same values re-asserted" and "the config Dart sent" are different bytes and the worker promises the
  // latter (the Windows runner forwards it untouched too).
  const memfs = memfsWithLeftover();
  const core = makeCore({ memfs });
  await arrange(core, { samples: [] });

  await deliver({ type: 'startLive' });

  assert.equal(core.startConfigs[0], JSON.stringify(INIT_CONFIG));
  assert.equal(hooks.pipelineRoots(), hooks.sharedRoots());

  sessionHooks.setLiveFrameInFlight(null);
  await deliver({ type: 'stopLive' });

  // THE SHARP CASE, because for the config above a rebuilt-but-identical object serialises to the same bytes and
  // could not be told apart. A config with no `directory` block at all can: forwarding it means the core sees
  // exactly what Dart sent and raises its own "missing key" error, whereas rebuilding it would invent
  // `"directory":{}` and change what the core is answering about. Nothing this worker does may edit a config on
  // a session's behalf.
  await deliver({ type: 'setInitConfig', config: { video_mode: false } });
  await deliver({ type: 'startLive' });
  assert.equal(core.startConfigs[1], JSON.stringify({ video_mode: false }));

  sessionHooks.setLiveFrameInFlight(null);
  await deliver({ type: 'stopLive' });
  // A live stop still sweeps the SHARED root, so the leftover it finds there is its own catch -- harvested and
  // removed, exactly as before this change.
  assert.equal(memfs.has(LEFTOVER_FILE), false, 'a live harvest still sweeps the shared root');
});

test('a record finishing during an import reaches Dart through the existing incremental path',
  { timeout: 10000 }, async () => {
    // HOW THE IDS GET TO DART, and deliberately not a second mechanism: the same `liveRecord` message live
    // capture uses, which the web PlatformChannel already persists to OPFS and relays as
    // `onLiveRecordsHarvested` -> addFromFileAsync. What changes for an import is only WHERE the record is read
    // from -- the running pipeline's root -- so the wire format has to come out identical.
    const memfs = memfsWithLeftover();
    const core = makeCore({ memfs });
    await arrange(core, { samples: ticks(50) });

    const importing = deliver({ type: 'startVideoImport', file: clip() });
    await settle();
    core.finishRecord('mid-import-record', ['record.json', 'trainee.jpg']);
    // The per-record harvest fires from the 50 ms drain interval, so what is awaited is a TICK rather than a
    // promise -- but it is awaited by watching for the harvest itself, not by sleeping over a couple of periods.
    await until(() => postedOfType('liveRecord').length > 0, 5000,
      'the drain interval never harvested the record that finished mid-import');

    const shipped = postedOfType('liveRecord');
    assert.equal(shipped.length, 1, 'a record that finishes during an import must ship at once, not at the end');
    assert.equal(shipped[0].recordId, 'mid-import-record');
    assert.deepEqual(shipped[0].files.map((f) => f.path).sort(), [
      'chara_detail/active/mid-import-record/record.json',
      'chara_detail/active/mid-import-record/trainee.jpg',
    ], 'storage-relative to the SCOPED root, so Dart writes it into the real store like any other record');

    deliver({ type: 'cancelVideoImport' });
    await within(3000, importing, 'the import never ended');
    // Read again now the import is over: the wait above ends on the turn the FIRST harvest lands, so "shipped
    // once" is only established by looking after every later drain tick has had its chance.
    assert.equal(postedOfType('liveRecord').length, 1, 'and exactly once -- the end must not ship it a second time');
    assertNoScopesLeft(memfs, 'an incrementally harvested import');
  });

test('a record regeneration is refused while an import owns the loop', async () => {
  // THE ONE COEXISTENCE THE ISOLATION ENDS. A regeneration is a passenger: it stages its inputs into the SHARED
  // root and rides whatever loop is running. An import's loop is built for a root of its own, so the recognizer
  // would look for the record where the import writes -- and staging into the import's root instead is exactly
  // the leftover this whole change exists to make unreachable. Refused up front, rather than left to fail deep
  // in the recognizer with an unrelated message.
  const memfs = memfsWithLeftover();
  const core = makeCore({ memfs });
  await arrange(core, { samples: ticks(50) });

  const importing = deliver({ type: 'startVideoImport', file: clip() });
  await settle();
  const scope = hooks.pipelineRoots().scope;

  await deliver({
    type: 'updateRecord',
    recordId: 'regenerated-record',
    files: [{ path: 'chara_detail/active/regenerated-record/record.json', buffer: new Uint8Array([1]).buffer }],
  });

  const errors = postedOfType('error');
  assert.equal(errors.length, 1);
  assert.match(errors[0].msg, /a video import owns the event loop/);
  assert.equal(errors[0].expected, true, 'refusing a regeneration during an import is an app state, not a bug');
  // NOTHING WAS STAGED, in either root: not in the import's (which the sweep would have shipped as a capture)
  // and not in the shared one (where it would have been orphaned by a handler that returned early).
  assert.equal(memfs.paths().some((p) => p.includes('regenerated-record')), false);
  assert.equal(hooks.pipelineRoots().scope, scope, 'and the running import is untouched');

  deliver({ type: 'cancelVideoImport' });
  await within(3000, importing, 'the import never ended');
});

test('a regeneration is refused for as long as the SCOPED PIPELINE is up, not merely the import session',
  async () => {
    // THE HOLE THE ISOLATION ITSELF CLOSES. `stopVideoImportProducer` clears `videoImportSession` BEFORE its
    // unbounded join of the browser's decode operations, while the import's pipeline -- and `pipelineRoots` --
    // stay up until `flushHarvestStopped` puts them back. A gate keyed on the session handle is therefore open
    // for the whole join, which is exactly as long as a demuxer, a decoder and a bundle fetch take to settle.
    // A regeneration delivered into it was let through, staged into the SHARED root and called
    // `Module.updateRecord` on a pipeline built for the SCOPED one; the record then failed or timed out for a
    // reason no message named. Keying on the roots makes the gate exactly as wide as the condition it describes.
    //
    // The window is held open by parking the module loader, the same way the ownership-before-setup test does.
    const memfs = memfsWithLeftover();
    const core = makeCore({ memfs });
    posted.length = 0;
    hooks.installCore(core);
    const mb = makeMediabunny({ samples: ticks(5) });
    let releaseLoad;
    hooks.setModuleLoader(() => new Promise((resolve) => { releaseLoad = () => resolve(mb.module); }));
    await deliver({ type: 'setInitConfig', config: INIT_CONFIG });

    const importing = deliver({ type: 'startVideoImport', file: clip() });
    let stopping = Promise.resolve();
    try {
      await settle();
      const scope = hooks.pipelineRoots().scope;
      assert.equal(typeof scope, 'string', 'the import must be running on a scoped root');

      stopping = deliver({ type: 'stop' });
      await settle();
      // THE WINDOW ITSELF, asserted before the regeneration is delivered into it: the session handle is already
      // gone and the scoped pipeline is still the running one. A test that skipped this could pass against a
      // gate that never had a hole to close.
      assert.equal(hooks.session(), null, 'the producer stop clears the session handle before it joins');
      assert.equal(hooks.pipelineRoots().scope, scope, 'while the scoped pipeline is still up');

      const regenerating = deliver({
        type: 'updateRecord',
        recordId: 'raced-record',
        files: [{ path: 'chara_detail/active/raced-record/record.json', buffer: new Uint8Array([1]).buffer }],
      });
      await settle();

      const errors = postedOfType('error');
      assert.equal(errors.length, 1);
      assert.match(errors[0].msg, /a video import owns the event loop/);
      assert.equal(errors[0].expected, true);
      assert.deepEqual(core.updates, [],
        'no regeneration may be handed to a pipeline built for the import\'s storage root');
      assert.equal(memfs.paths().some((p) => p.includes('raced-record')), false, 'and nothing may be staged');
      // The refusal is IMMEDIATE. Letting it through does not merely stage in the wrong place: nothing ever
      // completes the update, so the handler burns its full 120 s timeout inside the teardown window.
      await within(1000, regenerating, 'the refusal must be immediate, not a 120 s update timeout');
    } finally {
      releaseLoad();
      await importing;
      await stopping;
    }
    assertNoScopesLeft(memfs, 'a stop that raced a regeneration');
  });

test('an import is refused while a regeneration is in flight, instead of rebuilding the pipeline under it',
  async () => {
    // THE OTHER DIRECTION, and the one whose cost the user pays late. The scoped root is minted fresh per import
    // and is part of the pipeline identity the core compares, so starting an import while a regeneration is in
    // flight rebuilds the pipeline underneath it -- GUARANTEED, not merely possible. Nothing then settles the
    // regeneration's Future until this import's teardown injects an error or the 120 s update timeout fires, and
    // an import commonly outlives 120 s: the ordinary outcome is an unexplained failure (and a Sentry issue) two
    // minutes in, while the import is still running happily. A UI gate is the affordance; this is the guarantee.
    const memfs = memfsWithLeftover();
    const core = makeCore({ memfs });
    await arrange(core, { samples: ticks(3) });

    const regenerating = deliver({
      type: 'updateRecord',
      recordId: 'in-flight-record',
      files: [{ path: 'chara_detail/active/in-flight-record/record.json', buffer: new Uint8Array([1]).buffer }],
    });
    await settle();
    assert.deepEqual(core.updates, ['in-flight-record'], 'the regeneration must really be in flight');

    await deliver({ type: 'startVideoImport', file: clip() });

    const errors = postedOfType('error');
    assert.equal(errors.length, 1);
    assert.match(errors[0].msg, /a record regeneration is in flight/);
    assert.equal(errors[0].expected, true, 'a regeneration in flight is an app state, not a bug');
    // NOTHING WAS TAKEN AND NOTHING WAS BUILT: no claim, no scoped root, no session, and no terminal message for
    // an import that never began.
    assert.equal(core.calls.includes('startCaptureSession'), false, 'the claim must not even be asked for');
    assert.equal(hooks.session(), null);
    assert.equal(hooks.pipelineRoots(), hooks.sharedRoots(), 'the regeneration\'s pipeline must be left alone');
    assert.deepEqual(postedOfType('videoImportDone'), []);
    assertNoScopesLeft(memfs, 'a start refused for a regeneration');

    // And the regeneration goes on to finish normally on the pipeline it started with.
    core.queued.push(JSON.stringify({ type: 'onCharaDetailUpdated', id: 'in-flight-record' }));
    await within(3000, regenerating, 'the regeneration never completed');
    const updated = postedOfType('updated');
    assert.equal(updated.length, 1);
    assert.equal(updated[0].error, undefined, 'the regeneration must not be collateral damage of the refusal');
    assert.deepEqual(updated[0].files.map((f) => f.path), ['chara_detail/active/in-flight-record/record.json']);
  });

test('a start whose core call THROWS leaves no scoped area behind', async () => {
  // The third exit from the claim's door, and the only one with no teardown coming for it. The scope is created
  // BEFORE the start because the core may write into it while building the pipeline, so a throw out of
  // `startCaptureSessionOfKind` (or out of re-serializing the config) strands the directory just minted.
  // Cosmetic on its own -- three empty dirs, and the counter never hands the number out again -- but it is the
  // one exit that would accumulate one of them per attempt for the lifetime of the page.
  const memfs = memfsWithLeftover();
  const core = makeCore({ memfs });
  await arrange(core, { samples: ticks(3) });
  core.startCaptureSessionOfKind = () => { throw new Error('embind: startCaptureSessionOfKind failed'); };

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.match(postedOfType('error')[0].msg, /startCaptureSessionOfKind failed/);
  assertNoScopesLeft(memfs, 'a start whose core call threw');
  assert.equal(hooks.pipelineRoots(), hooks.sharedRoots());
  assert.equal(hooks.session(), null);
  assert.equal(core.isActive(), false, 'and no claim may be left behind either');
});

// --- the duration scan is off the critical path ----------------------------------------------------------------
//
// `computeDuration()` resolves the LAST packet's timestamp, so for a container that declares no duration -- which
// Matroska from OBS routinely is -- it walks the whole file. Awaiting it meant the import produced nothing until a
// full ranged-read pass over a possibly multi-gigabyte clip had finished, and a `cancel` or a `stop` delivered
// into that pass waited it out: the worker joins this producer BEFORE Module.stop(), so every later teardown
// queued behind it for the duration. The fix is metadata first, and the scan started but never awaited.

test('a clip that declares a duration is never scanned for one', async () => {
  // METADATA FIRST. The cheap call answers from the container's own duration element; the scan walks to the last
  // packet of the file. Degrading to "always scan" would be invisible in every other assertion here -- the
  // denominator comes out the same -- while costing a full ranged-read pass over every imported clip, so the
  // property that has to be held down is that the expensive call is NOT MADE.
  const durationCalls = [];
  const core = makeCore({ autoDrain: true });
  await arrange(core, { samples: ticks(2), durationSeconds: 3, durationCalls });

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.deepEqual(durationCalls, ['metadata'], 'a declared duration must not be re-derived by walking the file');
  assert.equal(postedOfType('videoImportProgress')[0].durationMs, 3000);
});

test('a clip that declares no duration decodes without waiting for the duration scan', { timeout: 10000 },
  async () => {
    const core = makeCore({ autoDrain: true });
    let releaseScan;
    const scanStarted = { value: false };
    await arrange(core, {
      samples: ticks(3),
      declaresDuration: false,
      scannedDurationSeconds: 7,
      // The scan is held open for the whole import. If anything awaited it, nothing below would ever run.
      beforeDurationScan: () => new Promise((resolve) => {
        scanStarted.value = true;
        releaseScan = resolve;
      }),
    });

    await within(3000, deliver({ type: 'startVideoImport', file: clip() }),
      'the import waited for the duration scan');

    // THE WHOLE CLIP WAS DECODED while the scan was still pending, and the session ended normally.
    assert.equal(scanStarted.value, true, 'the scan must still be started -- it is deferred, not dropped');
    assert.equal(core.pushes.length, 3);
    assert.equal(postedOfType('videoImportDone')[0].reason, 'completed');
    // Progress fell back to counts, exactly as the message protocol documents for a clip with no duration.
    assert.deepEqual(postedOfType('videoImportProgress').map((p) => p.durationMs), [0, 0]);

    // The abandoned scan settling afterwards must be harmless: no throw, no unhandled rejection, no message.
    const before = postedTypes().length;
    releaseScan();
    await settle();
    assert.equal(postedTypes().length, before, 'a scan that lands after the import must post nothing');
  });

test('a cancel is not delayed by an unresolved duration scan', { timeout: 10000 }, async () => {
  // The teardown consequence of the same defect, and the one that reached past the import: the worker joins this
  // producer before Module.stop(), and every later teardown chains behind that join.
  const core = makeCore();
  const max = sessionHooks.offlineInflightMax();
  let releaseScan;
  await arrange(core, {
    samples: ticks(50),
    declaresDuration: false,
    beforeDurationScan: () => new Promise((resolve) => { releaseScan = resolve; }),
  });

  const importing = deliver({ type: 'startVideoImport', file: clip() });
  await settle();
  assert.equal(core.pushes.length, max, 'the producer must have reached the flow gate with the scan still open');

  deliver({ type: 'cancelVideoImport' });
  await within(3000, importing, 'the cancel waited for the duration scan');

  assert.equal(postedOfType('videoImportDone')[0].reason, 'cancelled');
  assert.equal(sessionHooks.teardownsInFlight(), 0, 'the teardown queue must be idle, not parked on the scan');
  releaseScan();
  await settle();
});

// --- the reason kind ------------------------------------------------------------------------------------------
//
// WHY A KIND TRAVELS BESIDE THE PROSE. Measured in a browser: a user picked a 65-byte text file renamed to
// `.mp4`, and the worker resolved the cause exactly -- "this file is not a video the app can read (65 byte(s);
// its format was not recognised); pick a recording made by a screen or game capture app". Every message
// asserted above is like that one: English, developer-worded, written for a log. What the user was shown was a
// single Japanese line hedging between "an unsupported format" and "another operation is running" -- two
// unrelated causes, neither of them the one that applied. The messages stay exactly as they are; a stable
// discriminator now rides with them, and Dart maps it to one translated sentence per case
// (test/video_import_reason_test.dart pins the other end of that vocabulary).
//
// These tests are the only place the JavaScript half can be caught getting it wrong, and the failure they guard
// against is SILENT: a kind that is misspelt, dropped or routed to the wrong case does not throw anywhere. It
// degrades to the same generic sentence that was the defect in the first place.

test('every refusal the decode driver makes names its own cause, without losing the prose', async () => {
  for (const [spec, kind, pattern] of [
    [{ samples: [], unsupportedFormat: true }, 'not_a_video', /not a video the app can read/],
    [{ samples: [], track: null }, 'no_video_track', /no video track/],
    [{ samples: [], canDecode: false, codec: 'hevc' }, 'codec_unsupported', /cannot decode/],
    [{ samples: [{ timestamp: 0, codedWidth: 4, codedHeight: 2, format: 'I422' }] }, 'pixel_format_unsupported',
      /pixel format the app cannot read/],
  ]) {
    const core = makeCore({ autoDrain: true });
    await arrange(core, spec);

    await deliver({ type: 'startVideoImport', file: clip() });

    const done = postedOfType('videoImportDone').at(-1);
    assert.equal(done.reason, 'refused', kind);
    assert.equal(done.reasonKind, kind, 'the front end has one translated sentence per kind and cannot guess');
    // The English detail is NOT replaced by the kind: it is what the log and a bug report are read from.
    assert.match(done.message, pattern, kind);
  }
});

test('a bundle that will not load names the fetch, not the clip', async () => {
  // Same outcome kind, opposite advice: the user should check their connection and retry the same file, not go
  // looking for a different one. Indistinguishable under the generic line.
  const core = makeCore();
  await arrange(core, { samples: [] });
  hooks.setModuleLoader(async () => { throw new Error('NetworkError when attempting to fetch resource'); });

  await deliver({ type: 'startVideoImport', file: clip() });

  const done = postedOfType('videoImportDone')[0];
  assert.equal(done.reason, 'refused');
  assert.equal(done.reasonKind, 'decoder_unavailable');
});

test('an ordinary ending and a genuine bug name no cause at all', async () => {
  // An empty kind is a decision, not an omission. "Completed" and "cancelled" have nothing to narrow, and a
  // wire-format disagreement between this code and the UA is not something a user can be told to act on -- so
  // both take the outcome's own line rather than being given a cause that would only be invented here.
  const completing = makeCore({ autoDrain: true });
  await arrange(completing, { samples: ticks(2) });
  await deliver({ type: 'startVideoImport', file: clip() });
  const completed = postedOfType('videoImportDone')[0];
  assert.equal(completed.reason, 'completed');
  assert.equal(completed.reasonKind, '');

  const broken = makeCore({ autoDrain: true, refuseLayout: true });
  await arrange(broken, { samples: [{ timestamp: 0, codedWidth: 4, codedHeight: 2, padLayout: true }] });
  await deliver({ type: 'startVideoImport', file: clip() });
  const failed = postedOfType('videoImportDone')[0];
  assert.equal(failed.reason, 'failed');
  assert.equal(failed.reasonKind, '', 'a bug must not be dressed up as something the user did');
});

test('a producer that lost its brake is named on the message that reports it', async () => {
  // The one ending whose `reason` IS its cause. It is a failure and not a refusal -- the clip was importing when
  // it happened -- so the generic failure line would be true but would say nothing about a page that has to be
  // reloaded before another import can work.
  const core = makeCore();
  let swapped = false;
  await arrange(core, {
    samples: ticks(6),
    beforeSample: () => {
      if (swapped) return;
      swapped = true;
      hooks.installCore(makeCore({ counters: false }));
    },
  });

  await deliver({ type: 'startVideoImport', file: clip() });

  const done = postedOfType('videoImportDone')[0];
  assert.equal(done.reason, 'unbraked');
  assert.equal(done.reasonKind, 'unbraked');
});

test('a start refused before a session exists tags its cause into the error message', async () => {
  // NO `videoImportDone` EXISTS ON THIS PATH -- deliberately, for each of these refusals -- so there is no field
  // to put a kind in. The refusal is reported on the worker's generic error channel, which carries no
  // per-operation payload at all, and the client hands the operation it settles the message STRING and nothing
  // else. So the kind rides inside the text and Dart strips it back off (`videoImportReasonInText`). If the two
  // ever stop matching, every one of these falls back to the hedged line without a single test going red
  // anywhere else.
  const cases = [
    ['core_outdated', async () => {
      await arrange(makeCore({ offlinePush: false }), { samples: ticks(3) });
      await deliver({ type: 'startVideoImport', file: clip() });
    }],
    ['core_outdated', async () => {
      await arrange(makeCore({ drainExport: false }), { samples: ticks(3) });
      await deliver({ type: 'startVideoImport', file: clip() });
    }],
    ['core_outdated', async () => {
      await arrange(makeCore({ counters: false }), { samples: ticks(3) });
      await deliver({ type: 'startVideoImport', file: clip() });
    }],
    ['regeneration_in_flight', async () => {
      const core = makeCore({ memfs: memfsWithLeftover() });
      await arrange(core, { samples: ticks(3) });
      const regenerating = deliver({
        type: 'updateRecord',
        recordId: 'in-flight-record',
        files: [{ path: 'chara_detail/active/in-flight-record/record.json', buffer: new Uint8Array([1]).buffer }],
      });
      await settle();
      await deliver({ type: 'startVideoImport', file: clip() });
      core.queued.push(JSON.stringify({ type: 'onCharaDetailUpdated', id: 'in-flight-record' }));
      await within(3000, regenerating, 'the regeneration never completed');
    }],
    ['capture_in_flight', async () => {
      await arrange(makeCore(), { samples: ticks(3) });
      await deliver({ type: 'startLive' });
      await deliver({ type: 'startVideoImport', file: clip() });
      sessionHooks.setLiveFrameInFlight(null);
      await deliver({ type: 'stopLive' });
    }],
  ];
  for (const [kind, run] of cases) {
    await run();
    const refusal = postedOfType('error').find((e) => e.msg.includes('[video_import_reason='));
    assert.notEqual(refusal, undefined, 'an untagged start refusal falls back to the hedged line: ' + kind);
    assert.match(refusal.msg, new RegExp('\\[video_import_reason=' + kind + '\\]$'), refusal.msg);
    // The sentence still leads, so a worker console line still reads as English first.
    assert.match(refusal.msg, /^[a-z]/, refusal.msg);
  }
});

test('a second start is tagged as BUSY, which is not the same situation as an unreadable file', async () => {
  // The exact conflation the browser run found: "another operation is running" and "this file is not a video"
  // were one sentence. They call for opposite actions -- wait, or pick a different file -- so the two paths must
  // not resolve to the same discriminator, whichever side of the session boundary they are refused on.
  const core = makeCore();
  await arrange(core, { samples: ticks(50) });
  const importing = deliver({ type: 'startVideoImport', file: clip() });
  await settle();

  await deliver({ type: 'startVideoImport', file: clip(2048) });

  const busy = postedOfType('error').at(-1);
  assert.match(busy.msg, /\[video_import_reason=already_importing\]$/);
  assert.equal(busy.expected, true);

  deliver({ type: 'cancelVideoImport' });
  await within(3000, importing, 'the running import must still be cancellable after a refused duplicate');
  const done = postedOfType('videoImportDone');
  assert.equal(done.length, 1, 'still exactly one terminal message, for one import');
  assert.equal(done[0].reasonKind, '', 'the cancelled import must not inherit the refusal cause');
});

// --- the ending the CORE classifies: "it finished" and "it produced something" are two facts -----------------
//
// WHAT THESE COVER AND WHAT THEY CANNOT. The rule itself -- a completed run that produced no record is a refusal
// -- lives in C++ (native_api_messages.h videoImportVerdictOf) and is asserted there; `makeCore` models it so
// that what is tested here is the WORKER's half: that it asks at all, that it asks after the join rather than
// where the decode ends, that it relays the answer instead of composing one, and that it declines to claim a
// count it could not have. Nothing in this file loads the real wasm module, so a build whose export is missing
// or whose rule has changed is caught by the pins and by the C++ suite, never here.

test('an import that produced no record is reported as a refusal, not as a completion', async () => {
  // THE DEFECT, DIRECTLY. Every frame decodes, every frame is supplied, and the recognizer writes nothing --
  // a recording of the wrong screen. Before the verdict existed this posted `reason: "completed"`, the capture
  // card treated it as an ordinary success and showed nothing at all, and the user was told the import worked.
  const core = makeCore({ autoDrain: true, records: 0 });
  await arrange(core, { samples: ticks(4) });

  await deliver({ type: 'startVideoImport', file: clip() });

  const done = postedOfType('videoImportDone')[0];
  assert.equal(done.reason, 'refused', 'a run that produced nothing must not be reported as a completion');
  assert.equal(done.reasonKind, 'no_records');
  assert.equal(done.records, 0);
  // The frame counts are untouched: they say the decode worked, which is exactly what makes this ending
  // confusing without the record count beside them.
  assert.equal(done.decoded, 4);
  assert.equal(done.supplied, 4);
});

test('a completed import carries the count the core took, and keeps its completion', async () => {
  const core = makeCore({ autoDrain: true, records: 3 });
  await arrange(core, { samples: ticks(2) });

  await deliver({ type: 'startVideoImport', file: clip() });

  const done = postedOfType('videoImportDone')[0];
  assert.equal(done.reason, 'completed');
  assert.equal(done.reasonKind, '');
  assert.equal(done.records, 3);
});

test('the count is read AFTER the join, so the record the pipeline was still holding is in it', async () => {
  // THE ORDERING HAZARD, FALSIFIED. This clip's only record is produced during the drain -- the barrier's last
  // poll is what writes it -- so a verdict read where the decode ends sees zero and reports a healthy
  // single-record import as `refused/no_records`. Read after `endVideoImport`, it sees one.
  const core = makeCore({
    autoDrain: true, memfs: makeMemfs(), drainPolls: 3, tailRecord: 'tail-record-id', records: 0,
  });
  await arrange(core, { samples: ticks(2) });

  await deliver({ type: 'startVideoImport', file: clip() });

  assert.equal(core.stoppedWhileBusy, false, 'the join must still wait for the barrier');
  assert.equal(core.recordsProduced(), 1, 'the tail record exists only because the teardown waited');
  const done = postedOfType('videoImportDone')[0];
  assert.equal(done.reason, 'completed', 'the tail record is what makes this a completion');
  assert.equal(done.records, 1);
});

test('the clip is announced as ended before the pipeline is joined, and its notification goes out first',
  async () => {
    // TWO PROPERTIES OF ONE SIGNAL. `endOfInput` is what closes a chara-detail session the clip left open, so it
    // has to reach the core BEFORE the drain barrier and the join -- otherwise the very notification it produces
    // is what the barrier was supposed to wait for. And that notification has to leave the worker BEFORE
    // `videoImportDone`: the Dart side counts the sessions that ended empty as they arrive and closes the tally
    // when the terminal message lands (video_import_ops.dart VideoImportSessionTally), so one that arrived after
    // it would be counted into nothing and the run would report that it had lost nothing.
    const core = makeCore({
      autoDrain: true,
      records: 1,
      // What the real core does when the input ends on an open scene: the scraper's session is closed unfinished,
      // which is announced as a failed finish plus the error tag the front end translates.
      onEndOfInput: (c) => {
        c.queued.push(JSON.stringify({ type: 'onCharaDetailFinished', id: 'half-captured', success: false }));
        c.queued.push(JSON.stringify({ type: 'onError', message: 'closed_before_completed' }));
      },
    });
    await arrange(core, { samples: ticks(2) });

    await deliver({ type: 'startVideoImport', file: clip() });

    assert.equal(core.calls.indexOf('endOfInput') < core.calls.indexOf('stop'), true,
      'the end of the clip must reach the core before the loop is joined');
    const types = postedTypes();
    const lastNotify = types.lastIndexOf('notify');
    const terminal = types.indexOf('videoImportDone');
    assert.notEqual(lastNotify, -1, 'the close must produce a notification at all');
    assert.equal(lastNotify < terminal, true,
      'a session event after the terminal message is counted into a tally that has already closed');
    const relayed = postedOfType('notify').map((m) => JSON.parse(m.json).type);
    assert.deepEqual(relayed, ['onCharaDetailFinished', 'onError']);
  });

test('a healthy import whose ending a stop took over is NOT reported as having produced nothing', async () => {
  // THE ONE PATH WITH NO BARRIER OF ITS OWN. A `stop` delivered while the driver is disposing its demuxer finds
  // an outcome that is already `completed`, revokes the session and takes the ending over -- so the producer's
  // handler reports at once, with the pipeline still holding this clip's records. A verdict read unconditionally
  // there counts zero and rewrites a perfectly good import into `refused/no_records`. The core's own drain
  // predicate is what stops it: not drained, so no count is claimed and the ending is relayed as it stands.
  let releaseDispose;
  const disposeGate = () => new Promise((resolve) => { releaseDispose = resolve; });
  // `drainPolls` above zero is a pipeline that still holds work at the moment the ending is reported, and
  // `records: 0` is the undercount a naive read would take there.
  const core = makeCore({ autoDrain: true, drainPolls: 5, records: 0 });
  await arrange(core, { samples: ticks(2), disposeGate });

  const importing = deliver({ type: 'startVideoImport', file: clip() });
  await settle();
  assert.equal(releaseDispose !== undefined, true, 'the driver must be parked in dispose, past its outcome');

  const stopping = deliver({ type: 'stop' });
  await settle();
  releaseDispose();
  await within(3000, Promise.all([importing, stopping]), 'the stop never joined the completed producer');

  const done = postedOfType('videoImportDone');
  assert.equal(done.length, 1);
  assert.notEqual(done[0].reason, 'refused', 'an unread count must never be reported as an empty import');
  assert.equal(done[0].reason, 'completed');
  assert.equal('records' in done[0], false,
    'an unread count is absent, not stated as zero: this side must not report a number it never took');
  assert.equal(core.calls.includes('videoImportVerdict'), false,
    'the verdict must not even be asked for while the pipeline still holds work');
});

test('an import is refused on a core that predates the end-of-clip signal and the verdict', async () => {
  // FAIL-CLOSED, like the drain barrier and the offline push before it. Such a core imports every clip that
  // yields records perfectly well and is silent about exactly the two endings this change exists to report, so
  // running degraded would work for everyone who did not need it and fail invisibly for everyone who did.
  await arrange(makeCore({ terminalExports: false }), { samples: ticks(3) });

  await deliver({ type: 'startVideoImport', file: clip() });

  const refusal = postedOfType('error').at(-1);
  assert.match(refusal.msg, /\[video_import_reason=core_outdated\]$/);
  assert.match(refusal.msg, /endOfInput and Module\.videoImportVerdict/);
  assert.equal(refusal.expected, true, 'a stale local artifact is an app state, not a crash report');
  assert.deepEqual(postedOfType('videoImportDone'), [], 'no import started, so it has no ending to report');
});
