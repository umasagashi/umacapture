// The ledger (guard/src/ledger.mjs) on a real D1 (Miniflare) carrying guard/migrations: what a run writes
// from an Analytics answer, the spend it reads back, catching up, a stalled ledger and ledger-bridge, the
// first run's ledger rows, the daily fold and the hourly re-read. The Analytics answers are built here;
// nothing is sent anywhere.

import { after, before, beforeEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Miniflare } from "miniflare";
import { DATASETS, parseAnalytics, rereadQuery } from "../../guard/src/analytics.mjs";
import { CFG, GUARD_DATABASE_ID, GUARD_SCRIPT } from "../../guard/src/config.mjs";
import { decide } from "../../guard/src/decide.mjs";
import { KEEP } from "../../guard/src/lease.mjs";
import {
  applyBridge,
  bridgePlan,
  combineRead,
  costMicros,
  foldDays,
  initLedger,
  postLedger,
  readDataset,
  readSpend,
  rereadRaise,
} from "../../guard/src/ledger.mjs";
import { dayEnd, dayOf, dayStart, periodStart } from "../../guard/src/time.mjs";
import { ledgerStalled, queryRange } from "../../guard/src/witness.mjs";
import { migrationStatements } from "../support/worker_harness.mjs";

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "guard", "migrations");
const cfg = { ...CFG, PROBE_ROWS: 2 };
const MIN = 60;
const HOUR = 3_600;
const NOW = 1_800_000_000 + 13 * HOUR; // a cell boundary, mid-day UTC
const WEB = "umacapture-web";
const STAGING = "umacapture-web-staging";
const PROD_DB = "4e8ae460-31b2-4a75-b340-c554e67e892a";
const STAGING_DB = CFG.STAGING_DATABASES[0];

/** A run every minute over [from, to), at second 2 of the minute. */
const everyMinute = (from, to) => Array.from({ length: Math.max(0, (to - from) / MIN) }, (_, i) => from + i * MIN + 2);
const cellStart = (s) => s - (s % MIN);

/**
 * What Analytics holds: `counted` the cell starts where it counted the guard's own run (once), `usage`
 * per cell start the web Worker's requests (also used as production's D1 rows), `staging` the same for
 * staging, `extra` further raw rows. `rows(dataset, range)` is the answer to a query for that range.
 */
function world({ counted = [], usage = new Map(), staging = new Map(), extra = [] }) {
  const all = { workers: [], d1: [] };
  for (const t of counted) {
    all.workers.push({ t, key: GUARD_SCRIPT, requests: 1, cpu_us: 1_500 });
    all.d1.push({ t, key: GUARD_DATABASE_ID, rows_read: 4, rows_written: cfg.PROBE_ROWS });
  }
  for (const [t, n] of usage) {
    all.workers.push({ t, key: WEB, requests: n, cpu_us: 3_000 * n });
    all.d1.push({ t, key: PROD_DB, rows_read: 10 * n, rows_written: n });
  }
  for (const [t, n] of staging) {
    all.workers.push({ t, key: STAGING, requests: n, cpu_us: 1_000 * n });
    all.d1.push({ t, key: STAGING_DB, rows_read: n, rows_written: n });
  }
  for (const r of extra) all[r.dataset].push(r);
  return (dataset, range) => all[dataset].filter((r) => r.t >= range.qFrom && r.t < range.qTo).map(({ dataset: _, ...r }) => r);
}

/** Production's usage, as world() reports it, over cells starting in [from, to): the web Worker's `usage` and the guard's own `counted` runs. */
const usageCost = (usage, counted, from, to) => {
  const q = { requests: 0, cpu_ms: 0, rows_read: 0, rows_written: 0 };
  for (const t of new Set([...usage.keys(), ...counted])) {
    if (t < from || t >= to) continue;
    const n = usage.get(t) ?? 0;
    const c = counted.includes(t) ? 1 : 0;
    q.requests += n + c;
    q.cpu_ms += Math.ceil((3_000 * n + 1_500 * c) / 1000);
    q.rows_read += 10 * n + 4 * c;
    q.rows_written += n + cfg.PROBE_ROWS * c;
  }
  return q;
};

let mf;
let db;

const all = async (sql, ...params) => (await db.prepare(sql).bind(...params).all()).results;
const ledgerRows = async () => Object.fromEntries((await all("SELECT dataset, from_s, to_s FROM guard_ledger")).map((r) => [r.dataset, r]));
const setLedger = (from, to, datasets = DATASETS) =>
  db.batch(datasets.map((d) => db.prepare("INSERT OR REPLACE INTO guard_ledger (dataset, from_s, to_s) VALUES (?1, ?2, ?3)").bind(d, from, to)));
const snapshot = async () => ({
  ledger: await all("SELECT * FROM guard_ledger ORDER BY dataset"),
  cells: await all("SELECT * FROM guard_cells ORDER BY env, cell"),
  gaps: await all("SELECT * FROM guard_gaps ORDER BY dataset, cell"),
  holes: await all("SELECT * FROM guard_holes ORDER BY dataset, from_s"),
  daily: await all("SELECT * FROM guard_daily ORDER BY env, day"),
});

/** Production open within budget until well after nowSec; staging closed. */
function openState(nowSec) {
  const row = (env, mode) => ({
    env, gen: 0, mode, stage_a: 0, base_limit_micros: 10_000_000, limit_micros: 10_000_000,
    limit_period_start_s: periodStart(nowSec, cfg), pending_allowance_micros: null, warn_permille: 800,
    open_until_s: mode === "open" ? nowSec + 86_400 : null, updated_at_s: 0,
  });
  return { env: { production: row("production", "open"), staging: row("staging", "closed") } };
}

/** One run at nowSec, as far as the ledger goes: read both datasets, write the ledger, decide. */
async function step({ nowSec, runs, rows }) {
  const ledger = await ledgerRows();
  const gaps = await all("SELECT dataset, cell, seen_s FROM guard_gaps");
  const datasets = {};
  for (const d of DATASETS) {
    const range = queryRange(ledger[d].to_s, nowSec, cfg);
    datasets[d] = readDataset({ dataset: d, rows: rows(d, range), range, ledger: ledger[d], runs, gaps, nowSec, cfg });
  }
  const read = combineRead(datasets);
  const post = await postLedger(db, { read, ledger }, nowSec, cfg);
  const plan = decide({ state: openState(nowSec), read: { tp: read.tp, spend: post.spend, hold: read.hold }, nowSec, cfg });
  return { read, post, plan };
}

describe("guard ledger", () => {
  before(async () => {
    mf = new Miniflare({
      modules: true,
      script: "export default { fetch() { return new Response(''); } };",
      compatibilityDate: "2026-07-28",
      d1Databases: { GUARD_DB: "guard-test" },
    });
    db = await mf.getD1Database("GUARD_DB");
  });
  after(() => mf.dispose());
  beforeEach(async () => {
    const tables = await all("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'guard%'");
    await db.batch([...tables.map((t) => db.prepare(`DROP TABLE ${t.name}`)), ...migrationStatements(MIGRATIONS).map((s) => db.prepare(s))]);
  });

  test("an answer holding the guard's rows only in its oldest cells leaves t_p old and extends nothing", async () => {
    const t0 = NOW - 30 * MIN;
    await setLedger(t0, t0);
    const runs = everyMinute(t0, NOW);
    const rows = world({ counted: [t0, t0 + MIN, t0 + 2 * MIN], usage: new Map([[t0, 40]]) });
    const { read, post, plan } = await step({ nowSec: NOW, runs, rows });
    assert.equal(read.tp, t0 + 2 * MIN);
    assert.notEqual(post.spend, null);
    assert.equal(plan.lease.Ep, KEEP);
  });

  test("rows of cells from t_p on enter neither the spend nor the ledger", async () => {
    const from = NOW - 40 * MIN;
    await setLedger(from, from);
    const runs = everyMinute(from, NOW);
    const usage = new Map(everyMinute(from, NOW).map((s) => [cellStart(s), 7]));
    const counted = runs.filter((s) => s < NOW - 6 * MIN).map(cellStart);
    const { read, post } = await step({ nowSec: NOW, runs, rows: world({ counted, usage }) });
    assert.equal(read.tp, NOW - 7 * MIN);
    const cells = await all("SELECT cell FROM guard_cells");
    assert.ok(cells.length > 0 && cells.every((c) => (c.cell + 1) * MIN <= read.tp));
    assert.equal(post.spend.production, costMicros(usageCost(usage, counted, from, read.tp), cfg));
    assert.equal((await ledgerRows()).workers.to_s, read.tp);
  });

  test("writing the same answer twice leaves the ledger as one write did", async () => {
    const from = NOW - 20 * MIN;
    await setLedger(from, from);
    const runs = everyMinute(from, NOW);
    const rows = world({ counted: runs.filter((s) => s < NOW - 3 * MIN).map(cellStart), usage: new Map(runs.map((s) => [cellStart(s), 3])) });
    await step({ nowSec: NOW, runs, rows });
    const once = await snapshot();
    await step({ nowSec: NOW, runs, rows });
    assert.deepEqual(await snapshot(), once);
  });

  test("a smaller answer arriving later does not lower the ledger", async () => {
    const from = NOW - 20 * MIN;
    await setLedger(from, from);
    const runs = everyMinute(from, NOW);
    const counted = runs.filter((s) => s < NOW - 3 * MIN).map(cellStart);
    await step({ nowSec: NOW, runs, rows: world({ counted, usage: new Map(runs.map((s) => [cellStart(s), 10])) }) });
    const big = await snapshot();
    await step({ nowSec: NOW, runs, rows: world({ counted, usage: new Map(runs.map((s) => [cellStart(s), 4])) }) });
    assert.deepEqual(await snapshot(), big);
  });

  test("a run that is catching up (q_to < nowSec) extends nothing", async () => {
    const from = NOW - 6 * HOUR - 10 * MIN;
    await setLedger(from, from);
    const runs = everyMinute(from, NOW);
    const { read, post, plan } = await step({ nowSec: NOW, runs, rows: world({ counted: runs.filter((s) => s < NOW - 2 * MIN).map(cellStart) }) });
    assert.equal(read.tp, NOW - 11 * MIN); // t_p + D lies ahead of nowSec...
    assert.equal(read.hold, true);
    assert.notEqual(post.spend, null);
    assert.equal(plan.measurable, true);
    assert.equal(plan.lease.Ep, KEEP); // ...and still nothing is extended
    assert.equal((await ledgerRows()).workers.to_s, NOW - 11 * MIN);
  });

  test("catching up over a range with no passing control stalls the ledger, which does not move", async () => {
    const from = NOW - 8 * HOUR;
    await setLedger(from, from);
    const runs = everyMinute(NOW - HOUR, NOW);
    const { read } = await step({ nowSec: NOW, runs, rows: world({ counted: runs.map(cellStart) }) });
    assert.equal(read.datasets.workers.stalled, true);
    assert.equal(read.datasets.d1.stalled, true);
    assert.equal((await ledgerRows()).workers.to_s, from);
  });

  test("only c0 passing, then 12 hours without a record, stalls the ledger", async () => {
    const c0 = NOW - 12 * HOUR - MIN;
    await setLedger(c0 - HOUR, c0);
    const runs = [c0 + 2, ...everyMinute(NOW - 5 * MIN, NOW)];
    const { read } = await step({ nowSec: NOW, runs, rows: world({ counted: [c0] }) });
    assert.equal(read.datasets.workers.tp, c0);
    assert.equal(read.datasets.workers.stalled, true);
    assert.equal((await ledgerRows()).workers.to_s, c0);
  });

  test("a run that records a gap does not report a stall, and the next run moves on", async () => {
    const from = NOW - 6 * HOUR - 30 * MIN;
    await setLedger(from, from);
    const runs = everyMinute(from, NOW);
    const lost = from + 10 * MIN;
    const counted = runs.filter((s) => s < NOW - 2 * MIN).map(cellStart).filter((t) => t !== lost);
    const first = await step({ nowSec: NOW, runs, rows: world({ counted }) });
    assert.equal(first.read.datasets.workers.stalled, false);
    assert.deepEqual(first.read.datasets.workers.gapRows.map((g) => g.cell), [lost / MIN]);
    assert.equal((await ledgerRows()).workers.to_s, lost - MIN);
    const next = await step({ nowSec: NOW + MIN, runs: [...runs, NOW + 2], rows: world({ counted }) });
    assert.equal(next.read.datasets.workers.stalled, false);
    assert.ok((await ledgerRows()).workers.to_s > lost);
  });

  test("catching up with records at the end of the range that are not counted yet reports no stall", async () => {
    const from = NOW - 8 * HOUR;
    await setLedger(from, from);
    const runs = everyMinute(from + 6 * HOUR - 10 * MIN, NOW);
    const { read } = await step({ nowSec: NOW, runs, rows: world({}) });
    assert.equal(read.datasets.workers.stalled, false);
    assert.equal(read.datasets.workers.tp, null);
  });

  test("after ledger-bridge the ledger goes on from the horizon, and the hole adds nothing to the spend", async () => {
    const from = NOW - 8 * HOUR;
    await setLedger(from, from);
    const runs = everyMinute(NOW - HOUR, NOW);
    const usage = new Map(everyMinute(from, NOW).map((s) => [cellStart(s), 5]));
    const plan = bridgePlan({ ledger: await ledgerRows(), runs, gaps: [], nowSec: NOW, cfg });
    assert.deepEqual(plan.map((b) => [b.dataset, b.old, b.new]), DATASETS.map((d) => [d, from, NOW - HOUR]));
    await applyBridge(db, plan, NOW, "operator");
    const counted = runs.filter((s) => s < NOW - 2 * MIN).map(cellStart);
    const { read, post } = await step({ nowSec: NOW, runs, rows: world({ counted, usage }) });
    assert.equal(read.hold, false);
    assert.deepEqual((await all("SELECT dataset, from_s, to_s FROM guard_holes ORDER BY dataset")).map((h) => [h.dataset, h.from_s, h.to_s]), [
      ["d1", from, NOW - HOUR],
      ["workers", from, NOW - HOUR],
    ]);
    assert.equal(post.spend.production, costMicros(usageCost(usage, counted, NOW - HOUR, read.tp), cfg));
  });

  test("ledger-bridge joins only the stalled dataset", async () => {
    await setLedger(NOW - 8 * HOUR, NOW - 8 * HOUR, ["workers"]);
    await setLedger(NOW - 8 * HOUR, NOW - 2 * MIN, ["d1"]);
    const runs = everyMinute(NOW - HOUR, NOW);
    const plan = bridgePlan({ ledger: await ledgerRows(), runs, gaps: [], nowSec: NOW, cfg });
    assert.deepEqual(plan.map((b) => b.dataset), ["workers"]);
    await applyBridge(db, plan, NOW, "operator");
    const s = await snapshot();
    assert.equal(s.ledger.find((r) => r.dataset === "d1").to_s, NOW - 2 * MIN);
    assert.deepEqual(s.holes.map((h) => h.dataset), ["workers"]);
  });

  test("ledger-bridge writes nothing when neither dataset is stalled", async () => {
    await setLedger(NOW - 8 * HOUR, NOW - 2 * MIN);
    const before = await snapshot();
    const plan = bridgePlan({ ledger: await ledgerRows(), runs: everyMinute(NOW - HOUR, NOW), gaps: [], nowSec: NOW, cfg });
    assert.deepEqual(plan, []);
    await applyBridge(db, plan, NOW, "operator");
    assert.deepEqual(await snapshot(), before);
  });

  test("after ledger-bridge the guard's next run no longer finds the ledger stalled", async () => {
    await setLedger(NOW - 8 * HOUR, NOW - 8 * HOUR);
    const runs = everyMinute(NOW - HOUR, NOW);
    await applyBridge(db, bridgePlan({ ledger: await ledgerRows(), runs, gaps: [], nowSec: NOW, cfg }), NOW, "operator");
    const { read } = await step({ nowSec: NOW + MIN, runs: [...runs, NOW + 2], rows: world({ counted: runs.map(cellStart) }) });
    assert.equal(read.datasets.workers.stalled, false);
    assert.equal(read.datasets.d1.stalled, false);
  });

  test("a bridge that loses its compare-and-set writes neither the hole nor the ledger, and doing it again reaches one state", async () => {
    const from = NOW - 8 * HOUR;
    await setLedger(from, from);
    const runs = everyMinute(NOW - HOUR, NOW);
    const stale = bridgePlan({ ledger: await ledgerRows(), runs, gaps: [], nowSec: NOW, cfg });
    await db.prepare("UPDATE guard_ledger SET to_s = ?1 WHERE dataset = 'workers'").bind(from + MIN).run(); // another writer moved it
    const done = await applyBridge(db, stale.filter((b) => b.dataset === "workers"), NOW, "operator");
    assert.deepEqual(done, [{ dataset: "workers", moved: false }]);
    assert.deepEqual(await all("SELECT * FROM guard_holes"), []);
    assert.equal((await ledgerRows()).workers.to_s, from + MIN);
    await applyBridge(db, bridgePlan({ ledger: await ledgerRows(), runs, gaps: [], nowSec: NOW, cfg }), NOW, "operator");
    const once = await snapshot();
    await applyBridge(db, bridgePlan({ ledger: await ledgerRows(), runs, gaps: [], nowSec: NOW, cfg }), NOW, "operator");
    assert.deepEqual(await snapshot(), once);
    assert.equal((await ledgerRows()).workers.to_s, NOW - HOUR);
  });

  test("a bridge repeated before the guard runs again (its answer lost) writes nothing more", async () => {
    await setLedger(NOW - 8 * HOUR, NOW - 8 * HOUR);
    const runs = everyMinute(NOW - HOUR, NOW);
    await applyBridge(db, bridgePlan({ ledger: await ledgerRows(), runs, gaps: [], nowSec: NOW, cfg }), NOW, "operator");
    const once = await snapshot();
    const again = bridgePlan({ ledger: await ledgerRows(), runs, gaps: [], nowSec: NOW + 30, cfg });
    assert.deepEqual(again, []);
    await applyBridge(db, again, NOW + 30, "operator");
    assert.deepEqual(await snapshot(), once);
  });

  test("a bridge after the guard recovered (its latch still set) writes nothing", async () => {
    const from = NOW - 8 * HOUR;
    await setLedger(from, from);
    const runs = everyMinute(from + 2 * HOUR, NOW); // the guard came back two hours in
    const plan = bridgePlan({ ledger: await ledgerRows(), runs, gaps: [], nowSec: NOW, cfg });
    assert.deepEqual(plan, []);
  });

  test("a bridge whose new to_s would not lie after the old one is not made", async () => {
    const short = { ...cfg, Q_MAX_S: 30 * MIN }; // a range shorter than the horizon: stalled with to_s inside it
    await setLedger(NOW - 5 * HOUR, NOW - 50 * MIN);
    const runs = everyMinute(NOW - 25 * MIN, NOW);
    const ledger = await ledgerRows();
    assert.equal(ledgerStalled({ toS: ledger.workers.to_s, nowSec: NOW, runs, gaps: new Set(), cfg: short }), true);
    assert.deepEqual(bridgePlan({ ledger, runs, gaps: [], nowSec: NOW, cfg: short }), []);
  });

  test("the first run with an empty guard_ledger and no reconciliation inserts both rows at its cell", async () => {
    const out = await initLedger(db, { ledger: {}, billToS: null }, NOW + 17, cfg);
    assert.deepEqual(out.stalled, []);
    assert.deepEqual(await all("SELECT dataset, from_s, to_s FROM guard_ledger ORDER BY dataset"), [
      { dataset: "d1", from_s: NOW, to_s: NOW },
      { dataset: "workers", from_s: NOW, to_s: NOW },
    ]);
    assert.deepEqual(out.ledger, await ledgerRows());
  });

  test("two first runs inserting at once leave the two rows of one of them", async () => {
    const [a, b] = await Promise.all([
      initLedger(db, { ledger: {}, billToS: null }, NOW, cfg),
      initLedger(db, { ledger: {}, billToS: null }, NOW + MIN, cfg),
    ]);
    const rows = await all("SELECT dataset, from_s, to_s FROM guard_ledger ORDER BY dataset");
    assert.equal(rows.length, 2);
    assert.equal(rows[0].from_s, rows[1].from_s);
    assert.deepEqual(a.ledger, b.ledger);
  });

  test("an empty guard_ledger after reconciliation began is not refilled, and the run cannot measure", async () => {
    await db.prepare("UPDATE guard_bill SET to_s = ?1 WHERE id = 1").bind(dayStart(dayOf(NOW))).run();
    const out = await initLedger(db, { ledger: {}, billToS: dayStart(dayOf(NOW)) }, NOW, cfg);
    assert.deepEqual(out.stalled, ["workers", "d1"]);
    assert.deepEqual(await all("SELECT * FROM guard_ledger"), []);
  });

  test("rows of cells before the ledger's from_s are not written to guard_cells", async () => {
    const from = NOW - 30 * MIN;
    await setLedger(from, from);
    const runs = everyMinute(NOW - 2 * HOUR, NOW);
    const usage = new Map(runs.map((s) => [cellStart(s), 2]));
    const { read } = await step({ nowSec: NOW, runs, rows: world({ counted: runs.filter((s) => s < NOW - 2 * MIN).map(cellStart), usage }) });
    assert.ok(read.tp > from);
    const cells = await all("SELECT cell FROM guard_cells ORDER BY cell");
    assert.ok(cells.length > 0);
    assert.equal(cells[0].cell, from / MIN);
  });

  test("the cells of 23:59 and of the next 00:00 fold into different days", async () => {
    const d = dayOf(NOW - 2 * 86_400);
    const late = dayEnd(d) - MIN;
    const early = dayEnd(d);
    await db.batch([
      db.prepare("INSERT INTO guard_cells (env, cell, requests, cpu_ms) VALUES ('production', ?1, 11, 1)").bind(late / MIN),
      db.prepare("INSERT INTO guard_cells (env, cell, requests, cpu_ms) VALUES ('production', ?1, 22, 2)").bind(early / MIN),
    ]);
    await foldDays(db, { minToS: dayEnd(dayOf(early)) + cfg.H_W_S }, NOW, cfg);
    assert.deepEqual(
      (await all("SELECT env, day, requests, cpu_ms FROM guard_daily ORDER BY day")).map((r) => [r.day, r.requests]),
      [
        [d, 11],
        [dayOf(early), 22],
      ],
    );
  });

  test("the re-read only raises, and failing changes no decision", async () => {
    const d = dayOf(NOW - 3 * 86_400);
    await setLedger(dayStart(d) - 86_400, NOW - 2 * MIN);
    await db.prepare("INSERT INTO guard_daily VALUES ('production', ?1, 100, 10, 'measured', 0, 0, 0)").bind(d).run();
    const hourly = (requests) => [{ t: dayStart(d) + HOUR, key: WEB, requests, cpu_us: 10_000 }];
    assert.deepEqual(await rereadRaise(db, { dataset: "workers", rows: hourly(80) }, NOW, cfg), []);
    assert.equal((await all("SELECT requests FROM guard_daily"))[0].requests, 100);
    const spendBefore = await readSpend(db, { fromS: dayStart(d) - 86_400, tp: NOW - 3 * MIN }, NOW, cfg);
    const decideWith = (spend) => decide({ state: openState(NOW), read: { tp: NOW - 3 * MIN, spend, hold: false }, nowSec: NOW, cfg });
    assert.equal(await rereadRaise(db, { dataset: "workers", rows: null }, NOW, cfg), null);
    const spendAfter = await readSpend(db, { fromS: dayStart(d) - 86_400, tp: NOW - 3 * MIN }, NOW, cfg);
    assert.deepEqual(spendAfter, spendBefore);
    assert.deepEqual(decideWith(spendAfter), decideWith(spendBefore));
    const raised = await rereadRaise(db, { dataset: "workers", rows: hourly(120) }, NOW, cfg);
    assert.deepEqual(raised, [{ env: "production", day: d, column: "requests", ledger: 100, read: 120 }]);
    assert.equal((await all("SELECT requests FROM guard_daily"))[0].requests, 120);
  });

  test("the re-read reads by hour: guard_daily ends at the billed value where a day's sampled aggregate is 2.29 times it", async () => {
    const d = dayOf(NOW - 3 * 86_400);
    const billed = 1_200; // what the bill says production's requests were that day, hour by hour 50
    await db.prepare("INSERT INTO guard_daily VALUES ('production', ?1, 1000, 0, 'measured', 0, 0, 0)").bind(d).run();
    // Analytics: the hourly aggregates add up to the bill; a daily aggregate is sampled to 2.29 times it.
    const analytics = ({ query }) => {
      const hourly = query.includes("datetimeHour");
      const raw = hourly
        ? Array.from({ length: 24 }, (_, h) => ({ dimensions: { datetimeHour: new Date((dayStart(d) + h * HOUR) * 1000).toISOString(), scriptName: WEB }, sum: { requests: billed / 24, cpuTimeUs: 0 } }))
        : [{ dimensions: { date: d, scriptName: WEB }, sum: { requests: Math.round(billed * 2.29), cpuTimeUs: 0 } }];
      return { data: { viewer: { accounts: [{ workersInvocationsAdaptive: raw }] } }, errors: null };
    };
    const q = rereadQuery({ dataset: "workers", fromS: dayStart(d), toS: NOW, accountId: "account", cfg });
    const rows = parseAnalytics({ dataset: "workers", granularity: "hour", status: 200, body: analytics(q), cfg });
    await rereadRaise(db, { dataset: "workers", rows }, NOW, cfg);
    assert.equal((await all("SELECT requests FROM guard_daily WHERE day = ?1", d))[0].requests, billed);
  });

  test("an unknown script counts as production", async () => {
    const from = NOW - 20 * MIN;
    await setLedger(from, from);
    const runs = everyMinute(from, NOW);
    const extra = [{ dataset: "workers", t: from + MIN, key: "mystery-script", requests: 9, cpu_us: 9_000 }];
    const { read } = await step({ nowSec: NOW, runs, rows: world({ counted: runs.filter((s) => s < NOW - 2 * MIN).map(cellStart), extra }) });
    assert.deepEqual(read.datasets.workers.unknownScripts, ["mystery-script"]);
    const cell = await all("SELECT env, requests FROM guard_cells WHERE cell = ?1", (from + MIN) / MIN);
    assert.deepEqual(cell, [{ env: "production", requests: 10 }]);
  });
});
