// Whole runs of the guard (guard/src/run.mjs) on a real D1 (Miniflare) carrying guard/migrations, with
// every outside call answered here: GraphQL Analytics, the rulesets API, Billable Usage and Sentry are
// fakes in cloud(), and nothing is sent anywhere. Covers rule G's reading and writing, the order of one
// run, the notifications, and the leases a sequence of runs keeps through an isolated loss.

import { after, before, beforeEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Miniflare } from "miniflare";
import { CFG, GUARD_DATABASE_ID, GUARD_SCRIPT } from "../../guard/src/config.mjs";
import { formatLease, parseLease } from "../../guard/src/lease.mjs";
import { RULE_MARK, RULE_MARK_PREFIX } from "../../guard/src/rules.mjs";
import { runGuard } from "../../guard/src/run.mjs";
import { cellOf, dayOf, dayStart, periodStart } from "../../guard/src/time.mjs";
import { migrationStatements } from "../support/worker_harness.mjs";

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "guard", "migrations");
const MIN = 60;
const HOUR = 3_600;
const DAY = 86_400;
const NOW = 1_800_000_000 + 13 * HOUR; // a cell boundary, mid-day UTC
const WEB = "umacapture-web";
const PROD_DB = "4e8ae460-31b2-4a75-b340-c554e67e892a";
/** PROBE_ROWS as this D1 reports the control INSERT (measured in before(), as the rollout measures it). */
let cfg;

let mf;
let db;
let seq = 0;

const all = async (sql, ...params) => (await db.prepare(sql).bind(...params).all()).results;
const one = async (sql, ...params) => db.prepare(sql).bind(...params).first();
const health = () => one("SELECT * FROM guard_health WHERE id = 1");
const envRow = (e) => one("SELECT * FROM guard_env WHERE env = ?1", e);
const alertKeys = async () => (await all("SELECT key FROM guard_alerts ORDER BY key")).map((r) => r.key);
const iso = (s) => new Date(s * 1000).toISOString().replace(".000Z", "Z");

const update = (table, where, fields) => {
  const keys = Object.keys(fields);
  return db.prepare(`UPDATE ${table} SET ${keys.map((k, i) => `${k} = ?${i + 1}`).join(", ")} WHERE ${where}`).bind(...keys.map((k) => fields[k]));
};

/** Rule G as the rulesets API holds it. */
const gRule = ({ Ep, Es = 0, Ea = CFG.EA_OFF, id = "g1", enabled = true, action = "block", description = RULE_MARK, expression = null }) => ({
  id,
  action,
  expression: expression ?? formatLease({ Ep, Es, Ea }, CFG),
  description,
  enabled,
});
const otherRule = (id = "x1") => ({ id, action: "block", expression: 'http.host eq "example.invalid"', description: "someone else's", enabled: true });

/**
 * The outside world of a run. Analytics counts the guard's runs (`runs`) per cell once the cell ended
 * `lagS` before the run, except the cells in `dropped[dataset]`; `usage` maps a cell start to the web
 * Worker's requests (and production's D1 rows), visible on the same delay. The rulesets API holds `rules`
 * (or no entry point). Every call is recorded in `calls`; every notification in `sent`.
 */
function cloud(over = {}) {
  const c = {
    now: NOW,
    lagS: 60,
    runs: [],
    dropped: { workers: new Set(), d1: new Set() },
    usage: new Map(),
    /** When set, every answer after a dataset's first in one run carries these amounts instead (an older answer). */
    staleUsage: null,
    extra: { workers: [], d1: [] },
    guardEventType: "cron",
    graphqlFail: false,
    entrypoint: true,
    rules: [],
    /** `({ method, path }) => answer | "throw" | undefined`: a failure the rulesets API gives instead of acting. */
    cfFail: null,
    /** The rulesets API applies a POST or PATCH and then the answer is lost. */
    loseWrites: false,
    sendOk: true,
    bill: () => ({ status: 500, body: null }),
    calls: { graphql: [], cf: [], bill: 0 },
    perRun: {},
    sent: [],
    ruleSeq: 0,
    ...over,
  };

  c.graphql = async (body) => {
    const q = body.query;
    const v = body.variables;
    const dataset = q.includes("workersInvocationsAdaptive") ? "workers" : "d1";
    const hour = q.includes("datetimeHour");
    c.calls.graphql.push({ dataset, hour, query: q, variables: v, now: c.now });
    const id = `${dataset}:${hour}`;
    c.perRun[id] = (c.perRun[id] ?? 0) + 1;
    if (c.graphqlFail) return { status: 500, body: null };
    const from = Date.parse(v.f) / 1000;
    const to = Date.parse(v.t) / 1000;
    const filter = /eventType\s*:\s*"([^"]*)"/.exec(q)?.[1] ?? null;
    const visible = (t) => t - (t % MIN) + MIN + c.lagS <= c.now;
    const raw = [];
    const perCell = new Map();
    for (const s of c.runs) {
      const start = s - (s % MIN);
      if (!visible(start) || c.dropped[dataset].has(start)) continue;
      perCell.set(start, (perCell.get(start) ?? 0) + 1);
    }
    for (const [t, k] of perCell) {
      raw.push(
        dataset === "workers"
          ? { t, key: GUARD_SCRIPT, eventType: c.guardEventType, requests: k, cpuTimeUs: 1_000 * k }
          : { t, key: GUARD_DATABASE_ID, rowsRead: k, rowsWritten: cfg.PROBE_ROWS * k },
      );
    }
    const usage = c.perRun[id] > 1 && c.staleUsage !== null ? c.staleUsage : c.usage;
    for (const [t, u] of usage) {
      if (!visible(t)) continue;
      raw.push(dataset === "workers" ? { t, key: WEB, eventType: "fetch", requests: u, cpuTimeUs: 2_000 * u } : { t, key: PROD_DB, rowsRead: u, rowsWritten: u });
    }
    for (const r of c.extra[dataset]) if (visible(r.t)) raw.push(r);
    const sums = dataset === "workers" ? ["requests", "cpuTimeUs"] : ["rowsRead", "rowsWritten"];
    const bucket = hour ? HOUR : MIN;
    const groups = new Map();
    for (const r of raw) {
      if (r.t < from || r.t >= to || (filter !== null && r.eventType !== filter)) continue;
      const b = r.t - (r.t % bucket);
      const g = groups.get(`${b}|${r.key}`) ?? { b, key: r.key, sum: Object.fromEntries(sums.map((k) => [k, 0])) };
      for (const k of sums) g.sum[k] += r[k] ?? 0;
      groups.set(`${b}|${r.key}`, g);
    }
    const time = hour ? "datetimeHour" : "datetimeMinute";
    const keyDim = dataset === "workers" ? "scriptName" : "databaseId";
    const node = dataset === "workers" ? "workersInvocationsAdaptive" : "d1AnalyticsAdaptiveGroups";
    const out = [...groups.values()].sort((a, b) => a.b - b.b).map((g) => ({ dimensions: { [time]: iso(g.b), [keyDim]: g.key }, sum: g.sum }));
    return { status: 200, body: { data: { viewer: { accounts: [{ [node]: out }] } }, errors: null } };
  };

  c.cf = async ({ method, path, body }) => {
    c.calls.cf.push({ method, path, body: body === undefined ? undefined : structuredClone(body) });
    const fail = c.cfFail?.({ method, path });
    if (fail === "throw") throw new Error("no answer");
    if (fail !== undefined && fail !== null) return fail;
    if (method === "GET") {
      if (!c.entrypoint) return { status: 404, body: { result: null, success: false, errors: [{ code: 10003, message: "could not find entrypoint ruleset" }], messages: [] } };
      return { status: 200, body: { success: true, errors: [], messages: [], result: { id: "rs1", rules: structuredClone(c.rules) } } };
    }
    const { position: _, ...rule } = body;
    if (method === "POST") c.rules.unshift({ id: `new${++c.ruleSeq}`, ...rule });
    if (method === "PATCH") {
      const id = path.split("/").pop();
      const i = c.rules.findIndex((r) => r.id === id);
      const [old] = c.rules.splice(i, 1);
      c.rules.unshift({ ...old, ...rule });
    }
    if (c.loseWrites) throw new Error("answer lost");
    return { status: 200, body: { success: true, errors: [], messages: [], result: {} } };
  };

  c.fetchBill = async (path) => {
    c.calls.bill += 1;
    return c.bill(path);
  };
  c.send = async (event) => {
    c.sent.push(event);
    return c.sendOk;
  };
  c.writes = () => c.calls.cf.filter((x) => x.method !== "GET");
  c.sentNames = () => c.sent.map((e) => e.name);
  /** Rule G's times as the API holds them (null when there is not exactly one readable G). */
  c.lease = () => {
    const ours = c.rules.filter((r) => r.description.startsWith(RULE_MARK_PREFIX));
    return ours.length === 1 ? parseLease(ours[0].expression, CFG) : null;
  };
  return c;
}

/**
 * One run at nowSec, whose cron fired 2 seconds earlier; the run reaches the rule gate `lateMs` after the
 * firing. The run's own control event joins what Analytics will count.
 */
async function runAt(c, nowSec, { lateMs = 2_500, cfg: runCfg = cfg } = {}) {
  c.now = nowSec;
  c.perRun = {};
  c.runs.push(nowSec);
  const scheduledMs = (nowSec - 2) * 1000;
  return runGuard({
    db,
    cfg: runCfg,
    nowSec,
    scheduledMs,
    clock: () => scheduledMs + lateMs,
    runId: `${nowSec}-${++seq}`,
    accountId: "account",
    zoneId: "zone",
    graphql: c.graphql,
    cf: c.cf,
    fetchBill: c.fetchBill,
    send: c.send,
  });
}

/**
 * The state of an armed guard at NOW: production open within a $10 limit until 10 days on, staging
 * closed, the ledger from NOW - 70 min reaching NOW - 5 min, a run every minute (at second 2) over
 * `history` already in guard_runs and in `c.runs`, billing reconciliation tried at NOW (not due again
 * today), the re-read and the sweep done at NOW. Each part can be overridden.
 */
async function setState(c, { prod = {}, staging = {}, healthRow = {}, bill = {}, ledger = { from: NOW - 70 * MIN, to: NOW - 5 * MIN }, history = [NOW - 70 * MIN, NOW], alerts = [] } = {}) {
  const pStart = periodStart(NOW, cfg);
  const runs = [];
  for (let t = history[0]; t < history[1]; t += MIN) runs.push(t + 2);
  c.runs.push(...runs);
  const statements = [
    update("guard_env", "env = 'production'", { open_until_s: NOW + 10 * DAY, limit_period_start_s: pStart, ...prod }),
    update("guard_env", "env = 'staging'", { limit_period_start_s: pStart, ...staging }),
    update("guard_health", "id = 1", { arm_requested_s: NOW - DAY, last_reread_s: NOW, last_sweep_s: NOW, ...healthRow }),
    update("guard_bill", "id = 1", { from_s: dayStart(dayOf(NOW)) - 5 * DAY, to_s: dayStart(dayOf(NOW)) - DAY, last_try_s: NOW, ...bill }),
    db.prepare("INSERT INTO guard_runs (run_id, started_s) SELECT 'h' || value, value FROM json_each(?1)").bind(JSON.stringify(runs)),
    ...alerts.map(([key, since]) => db.prepare("INSERT INTO guard_alerts (key, since_s) VALUES (?1, ?2)").bind(key, since)),
  ];
  if (ledger !== null) {
    statements.push(db.prepare("INSERT INTO guard_ledger (dataset, from_s, to_s) VALUES ('workers', ?1, ?2), ('d1', ?1, ?2)").bind(ledger.from, ledger.to));
  }
  await db.batch(statements);
}

/** A cloud with rule G holding Ep, and the default state. */
async function armed({ Ep = NOW + 600, state = {}, ...over } = {}) {
  const c = cloud({ rules: [gRule({ Ep }), otherRule()], ...over });
  await setState(c, state);
  return c;
}

/** Back to the migration's state (dropping a table drops its triggers too). */
async function resetDb() {
  const tables = await all("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'guard%'");
  await db.batch([...tables.map((t) => db.prepare(`DROP TABLE ${t.name}`)), ...migrationStatements(MIGRATIONS).map((s) => db.prepare(s))]);
}

const T1 = NOW + 2; // the first run of a test: second 2 of the minute starting at NOW

describe("guard run", () => {
  before(async () => {
    mf = new Miniflare({
      modules: true,
      script: "export default { fetch() { return new Response(''); } };",
      compatibilityDate: "2026-07-28",
      d1Databases: { GUARD_DB: "guard-run-test" },
    });
    db = await mf.getD1Database("GUARD_DB");
    await resetDb();
    const r = await db.prepare("INSERT INTO guard_runs (run_id, started_s) VALUES (?1, ?2)").bind("measure", 0).run();
    cfg = { ...CFG, PROBE_ROWS: r.meta.rows_written };
  });
  after(() => mf.dispose());
  beforeEach(resetDb);

  describe("rule G (U3)", () => {
    test("with no rule and no attempt recorded, the attempt is recorded and then one POST creates G first", async () => {
      const c = await armed();
      c.rules = [otherRule()];
      await runAt(c, T1);
      assert.deepEqual(
        c.writes().map((w) => w.method),
        ["POST"],
      );
      assert.equal((await health()).create_attempt_s, T1);
      assert.equal(c.rules[0].description, RULE_MARK);
      assert.equal(c.rules[0].enabled, true);
      assert.equal(c.lease().Ep, NOW - 2 * MIN + cfg.D_S); // t_p + D: the run measured
    });

    test("with no rule and an attempt within CREATE_HOLD_S, nothing is created and rule_missing is sent", async () => {
      const c = await armed({ state: { healthRow: { create_attempt_s: T1 - cfg.CREATE_HOLD_S } } });
      c.rules = [otherRule()];
      await runAt(c, T1);
      assert.equal(c.writes().length, 0);
      assert.equal((await health()).create_attempt_s, T1 - cfg.CREATE_HOLD_S);
      assert.deepEqual(c.sentNames(), ["rule_missing"]);
    });

    test("one rule G is taken and patched, and the create attempt is cleared", async () => {
      const c = await armed({ state: { healthRow: { create_attempt_s: T1 - 2 * cfg.CREATE_HOLD_S } } });
      await runAt(c, T1);
      assert.deepEqual(
        c.writes().map((w) => [w.method, w.path]),
        [["PATCH", "/zones/zone/rulesets/rs1/rules/g1"]],
      );
      const { expression, ...fields } = c.writes()[0].body;
      assert.deepEqual(fields, { action: "block", description: RULE_MARK, enabled: true, position: { before: "" } });
      assert.equal((await health()).create_attempt_s, null);
      assert.equal(c.lease().Ep, NOW - 2 * MIN + cfg.D_S);
    });

    test("with two rules carrying the mark nothing is created, extended or deleted, and rule_ambiguous is sent", async () => {
      const c = await armed();
      c.rules = [gRule({ Ep: NOW + 600 }), gRule({ Ep: NOW + 900, id: "g2" }), otherRule()];
      const before = structuredClone(c.rules);
      await runAt(c, T1);
      assert.equal(c.writes().length, 0);
      assert.deepEqual(c.rules, before);
      assert.ok(c.sentNames().includes("rule_ambiguous"));
    });

    for (const kind of ["POST", "PATCH"]) {
      test(`a ${kind} whose answer is lost leaves the next run deciding as if it had arrived`, async () => {
        const scenario = async (lose) => {
          await resetDb();
          const c = await armed();
          if (kind === "POST") c.rules = [otherRule()];
          c.loseWrites = lose;
          await runAt(c, T1);
          c.loseWrites = false;
          const first = c.writes().length;
          await runAt(c, T1 + 7 * MIN);
          // last_patch_error is left out: a lost answer is recorded as a failure, which is the point of it.
          const h = await health();
          return { first, second: c.writes().slice(first), rules: c.rules, h: { create: h.create_attempt_s, backoff: h.api_backoff_until_s, seen: h.rule_seen_since_s } };
        };
        const lost = await scenario(true);
        const kept = await scenario(false);
        assert.equal(lost.first, 1);
        assert.deepEqual(lost, kept);
        assert.equal(lost.rules.filter((r) => r.description.startsWith(RULE_MARK_PREFIX)).length, 1);
      });
    }

    for (const [name, rule] of [
      ["not first", null],
      ["disabled", gRule({ Ep: NOW + 600, enabled: false })],
      ["with an edited expression", gRule({ Ep: NOW + 600, expression: `${formatLease({ Ep: NOW + 600, Es: 0, Ea: CFG.EA_OFF }, CFG)} or false` })],
    ]) {
      test(`a rule G ${name} is written back first, enabled and in the guard's form`, async () => {
        const c = await armed();
        c.rules = rule === null ? [otherRule(), gRule({ Ep: NOW + 600 })] : [rule, otherRule()];
        await runAt(c, T1);
        assert.equal(c.writes().length, 1);
        assert.equal(c.rules[0].id, "g1");
        assert.equal(c.rules[0].enabled, true);
        assert.equal(c.rules[0].action, "block");
        assert.deepEqual(c.lease(), { Ep: NOW - 2 * MIN + cfg.D_S, Es: 0, Ea: CFG.EA_OFF });
      });
    }

    test("an unreadable GET writes nothing and sends rules_unreadable; an answer of another shape is unreadable too", async () => {
      for (const answer of [{ status: 500, body: null }, { status: 200, body: { success: true, result: { id: "rs1", rules: "none" } } }, "throw"]) {
        await resetDb();
        const c = await armed({ cfFail: ({ method }) => (method === "GET" ? answer : undefined) });
        const before = await health();
        await runAt(c, T1);
        assert.equal(c.writes().length, 0);
        assert.deepEqual(c.sentNames(), ["rules_unreadable"]);
        assert.equal((await health()).rule_seen_since_s, before.rule_seen_since_s);
      }
    });

    test("a missing entry point (404) writes nothing and sends entrypoint_missing", async () => {
      const c = await armed({ entrypoint: false });
      await runAt(c, T1);
      assert.equal(c.writes().length, 0);
      assert.deepEqual(c.sentNames(), ["entrypoint_missing"]);
    });

    test("a PATCH answered 429 records Retry-After, and the next run asks Cloudflare nothing", async () => {
      const c = await armed({ cfFail: ({ method }) => (method === "PATCH" ? { status: 429, body: { success: false, errors: [] }, retryAfter: "120" } : undefined) });
      await runAt(c, T1);
      const h = await health();
      assert.equal(h.api_backoff_until_s, T1 + 120);
      assert.match(h.last_patch_error, /^PATCH 429/);
      assert.ok(c.sentNames().includes("patch_failed"));
      const calls = c.calls.cf.length + c.calls.graphql.length;
      await runAt(c, T1 + MIN);
      assert.equal(c.calls.cf.length + c.calls.graphql.length, calls);
      assert.equal(c.calls.bill, 0);
    });

    test("a G disabled, not first or edited resets rule_seen_since_s to NULL and sends rule_tampered", async () => {
      for (const rules of [
        [gRule({ Ep: NOW + 600, enabled: false }), otherRule()],
        [otherRule(), gRule({ Ep: NOW + 600 })],
        [gRule({ Ep: NOW + 600, expression: "true" }), otherRule()],
      ]) {
        await resetDb();
        const c = await armed({ state: { healthRow: { rule_seen_since_s: NOW - DAY } } });
        c.rules = rules;
        await runAt(c, T1);
        assert.equal((await health()).rule_seen_since_s, null);
        assert.ok(c.sentNames().includes("rule_tampered"));
      }
    });

    test("a G whose Ep is a past positive time keeps rule_seen_since_s and sends no rule_tampered", async () => {
      const c = await armed({ Ep: T1 - 100, state: { healthRow: { rule_seen_since_s: NOW - DAY } } });
      await runAt(c, T1);
      assert.equal((await health()).rule_seen_since_s, NOW - DAY);
      assert.ok(!c.sentNames().includes("rule_tampered"));
    });

    test("a G whose Ep is nowSec + D_S + 61 resets rule_seen_since_s, sends rule_tampered and is patched to 0 or a new lease", async () => {
      for (const measurable of [true, false]) {
        await resetDb();
        const c = await armed({ Ep: T1 + cfg.D_S + 61, graphqlFail: !measurable, state: { healthRow: { rule_seen_since_s: NOW - DAY } } });
        await runAt(c, T1);
        assert.equal((await health()).rule_seen_since_s, null);
        assert.ok(c.sentNames().includes("rule_tampered"));
        assert.equal(c.writes().length, 1);
        assert.equal(c.lease().Ep, measurable ? NOW - 2 * MIN + cfg.D_S : 0);
      }
    });

    test("a G in the protecting form is first seen into rule_seen_since_s, and kept there", async () => {
      const c = await armed();
      await runAt(c, T1);
      assert.equal((await health()).rule_seen_since_s, T1);
      await runAt(c, T1 + MIN);
      assert.equal((await health()).rule_seen_since_s, T1);
    });

    test("before arm nothing is written and only whether the GET was readable is judged", async () => {
      const c = await armed({ entrypoint: false, state: { healthRow: { arm_requested_s: null } } });
      await runAt(c, T1);
      assert.equal(c.writes().length, 0);
      assert.deepEqual(c.sentNames(), []);
    });
  });

  describe("the order of one run (U4)", () => {
    test("a control INSERT that fails ends the run: nothing is asked, written or sent", async () => {
      const c = await armed();
      await db.prepare("DROP TABLE guard_runs").run();
      const before = { env: await all("SELECT * FROM guard_env"), ledger: await all("SELECT * FROM guard_ledger") };
      assert.equal((await runAt(c, T1)).ended, "record");
      assert.equal(c.calls.cf.length + c.calls.graphql.length + c.calls.bill + c.sent.length, 0);
      assert.deepEqual({ env: await all("SELECT * FROM guard_env"), ledger: await all("SELECT * FROM guard_ledger") }, before);
    });

    test("a control INSERT writing other than PROBE_ROWS rows writes neither the rule nor the ledger", async () => {
      const c = await armed();
      const before = { env: await all("SELECT * FROM guard_env"), ledger: await all("SELECT * FROM guard_ledger"), cells: await all("SELECT * FROM guard_cells") };
      await runAt(c, T1, { cfg: { ...cfg, PROBE_ROWS: cfg.PROBE_ROWS + 1 } });
      assert.equal(c.writes().length, 0);
      assert.deepEqual({ env: await all("SELECT * FROM guard_env"), ledger: await all("SELECT * FROM guard_ledger"), cells: await all("SELECT * FROM guard_cells") }, before);
    });

    test("a row count other than PROBE_ROWS makes no GraphQL or rules request and sends probe_rows_mismatch", async () => {
      const c = await armed();
      await runAt(c, T1, { cfg: { ...cfg, PROBE_ROWS: cfg.PROBE_ROWS + 1 } });
      assert.equal(c.calls.graphql.length, 0);
      assert.equal(c.calls.cf.length, 0);
      assert.deepEqual(c.sentNames(), ["probe_rows_mismatch"]);
      assert.equal(c.sent[0].extra.rows_written, cfg.PROBE_ROWS);
      await runAt(c, T1 + MIN);
      assert.deepEqual(await alertKeys(), []);
    });

    // The operator closing production once, as guard.sh does: one change, gen moved on by one. Before the
    // commit it beats the run's compare-and-set, after which gen is exactly what the run's own commit would
    // have left (so only the lost commit stops the rule); after the commit it moves gen past that value.
    const OPERATOR_CLOSE = "UPDATE guard_env SET mode = 'closed', gen = gen + 1 WHERE env = 'production'";
    for (const [name, gate] of [
      ["a lost compare-and-set", { closeAt: "graphql" }],
      ["a change by another writer after the run's commit", { closeAt: "GET" }],
      ["a run past RUN_DEADLINE_MS", { lateMs: CFG.RUN_DEADLINE_MS + 1 }],
    ]) {
      test(`${name} writes no rule, while billing reconciliation and the notifications still run`, async () => {
        const c = await armed({
          state: { prod: { pending_allowance_micros: 1_000_000, open_until_s: T1 + 47 * HOUR }, bill: { last_try_s: null } },
        });
        let closed = false;
        const closeOnce = async () => {
          if (closed) return;
          closed = true;
          await db.prepare(OPERATOR_CLOSE).run();
        };
        const { graphql, cf } = c;
        if (gate.closeAt === "graphql") c.graphql = async (body) => (await closeOnce(), graphql(body));
        if (gate.closeAt === "GET") c.cf = async (req) => (req.method === "GET" && (await closeOnce()), cf(req));
        const r = await runAt(c, T1, { lateMs: gate.lateMs ?? 2_500 });
        assert.equal(r.committed, gate.closeAt !== "graphql");
        assert.equal(r.mayWriteRules, false);
        assert.equal(c.writes().length, 0);
        assert.equal(c.calls.bill, 1);
        assert.equal((await one("SELECT last_try_s FROM guard_bill WHERE id = 1")).last_try_s, T1);
        assert.ok(c.sentNames().includes("lease_closing_soon"));
      });
    }

    test("while api_backoff_until_s lies ahead nothing is asked of Cloudflare, billing is not tried, and a tripped environment is latched", async () => {
      const c = await armed({
        state: { prod: { mode: "tripped", spent_at_trip_micros: 10_000_001 }, healthRow: { api_backoff_until_s: T1 + 30 }, bill: { last_try_s: null } },
      });
      await runAt(c, T1);
      assert.equal(c.calls.graphql.length + c.calls.cf.length + c.calls.bill, 0);
      assert.equal((await one("SELECT last_try_s FROM guard_bill WHERE id = 1")).last_try_s, null);
      assert.deepEqual(await alertKeys(), ["trip:production"]);
      assert.deepEqual(c.sentNames(), ["trip"]);
    });

    test("GraphQL is asked once per dataset in a run, and once more per dataset in a re-read run", async () => {
      const c = await armed();
      await runAt(c, T1);
      assert.deepEqual(c.perRun, { "workers:false": 1, "d1:false": 1 });
      await update("guard_health", "id = 1", { last_reread_s: T1 - HOUR }).run();
      await runAt(c, T1 + MIN);
      assert.deepEqual(c.perRun, { "workers:false": 1, "d1:false": 1, "workers:true": 1, "d1:true": 1 });
    });

    test("the spend comes from the answer that proved the cells: a later, older answer cannot lower it", async () => {
      // Production's limit is 5,000 micro-USD. The first answer of each dataset holds 10,000 requests in
      // one counted cell (over the limit); any further answer in the run holds none of them.
      const c = await armed({ state: { prod: { limit_micros: 5_000, base_limit_micros: 5_000 } } });
      c.usage = new Map([[NOW - 10 * MIN, 10_000]]);
      c.staleUsage = new Map();
      await runAt(c, T1);
      assert.equal((await envRow("production")).mode, "tripped");
      assert.equal(c.lease().Ep, 0);
    });

    test("a ledger batch that fails extends nothing", async () => {
      const c = await armed();
      await db.prepare("CREATE TRIGGER guard_test_fail BEFORE UPDATE ON guard_ledger BEGIN SELECT RAISE(ABORT, 'refused'); END").run();
      const r = await runAt(c, T1);
      assert.notEqual(r.read.tp, null);
      assert.equal(r.spend, null);
      assert.equal(c.lease().Ep, NOW + 600);
      assert.equal(c.writes().length, 0);
    });

    test("probe_lost is sent by the run that waited for the horizon, not by the run that accepted a gap at once", async () => {
      // An isolated loss in Workers 10 minutes back: accepted at once, nothing sent.
      let c = await armed();
      c.dropped.workers.add(NOW - 10 * MIN);
      await runAt(c, T1);
      assert.deepEqual(await all("SELECT dataset, cell FROM guard_gaps"), [{ dataset: "workers", cell: cellOf(NOW - 10 * MIN, cfg) }]);
      assert.ok(!c.sentNames().includes("probe_lost"));
      // A loss older than the horizon: recorded with probe_lost.
      await resetDb();
      c = await armed({ state: { ledger: { from: NOW - 90 * MIN, to: NOW - 90 * MIN }, history: [NOW - 90 * MIN, NOW] } });
      c.dropped.workers.add(NOW - 90 * MIN);
      await runAt(c, T1);
      assert.deepEqual(await all("SELECT dataset, cell FROM guard_gaps"), [{ dataset: "workers", cell: cellOf(NOW - 90 * MIN, cfg) }]);
      assert.deepEqual(
        c.sent.filter((e) => e.name === "probe_lost").map((e) => e.extra),
        [{ dataset: "workers", cells: 1 }],
      );
    });

    test("a shortfall older than the horizon in the range's first cell is recorded although t_p is null, and the next run moves on", async () => {
      // Workers' first cell with a run is short and older than the horizon, so no Workers cell passes before
      // it and the run's t_p is null. The gap is still written; without it every later run stops on it.
      const c = await armed({ state: { ledger: { from: NOW - 90 * MIN, to: NOW - 90 * MIN }, history: [NOW - 90 * MIN, NOW] } });
      c.dropped.workers.add(NOW - 90 * MIN);
      const first = await runAt(c, T1);
      assert.equal(first.read.tp, null);
      assert.equal(c.lease().Ep, NOW + 600);
      const second = await runAt(c, T1 + MIN);
      assert.equal(second.read.tp, NOW - MIN);
      assert.equal(c.lease().Ep, NOW - MIN + cfg.D_S);
    });
  });

  describe("notifications (U4)", () => {
    test("the run that trips sends trip once, and the next run does not send it again", async () => {
      const c = await armed({ state: { prod: { limit_micros: 100, base_limit_micros: 100 } } });
      await runAt(c, T1);
      assert.equal((await envRow("production")).mode, "tripped");
      assert.deepEqual(c.sentNames(), ["trip"]);
      assert.equal(c.lease().Ep, 0);
      await runAt(c, T1 + MIN);
      assert.deepEqual(c.sentNames(), ["trip"]);
    });

    test("a notification Sentry does not take is not latched, and the next run sends it again", async () => {
      const c = await armed({ state: { prod: { limit_micros: 100, base_limit_micros: 100 } } });
      c.sendOk = false;
      await runAt(c, T1);
      assert.deepEqual(await alertKeys(), []);
      c.sendOk = true;
      await runAt(c, T1 + MIN);
      assert.deepEqual(c.sentNames(), ["trip", "trip"]);
      assert.deepEqual(await alertKeys(), ["trip:production"]);
    });

    test("three runs that cannot measure send blind_start once; the next measured run sends blind_end once", async () => {
      const c = await armed({ graphqlFail: true });
      for (let i = 0; i < 3; i++) await runAt(c, T1 + i * MIN);
      assert.deepEqual(c.sentNames(), ["blind_start"]);
      c.graphqlFail = false;
      await runAt(c, T1 + 3 * MIN);
      assert.deepEqual(c.sentNames(), ["blind_start", "blind_end"]);
      assert.equal(c.sent[1].extra.blind_s, 3 * MIN);
      await runAt(c, T1 + 4 * MIN);
      assert.deepEqual(c.sentNames(), ["blind_start", "blind_end"]);
      assert.deepEqual(await alertKeys(), []);
    });

    test("a blind_end Sentry does not take leaves the row, and the next measured run sends blind_end again", async () => {
      const c = await armed({ state: { alerts: [["blind", NOW - 600]] } });
      c.sendOk = false;
      await runAt(c, T1);
      assert.deepEqual(await alertKeys(), ["blind"]);
      c.sendOk = true;
      await runAt(c, T1 + MIN);
      assert.deepEqual(c.sentNames(), ["blind_end", "blind_end"]);
      assert.deepEqual(await alertKeys(), []);
    });

    test("a run during api_backoff_until_s leaves the blind row as it is", async () => {
      const c = await armed({ state: { alerts: [["blind", NOW - 600]], healthRow: { api_backoff_until_s: T1 + 30 } } });
      await runAt(c, T1);
      assert.deepEqual(await all("SELECT key, since_s FROM guard_alerts"), [{ key: "blind", since_s: NOW - 600 }]);
      assert.deepEqual(c.sentNames(), []);
    });

    test("a run whose GET cannot be read leaves the rule_* and patch_failed rows as they are", async () => {
      const latched = ["patch_failed", "rule_ambiguous", "rule_missing", "rule_tampered", "entrypoint_missing"].map((k) => [k, NOW - 600]);
      const c = await armed({ state: { alerts: latched }, cfFail: ({ method }) => (method === "GET" ? { status: 503, body: null } : undefined) });
      await runAt(c, T1);
      assert.deepEqual(await alertKeys(), [...latched.map(([k]) => k), "rules_unreadable"].sort());
    });

    test("lease_closing_soon: sent once for production 47 hours from its end, never for staging's window or production at 0", async () => {
      const c = await armed({ state: { prod: { open_until_s: T1 + 47 * HOUR } } });
      await runAt(c, T1);
      await runAt(c, T1 + MIN);
      assert.deepEqual(c.sentNames(), ["lease_closing_soon"]);
      for (const state of [
        { staging: { mode: "open", open_until_s: T1 + HOUR, limit_micros: 1_000_000 } },
        { prod: { open_until_s: 0 } },
      ]) {
        await resetDb();
        const d = await armed({ state });
        await runAt(d, T1);
        assert.ok(!d.sentNames().includes("lease_closing_soon"));
      }
    });

    test("an unreadable billing answer sends bill_unreadable once and leaves bill_unmapped, which it cannot judge, as it is; the next readable attempt clears both", async () => {
      const c = await armed({ state: { bill: { last_try_s: null }, alerts: [["bill_unmapped", NOW - DAY]] } });
      await runAt(c, T1);
      assert.equal(c.calls.bill, 1);
      assert.deepEqual(c.sentNames(), ["bill_unreadable"]);
      await runAt(c, T1 + MIN); // the day's attempt is taken: no second try, no second notification
      assert.equal(c.calls.bill, 1);
      assert.deepEqual(await all("SELECT key, since_s FROM guard_alerts ORDER BY key"), [
        { key: "bill_unmapped", since_s: NOW - DAY },
        { key: "bill_unreadable", since_s: T1 },
      ]);
      // A day on, an answer holding only a storage row is readable (and passes no day).
      c.bill = () => ({
        status: 200,
        body: {
          success: true,
          errors: [],
          result: [
            {
              ServiceName: "D1 - Storage GB-mo (first 5GB included)",
              ConsumedUnit: "GB-months",
              ConsumedQuantity: 0.1,
              BillingCurrency: "USD",
              ChargePeriodStart: `${dayOf(NOW)}T00:00:00Z`,
              ChargePeriodEnd: `${dayOf(NOW + DAY)}T00:00:00Z`,
            },
          ],
        },
      });
      await runAt(c, T1 + DAY);
      assert.equal(c.calls.bill, 2);
      assert.ok(!(await alertKeys()).some((k) => k.startsWith("bill_")));
    });

    test("ledger rows missing once reconciliation began are not put back: the run cannot measure and ledger_stalled is sent per dataset", async () => {
      const c = await armed({ state: { ledger: null } });
      const r = await runAt(c, T1);
      assert.deepEqual(await all("SELECT * FROM guard_ledger"), []);
      assert.equal(r.plan.measurable, false);
      assert.equal(c.lease().Ep, NOW + 600);
      assert.deepEqual(await alertKeys(), ["blind", "ledger_stalled:d1", "ledger_stalled:workers"]);
    });

    test("a script not in KNOWN_SCRIPTS sends unknown_script once, and the second run does not", async () => {
      const c = await armed();
      c.extra.workers.push({ t: NOW - 10 * MIN, key: "mystery", requests: 3, cpuTimeUs: 3_000 });
      await runAt(c, T1);
      await runAt(c, T1 + MIN);
      assert.deepEqual(
        c.sent.map((e) => [e.name, e.extra]),
        [["unknown_script", { script: "mystery" }]],
      );
    });
  });

  describe("leases over many runs", () => {
    test("an isolated loss closes nothing: every minute from before the lost cell to 30 minutes after it, G's lease lies ahead", async () => {
      const c0 = NOW + 5 * MIN; // the lost cell
      const c = await armed();
      c.dropped.workers.add(c0);
      c.dropped.d1.add(c0);
      for (let m = NOW; m <= c0 + 30 * MIN; m += MIN) {
        const t = m + 2;
        assert.ok(c.lease().Ep > t, `the lease ${c.lease().Ep} has run out at ${t}`);
        await runAt(c, t);
        assert.ok(c.lease().Ep > t, `the lease ${c.lease().Ep} has run out at ${t}`);
      }
      const gaps = await all("SELECT dataset, cell, runs, counted FROM guard_gaps ORDER BY dataset");
      assert.deepEqual(gaps, [
        { dataset: "d1", cell: cellOf(c0, cfg), runs: 1, counted: 0 },
        { dataset: "workers", cell: cellOf(c0, cfg), runs: 1, counted: 0 },
      ]);
      assert.ok(c.lease().Ep > c0 + cfg.D_S, "t_p moved past the lost cell");
    });

    test("the guard's rows labelled eventType unknown still prove their cells: no query narrows by eventType", async () => {
      const c = await armed({ guardEventType: "unknown" });
      const r = await runAt(c, T1);
      assert.equal(r.read.tp, NOW - 2 * MIN);
      assert.equal(c.lease().Ep, NOW - 2 * MIN + cfg.D_S);
      assert.ok(c.calls.graphql.every((q) => !/eventType/.test(q.query)));
    });

    test("whatever the answers and the state, a written lease stays within nowSec + D_S + 60 and open_until_s, and tripped stays tripped", async () => {
      let x = 0x2545f491;
      const rand = () => {
        x ^= x << 13;
        x ^= x >>> 17;
        x ^= x << 5;
        return (x >>> 0) / 2 ** 32;
      };
      const c = await armed({ state: { staging: { mode: "open", open_until_s: NOW + 30 * MIN, limit_micros: 50_000 } } });
      let tripped = new Set();
      for (let i = 0; i < 20; i++) {
        const t = T1 + i * MIN;
        // Between runs: answers lose cells, usage arrives, the operator or reconciliation moves open_until_s.
        if (rand() < 0.3) c.dropped[rand() < 0.5 ? "workers" : "d1"].add(t - Math.floor(rand() * 20) * MIN - 2);
        c.usage.set(t - 2 - Math.floor(rand() * 5) * MIN, Math.floor(rand() * 3_000));
        c.graphqlFail = rand() < 0.1;
        await update("guard_env", "env = 'production'", { open_until_s: t + Math.floor((rand() - 0.3) * 3_000) }).run();
        if (rand() < 0.2) await update("guard_env", "env = 'staging'", { open_until_s: t + Math.floor((rand() - 0.2) * 2_000) }).run();
        const before = Object.fromEntries((await all("SELECT env, mode, open_until_s FROM guard_env")).map((r) => [r.env, r]));
        const writes = c.writes().length;
        await runAt(c, t);
        for (const w of c.writes().slice(writes)) {
          const { Ep, Es } = parseLease(w.body.expression, CFG);
          for (const [v, e] of [[Ep, "production"], [Es, "staging"]]) {
            if (v === 0) continue;
            assert.ok(v <= t + cfg.D_S + cfg.WRITE_MARGIN_S, `${e} ${v} past nowSec + D at ${t}`);
            assert.ok(v <= before[e].open_until_s, `${e} ${v} past open_until_s ${before[e].open_until_s}`);
          }
        }
        const after = await all("SELECT env, mode FROM guard_env");
        for (const r of after) if (tripped.has(r.env)) assert.equal(r.mode, "tripped");
        tripped = new Set(after.filter((r) => r.mode === "tripped").map((r) => r.env));
      }
    });
  });
});
