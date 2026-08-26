// Node coverage for the web worker's content-freshness measurement (web/worker.js), the input the capture
// page's "the shared picture is not changing" notice is computed from.
//
// Why this exists at all: the measurement used to be a hash of 256 fixed points of each frame, which reads
// about one pixel in two thousand at 1080p. A screen with one small moving element -- a spinner, a counter, a
// character's idle animation -- scored "identical" on that grid, so a working capture could be reported as
// frozen and (before the notice was made advisory) stopped. No browser run would have caught it: the frames
// were arriving, the picture was moving, and the only wrong thing was which pixels were looked at. That is a
// property to hold down off a browser, on exact pixels, which is what this file does.
//
// The verdict built ON these numbers is Dart's (`shouldNoticeLiveContentFreeze`, with its own truth table in
// test/live_content_freeze_test.dart). Nothing here asserts about thresholds.

import assert from 'node:assert/strict';
import test from 'node:test';

// web/worker.js is a module worker: it reads `self` at load time and installs its handlers on it. Stand one up
// before the import so the module body can run in Node.
globalThis.self = {
  postMessage() {},
  onmessage: null,
  onerror: null,
  onunhandledrejection: null,
};
const { __previewRelayTestHooks, __liveContentTestHooks } = await import('../web/worker.js');
// The preview relay owns a module-lifetime MessageChannel that keeps Node alive; close it even though this
// file never drives the relay.
test.after(() => __previewRelayTestHooks().closeYieldChannel());

const live = __liveContentTestHooks();

// A 320x180 pane's worth of RGBA, which is 57600 pixels: small enough to build per frame, and far more than
// the 256 points the old sampled hash would have looked at.
const WIDTH = 320;
const HEIGHT = 180;
const SIZE = WIDTH * HEIGHT * 4;

/// Fills `buf` with a deterministic picture. `mutateAt`, when given, changes the single pixel at that index --
/// this is the "one small thing moved" case the sampled hash was blind to.
function paint(seed, mutateAt) {
  return (buf) => {
    for (let i = 0; i < buf.length; i += 4) {
      const v = (i * 2654435761 + seed) & 0xff;
      buf[i] = v;
      buf[i + 1] = v ^ 0x5a;
      buf[i + 2] = v ^ 0xa5;
      buf[i + 3] = 0xff;
    }
    if (mutateAt !== undefined) buf[mutateAt * 4] ^= 0x01;
  };
}

/// Feeds `count` frames of the same picture, one every 33 ms of simulated time, starting at `startMs`.
/// Returns the time of the last frame.
function supplyIdentical(count, startMs, mutateAt) {
  let now = startMs;
  for (let i = 0; i < count; i++) {
    live.supplyFrame(SIZE, now, paint(1, mutateAt));
    now += 33;
  }
  return now - 33;
}

test('a still picture accumulates a run in real time and in repeats', () => {
  live.reset(0);
  const last = supplyIdentical(11, 1000);

  // Eleven frames, ten of which repeated their predecessor, spanning 330 ms.
  assert.equal(live.run(last).repeats, 10);
  assert.equal(live.run(last).runMs, 330);
});

test('the very first frame of a session starts no run', () => {
  live.reset(0);
  live.supplyFrame(SIZE, 1000, paint(1));

  assert.equal(live.run(1000).repeats, 0);
  assert.equal(live.run(1000).runMs, 0);
});

test('one changed pixel anywhere ends the run -- including the last pixel of the frame', () => {
  // THE regression this file exists for. A single pixel is 1/57600 of this frame; the sampled hash read 256
  // points and would have called both of these identical.
  for (const at of [0, 1, WIDTH * HEIGHT - 1, ((WIDTH * HEIGHT) / 2) | 0]) {
    live.reset(0);
    supplyIdentical(5, 1000);
    assert.equal(live.run(1132).repeats, 4, `setup failed for pixel ${at}`);

    live.supplyFrame(SIZE, 1165, paint(1, at));
    assert.equal(live.run(1165).repeats, 0, `a change at pixel ${at} did not end the run`);
    assert.equal(live.run(1165).runMs, 0);
  }
});

test('the run resumes from the changed frame, not from the start of the session', () => {
  live.reset(0);
  supplyIdentical(5, 1000);
  live.supplyFrame(SIZE, 1165, paint(2));       // a new picture
  live.supplyFrame(SIZE, 1198, paint(2));       // ... which then repeats
  live.supplyFrame(SIZE, 1231, paint(2));

  assert.equal(live.run(1231).repeats, 2);
  assert.equal(live.run(1231).runMs, 1231 - 1165);
});

test('a frame size change starts a fresh run instead of comparing incomparable geometry', () => {
  live.reset(0);
  supplyIdentical(5, 1000);
  assert.equal(live.run(1132).repeats, 4);

  const otherSize = (WIDTH + 2) * HEIGHT * 4;
  live.supplyFrame(otherSize, 1165, paint(1));
  assert.equal(live.run(1165).repeats, 0);

  // ... and the frames after the resize are compared with each other normally.
  live.supplyFrame(otherSize, 1198, paint(1));
  assert.equal(live.run(1198).repeats, 1);
});

test('a copy that throws leaves the previous frame intact as the comparison partner', () => {
  // Gecko can throw from copyTo on an element-derived frame. The buffer it half-wrote must not become what the
  // next frame is compared against, or one bad frame would report a content change that never happened.
  live.reset(0);
  supplyIdentical(3, 1000);
  assert.equal(live.run(1066).repeats, 2);

  live.supplyFrame(SIZE, 1099, (buf) => {
    buf[0] = 0x7f;      // a partial write, as a throwing copyTo would leave behind
    return false;       // ... and then it threw
  });

  // The next frame carries the same picture as before the failure, so the run continues across it.
  live.supplyFrame(SIZE, 1132, paint(1));
  assert.equal(live.run(1132).repeats, 3);
  assert.equal(live.run(1132).runMs, 132);
});

test('a run is cleared when supply resumes, so a suspension cannot be measured as stillness', () => {
  // resetLiveContentRun is what handleLiveSupply calls on an `enabled:true` transition. Minimising the shared
  // window and restoring it shows the same picture on either side of the gap, and that must not read as a run
  // spanning the whole suspension.
  live.reset(0);
  supplyIdentical(5, 1000);
  assert.equal(live.run(1132).repeats, 4);

  live.resetRun(61132);                          // a minute later, supply comes back
  live.supplyFrame(SIZE, 61132, paint(1));       // the same picture the gap started with

  assert.equal(live.run(61132).repeats, 0);
  assert.equal(live.run(61132).runMs, 0);
});
