// Billing reconciliation (guard/src/bill.mjs): the Billable Usage answers are built here and handed in
// through a fake fetchBill; nothing is sent anywhere. The ledger side runs on a real D1 (Miniflare)
// carrying guard/migrations.

import { after, before, beforeEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Miniflare } from "miniflare";
import { parseAnalytics, rereadQuery } from "../../guard/src/analytics.mjs";
import {
  advanceStatements,
  applyReconAccept,
  billRange,
  parseBill,
  readLedgerDays,
  reconAcceptPlan,
  reconAcceptStatements,
  reconcile,
  reconcileBilling,
} from "../../guard/src/bill.mjs";
import { CFG } from "../../guard/src/config.mjs";
import { rereadRaise } from "../../guard/src/ledger.mjs";
import { dayOf, dayStart, periodStart } from "../../guard/src/time.mjs";
import { migrationStatements } from "../support/worker_harness.mjs";

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "guard", "migrations");
const cfg = CFG;
const DAY = 86_400;
const HOUR = 3_600;
const NOW = dayStart("2026-11-02") + 12 * HOUR;
const D = (s) => dayStart(s);

const NAMES = {
  requests: "Workers Standard Requests (first 10M are included)",
  cpu_ms: "Workers CPU ms (first 30M are included)",
  rows_read: "D1 - Rows Read (first 25 billion included)",
  rows_written: "D1 - Rows Written (first 50 million included)",
};
const STORAGE = ["D1 - Storage GB-mo (first 5GB included)", "GB-months"];
const RETIRED = [["R2 Data Storage (First 10GB-Month included)", "GB-months"]];
const INCLUDED = [
  ["R2 Storage Class A Operations (First 1M included)", ""],
  ["R2 Storage Class B Operations (First 10M included)", ""],
];
/** A day's usage, each metric well above BILL_A_MICROS at its price. */
const USAGE = Object.freeze({ requests: 100_000, cpu_ms: 2_000_000, rows_read: 50_000_000, rows_written: 100_000 });

const iso = (s) => new Date(s * 1000).toISOString().replace(".000Z", "Z");
/** One Billable Usage row of a kind for the UTC day starting at `s`, in the billing period holding it. */
const row = (name, unit, s, q, over = {}) => ({
  ServiceName: name,
  ConsumedUnit: unit,
  ChargePeriodStart: iso(s),
  ChargePeriodEnd: iso(s + DAY),
  BillingPeriodStart: iso(periodStart(s, cfg)),
  BillingCurrency: "USD",
  ConsumedQuantity: q,
  ...over,
});
/** The four reconciled rows of a day, `usage` per metric (a metric left out has no row). */
const dayRows = (s, usage = USAGE) => Object.entries(usage).map(([m, q]) => row(NAMES[m], "", s, q));
const answer = (result, over = {}) => ({ status: 200, body: { result, success: true, errors: [], messages: [], ...over } });
/** The days [from, to) as 00:00 UTC instants. */
const days = (from, to) => Array.from({ length: (D(to) - D(from)) / DAY }, (_, i) => D(from) + i * DAY);

/** Runs the pure reconcile on a parsed answer, with the ledger at USAGE on every day. */
const run = ({ toS, result, nowSec = NOW, ledgerDay = () => ({ ...USAGE }) }) => {
  const p = parseBill({ ...answer(result), cfg });
  assert.equal(p.ok, true, JSON.stringify(p));
  return reconcile({ toS, rows: p.rows, ledgerDay, nowSec, cfg });
};

let mf;
let db;
const all = async (sql, ...params) => (await db.prepare(sql).bind(...params).all()).results;
const billRow = async () => (await all("SELECT * FROM guard_bill WHERE id = 1"))[0];
const openUntil = async () => (await all("SELECT open_until_s FROM guard_env WHERE env = 'production'"))[0].open_until_s;
const state = async () => ({
  bill: await billRow(),
  env: await all("SELECT * FROM guard_env ORDER BY env"),
  accepts: await all("SELECT * FROM guard_bill_accepts ORDER BY from_s"),
});
/** Ledger rows covering [from, to) for both datasets, and production's guard_daily at `usage` on each day in it. */
async function seedLedger(from, to, usage = USAGE) {
  await db.batch([
    ...["workers", "d1"].map((d) => db.prepare("INSERT OR REPLACE INTO guard_ledger (dataset, from_s, to_s) VALUES (?1, ?2, ?3)").bind(d, from, to)),
    ...days(dayOf(from), dayOf(to - cfg.H_W_S)).map((s) =>
      db
        .prepare("INSERT OR REPLACE INTO guard_daily VALUES ('production', ?1, ?2, ?3, 'measured', ?4, ?5, 0)")
        .bind(dayOf(s), usage.requests, usage.cpu_ms, usage.rows_read, usage.rows_written),
    ),
  ]);
}
const setReach = (toS, lastTry = null) => db.prepare("UPDATE guard_bill SET to_s = ?1, from_s = ?1, last_try_s = ?2 WHERE id = 1").bind(toS, lastTry).run();
/** A fake Billable Usage API: answers with `reply` (a function of the path or a fixed answer) and counts its calls. */
const fakeBill = (reply) => {
  const f = async (path) => {
    f.calls.push(path);
    if (reply instanceof Error) throw reply;
    return typeof reply === "function" ? reply(path) : reply;
  };
  f.calls = [];
  return f;
};
const attempt = (fetchBill, nowSec = NOW) => reconcileBilling(db, { fetchBill, accountId: "account", nowSec, cfg });
/** A D1 binding that behaves like `db` except where `hooks` intercept prepare(sql) or batch. */
const wrap = (hooks) => ({
  prepare: (sql) => {
    const s = db.prepare(sql);
    return hooks.prepare ? hooks.prepare(sql, s) : s;
  },
  batch: (stmts) => (hooks.batch ? hooks.batch(stmts) : db.batch(stmts)),
});

describe("guard billing reconciliation", () => {
  before(async () => {
    mf = new Miniflare({
      modules: true,
      script: "export default { fetch() { return new Response(''); } };",
      compatibilityDate: "2026-07-28",
      d1Databases: { GUARD_DB: "guard-bill-test" },
    });
    db = await mf.getD1Database("GUARD_DB");
  });
  after(() => mf.dispose());
  beforeEach(async () => {
    const tables = await all("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'guard%'");
    await db.batch([...tables.map((t) => db.prepare(`DROP TABLE ${t.name}`)), ...migrationStatements(MIGRATIONS).map((s) => db.prepare(s))]);
  });

  test("four metrics agreeing move the reach one day and open_until_s to its end + T_R", async () => {
    await seedLedger(D("2026-10-30"), NOW);
    await setReach(D("2026-10-30"));
    const f = fakeBill(answer([...dayRows(D("2026-10-30")), ...dayRows(D("2026-10-31"))]));
    const r = await attempt(f);
    assert.equal(r.advanced, true);
    assert.equal((await billRow()).to_s, D("2026-10-31"));
    assert.equal(await openUntil(), D("2026-10-31") + cfg.T_R_S);
    assert.equal(f.calls.length, 1);
  });

  test("three days that piled up are moved past in one attempt", async () => {
    await seedLedger(D("2026-10-28"), NOW);
    await setReach(D("2026-10-28"));
    const f = fakeBill(answer(days("2026-10-28", "2026-11-01").flatMap((s) => dayRows(s))));
    await attempt(f);
    assert.equal((await billRow()).to_s, D("2026-10-31"));
    assert.equal(await openUntil(), D("2026-10-31") + cfg.T_R_S);
  });

  test("without a newer day's row the day is not passed", () => {
    const r = run({ toS: D("2026-10-31"), result: dayRows(D("2026-10-31")) });
    assert.deepEqual([r.to, r.openUntil, r.verdict], [D("2026-10-31"), null, "no_row"]);
  });

  test("a day with no row stops the walk even when the two days after it have rows", () => {
    const r = run({ toS: D("2026-10-29"), result: [...dayRows(D("2026-10-30")), ...dayRows(D("2026-10-31"))] });
    assert.deepEqual([r.to, r.openUntil, r.verdict], [D("2026-10-29"), null, "no_row"]);
  });

  test("a bill larger than the ledger stops the walk as a mismatch", () => {
    const r = run({ toS: D("2026-10-30"), result: [...dayRows(D("2026-10-30"), { ...USAGE, requests: 2 * USAGE.requests }), ...dayRows(D("2026-10-31"))] });
    assert.equal(r.to, D("2026-10-30"));
    assert.equal(r.verdict, "mismatch");
    assert.deepEqual(r.detail, { day: "2026-10-30", metric: "requests", bill: 2 * USAGE.requests, ledger: USAGE.requests });
  });

  test("a bill smaller than the ledger stops the walk as a mismatch", () => {
    const r = run({ toS: D("2026-10-30"), result: [...dayRows(D("2026-10-30"), { ...USAGE, cpu_ms: USAGE.cpu_ms / 2 }), ...dayRows(D("2026-10-31"))] });
    assert.deepEqual([r.to, r.verdict, r.detail.metric], [D("2026-10-30"), "mismatch", "cpu_ms"]);
  });

  test("one metric disagreeing stops the walk although the others agree and the total cost matches", () => {
    // rows_written is short by as many micro-USD as requests is over: summed in money they cancel out.
    const over = { ...USAGE, requests: USAGE.requests + 100_000, rows_written: USAGE.rows_written - 30_000 };
    const r = run({ toS: D("2026-10-30"), result: [...dayRows(D("2026-10-30"), over), ...dayRows(D("2026-10-31"))] });
    assert.deepEqual([r.to, r.verdict], [D("2026-10-30"), "mismatch"]);
  });

  test("an empty answer, a status other than 200 and errors are all refused and move nothing", async () => {
    await seedLedger(D("2026-10-30"), NOW);
    const good = [...dayRows(D("2026-10-30")), ...dayRows(D("2026-10-31"))];
    for (const a of [answer([]), { ...answer(good), status: 500 }, answer(good, { errors: [{ code: 1000, message: "x" }] }), answer(good, { success: false }), { status: 200, body: null }]) {
      assert.deepEqual(parseBill({ ...a, cfg }), { ok: false, reason: "unreadable" });
      await setReach(D("2026-10-30"));
      const r = await attempt(fakeBill(a));
      assert.deepEqual([r.tried, r.unreadable, r.advanced], [true, true, false]);
      assert.equal((await billRow()).to_s, D("2026-10-30"));
      assert.equal(await openUntil(), 0);
    }
  });

  test("a row of a kind not in BILL_CLASS is refused as unmapped and moves nothing", async () => {
    await seedLedger(D("2026-10-30"), NOW);
    await setReach(D("2026-10-30"));
    const kv = row("Workers KV Reads (first 10M are included)", "", D("2026-10-30"), 5);
    const r = await attempt(fakeBill(answer([...dayRows(D("2026-10-30")), ...dayRows(D("2026-10-31")), kv])));
    assert.equal(r.advanced, false);
    assert.deepEqual(r.unmapped, { ServiceName: kv.ServiceName, ConsumedUnit: "", day: "2026-10-30" });
    assert.equal((await billRow()).to_s, D("2026-10-30"));
  });

  test("a reconciled row whose period is not one UTC day is refused and moves nothing", () => {
    const s = D("2026-10-30");
    for (const over of [{ ChargePeriodEnd: "2026-10-30T23:59:59Z" }, { ChargePeriodStart: "2026-10-30T09:00:00Z", ChargePeriodEnd: "2026-10-31T09:00:00Z" }, { ChargePeriodEnd: "2026-11-30T00:00:00Z" }, { BillingCurrency: "JPY" }, { ConsumedQuantity: "100000" }, { ConsumedQuantity: -1 }]) {
      const bad = row(NAMES.requests, "", s, USAGE.requests, over);
      assert.deepEqual(parseBill({ ...answer([bad, ...dayRows(s).slice(1), ...dayRows(s + DAY)]), cfg }), { ok: false, reason: "unreadable" }, JSON.stringify(over));
    }
  });

  test("a day the ledger cannot speak for is not passed: a hole, the ledger not there yet, or before its start", async () => {
    const result = [...dayRows(D("2026-10-30")), ...dayRows(D("2026-10-31"))];
    // The ledger reaches only to 2026-10-31 00:30: the 30th ends after reach - H_W_S.
    await seedLedger(D("2026-10-29"), D("2026-10-31") + 1_800);
    let ld = await readLedgerDays(db, { fromS: D("2026-10-30"), untilS: NOW }, cfg);
    assert.equal(run({ toS: D("2026-10-30"), result, ledgerDay: (d) => ld.get(d) ?? null }).verdict, "ledger_incomplete");
    // The ledger reaches far enough but a hole overlaps the 30th.
    await seedLedger(D("2026-10-29"), NOW);
    await db.prepare("INSERT INTO guard_holes VALUES ('d1', ?1, ?2, ?3, 'op')").bind(D("2026-10-30") + 600, D("2026-10-30") + 1_200, NOW).run();
    ld = await readLedgerDays(db, { fromS: D("2026-10-30"), untilS: NOW }, cfg);
    assert.equal(ld.get(D("2026-10-30")), null);
    assert.equal(run({ toS: D("2026-10-30"), result, ledgerDay: (d) => ld.get(d) ?? null }).verdict, "ledger_incomplete");
    // One dataset's ledger starts inside the day.
    await db.prepare("DELETE FROM guard_holes").run();
    await db.prepare("UPDATE guard_ledger SET from_s = ?1 WHERE dataset = 'workers'").bind(D("2026-10-30") + 60).run();
    ld = await readLedgerDays(db, { fromS: D("2026-10-30"), untilS: NOW }, cfg);
    assert.equal(ld.get(D("2026-10-30")), null);
    assert.deepEqual(ld.get(D("2026-10-31")), { ...USAGE });
  });

  test("the ledger side sums every environment, preferring an environment's guard_daily row to its cells", async () => {
    await seedLedger(D("2026-10-30"), NOW);
    const cell = (D("2026-10-30") + 5 * HOUR) / 60;
    await db.batch([
      db.prepare("INSERT INTO guard_cells VALUES ('staging', ?1, 7, 8, 9, 10)").bind(cell),
      db.prepare("INSERT INTO guard_cells VALUES ('production', ?1, 1000, 1000, 1000, 1000)").bind(cell), // folded: guard_daily wins
    ]);
    const ld = await readLedgerDays(db, { fromS: D("2026-10-30"), untilS: NOW }, cfg);
    assert.deepEqual(ld.get(D("2026-10-30")), { requests: USAGE.requests + 7, cpu_ms: USAGE.cpu_ms + 8, rows_read: USAGE.rows_read + 9, rows_written: USAGE.rows_written + 10 });
  });

  test("a day that has not ended is not judged", () => {
    const today = D(dayOf(NOW));
    const r = run({ toS: today, result: [...dayRows(today), ...dayRows(today + DAY)] });
    assert.deepEqual([r.to, r.openUntil], [today, null]);
  });

  test("whatever the input, the returned open_until never passes nowSec + T_R_S", () => {
    let seed = 7;
    const rand = (n) => ((seed = (seed * 1_103_515_245 + 12_345) % 2 ** 31) % n);
    for (let i = 0; i < 300; i++) {
      const nowSec = D("2026-10-20") + rand(20 * DAY);
      const toS = D("2026-10-10") + rand(25) * DAY;
      const result = days("2026-10-05", "2026-11-12").flatMap((s) => (rand(4) === 0 ? [] : dayRows(s)));
      if (result.length === 0) continue;
      const r = run({ toS, result, nowSec });
      if (r.openUntil !== null) assert.ok(r.openUntil <= nowSec + cfg.T_R_S, JSON.stringify({ nowSec, toS, r }));
      assert.ok(r.to <= Math.max(toS, nowSec));
    }
  });

  test("a failing batch leaves the state as it was", async () => {
    await seedLedger(D("2026-10-30"), NOW);
    await setReach(D("2026-10-30"));
    const before = await state();
    const failing = wrap({ batch: async () => { throw new Error("D1_ERROR"); } });
    const r = await reconcileBilling(failing, { fetchBill: fakeBill(answer([...dayRows(D("2026-10-30")), ...dayRows(D("2026-10-31"))])), accountId: "a", nowSec: NOW, cfg });
    assert.equal(r.advanced, false);
    const afterState = await state();
    assert.deepEqual({ ...afterState.bill, last_try_s: null }, { ...before.bill, last_try_s: null });
    assert.deepEqual(afterState.env, before.env);
  });

  test("a recon-accept that moved to_s after the run read it makes the run's batch change neither row", async () => {
    await setReach(D("2026-10-30"));
    await applyReconAccept(db, { through: "2026-10-31", nowSec: NOW, by: "op", cfg });
    const before = await state();
    const stmts = advanceStatements({ old: D("2026-10-30"), to: D("2026-10-31"), verdict: "no_row" }, NOW + 5, cfg);
    await db.batch(stmts.map((s) => db.prepare(s.sql).bind(...s.params)));
    assert.deepEqual(await state(), before);
  });

  test("two runs moving the reach with the same answer end where one run does", async () => {
    await setReach(D("2026-10-30"));
    const stmts = advanceStatements({ old: D("2026-10-30"), to: D("2026-10-31"), verdict: "no_row" }, NOW, cfg);
    await db.batch(stmts.map((s) => db.prepare(s.sql).bind(...s.params)));
    const once = await state();
    await db.batch(stmts.map((s) => db.prepare(s.sql).bind(...s.params)));
    assert.deepEqual(await state(), once);
    assert.equal(once.bill.to_s, D("2026-10-31"));
    assert.equal(once.env.find((e) => e.env === "production").open_until_s, D("2026-10-31") + cfg.T_R_S);
  });

  test("a run that loses the last_try_s compare-and-set, or cannot write it, does not call the API", async () => {
    await setReach(D("2026-10-30"));
    // Another run claims the attempt between this run's read and its claim.
    const racing = wrap({
      prepare: (sql, s) => {
        if (!sql.includes("SET last_try_s")) return s;
        return { bind: (...p) => ({ run: async () => { await db.prepare("UPDATE guard_bill SET last_try_s = ?1").bind(NOW - 1).run(); return s.bind(...p).run(); } }) };
      },
    });
    const f1 = fakeBill(answer(dayRows(D("2026-10-30"))));
    assert.equal((await reconcileBilling(racing, { fetchBill: f1, accountId: "a", nowSec: NOW, cfg })).tried, false);
    assert.equal(f1.calls.length, 0);
    await setReach(D("2026-10-30"));
    const broken = wrap({ prepare: (sql, s) => (sql.includes("SET last_try_s") ? { bind: () => ({ run: async () => { throw new Error("D1_ERROR"); } }) } : s) });
    const f2 = fakeBill(answer(dayRows(D("2026-10-30"))));
    assert.equal((await reconcileBilling(broken, { fetchBill: f2, accountId: "a", nowSec: NOW, cfg })).tried, false);
    assert.equal(f2.calls.length, 0);
  });

  test("recon-accept refuses a day that has not ended, sets open_until_s to its end + T_R, and repeating it changes nothing", async () => {
    assert.deepEqual(await applyReconAccept(db, { through: "2026-11-02", nowSec: NOW, by: "op", cfg }), { refuse: "the day has not ended" });
    assert.deepEqual(await applyReconAccept(db, { through: "2026-11-01", nowSec: NOW, by: "op", cfg }), { accepted: true });
    const once = await state();
    assert.equal(once.bill.to_s, D("2026-11-02"));
    assert.equal(once.env.find((e) => e.env === "production").open_until_s, D("2026-11-02") + cfg.T_R_S);
    assert.deepEqual(once.accepts.map((a) => [a.from_s, a.to_s]), [[D("2026-11-01"), D("2026-11-02")]]);
    assert.deepEqual(await applyReconAccept(db, { through: "2026-11-01", nowSec: NOW + 60, by: "op", cfg }), { noop: true });
    assert.deepEqual(await state(), once);
    assert.deepEqual(await applyReconAccept(db, { through: "2026-10-31", nowSec: NOW, by: "op", cfg }), { refuse: "the day lies before the current reach" });
  });

  test("a recon-accept that loses its compare-and-set writes nothing, the acceptance record included, and redoing it reaches one state", async () => {
    await setReach(D("2026-10-29"));
    const before = await state();
    // Planned against to_s = 10-28, but to_s is 10-29 by the time the batch runs.
    const stmts = reconAcceptPlan({ through: "2026-10-31", old: D("2026-10-28"), nowSec: NOW });

    const res = await db.batch(reconAcceptStatements(stmts, NOW, "op", cfg).map((s) => db.prepare(s.sql).bind(...s.params)));
    assert.equal(res[1].meta.changes, 0);
    assert.deepEqual(await state(), before);
    assert.deepEqual(await applyReconAccept(db, { through: "2026-10-31", nowSec: NOW, by: "op", cfg }), { accepted: true });
    const once = await state();
    assert.deepEqual(once.accepts.map((a) => [a.from_s, a.to_s]), [[D("2026-10-29"), D("2026-11-01")]]);
    assert.deepEqual(await applyReconAccept(db, { through: "2026-10-31", nowSec: NOW, by: "op", cfg }), { noop: true });
    assert.deepEqual(await state(), once);
  });

  test("recon-accept --through takes only a real UTC day written YYYY-MM-DD, and 2026-11-14 reaches the start of 2026-11-15", () => {
    const now = D("2026-11-20");
    for (const t of ["2026-11-1", "2026-02-30", "2026-11-14T00:00:00Z"]) assert.ok(reconAcceptPlan({ through: t, old: null, nowSec: now }).refuse, t);
    assert.deepEqual(reconAcceptPlan({ through: "2026-11-14", old: null, nowSec: now }), { old: null, new: D("2026-11-15") });
  });

  test("while to_s is NULL nothing is asked or written; right after recon-accept the API is called once", async () => {
    const f = fakeBill(answer(dayRows(D("2026-10-30"))));
    assert.equal((await attempt(f)).tried, false);
    assert.equal(f.calls.length, 0);
    assert.equal((await billRow()).last_try_s, null);
    assert.equal(await openUntil(), 0);
    await applyReconAccept(db, { through: "2026-10-30", nowSec: NOW, by: "op", cfg });
    await attempt(f);
    await attempt(f, NOW + 60);
    assert.equal(f.calls.length, 1);
  });

  test("an unreadable attempt reports unreadable, a readable one does not, and the next failure reports it again", async () => {
    // The latch of bill_unreadable (send once, clear on a readable answer) belongs to the notifications; this
    // asserts the fact they read.
    await setReach(D("2026-10-30"));
    assert.equal((await attempt(fakeBill(new Error("timeout")))).unreadable, true);
    assert.equal((await attempt(fakeBill(answer(dayRows(D("2026-10-30")))), NOW + DAY)).unreadable, false);
    assert.equal((await attempt(fakeBill({ status: 403, body: {} }), NOW + 2 * DAY)).unreadable, true);
  });

  test("an answer holding all eight real kinds passes a day whose four metrics agree: storage, retired and included rows do not stop it", () => {
    const s = D("2026-10-30");
    const result = [s, s + DAY].flatMap((x) => [...dayRows(x), row(...STORAGE, x, 0.0019), ...[...RETIRED, ...INCLUDED].map(([n, u]) => row(n, u, x, 3))]);
    const r = run({ toS: s, result });
    assert.deepEqual([r.to, r.openUntil], [s + DAY, s + DAY + cfg.T_R_S]);
  });

  test("the storage row's value or period changes nothing: 0, a huge value, a month", () => {
    const s = D("2026-10-30");
    const base = [...dayRows(s), ...dayRows(s + DAY)];
    const expected = run({ toS: s, result: [...base, row(...STORAGE, s, 0.0019)] });
    for (const st of [row(...STORAGE, s, 0), row(...STORAGE, s, 1e12), row(...STORAGE, s, 3, { ChargePeriodStart: "2026-10-22T00:00:00Z", ChargePeriodEnd: "2026-11-22T00:00:00Z" })]) {
      assert.deepEqual(run({ toS: s, result: [...base, st] }), expected);
    }
  });

  test("a retired kind's row on 2026-11-04 is refused as unmapped", () => {
    const s = D("2026-11-03");
    for (const [n, u] of RETIRED) {
      const p = parseBill({ ...answer([...dayRows(s), ...dayRows(s + DAY), row(n, u, s, 1), row(n, u, s + DAY, 1)]), cfg });
      assert.deepEqual(p, { ok: false, reason: "unmapped", row: { ServiceName: n, ConsumedUnit: u, day: "2026-11-04" } });
    }
    assert.equal(parseBill({ ...answer([...dayRows(s), ...dayRows(s + DAY), row(...RETIRED[0], s, 1)]), cfg }).ok, true);
  });

  test("R2 operations rows after 2026-11-04 within the billing period's allowance let the reach move; past it they are refused as unmapped and move nothing", async () => {
    const now = D("2026-11-15") + 12 * HOUR;
    const s = D("2026-11-13");
    const [classA, classB] = INCLUDED;
    const base = [...dayRows(s), ...dayRows(s + DAY)];
    await seedLedger(s, now);
    await setReach(s);
    const within = await attempt(fakeBill(answer([...base, row(...classA, s, 1), row(...classA, s + DAY, 3), row(...classB, s + DAY, 2)])), now);
    assert.deepEqual([within.verdict, within.advanced], ["no_row", true]);
    assert.equal((await billRow()).to_s, s + DAY);
    assert.equal(await openUntil(), s + DAY + cfg.T_R_S);
    // The allowance is per billing period: 1,000,001 Class A operations in one period are past it, the same
    // number split over two periods is not.
    await setReach(s);
    const over = await attempt(fakeBill(answer([...base, row(...classA, s, 400_000), row(...classA, s + DAY, 600_001)])), now);
    assert.deepEqual([over.verdict, over.advanced], ["unmapped", false]);
    assert.deepEqual(over.unmapped, { ServiceName: classA[0], ConsumedUnit: "", day: "2026-11-13" });
    assert.equal((await billRow()).to_s, s);
    assert.equal(await openUntil(), s + DAY + cfg.T_R_S);
    const split = [row(...classA, D("2026-11-21"), 600_000), row(...classA, D("2026-11-22"), 400_001)];
    assert.equal(parseBill({ ...answer([...base, ...split]), cfg }).ok, true);
  });

  test("an unknown ServiceName (only the bracketed text differs) or a ConsumedUnit that differs is refused as unmapped", () => {
    const s = D("2026-10-30");
    const base = [...dayRows(s), ...dayRows(s + DAY)];
    for (const bad of [
      row("Workers Standard Requests (first 20M are included)", "", s, 1),
      row(NAMES.requests, "GB-months", s, 1),
      row(STORAGE[0], "", s, 1),
      { ...row(NAMES.requests, "", s, 1), ConsumedUnit: undefined },
    ]) {
      assert.equal(parseBill({ ...answer([...base, bad]), cfg }).reason, "unmapped", JSON.stringify(bad));
    }
  });

  test("an unknown kind's row on a day before the reach still stops reconciliation", () => {
    const s = D("2026-10-30");
    const p = parseBill({ ...answer([row("Queues Operations", "", D("2026-10-25"), 1), ...dayRows(s), ...dayRows(s + DAY)]), cfg });
    assert.deepEqual(p, { ok: false, reason: "unmapped", row: { ServiceName: "Queues Operations", ConsumedUnit: "", day: "2026-10-25" } });
  });

  test("each metric needs its own newer row: Workers up to d+1 and D1 up to d+2 pass only day d", () => {
    const d = D("2026-10-29");
    const d1 = { rows_read: USAGE.rows_read, rows_written: USAGE.rows_written };
    const result = [...dayRows(d), ...dayRows(d + DAY), ...dayRows(d + 2 * DAY, d1)];
    const r = run({ toS: d, result });
    assert.deepEqual([r.to, r.verdict], [d + DAY, "no_row"]);
  });

  test("rows_written missing on day d alone is no row, not 0, even with its d+1 row, D1's other rows and a ledger within a", () => {
    const d = D("2026-10-30");
    const usage = { ...USAGE, rows_written: 3 }; // only the guard's own writes: x_led <= a
    const { rows_written: _, ...withoutWritten } = usage;
    const result = [...dayRows(d, withoutWritten), row(...STORAGE, d, 0.0019), ...dayRows(d + DAY, usage), row(...STORAGE, d + DAY, 0.0019)];
    const r = run({ toS: d, result, ledgerDay: () => ({ ...usage }) });
    assert.deepEqual([r.to, r.openUntil, r.verdict], [d, null, "no_row"]);
  });

  test("an answer with storage, retired and included rows only, no reconciled row, passes nothing even with a ledger within a", () => {
    const d = D("2026-10-30");
    const result = [d, d + DAY].flatMap((x) => [row(...STORAGE, x, 0.0019), ...[...RETIRED, ...INCLUDED].map(([n, u]) => row(n, u, x, 1))]);
    const tiny = { requests: 1, cpu_ms: 1, rows_read: 4, rows_written: 2 };
    const r = run({ toS: d, result, ledgerDay: () => ({ ...tiny }) });
    assert.deepEqual([r.to, r.openUntil, r.verdict], [d, null, "no_row"]);
  });

  test("after the hourly re-read raises guard_daily to the billed value, that day's reconciliation passes", async () => {
    const d = "2026-10-30";
    const billed = 1_200_000;
    await seedLedger(D(d), NOW, { ...USAGE, requests: 400_000 }); // sampled low: three times short of the bill
    const result = [...dayRows(D(d), { ...USAGE, requests: billed }), ...dayRows(D(d) + DAY)];
    let readDays = await readLedgerDays(db, { fromS: D(d), untilS: NOW }, cfg);
    assert.equal(run({ toS: D(d), result, ledgerDay: (x) => readDays.get(x) ?? null }).verdict, "mismatch");
    const raw = Array.from({ length: 24 }, (_, h) => ({ dimensions: { datetimeHour: new Date((D(d) + h * HOUR) * 1000).toISOString(), scriptName: "umacapture-web" }, sum: { requests: billed / 24, cpuTimeUs: 0 } }));
    assert.match(rereadQuery({ dataset: "workers", fromS: D(d), toS: NOW, accountId: "account", cfg }).query, /datetimeHour/);
    const rows = parseAnalytics({ dataset: "workers", granularity: "hour", status: 200, body: { data: { viewer: { accounts: [{ workersInvocationsAdaptive: raw }] } }, errors: null }, cfg });
    await rereadRaise(db, { dataset: "workers", rows }, NOW, cfg);
    readDays = await readLedgerDays(db, { fromS: D(d), untilS: NOW }, cfg);
    const r = run({ toS: D(d), result, ledgerDay: (x) => readDays.get(x) ?? null });
    assert.deepEqual([r.to, r.openUntil], [D(d) + DAY, D(d) + DAY + cfg.T_R_S]);
  });

  test("the query asks from the first day of the reach's billing period to tomorrow, exclusive", () => {
    assert.deepEqual(billRange(D("2026-11-01"), NOW, cfg), { from: "2026-10-22", to: "2026-11-03" });
    assert.deepEqual(billRange(D("2026-11-22"), D("2026-11-23") + 5, cfg), { from: "2026-11-22", to: "2026-11-24" });
  });
});
