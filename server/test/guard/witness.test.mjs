// The instrument check (guard/src/witness.mjs): t_p from the guard's own control events cell by cell, the
// gaps a run records (at once when a later cell proves the loss, or at the horizon), and the reading of
// an Analytics answer. Pure; the Analytics answers are built here.

import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { parseAnalytics } from "../../guard/src/analytics.mjs";
import { CFG, GUARD_DATABASE_ID, GUARD_SCRIPT } from "../../guard/src/config.mjs";
import { decide } from "../../guard/src/decide.mjs";
import { KEEP } from "../../guard/src/lease.mjs";
import { combineRead, readDataset } from "../../guard/src/ledger.mjs";
import { periodStart } from "../../guard/src/time.mjs";
import { queryRange, rangeCells, scanDataset, witness } from "../../guard/src/witness.mjs";

const cfg = { ...CFG, PROBE_ROWS: 2 };
const T0 = 1_800_000_000; // a cell boundary
const C = (t) => t / cfg.CELL_S; // the cell starting at t
const MIN = 60;

/** The lease production gets from t_p at nowSec, everything else open and within budget. */
function leaseAt(tp, nowSec, hold = false) {
  const env = (e, mode) => ({
    env: e, gen: 0, mode, stage_a: 0, base_limit_micros: 10_000_000, limit_micros: 10_000_000,
    limit_period_start_s: periodStart(nowSec, cfg), pending_allowance_micros: null, warn_permille: 800,
    open_until_s: mode === "open" ? nowSec + 86_400 : null, updated_at_s: 0,
  });
  const state = { env: { production: env("production", "open"), staging: env("staging", "closed") } };
  return decide({ state, read: { tp, spend: { production: 0, staging: 0 }, hold }, nowSec, cfg }).lease.Ep;
}

/** Runs at each of `times`; `counted` maps a cell start to how many of the guard's events Analytics counted there. */
const controls = (counted) => new Map([...counted].map(([t, n]) => [C(t), n]));

/** An Analytics answer's rows for `dataset`: per cell start, the guard's own counted runs, and production's usage. */
function rows(dataset, counted, production = new Map()) {
  const out = [];
  for (const [t, n] of counted) {
    out.push(dataset === "workers" ? { t, key: GUARD_SCRIPT, requests: n, cpu_us: 2_000 * n } : { t, key: GUARD_DATABASE_ID, rows_read: 3 * n, rows_written: cfg.PROBE_ROWS * n });
  }
  for (const [t, n] of production) {
    out.push(dataset === "workers" ? { t, key: "umacapture-web", requests: n, cpu_us: 5_000 * n } : { t, key: "4e8ae460-31b2-4a75-b340-c554e67e892a", rows_read: n, rows_written: n });
  }
  return out;
}

/**
 * One dataset's reading at nowSec of a ledger at toS. By default the ledger reaches the horizon, so no cell of
 * the range is one an earlier response proved: a shortfall is Analytics' and not a response's.
 */
function readOne(dataset, { counted, runs, gaps = [], nowSec, toS = nowSec - cfg.H_W_S }) {
  const range = queryRange(toS, nowSec, cfg);
  const ledger = { from_s: T0 - 86_400, to_s: toS };
  const answer = rows(dataset, counted).filter((r) => r.t >= range.qFrom && r.t < range.qTo); // what a query for the range returns
  return readDataset({ dataset, rows: answer, range, ledger, runs, gaps, nowSec, cfg });
}

/** A run every minute from `from` to `to` (inclusive of from, exclusive of to), at second 2 of the minute. */
const everyMinute = (from, to) => Array.from({ length: (to - from) / MIN }, (_, i) => from + i * MIN + 2);
/** Every run of `runs` counted once in its cell, except the cells listed in `missing`. */
const countAll = (runs, missing = []) => new Map(runs.map((s) => s - (s % MIN)).filter((t) => !missing.includes(t)).map((t) => [t, 1]));

describe("witness", () => {
  test("records at 0 and 1,800 with two events counted at 0 keep t_p at the start of the first cell", () => {
    // Records at 0 and 1,800; Analytics counts 2 in the cell of 0 and nothing after.
    const runs = [T0, T0 + 1_800];
    const cells = rangeCells({ qFrom: T0, qTo: T0 + 1_830 }, cfg);
    const tp = witness({ runs, a: controls(new Map([[T0, 2]])), need: 1, cells, gaps: new Set(), cfg });
    assert.equal(tp, T0);
    assert.equal(leaseAt(tp, T0 + 1_800), KEEP); // t_p + D lies in the past: nothing is extended
  });

  test("a surplus in a newer cell does not make up for a shortfall in an older one", () => {
    const runs = [T0, T0 + 1_800];
    const cells = rangeCells({ qFrom: T0, qTo: T0 + 1_830 }, cfg);
    const tp = witness({ runs, a: controls(new Map([[T0 + 1_800, 5]])), need: 1, cells, gaps: new Set(), cfg });
    assert.equal(tp, null);
  });

  test("no records give a null t_p", () => {
    const cells = rangeCells({ qFrom: T0, qTo: T0 + 3_600 }, cfg);
    assert.equal(witness({ runs: [], a: controls(new Map([[T0, 3]])), need: 1, cells, gaps: new Set(), cfg }), null);
    assert.equal(leaseAt(null, T0 + 3_600), KEEP);
  });

  test("runs every 9 and 16 minutes keep lease - t_p within D", () => {
    const runs = [];
    for (let t = T0, i = 0; t < T0 + 3 * 3_600; t += (i++ % 2 === 0 ? 9 : 16) * MIN) runs.push(t + 5);
    const nowSec = T0 + 3 * 3_600;
    const counted = countAll(runs.filter((s) => s < nowSec - 5 * MIN)); // Analytics 5 minutes behind
    const tp = witness({ runs, a: controls(counted), need: 1, cells: rangeCells({ qFrom: T0, qTo: nowSec }, cfg), gaps: new Set(), cfg });
    assert.equal(tp, Math.max(...counted.keys()));
    const lease = leaseAt(tp, nowSec);
    assert.ok(lease === KEEP || lease - tp <= cfg.D_S);
  });

  test("a shortfall in the middle stops the scan", () => {
    const runs = everyMinute(T0, T0 + 3 * MIN);
    const tp = witness({ runs, a: controls(countAll(runs, [T0 + MIN])), need: 1, cells: rangeCells({ qFrom: T0, qTo: T0 + 3 * MIN }, cfg), gaps: new Set(), cfg });
    assert.equal(tp, T0);
  });

  test("cells in guard_gaps are passed over", () => {
    const runs = everyMinute(T0, T0 + 3 * MIN);
    const tp = witness({ runs, a: controls(countAll(runs, [T0 + MIN])), need: 1, cells: rangeCells({ qFrom: T0, qTo: T0 + 3 * MIN }, cfg), gaps: new Set([C(T0 + MIN)]), cfg });
    assert.equal(tp, T0 + 2 * MIN);
  });

  test("a shortfall older than the horizon is written to guard_gaps in that run, which extends nothing", () => {
    const nowSec = T0 + 2 * 3_600;
    const toS = nowSec - cfg.H_W_S - 20 * MIN;
    const runs = everyMinute(toS, nowSec);
    const old1 = nowSec - cfg.H_W_S - 10 * MIN;
    const old2 = nowSec - cfg.H_W_S - 5 * MIN;
    const recent = nowSec - 30 * MIN; // short too, but inside the horizon
    const counted = countAll(runs.filter((s) => s < nowSec - 2 * MIN), [old1, old2, recent]);
    const w = readOne("workers", { counted, runs, nowSec, toS });
    assert.deepEqual(w.gapRows, [
      { cell: C(old1), runs: 1, counted: 0, seen_s: nowSec },
      { cell: C(old2), runs: 1, counted: 0, seen_s: nowSec },
    ]);
    assert.equal(w.lost, true);
    assert.equal(w.tp, old1 - MIN);
    assert.equal(w.hold, true);
    const d1 = readOne("d1", { counted: countAll(runs.filter((s) => s < nowSec - 2 * MIN)), runs, nowSec, toS });
    const r = combineRead({ workers: w, d1 });
    assert.equal(leaseAt(r.tp, nowSec, r.hold), KEEP);
  });

  test("t_p is the smaller of the two datasets'", () => {
    const nowSec = T0 + 2 * 3_600;
    const runs = everyMinute(nowSec - 70 * MIN, nowSec);
    const w = readOne("workers", { counted: countAll(runs.filter((s) => s < nowSec - 2 * MIN)), runs, nowSec });
    const d = readOne("d1", { counted: countAll(runs.filter((s) => s < nowSec - 9 * MIN)), runs, nowSec });
    assert.equal(w.tp, nowSec - 3 * MIN);
    assert.equal(d.tp, nowSec - 10 * MIN);
    const r = combineRead({ workers: w, d1: d });
    assert.equal(r.tp, nowSec - 10 * MIN);
    assert.equal(r.hold, false);
    assert.equal(leaseAt(r.tp, nowSec, r.hold), nowSec - 10 * MIN + cfg.D_S);
    assert.equal(combineRead({ workers: w, d1: { ...d, tp: null } }).tp, null);
  });

  test("errors, a full page or a non-numeric field give a null t_p", () => {
    const row = (requests) => ({ dimensions: { datetimeMinute: "2027-01-15T08:00:00Z", scriptName: GUARD_SCRIPT }, sum: { requests, cpuTimeUs: 10 } });
    const body = (raw, extra = {}) => ({ data: { viewer: { accounts: [{ workersInvocationsAdaptive: raw }] } }, errors: null, ...extra });
    const parse = (status, b, c = cfg) => parseAnalytics({ dataset: "workers", granularity: "minute", status, body: b, cfg: c });
    assert.equal(parse(200, body([row(1)])).length, 1);
    assert.equal(parse(200, body([row(1)], { errors: [{ message: "x" }] })), null);
    assert.equal(parse(200, body([row(1), row(1)]), { ...cfg, QUERY_LIMIT: 2 }), null);
    assert.equal(parse(200, body([row("1")])), null);
    assert.equal(parse(200, body([row(null)])), null);
    assert.equal(parse(200, body([row(1.5)])), null);
    assert.equal(parse(500, body([row(1)])), null);
    const nowSec = T0 + 3_600;
    const refused = readDataset({ dataset: "workers", rows: null, range: queryRange(nowSec - MIN, nowSec, cfg), ledger: { from_s: T0, to_s: nowSec - MIN }, runs: everyMinute(T0, nowSec), gaps: [], nowSec, cfg });
    assert.equal(refused.tp, null);
    assert.equal(refused.readable, false);
  });

  // The cell c of the isolated-shortfall cases: runs every minute around it, c counted short (R = 1, a = 0), every later cell counted.
  const C0 = T0 + 3_600;
  const isolated = (nowSec, dataset = "workers", gaps = []) => {
    const runs = everyMinute(C0 - 30 * MIN, nowSec);
    const counted = countAll(runs.filter((s) => s < nowSec - MIN), [C0]);
    return readOne(dataset, { counted, runs, gaps, nowSec });
  };

  test("a run GAP_ACCEPT_S + 1 minute after an isolated shortfall records it at once and extends nothing; the next run passes over it", () => {
    const nowSec = C0 + cfg.GAP_ACCEPT_S + MIN;
    const first = isolated(nowSec);
    assert.deepEqual(first.gapRows, [{ cell: C(C0), runs: 1, counted: 0, seen_s: nowSec }]);
    assert.equal(first.lost, false);
    assert.equal(first.hold, true);
    assert.equal(leaseAt(first.tp, nowSec, first.hold), KEEP);
    const next = isolated(nowSec + MIN, "workers", [{ dataset: "workers", ...first.gapRows[0] }]);
    assert.deepEqual(next.gapRows, []);
    assert.ok(next.tp > C0);
    assert.equal(next.hold, false);
    assert.equal(leaseAt(next.tp, nowSec + MIN, next.hold), next.tp + cfg.D_S);
  });

  test("when every cell from c on is short (ingestion stopped), nothing is accepted and t_p stays before c", () => {
    const nowSec = C0 + 20 * MIN;
    const runs = everyMinute(C0 - 30 * MIN, nowSec);
    const w = readOne("workers", { counted: countAll(runs.filter((s) => s < C0)), runs, nowSec });
    assert.deepEqual(w.gapRows, []);
    assert.equal(w.tp, C0 - MIN);
    const lease = leaseAt(w.tp, nowSec, w.hold);
    assert.ok(lease === KEEP || lease - w.tp <= cfg.D_S);
  });

  test("a shortfall younger than GAP_ACCEPT_S is not accepted", () => {
    const w = isolated(C0 + cfg.GAP_ACCEPT_S - MIN);
    assert.deepEqual(w.gapRows, []);
    assert.equal(w.tp, C0 - MIN);
  });

  test("with K_GAP of the dataset's gaps in the last H_W_S, a new isolated shortfall waits for the horizon", () => {
    const nowSec = C0 + cfg.GAP_ACCEPT_S + MIN;
    const old = Array.from({ length: cfg.K_GAP }, (_, i) => ({ dataset: "workers", cell: C(C0 - 25 * MIN) + i, runs: 1, counted: 0, seen_s: nowSec - 30 * MIN }));
    const w = isolated(nowSec, "workers", old);
    assert.deepEqual(w.gapRows, []);
    // Past the horizon the cell is recorded as lost.
    const late = C0 + cfg.H_W_S + MIN;
    const runs = everyMinute(C0 - 30 * MIN, late);
    const at = readOne("workers", { counted: countAll(runs.filter((s) => s < late - MIN), [C0]), runs, gaps: old, nowSec: late, toS: C0 - 10 * MIN });
    assert.deepEqual(at.gapRows.map((g) => g.cell), [C(C0)]);
    assert.equal(at.lost, true);
  });

  test("K_GAP gaps in Workers do not stop D1 from accepting its own isolated shortfall", () => {
    const nowSec = C0 + cfg.GAP_ACCEPT_S + MIN;
    const workersGaps = Array.from({ length: cfg.K_GAP }, (_, i) => ({ dataset: "workers", cell: C(C0 - 25 * MIN) + i, runs: 1, counted: 0, seen_s: nowSec - 30 * MIN }));
    const d1 = isolated(nowSec, "d1", workersGaps);
    assert.deepEqual(d1.gapRows, [{ cell: C(C0), runs: 1, counted: 0, seen_s: nowSec }]);
    assert.equal(isolated(nowSec, "workers", workersGaps).gapRows.length, 0);
  });

  test("scanDataset proves nothing while PROBE_ROWS is unset", () => {
    const runs = everyMinute(T0, T0 + 3 * MIN);
    const out = scanDataset({ runs, a: controls(countAll(runs)), need: null, cells: rangeCells({ qFrom: T0, qTo: T0 + 3 * MIN }, cfg), gaps: [], nowSec: T0 + 3 * MIN, cfg });
    assert.equal(out.tp, null);
  });
});
