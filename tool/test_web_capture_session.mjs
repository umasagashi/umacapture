// Node coverage for the web worker's capture-session lifecycle (web/worker.js): WHEN the core's session claim is
// given back relative to the teardown, and what a `startLive` that lands in the middle of a teardown does.
//
// Why this exists at all: the claim used to be released at the TOP of the teardown, before the in-flight frame
// was joined and long before the harvest copied the session's records out of MEMFS. `self.onmessage` is not
// serialized across an await, so a start arriving in that window found the core with nothing to refuse and
// rebuilt the pipeline of a session whose records were still sitting there. The properties that close it are
// orderings across awaits -- release the claim last, and make a racing start wait the teardown out -- and an
// ordering is exactly what a browser run demonstrates worst: the window is milliseconds wide and opens only when
// a stop and a start collide. Here the race is deterministic, because this file owns the teardown's only await
// (`liveFrameInFlight`) and delivers the racing message while it is still pending.
//
// The Windows runner holds `capture_mutex` across the same teardown and gets the same outcome from the lock
// (windows/runner/native_controller.h); it has a thread to block and this worker does not, which is why the
// worker needs the two mechanisms asserted below.

import assert from 'node:assert/strict';
import test from 'node:test';

// web/worker.js is a module worker: it reads `self` at load time and installs its handlers on it. Stand one up
// before the import so the module body can run in Node. Every message this worker posts is recorded, because
// what the UI would see (`liveStarted`, `stopped`, `error`) is half of what is under test here.
const posted = [];
let harvestPostThrows = false;
globalThis.self = {
  postMessage(message) {
    posted.push(message);
    // The one seam that makes the harvest fail: harvestAndCleanup ships its files with exactly this message, and
    // every FS call it makes is individually try/caught, so a throwing FS cannot model a failing harvest.
    if (message && message.type === 'harvest' && harvestPostThrows) throw new Error('harvest post failed');
  },
  onmessage: null,
  onerror: null,
  onunhandledrejection: null,
};
const { __previewRelayTestHooks, __captureSessionTestHooks } = await import('../web/worker.js');
const hooks = __captureSessionTestHooks();

test.after(() => {
  // Two module-lifetime handles that would otherwise keep the Node process alive after the tests finish: the
  // preview relay's MessageChannel and the drain loop a live session starts.
  __previewRelayTestHooks().closeYieldChannel();
  hooks.stopDrainLoop();
});

/// A stub core recording the lifecycle calls in order. The start implements the real policy
/// (NativeApi::startCaptureSession / CaptureSessionPolicy) over a local TYPED claim, so "already open" and
/// "another kind holds it" mean here what they mean there.
///
/// `kinded` chooses which exports the core offers. A real core offers both -- the kind-taking pair carries a new
/// NAME precisely because worker.js's compatibility guard is a `typeof` test that cannot see a changed signature
/// -- so `kinded: false` models an older pinned web/wasm/ that has only the original pair. Both spellings record
/// the SAME strings in `calls`, so the ordering assertions below say nothing about which export was used; which
/// one was used is recorded separately, in `startedKinds` / `releasedKinds`, and only the tests that are about
/// that read them.
/// `counters` chooses whether the core publishes the frame-flow counter addresses. A real core publishes them,
/// so the default is true; `counters: false` models the build that must not be allowed to run an OFFLINE session
/// at all, because on that build the video-mode queue is unbounded and nothing brakes the producer.
function makeCore({ stopThrows = false, kinded = true, counters = true } = {}) {
  let activeKind = null;
  let running = false;
  const calls = [];
  const startedKinds = [];
  const releasedKinds = [];
  const start = (kind) => {
    if (activeKind !== null) {
      if (activeKind === kind) {
        calls.push('startCaptureSession:alreadyStarted');
        return { verdict: 'alreadyStarted', message: '' };
      }
      // CaptureSessionPolicy::mutualExclusionMessage, verbatim in shape: the refusal the core builds so both
      // front ends say the same thing about the same situation.
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
    // The kind each start ASKED FOR, recorded only by the kind-taking export. An empty array therefore means the
    // worker never reached that export -- which is what "the fallback was used" looks like from here.
    startedKinds,
    // Likewise for the release: empty means every release went through the untyped endAny export.
    releasedKinds,
    isActive: () => activeKind !== null,
    activeKind: () => activeKind,
    endCaptureSession() {
      calls.push('endCaptureSession');
      // endAny: releases whatever is held, without naming it.
      activeKind = null;
    },
    isRunning: () => running,
    stop() {
      calls.push('stop');
      if (stopThrows) throw new Error('joinEventLoop threw');
      running = false;
    },
    // Drained by the module-lifetime interval as well as by the teardown, so it is deliberately NOT recorded:
    // its call count is a function of wall-clock timing, not of the ordering under test.
    drainMessages: () => [],
    // The harvest sweeps an empty MEMFS: what this file asserts is WHEN the harvest runs, not what it finds.
    FS: {
      readdir: () => [],
      stat: () => ({ mode: 0 }),
      isDir: () => false,
      unlink() {},
      rmdir() {},
    },
  };
  if (kinded) {
    core.startCaptureSessionOfKind = (kind) => {
      startedKinds.push(kind);
      return start(kind);
    };
    // CaptureSessionPolicy::end: a release from a party that does not hold the claim is IGNORED, not obeyed.
    core.endCaptureSessionOfKind = (kind) => {
      calls.push('endCaptureSession');
      releasedKinds.push(kind);
      if (activeKind === kind) activeKind = null;
    };
  }
  if (counters) {
    // The producer-side brake, published exactly as the core publishes it: a shared heap plus the two BYTE
    // offsets (the worker converts to Int32 indices with >>> 2). Present on every core an offline session is
    // allowed to run against; see makeFlowCore below for the arithmetic tests that drive it in anger.
    core.HEAP32 = new Int32Array(new SharedArrayBuffer(8));
    core.frameFlowEnqueuedAddress = () => 0;
    core.frameFlowDequeuedAddress = () => 4;
  }
  // The original, untyped start. Present on a kinded core too -- the real core keeps it working for older
  // callers -- so "the kinded one is preferred" is a statement about the worker, not about what exists.
  core.startCaptureSession = () => start('live');
  return core;
}

/// Delivers one worker message. Returns the handler's promise WITHOUT awaiting it, so a caller can hold a
/// teardown open and deliver the next message into the middle of it.
function deliver(message) {
  return self.onmessage({ data: message });
}

/// Drains macrotask turns until the worker has gone QUIET, so "still parked" means parked rather than merely
/// not resumed yet.
///
/// THE WINDOW IS DERIVED FROM THE RUN, NOT PICKED. Nearly every `settle()` below backs an assertion of
/// ABSENCE -- "the start did not open a session", "the core was not even asked" -- and an absence observed
/// over a window nobody derived says nothing: a start that had simply not been scheduled yet reads exactly
/// like a start that is correctly waiting the teardown out. Nor can the window be a count of turns written
/// down here, because the paths it waits out hop through real macrotasks -- worker.js's MessageChannel
/// `macrotaskYield` (web/worker.js), its `setInterval` drain and supply timers, and
/// `Atomics.waitAsync` -- so how many turns they take is a property of web/worker.js that moves the day
/// someone adds a hop. A literal here would stop reaching the end of the path with nothing to say so, which
/// is the one change this helper exists to keep covering.
///
/// The positive control is the worker's own voice. `posted` is everything it emits, and every step of a
/// start and of a teardown goes through it (`liveStarted`, `harvest`, `stopped`, plus the `log` line each
/// path writes on the way). So a start that was NOT waiting -- the failure these assertions exist to be able
/// to see -- announces itself, and announcing is what keeps this loop turning. The loop stops only once the
/// worker has been silent for at least as many turns as it was busy, so the quiet has to hold for as long as
/// the activity took to establish it.
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

/// Installs a fresh core and takes the worker through a real `startLive`, leaving one live session open.
async function startSession(core) {
  posted.length = 0;
  harvestPostThrows = false;
  hooks.installCore(core);
  // The real config path: `setInitConfig` is what Dart uses between sessions, and startConfigJson refuses a
  // config that was never installed.
  await deliver({ type: 'setInitConfig', config: { video_mode: false } });
  await deliver({ type: 'startLive' });
  assert.equal(hooks.sessionOwner(), 'live');
  return core;
}

/// The types of the messages the worker posted, in order, ignoring the log chatter. Protocol messages travel as
/// JSON strings (`post`); only the binary-carrying ones (`harvest`) are posted as objects.
function postedTypes() {
  return posted
    .map((m) => (typeof m === 'string' ? JSON.parse(m).type : m.type))
    .filter((t) => t !== 'log');
}

test('a start delivered mid-teardown waits it out and opens a fresh session, claim released last', async () => {
  const core = await startSession(makeCore());

  // Park the teardown on its only await: the frame the producer is still processing.
  let releaseFrame;
  hooks.setLiveFrameInFlight(new Promise((resolve) => { releaseFrame = resolve; }));
  const stopping = deliver({ type: 'stopLive' });
  let starting = Promise.resolve();
  // Every assertion taken while the teardown is parked runs inside this try, and the `finally` unparks it. An
  // assertion that throws with the frame still pending would otherwise leave a teardown in flight forever --
  // and the very mechanism under test then makes every later `startLive` wait on it, so the whole file would
  // HANG instead of failing. A test that cannot fail loudly is worth nothing in CI.
  try {
    // (a) The claim is NOT back yet, and nothing has been joined or harvested either.
    assert.deepEqual(core.calls, ['startCaptureSession']);
    assert.equal(hooks.teardownInFlight(), true);
    assert.equal(hooks.sessionOwner(), null, 'the local supply gate closes at the top of the teardown');

    // A start lands in exactly the window the defect lived in.
    starting = deliver({ type: 'startLive' });
    await settle();
    assert.equal(hooks.sessionOwner(), null, 'the start must wait, not open a session over an unharvested one');
    assert.deepEqual(core.calls, ['startCaptureSession'], 'the core is not even asked while the teardown runs');
    assert.equal(postedTypes().filter((t) => t === 'liveStarted').length, 1,
      'the waiting start has not acknowledged: a second liveStarted here is the ghost session');
  } finally {
    releaseFrame();
    await stopping.catch(() => {});
    await starting.catch(() => {});
  }

  // (b) The claim goes back after the join and after the harvest -- and the waiting start then opens a real
  // session, the outcome Windows gets by blocking the start on `capture_mutex`.
  assert.deepEqual(core.calls, ['startCaptureSession', 'stop', 'endCaptureSession', 'startCaptureSession']);
  assert.equal(hooks.sessionOwner(), 'live');
  assert.equal(core.isActive(), true);
  // The harvest is a posted message rather than a core call, so its position is asserted on the post stream:
  // it precedes `stopped`, and the claim above was released after both.
  assert.deepEqual(postedTypes(), ['liveStarted', 'harvest', 'stopped', 'liveStarted']);

  // Leave no session open for the next test.
  hooks.setLiveFrameInFlight(null);
  await deliver({ type: 'stopLive' });
});

test('the harvest runs before the claim goes back', async () => {
  const core = await startSession(makeCore());
  // Ordering across the two channels: the harvest post must land while the claim is still held.
  const claimHeldAtHarvest = [];
  const inner = self.postMessage;
  self.postMessage = function (message) {
    if (message && message.type === 'harvest') claimHeldAtHarvest.push(core.isActive());
    return inner.call(this, message);
  };
  try {
    await deliver({ type: 'stopLive' });
  } finally {
    self.postMessage = inner;
  }
  assert.deepEqual(claimHeldAtHarvest, [true], 'harvested while the session claim was still held');
  assert.deepEqual(core.calls, ['startCaptureSession', 'stop', 'endCaptureSession']);
});

test('a throwing Module.stop still hands the claim back, exactly once', async () => {
  const core = await startSession(makeCore({ stopThrows: true }));

  await deliver({ type: 'stopLive' });

  assert.equal(core.calls.filter((c) => c === 'endCaptureSession').length, 1);
  assert.equal(core.isActive(), false, 'a held claim would answer every later start as a duplicate');
  assert.equal(hooks.teardownInFlight(), false, 'a teardown that threw must still release its waiters');
  assert.equal(postedTypes().includes('error'), true, 'the failure is still reported to the UI');
  // The next session starts normally rather than being answered as a duplicate of the one that failed to stop.
  await deliver({ type: 'startLive' });
  assert.equal(hooks.sessionOwner(), 'live');
  assert.equal(core.calls.filter((c) => c === 'startCaptureSession').length, 2);
  hooks.setLiveFrameInFlight(null);
  await deliver({ type: 'stopLive' });
});

test('a throwing harvest still hands the claim back, exactly once', async () => {
  const core = await startSession(makeCore());
  harvestPostThrows = true;

  await deliver({ type: 'stopLive' });
  harvestPostThrows = false;

  assert.equal(core.calls.filter((c) => c === 'endCaptureSession').length, 1);
  assert.equal(core.isActive(), false);
  assert.deepEqual(core.calls, ['startCaptureSession', 'stop', 'endCaptureSession']);
  assert.equal(hooks.teardownInFlight(), false);
  // The assertions above hold on the SUCCESSFUL path too, so on their own they would pass against a seam that
  // silently went inert (the harvest is individually try/caught almost everywhere; if this one reachable throw
  // ever stops throwing, this test must go red rather than quietly stop testing anything). The post stream is
  // what separates the two: the throw escapes flushHarvestStopped after the `finally` released the claim but
  // BEFORE the `stopped` post, and onmessage reports it as `error`.
  assert.deepEqual(postedTypes(), ['liveStarted', 'harvest', 'error']);
});

test('a teardown that throws does not kill a start waiting on it', async () => {
  // The combination is the point: neither a throwing teardown alone nor a waiting start alone shows this. The
  // set holds SETTLE-ONLY views of the teardowns precisely so that awaiting them cannot inherit a failure; with
  // the teardowns' own promises in the set, `Promise.all` inside awaitTeardownInFlight rejects, that rejection
  // propagates out of handleStartLive, and one failed stop silently converts an unrelated, already-granted start
  // into a second `error` -- no session opens at all.
  const core = await startSession(makeCore({ stopThrows: true }));

  let releaseFrame;
  hooks.setLiveFrameInFlight(new Promise((resolve) => { releaseFrame = resolve; }));
  const stopping = deliver({ type: 'stopLive' });
  let starting = Promise.resolve();
  try {
    starting = deliver({ type: 'startLive' });
    await settle();
    assert.equal(hooks.sessionOwner(), null, 'the start must still be parked on the failing teardown');
  } finally {
    releaseFrame();
    await stopping.catch(() => {});
    await starting.catch(() => {});
  }
  await settle();

  // The teardown's failure reaches the UI exactly once, as its own `error`; the start behind it then succeeds.
  assert.deepEqual(postedTypes(), ['liveStarted', 'error', 'liveStarted']);
  assert.equal(hooks.sessionOwner(), 'live', 'the waiting start must open a session, not inherit the failure');
  assert.equal(core.isActive(), true);
  assert.equal(core.calls.filter((c) => c === 'startCaptureSession').length, 2);

  hooks.setLiveFrameInFlight(null);
  await deliver({ type: 'stopLive' });
});

// An explicit timeout, because the failure mode under test IS hanging: node:test does not time a test out by
// default, so a bound that stops firing would leave this file wedged rather than red.
test('a teardown that never finishes degrades the start instead of hanging it', { timeout: 5000 }, async () => {
  // The bound is WALL CLOCK, not a count of teardowns: a count only advances when a teardown settles, so it
  // never fires for the case that matters -- stopLiveProducer joins the in-flight frame with no timeout, and
  // that frame is the browser's `copyTo`. Parking it forever is exactly that case.
  const core = await startSession(makeCore());
  const productionWaitMaxMs = hooks.teardownWaitMaxMs();
  // The production value is anchored to Dart's own `_startLiveTimeout` (60 s, lib/src/core/wasm_worker_client.dart)
  // and must stay ABOVE it: below, a teardown that is merely slow -- one that would have finished inside Dart's
  // budget and yielded a REAL session -- is converted into the degraded ghost asserted below instead.
  //
  // WHAT THIS PINS, AND WHAT IT DOES NOT. Node cannot read the Dart constant, so 60000 is a TRANSCRIPT of it,
  // not a reference to it. The assertion therefore holds one side of the relationship only: lowering the
  // worker's bound under 60 s reddens here, but RAISING `_startLiveTimeout` past the worker's 90 s breaks the
  // same relationship and nothing anywhere reddens -- no test on either side of the boundary compares the two
  // values. Anyone moving `_startLiveTimeout` has to move this number by hand.
  assert.equal(productionWaitMaxMs > 60000, true,
    'the start must not degrade while Dart is still waiting for it (_startLiveTimeout = 60 s)');
  hooks.setTeardownWaitMaxMs(30);
  let releaseFrame;
  hooks.setLiveFrameInFlight(new Promise((resolve) => { releaseFrame = resolve; }));
  const stopping = deliver({ type: 'stopLive' });
  let starting = Promise.resolve();
  try {
    starting = deliver({ type: 'startLive' });
    // RACED, not awaited. The failure mode under test is a start that never answers, and awaiting it directly
    // would wedge this file rather than fail it: node:test's own timeout marks the test failed but does not
    // cancel the body, so the `finally` below would never unpark the teardown and every later test would then
    // wait on it too. 500 ms is long enough for a 30 ms bound to fire many times over.
    const answered = await Promise.race([starting.then(() => true, () => true), sleep(500).then(() => false)]);
    assert.equal(answered, true, 'the start never answered: the bound did not fire on a stuck teardown');
    assert.equal(hooks.teardownsInFlight(), 1, 'the teardown really is still stuck');
    // DEGRADED, and asserted as such: the claim is still held, so the core answers this start as a duplicate and
    // the session it acknowledges has no frame producer. That is the documented cost of not hanging forever.
    assert.deepEqual(postedTypes(), ['liveStarted', 'liveStarted']);
    assert.equal(core.calls.filter((c) => c === 'startCaptureSession:alreadyStarted').length, 1);
    assert.equal(hooks.sessionOwner(), null);
  } finally {
    hooks.setTeardownWaitMaxMs(productionWaitMaxMs);
    releaseFrame();
    await stopping.catch(() => {});
    await starting.catch(() => {});
  }
  await settle();
  assert.equal(hooks.teardownsInFlight(), 0);
  assert.equal(core.isActive(), false);
});

test('overlapping teardowns are both tracked and serialized, and neither releases the claim early', async () => {
  const core = await startSession(makeCore());

  // Park the first teardown on the frame the producer is still processing.
  let releaseFrame;
  hooks.setLiveFrameInFlight(new Promise((resolve) => { releaseFrame = resolve; }));
  const stoppingLive = deliver({ type: 'stopLive' });
  let stopping = Promise.resolve();
  // Same discipline as the first test: every assertion taken while a teardown is parked runs inside this try,
  // and the `finally` unparks it, so a failed assertion fails loudly instead of hanging the file.
  try {
    assert.equal(hooks.teardownsInFlight(), 1);

    // The `stop` behind it takes handleStop's ELSE branch -- the parked teardown has already cleared
    // `sessionOwner` and the pull timer -- so nothing makes it await, and with single-slot bookkeeping it
    // overwrote and then cleared the parked teardown's entry a microtask later, leaving waiters seeing an idle
    // worker while a teardown was still running.
    stopping = deliver({ type: 'stop' });
    await settle();
    assert.equal(hooks.teardownsInFlight(), 2, 'a short teardown must not evict the parked one from the set');
    assert.equal(hooks.teardownInFlight(), true, 'a waiter must not see an idle worker here');
    assert.deepEqual(core.calls, ['startCaptureSession'],
      'the queued teardown must not join the loop while the first is still awaiting its in-flight frame');
    assert.equal(core.isActive(), true, 'the claim must not go back while a teardown is still parked');
    assert.equal(postedTypes().includes('stopped'), false);
  } finally {
    releaseFrame();
    await stoppingLive.catch(() => {});
    await stopping.catch(() => {});
  }
  await settle();

  // Both ran, in order, and the tracking is empty only once BOTH are done.
  assert.equal(hooks.teardownsInFlight(), 0);
  // The join happens once, in the first teardown. The second finds a joined loop AND a claim already handed
  // back, so it releases nothing -- it used to call the untyped endAny a second time, harmlessly, because the
  // worker had no way to know whether it still held anything. It knows now (`claimedKind`, written at the
  // claim's only door), and with a typed claim "release without knowing what you hold" is exactly the operation
  // that can take a video import's session away from it, so the redundant second release is gone rather than
  // kept as a no-op.
  assert.deepEqual(core.calls, ['startCaptureSession', 'stop', 'endCaptureSession']);
  assert.deepEqual(core.releasedKinds, ['live'], 'and the one release that did happen named its kind');
  assert.equal(core.isActive(), false);
  assert.equal(hooks.sessionOwner(), null);
});

// Property 2 of the worker's rule (see `currentTeardownToken`) is the one thing here that guards against a
// FUTURE handler rather than against the code as written: every teardown that exists today goes through
// `runTeardown`, so nothing in this file reached the check until now -- deleting it outright left the other seven
// tests green. What it has to catch is the handler video import will add, written by hand and forgetting to
// register, and the sub-case below is why the check cannot be a flag: a flag is TRUE for the whole of a parked
// teardown, which is exactly when an unregistered one does the damage.
test('a teardown that never registered is refused, even while a registered one is parked', async () => {
  const core = await startSession(makeCore());

  // (a) IDLE. Nothing is running, so this sub-case is caught by any guard, flag or token.
  assert.throws(() => hooks.unregisteredFlushHarvestStopped(), /outside runTeardown/);
  assert.deepEqual(core.calls, ['startCaptureSession'], 'a refused teardown must tear nothing down');
  assert.equal(core.isActive(), true);
  assert.equal(hooks.sessionOwner(), 'live', 'nor close the live supply gate');

  // (b) DELIVERED INTO A PARKED TEARDOWN -- the round-two defect. The registered teardown is parked on its
  // in-flight frame, i.e. it has NOT yet joined the loop or harvested; an unregistered one waved through here
  // runs `Module.stop()` + `endCaptureSession` underneath it, which is the very race the rule exists to prevent.
  let releaseFrame;
  hooks.setLiveFrameInFlight(new Promise((resolve) => { releaseFrame = resolve; }));
  const stopping = deliver({ type: 'stopLive' });
  // Same discipline as the tests above: assert inside a try whose `finally` unparks, or a failed assertion hangs
  // the file instead of failing it.
  try {
    assert.equal(hooks.teardownsInFlight(), 1, 'the registered teardown really is parked');
    assert.throws(() => hooks.unregisteredFlushHarvestStopped(), /outside runTeardown/,
      'an unregistered teardown must be refused even though a registered one is running');
    // The other half of "identity, not merely non-null": a token that was not the installed one is no better
    // than none, so a handler cannot mint its own way past the check.
    assert.throws(() => hooks.unregisteredFlushHarvestStopped({}), /outside runTeardown/);
    assert.deepEqual(core.calls, ['startCaptureSession'],
      'the refused calls must not join the loop the parked teardown is still holding open');
    assert.equal(core.isActive(), true, 'nor hand back the claim that teardown still owns');
    assert.equal(postedTypes().includes('stopped'), false);
  } finally {
    releaseFrame();
    await stopping.catch(() => {});
  }
  await settle();

  // The registered teardown is untouched by the refusals: it joins, harvests and hands the claim back as usual.
  assert.deepEqual(core.calls, ['startCaptureSession', 'stop', 'endCaptureSession']);
  assert.deepEqual(postedTypes(), ['liveStarted', 'harvest', 'stopped']);
  assert.equal(hooks.teardownsInFlight(), 0);
  assert.equal(core.isActive(), false);
});

// --- the second session kind: the core's exports, and what the worker asks them ------------------------------
//
// These cover the boundary a video import will call, before the import front end exists. The point of every one
// of them is that the EXCLUSION lives in the core: until the kind-taking export is reached, the only thing
// keeping a second web session out of a running one is `sessionOwner`, one variable in this one file, whereas
// Windows has had the invariant under a mutex all along.

test('the kinded start is preferred when the core offers it, and it names the kind', async () => {
  const core = await startSession(makeCore());

  assert.deepEqual(core.startedKinds, ['live'],
    'a core offering startCaptureSessionOfKind must be asked through it, not through the untyped export');
  assert.equal(hooks.claimedKind(), 'live', 'the worker must remember the kind it claimed, for the release');

  hooks.setLiveFrameInFlight(null);
  await deliver({ type: 'stopLive' });
  // The release names the same kind. This is what stops a live teardown from dropping an import's claim: the
  // core ignores a release from a party that does not hold it (CaptureSessionPolicy::end), and it can only do
  // that if the release says who it is.
  assert.deepEqual(core.releasedKinds, ['live']);
  assert.equal(hooks.claimedKind(), null);
  assert.equal(core.isActive(), false);
});

test('a core without the kinded exports still runs live capture, and cannot open an import', async () => {
  // An older pinned web/wasm/ (tool/web_deps.json): the `typeof` guard sees the missing export, and live capture
  // must keep working exactly as it does today rather than refusing every start.
  const core = await startSession(makeCore({ kinded: false }));

  assert.deepEqual(core.startedKinds, [], 'the fallback path must not have reached the kinded export');
  assert.deepEqual(core.calls, ['startCaptureSession']);
  assert.equal(hooks.sessionOwner(), 'live');
  assert.equal(hooks.claimedKind(), 'live');

  // An IMPORT against such a core is refused rather than falling back. The fallback opens a LIVE session -- that
  // is all the untyped export can do -- so serving an import through it would hand the caller a live session it
  // did not ask for, built with the wrong queue mode, and every cross-kind refusal afterwards would be about a
  // claim labelled wrongly.
  const verdict = await hooks.startCaptureSessionVerdict('import probe', 'videoImport');
  assert.equal(verdict.verdict, 'refused');
  assert.match(verdict.message, /predates Module\.startCaptureSessionOfKind/);
  assert.deepEqual(core.calls, ['startCaptureSession'], 'the core must not have been asked to start anything');
  assert.equal(hooks.claimedKind(), 'live', 'and the live claim is untouched');

  hooks.setLiveFrameInFlight(null);
  await deliver({ type: 'stopLive' });
  assert.deepEqual(core.releasedKinds, [], 'with no kinded release export, the untyped one is the fallback');
  assert.deepEqual(core.calls, ['startCaptureSession', 'stop', 'endCaptureSession']);
  assert.equal(core.isActive(), false);
});

test('a cross-kind start is refused by the CORE, not by sessionOwner', async () => {
  const core = await startSession(makeCore());
  assert.equal(hooks.sessionOwner(), 'live');

  // Asked through the claim's only door, which consults `sessionOwner` NOWHERE -- so a refusal here can only
  // have come from the core. That is the whole point: a JS-side owner check would be a second policy, and the
  // two front ends would be free to disagree about the same request again.
  const verdict = await hooks.startCaptureSessionVerdict('import probe', 'videoImport');

  assert.equal(verdict.verdict, 'refused');
  assert.match(verdict.message, /mutually exclusive/);
  assert.deepEqual(core.startedKinds, ['live', 'videoImport'], 'the core really was asked, and asked by kind');
  assert.deepEqual(core.calls, ['startCaptureSession', 'startCaptureSession:refused']);
  assert.equal(core.activeKind(), 'live', 'the running session must be left completely alone');
  assert.equal(hooks.sessionOwner(), 'live');
  assert.equal(hooks.claimedKind(), 'live', 'a refused start must not overwrite the claim the worker holds');

  hooks.setLiveFrameInFlight(null);
  await deliver({ type: 'stopLive' });

  // And with the live session gone the same request is granted, so the refusal was about the conflict and not
  // about the kind being unsupported.
  const second = await hooks.startCaptureSessionVerdict('import probe', 'videoImport');
  assert.equal(second.verdict, 'started');
  assert.equal(hooks.claimedKind(), 'videoImport');
  assert.equal(core.activeKind(), 'videoImport');
  assert.equal(hooks.sessionOwner(), null, 'an import takes no LIVE supply ownership');

  // Released by hand: there is no import teardown handler yet. It also demonstrates the half that matters most
  // once there is one -- the release names videoImport, so a live teardown running beside it cannot take it.
  hooks.releaseSession('test cleanup');
  assert.deepEqual(core.releasedKinds, ['live', 'videoImport']);
  assert.equal(core.isActive(), false);
});

// --- the offline producer's flow gate ------------------------------------------------------------------------
//
// The brake that makes the offline queue mode safe. An import session builds the pipeline with video_mode=true,
// and on Emscripten that is QueueLimitMode::NoLimit -- never blocks, never drops -- so the only thing bounding
// memory is this gate parking the decode loop on the core's frame-flow counters. Node can hold down the
// arithmetic and the wake, which is the part that was never covered before (the removed implementation had no
// automated coverage of its parking gate at all).
//
// WHAT THE COUNTERS MEAN, because the gate is only as good as the number it reads: their difference is the
// frames RESIDENT IN THE FRAME PATH -- the distributor's queue depth PLUS the scraper's -- and the core counts
// each of those two hops at both of its own ends (core/frame_flow_counters.h). An earlier draft counted the
// scraper's hop alone, which read 0 through the entire lead-in while the distributor's queue grew; the model
// below is the two-hop one, so a `noteDistributorDequeued` that failed to move the figure would be caught here
// rather than in a browser at the end of a five-minute clip.

/// A core that publishes only the two counters, over a real SharedArrayBuffer so the gate runs its real
/// `Atomics.waitAsync` path rather than a stand-in for it. The note* helpers below are named for the four real
/// call sites, so a test reads as a frame path rather than as two opaque numbers.
function makeFlowCore({ counters = true } = {}) {
  const heap = new Int32Array(new SharedArrayBuffer(8));
  const bumpDequeued = () => { Atomics.add(heap, 1, 1); Atomics.notify(heap, 1); };
  const core = {
    HEAP32: heap,
    // Hop 1 in: NativeApi::updateFrame's accepted send onto the distributor's queue.
    notePushed: () => Atomics.add(heap, 0, 1),
    // Hop 1 out: FrameDistributor::update, on the distributor runner.
    noteDistributed: bumpDequeued,
    // Hop 2 in: CharaDetailSceneContext's accepted send onto the scraper's queue.
    noteForwarded: () => Atomics.add(heap, 0, 1),
    // Hop 2 out: the chara_detail_updated listener, on the scraper thread.
    noteScraped: bumpDequeued,
    // What NativeApi::teardownLocked does: zero both halves AND wake, because a teardown is the one way the
    // frame path empties with no dequeue to do it.
    noteTornDown: () => { Atomics.store(heap, 0, 0); Atomics.store(heap, 1, 0); Atomics.notify(heap, 1); },
    // The drain loop is module-lifetime and an earlier test's live session started it, so it keeps ticking over
    // whichever core is installed. Without this it would throw on every beat from outside any test's scope.
    drainMessages: () => [],
  };
  if (counters) {
    // Byte offsets, exactly as the exports return them; the worker converts to Int32 indices with >>> 2.
    core.frameFlowEnqueuedAddress = () => 0;
    core.frameFlowDequeuedAddress = () => 4;
  }
  return core;
}

test('the flow gate reads the resident frame count off the core counters', async () => {
  const core = makeFlowCore();
  hooks.installCore(core);
  const max = hooks.offlineInflightMax();

  assert.equal(hooks.offlineFramesInFlight(), 0);
  for (let i = 0; i < max; i++) core.notePushed();
  assert.equal(hooks.offlineFramesInFlight(), max);
  core.noteDistributed();
  assert.equal(hooks.offlineFramesInFlight(), max - 1,
    'the figure is enqueued MINUS dequeued: a gate reading only one counter would never fall');

  // Below the limit: no parking at all, and the gate reports that a brake exists.
  assert.equal(await hooks.awaitOfflineFrameRoom(), true);
});

test('the lead-in is measured: frames the distributor has not taken yet count as resident', async () => {
  // THE HOLE THIS CLOSES. Before a chara-detail scene commits, nothing is ever forwarded to the scraper, so a
  // brake watching the scraper's hop alone read exactly 0 for the whole lead-in -- menus, loading, every frame
  // before the detail screen -- while a hardware decoder piled multi-megabyte frames onto the distributor's
  // queue. Here not one frame reaches the scraper, and the gate still parks.
  const core = makeFlowCore();
  hooks.installCore(core);
  const max = hooks.offlineInflightMax();

  for (let i = 0; i < max; i++) core.notePushed();
  assert.equal(hooks.offlineFramesInFlight(), max, 'a queue the scraper never sees is still a queue');

  let resumed = false;
  const waiting = hooks.awaitOfflineFrameRoom().then((gated) => { resumed = true; return gated; });
  try {
    await settle();
    assert.equal(resumed, false, 'the producer must park on the distributor backlog alone');

    // The distributor catches up. It forwards nothing onward, so the ONLY thing that can release the gate is
    // hop 1's own dequeue being counted.
    core.noteDistributed();
    const released = await Promise.race([waiting.then(() => true), sleep(500).then(() => false)]);
    assert.equal(released, true, 'a distributor dequeue must lower the figure and wake the producer');
  } finally {
    Atomics.store(core.HEAP32, 0, 0);
    Atomics.notify(core.HEAP32, 1);
    await waiting.catch(() => {});
  }
});

test('both hops count, so a frame in the handover is never invisible', async () => {
  // A frame moving from the distributor's queue to the scraper's is resident the whole way. If the handover
  // dropped it from the figure, a producer could push a fresh frame for every frame in flight and the real
  // resident count would be double what the gate believes.
  const core = makeFlowCore();
  hooks.installCore(core);

  core.notePushed();
  assert.equal(hooks.offlineFramesInFlight(), 1);
  core.noteDistributed();
  core.noteForwarded();
  assert.equal(hooks.offlineFramesInFlight(), 1, 'the handover must not make the frame vanish');
  core.noteScraped();
  assert.equal(hooks.offlineFramesInFlight(), 0);

  // And both queues holding frames at once adds up, because both hold whole decoded frames alive.
  for (let i = 0; i < 5; i++) core.notePushed();
  for (let i = 0; i < 2; i++) { core.noteDistributed(); core.noteForwarded(); }
  assert.equal(hooks.offlineFramesInFlight(), 5);
});

test('a teardown releases a parked producer without waiting for the timeout', async () => {
  // The gate's `Atomics.waitAsync` timeout is a safety net against a missed wake, NOT the mechanism. A teardown
  // is the one event that empties the frame path with no dequeue to do it, so the core's reset has to wake the
  // waiters itself (FrameFlowCounters::reset); without that wake, an import stopped mid-clip would sit parked
  // until the timeout expired, and the timeout would silently have become the mechanism.
  //
  // What this can and cannot see: it pins the JS half -- that a zeroing plus a notify releases the gate -- and
  // it models what the core does at teardown. It cannot observe the C++ futex wake itself, which compiles only
  // under __EMSCRIPTEN__.
  const core = makeFlowCore();
  hooks.installCore(core);
  for (let i = 0; i < hooks.offlineInflightMax() + 2; i++) core.notePushed();

  let resumed = false;
  const waiting = hooks.awaitOfflineFrameRoom().then((gated) => { resumed = true; return gated; });
  try {
    await settle();
    assert.equal(resumed, false);

    core.noteTornDown();
    const released = await Promise.race([waiting.then(() => true), sleep(500).then(() => false)]);
    assert.equal(released, true, 'a teardown must release the gate, not leave it to the waitAsync timeout');
    assert.equal(hooks.offlineFramesInFlight(), 0);
  } finally {
    Atomics.store(core.HEAP32, 0, 0);
    Atomics.notify(core.HEAP32, 1);
    await waiting.catch(() => {});
  }
});

// An explicit timeout and a raced await, for the reason the degraded-teardown test above has them: a gate whose
// depth arithmetic is wrong NEVER RESUMES, so awaiting it directly wedges this file instead of failing it. Found
// exactly that way -- breaking `offlineFramesInFlight` to read one counter hung the run rather than reddening it.
test('the flow gate parks at the limit and resumes when the pipeline drains', { timeout: 5000 }, async () => {
  const core = makeFlowCore();
  hooks.installCore(core);
  const max = hooks.offlineInflightMax();
  for (let i = 0; i < max + 3; i++) core.notePushed();

  let resumed = false;
  const waiting = hooks.awaitOfflineFrameRoom().then((gated) => { resumed = true; return gated; });
  try {
    await settle();
    assert.equal(resumed, false, 'a full pipeline must park the producer, not wave it through');

    // One dequeue is not enough -- the figure is still over the limit. This is what separates a real depth gate
    // from one that resumes on any wake at all.
    core.noteScraped();
    await settle();
    assert.equal(resumed, false);

    for (let i = 0; i < 3; i++) core.noteScraped();
    const released = await Promise.race([waiting.then(() => true), sleep(500).then(() => false)]);
    assert.equal(released, true, 'the gate never resumed: it is not reading the figure it claims to read');
    assert.equal(hooks.offlineFramesInFlight() < max, true);
  } finally {
    // Unwedge the gate whatever the assertions did. Its loop re-arms itself on a 30 ms waitAsync timeout, so a
    // still-parked producer would keep the Node event loop alive for the rest of the run; zeroing the enqueued
    // counter empties the frame path under every possible definition of it.
    Atomics.store(core.HEAP32, 0, 0);
    Atomics.notify(core.HEAP32, 1);
    await waiting.catch(() => {});
  }
});

test('a core with no counters offers no brake, and says so rather than pretending', async () => {
  // NOT a silent no-op: an offline session against such a build would run the unbounded queue with nothing
  // holding it back, which is worse than either alternative, so the caller has to be able to tell.
  hooks.installCore(makeFlowCore({ counters: false }));
  assert.equal(hooks.offlineFramesInFlight(), 0);
  assert.equal(await hooks.awaitOfflineFrameRoom(), false);
});

// --- a missing brake is a refusal, at the claim's door -------------------------------------------------------

test('an offline session is refused outright on a core that publishes no counters', async () => {
  // THE TRAP: `typeof Module.startCaptureSessionOfKind === 'function'` says NOTHING about whether the counters
  // were exported. Exports are feature-detected one at a time, and web/wasm/ is a separately refreshed artifact,
  // so a core CAN offer the kinded start and not the counters. An import that only checked the start would open
  // QueueLimitMode::NoLimit -- never blocks, never drops -- and feed it as fast as a hardware decoder runs.
  //
  // The refusal is checked at the claim's only door rather than left to the import front end, so whoever writes
  // that front end cannot forget it: the start it has to call already refuses on its behalf.
  const core = makeCore({ counters: false });
  hooks.installCore(core);

  const verdict = await hooks.startCaptureSessionVerdict('import probe', 'videoImport');

  assert.equal(verdict.verdict, 'refused');
  assert.match(verdict.message, /no frame-flow counters/);
  assert.deepEqual(core.startedKinds, [], 'the core must not be asked to open a session it cannot brake');
  assert.equal(core.isActive(), false);
  assert.equal(hooks.claimedKind(), null, 'a refused start must not leave a claim behind');
});

test('live capture is unaffected by the brake requirement', async () => {
  // The brake belongs to OFFLINE producers only. Live capture runs Discard mode -- the core sheds load itself --
  // and there is no way to slow a live source down anyway, so requiring counters of it would refuse a session
  // that is in no danger. A gate written as "refuse when the counters are missing" rather than "refuse when an
  // OFFLINE kind's counters are missing" would break every live start against an older pinned core.
  const core = makeCore({ counters: false });
  hooks.installCore(core);

  const verdict = await hooks.startCaptureSessionVerdict('live probe', 'live');

  assert.equal(verdict.verdict, 'started');
  assert.deepEqual(core.startedKinds, ['live']);
  assert.equal(hooks.claimedKind(), 'live');

  hooks.releaseSession('test cleanup');
  assert.equal(core.isActive(), false);
});

// --- releasing the claim: stranded, never stolen --------------------------------------------------------------

test('a release whose core call throws strands the claim rather than risking a retry that steals one', () => {
  // Two bad outcomes, and the code picks the less bad one deliberately. Clearing `claimedKind` BEFORE the core
  // call means a throw leaves this worker owning nothing and nothing retrying -- one stranded claim, visible as
  // every later start of that kind being answered `alreadyStarted`. Clearing it AFTER would leave a retry armed,
  // and if the first call HAD released, that retry would end whatever session of the same kind started since --
  // silently, because a release names a kind and not a session.
  const core = makeCore();
  core.endCaptureSessionOfKind = () => { throw new Error('release threw'); };
  hooks.installCore(core);
  core.startCaptureSession();
  // Take the claim through the worker's own bookkeeping, so this exercises the real release path.
  return hooks.startCaptureSessionVerdict('claim', 'live').then(() => {
    assert.equal(hooks.claimedKind(), 'live');

    assert.throws(() => hooks.releaseSession('throwing release'), /release threw/);

    assert.equal(hooks.claimedKind(), null, 'the claim must be given up locally even when the core call throws');
    // And a second release is a no-op rather than a retry: there is nothing left that could name a kind.
    const callsBefore = core.calls.length;
    hooks.releaseSession('second release');
    assert.equal(core.calls.length, callsBefore, 'a stranded claim must not be retried against the core');
  });
});

test('a release with no core instance clears the local claim instead of dangling it', async () => {
  // Module is nulled when the one-time setup fails and rolls back (setupOnce). The core instance that held the
  // claim is gone with it, so there is nothing to hand back -- and leaving `claimedKind` set would aim a later
  // release at a DIFFERENT core, which never took that claim.
  const core = makeCore();
  hooks.installCore(core);
  await hooks.startCaptureSessionVerdict('claim', 'live');
  assert.equal(hooks.claimedKind(), 'live');

  hooks.installCore(null);
  hooks.releaseSession('module gone');

  assert.equal(hooks.claimedKind(), null);
  assert.deepEqual(core.releasedKinds, [], 'a released module cannot be called, only forgotten');

  // A fresh core starts clean: it is asked for its own claim and is never handed the previous one's release.
  const next = makeCore();
  hooks.installCore(next);
  hooks.releaseSession('nothing held');
  assert.deepEqual(next.releasedKinds, []);
  await hooks.startCaptureSessionVerdict('claim again', 'live');
  assert.equal(hooks.claimedKind(), 'live');
  hooks.releaseSession('test cleanup');
  assert.deepEqual(next.releasedKinds, ['live']);
});

// -------------------------------------------------------------------------------------------------------------
// THE ONE-TIME SETUP, when two `init`s overlap.
//
// Same property as everything above -- `self.onmessage` is async and dispatches every message on its own
// independent call -- applied to the one handler that takes SECONDS to finish. The setup builds the wasm module,
// the ORT sessions and the inference pump, all module-lifetime; a second `init` delivered before the first one
// finished used to build a second of each. The pump is the part that corrupts results rather than only memory:
// the bridge has no compare-and-swap, so two pumps service the SAME published request and the late one's ST_DONE
// can answer the NEXT one with the previous request's output.
//
// It is reachable without a debug console: the Dart client's init timeout drops its ready completer without
// terminating the worker, so the next `_ensureReady()` posts a second `init` into a setup that is still running.
//
// `init` is the one message that needs real module URLs, which is why no test above drives it. Node imports a
// `data:` URL, so the two stubs below are installed as globals and reached through one-line modules.

const SETUP_ST_REQUEST = 1, SETUP_ST_DONE = 2;
const SETUP_W_MODEL = 1, SETUP_W_H = 2, SETUP_W_W = 3, SETUP_W_C = 4, SETUP_W_OUTCOUNT = 5;

const dataModule = (source) => 'data:text/javascript,' + encodeURIComponent(source);
const setupCoreUrl = dataModule('export default async () => globalThis.__testCoreFactory();');
// Both stubs DELEGATE on every call rather than re-exporting the globals: Node caches a module by URL, so the
// second test's import returns the first test's evaluation, and a binding captured at evaluation time would keep
// answering with the stubs the previous test already tore down.
const setupOrtUrl = dataModule(
  'export const env = { wasm: {} };'
  + 'export const InferenceSession = { create: (b, o) => globalThis.__testOrt.InferenceSession.create(b, o) };'
  + 'export class Tensor { constructor(type, data, dims) { this.type = type; this.data = data; this.dims = dims; } }');

/// A core just complete enough for `init`: the MEMFS calls it makes, the bridge it wires, and a SHARED control
/// block the pump can really run against (Atomics needs a SharedArrayBuffer, and the pump is the thing under
/// test). Every count is on the shared `tally` so two module instantiations are distinguishable from one.
function installSetupStubs(tally) {
  const heap = new SharedArrayBuffer(4096);
  const HEAP32 = new Int32Array(heap);
  globalThis.__testCoreFactory = async () => {
    tally.cores++;
    await new Promise((resolve) => setTimeout(resolve, 0));
    return {
      HEAP32,
      HEAPU8: new Uint8Array(heap),
      HEAPF64: new Float64Array(heap),
      FS: { mkdir: () => {}, writeFile: () => { tally.moduleFiles++; } },
      setupInferenceBridge: () => {
        tally.bridges++;
        // controlPtr 0 / stateIndex 0 puts the state cell at HEAP32[0]; the request and response blocks sit far
        // enough past the control words that nothing overlaps.
        return { controlPtr: 0, requestPtr: 256, responsePtr: 1024, stateIndex: 0 };
      },
      isRunning: () => false,
      drainMessages: () => [],
    };
  };
  // `run` PARKS instead of returning, and the count is taken as it is entered. That is what makes a second pump
  // observable rather than merely likely: the first pump cannot store ST_DONE while it is parked, so a second one
  // still reads ST_REQUEST and services the same request -- which is the defect itself, not a proxy for it.
  let releaseRun = null;
  const runGate = new Promise((resolve) => { releaseRun = resolve; });
  globalThis.__testOrt = {
    InferenceSession: {
      create: async () => {
        tally.sessions++;
        await new Promise((resolve) => setTimeout(resolve, 0));
        return {
          inputNames: ['in'],
          outputNames: ['out'],
          inputMetadata: [{ name: 'in', shape: [1, 1, 1, 1] }],
          run: async () => {
            tally.inferences++;
            await runGate;
            return { out: { data: [0.5] } };
          },
        };
      },
    },
  };
  return { HEAP32, releaseRun: () => releaseRun() };
}

function setupInitMessage() {
  return {
    type: 'init',
    coreUrl: setupCoreUrl,
    ortRuntimeUrl: setupOrtUrl,
    ortWasmDir: '/ort/',
    config: { video_mode: false },
    moduleFiles: [{ path: 'version_info.json', buffer: new ArrayBuffer(2) }],
    ortModels: [{ key: 'skill/prediction.onnx', buffer: new ArrayBuffer(4) }],
  };
}

/// Drives the overlapping pair of `init`s and leaves the worker set up. Returns the shared control block and the
/// release for the parked inference, so each test below asserts its own half of the outcome over the same run.
async function driveOverlappingInits(tally) {
  posted.length = 0;
  hooks.resetSetup();
  self.crossOriginIsolated = true;
  const stubs = installSetupStubs(tally);
  // Both delivered before either is awaited: the first suspends on the core import, and the second is dispatched
  // into the middle of it exactly as a `message` event would be.
  const first = deliver(setupInitMessage());
  const second = deliver(setupInitMessage());
  // The precondition, stated WITHOUT reference to the coalescing: the second init was dispatched while the first
  // setup had not finished. Read off `setupComplete`, which exists either way, so a build that coalesces nothing
  // still reaches the assertions below instead of failing here and reporting the wrong thing.
  assert.equal(hooks.setupComplete(), false, 'the second init has to land mid-setup, or this proves nothing');
  await Promise.all([first, second]);
  assert.equal(hooks.setupComplete(), true);
  return stubs;
}

/// Undoes everything driveOverlappingInits installed. `resetSetup` is the PRODUCTION rollback, so what it leaves
/// behind is what a failed setup leaves behind and nothing test-shaped.
async function teardownSetupStubs(releaseRun) {
  // Released before the rollback: a pump parked inside `run` would otherwise resume into a nulled Module.
  releaseRun();
  await settle();
  hooks.resetSetup();
  hooks.stopDrainLoop();
  delete self.crossOriginIsolated;
  delete globalThis.__testCoreFactory;
  delete globalThis.__testOrt;
}

test('a second init delivered into a running setup joins it instead of building a second of everything',
  { timeout: 10000 }, async () => {
    const tally = { cores: 0, sessions: 0, bridges: 0, moduleFiles: 0, inferences: 0 };
    const { releaseRun } = await driveOverlappingInits(tally);
    try {
      assert.equal(hooks.setupInFlight(), false, 'a finished attempt must retract itself');
      assert.deepEqual(
        { cores: tally.cores, sessions: tally.sessions, bridges: tally.bridges },
        { cores: 1, sessions: 1, bridges: 1 },
        'a second module strands the first instance and its pthreads, and re-creates every ORT session');
      // The joiner is answered, not ignored: Dart is waiting on a `ready` for each `init` it posted.
      assert.deepEqual(postedTypes(), ['ready', 'ready']);
    } finally {
      await teardownSetupStubs(releaseRun);
    }
  });

test('one published inference request is serviced ONCE after two overlapping inits', { timeout: 10000 },
  async () => {
    const tally = { cores: 0, sessions: 0, bridges: 0, moduleFiles: 0, inferences: 0 };
    const { HEAP32, releaseRun } = await driveOverlappingInits(tally);
    try {
      // The defect itself rather than a proxy for it. The bridge has no compare-and-swap, so a second pump reads
      // the same ST_REQUEST the first is still working on; `run` parks, so the first cannot store ST_DONE while
      // the second looks -- which is the ordering that lets the late ST_DONE answer the NEXT request with this
      // request's output, and that is a misrecognition with nothing in any log to show for it.
      HEAP32[SETUP_W_MODEL] = 0;
      HEAP32[SETUP_W_H] = 1; HEAP32[SETUP_W_W] = 1; HEAP32[SETUP_W_C] = 1;
      HEAP32[SETUP_W_OUTCOUNT] = 1;
      Atomics.store(HEAP32, 0, SETUP_ST_REQUEST);
      await settle();
      assert.equal(tally.inferences, 1, 'a second pump serviced the request the first one was already servicing');

      releaseRun();
      await settle();
      assert.equal(Atomics.load(HEAP32, 0), SETUP_ST_DONE, 'the single pump still answers the request');
    } finally {
      await teardownSetupStubs(releaseRun);
    }
  });
