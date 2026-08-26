// Node coverage for what is LEFT in JavaScript on the web capture path, after the shaping geometry and then
// the live preview both moved into the shared core.
//
// The even-alignment rule, the copy plan and the pane-anchor arithmetic are no longer testable from here: they
// live in native/src/core/frame_shaping.h and are swept exhaustively by
// native/test/core/test_native_api_frame_shaping.cpp, which is the same input domain this file used to loop
// over. The preview's five decisions (enable gate, expected-vs-actual gate, throttle, fit geometry, staleness
// re-check) went the same way, into LivePreviewPolicy (native/src/core/native_api.h), and are driven by
// native/test/core/test_native_api_preview.cpp.
//
// So what is tested here is what is genuinely left on this side, and only that:
//   * the WebCodecs `copyTo` options object (web/frame_shaping.mjs), which the core has no notion of; and
//   * the worker's preview RELAY (web/worker.js) -- that it forwards the switch to the core verbatim, forwards
//     whatever frame the core hands back, and forwards NOTHING when the core hands back nothing.
// The second group tests a negative -- this side decides nothing about the preview -- which is exactly the
// property that grows back quietly if nothing holds it down. It runs off a browser because the relay has no
// browser dependency left; a real ImageBitmap/VideoFrame path could not have been tested this way.

import assert from 'node:assert/strict';
import test from 'node:test';

import { rgbaCopyOptions } from '../web/frame_shaping.mjs';

// web/worker.js is a module worker: it reads `self` at load time and installs its handlers on it. Stand one up
// before the import so the module body can run in Node, and capture what it posts.
const posted = [];
globalThis.self = {
  postMessage(message, transfer) { posted.push({ message, transfer }); },
  onmessage: null,
  onerror: null,
  onunhandledrejection: null,
};
const { __previewRelayTestHooks } = await import('../web/worker.js');
const relay = __previewRelayTestHooks();
test.after(() => relay.closeYieldChannel());

test('a full-frame copy omits the WebCodecs rect option entirely', () => {
  const options = rgbaCopyOptions(673, null);
  assert.equal(Object.hasOwn(options, 'rect'), false);
  assert.deepEqual(options, { format: 'RGBA', layout: [{ offset: 0, stride: 673 * 4 }] });
});

test('a cropped copy spells the rect and packs the stride to the copied width', () => {
  assert.deepEqual(rgbaCopyOptions(8, { x: 10, y: 20, width: 8, height: 10 }), {
    format: 'RGBA',
    layout: [{ offset: 0, stride: 32 }],
    rect: { x: 10, y: 20, width: 8, height: 10 },
  });
});

// --- the worker's preview relay -----------------------------------------------------------------------------
// A stand-in for the wasm core: it records what the worker asked it to do and hands back whatever frames the
// test queued. `setPreviewEnabled` collects its whole argument list, so a worker that started telling the core
// a preview size again (the thing that used to be duplicated on both sides) fails on arity alone.
function fakeCore(frames = []) {
  const switchCalls = [];
  return {
    switchCalls,
    setPreviewEnabled: (...args) => switchCalls.push(args),
    takePreviewFrame: () => (frames.length === 0 ? null : frames.shift()),
  };
}

function previewPosts() {
  return posted.filter((p) => p.message && p.message.type === 'previewFrame');
}

test('the preview switch is relayed to the core verbatim, and carries no size', () => {
  const core = fakeCore();
  relay.installCore(core);
  relay.handlePreviewPreference({ type: 'preview', enabled: true, cropped: true });
  relay.handlePreviewPreference({ type: 'preview', enabled: false, cropped: false });
  // Exactly two arguments each: the box (576x320) and the cadence are LivePreviewPolicy's alone.
  assert.deepEqual(core.switchCalls, [[true, true], [false, false]]);
});

test('a switch posted before the core exists is remembered, not lost', () => {
  relay.installCore(null);
  relay.handlePreviewPreference({ type: 'preview', enabled: true, cropped: true });
  const core = fakeCore();
  relay.installCore(core);
  relay.applyPreviewPreference();
  assert.deepEqual(core.switchCalls, [[true, true]]);
});

test('one core frame is forwarded unchanged, with its buffer transferred', () => {
  posted.length = 0;
  const bgra = new Uint8Array([1, 2, 3, 255, 4, 5, 6, 255]);
  relay.installCore(fakeCore([{ width: 2, height: 1, bgra }]));
  relay.drainCorePreviewFrame();
  const frames = previewPosts();
  assert.equal(frames.length, 1);
  // The worker restates nothing about the frame: the size it posts is the size the core stamped on it.
  assert.deepEqual(frames[0].message, { type: 'previewFrame', width: 2, height: 1, bgra });
  assert.deepEqual(frames[0].transfer, [bgra.buffer]);
});

// The load-bearing negative. A frame in the slot is forwarded EVEN WITH THE SWITCH OFF, because the slot can
// only ever hold what the core's own enable gate already allowed through. Re-testing the preference here would
// be a second gate -- the exact duplication this stage removed -- and a stale one, since the core's copy of the
// switch is the authoritative one. Without this case a re-grown `if (!previewDesiredEnabled) return;` passes
// every other test in this file.
test('the relay does not second-guess the core: an off switch does not suppress a frame the core produced', () => {
  posted.length = 0;
  const bgra = new Uint8Array([9, 8, 7, 255]);
  const core = fakeCore([{ width: 1, height: 1, bgra }]);
  relay.installCore(core);
  relay.handlePreviewPreference({ type: 'preview', enabled: false, cropped: false });
  relay.drainCorePreviewFrame();
  assert.equal(previewPosts().length, 1);
});

test('an empty slot posts nothing at all', () => {
  posted.length = 0;
  relay.installCore(fakeCore([]));
  const before = relay.counters();
  relay.drainCorePreviewFrame();
  relay.drainCorePreviewFrame();
  assert.deepEqual(previewPosts(), []);
  assert.equal(relay.counters().emitted, before.emitted);
  assert.equal(relay.counters().errors, before.errors);
});

test('a throwing core costs one preview frame and nothing else', () => {
  posted.length = 0;
  const before = relay.counters();
  relay.installCore({
    setPreviewEnabled: () => {},
    takePreviewFrame: () => { throw new Error('core is unhappy'); },
  });
  relay.drainCorePreviewFrame();  // must not throw: a preview failure never fails the frame
  assert.deepEqual(previewPosts(), []);
  assert.equal(relay.counters().errors, before.errors + 1);
});

test('a core build predating the preview exports degrades to a no-op', () => {
  posted.length = 0;
  relay.installCore({});
  relay.handlePreviewPreference({ type: 'preview', enabled: true, cropped: false });
  relay.drainCorePreviewFrame();
  assert.deepEqual(previewPosts(), []);
});
