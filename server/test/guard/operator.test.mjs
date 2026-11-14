// The operator's commands (guard/src/operator.mjs, run by tool/cloudflare/guard.sh) on a real D1
// (Miniflare) carrying guard/migrations. "Another writer" is simulated by an executor that runs a write of
// its own between the command's read and its batch.

import { after, before, beforeEach, describe, test } from "node:test";
import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Miniflare } from "miniflare";
import { CFG } from "../../guard/src/config.mjs";
import {
  arm,
  bindingExecutor,
  closeEnv,
  durationToSeconds,
  inlineSql,
  ledgerBridge,
  limitBase,
  openEnv,
  reconAccept,
  status,
  usdToMicros,
} from "../../guard/src/operator.mjs";
import { dayStart } from "../../guard/src/time.mjs";
import { migrationStatements } from "../support/worker_harness.mjs";

const MIGRATIONS = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "guard", "migrations");
const cfg = CFG;
const DAY = 86_400;
const NOW = dayStart("2026-11-02") + 12 * 3_600;

let mf;
let db;
let x;
const all = async (sql, ...params) => (await db.prepare(sql).bind(...params).all()).results;
const env = async (e) => (await all("SELECT * FROM guard_env WHERE env = ?1", e))[0];
const snapshot = async () => {
  const tables = await all("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'guard%' ORDER BY name");
  const out = {};
  for (const t of tables) out[t.name] = await all(`SELECT * FROM ${t.name}`);
  return out;
};
/** An executor that runs `sql` (another writer) right before the command's first batch. */
const racing = (sql) => {
  let raced = false;
  return {
    query: x.query,
    batch: async (statements) => {
      if (!raced) {
        raced = true;
        await db.prepare(sql).run();
      }
      return x.batch(statements);
    },
  };
};
/**
 * An executor whose first batch applies only the statements at the indices in `keep`, one by one, and then
 * loses its answer: the remote D1 is not known to run a multi-statement command as one transaction, so any
 * of its statements may be the ones that took effect.
 */
const partial = (keep) => {
  let cut = false;
  return {
    query: x.query,
    batch: async (statements) => {
      if (cut) return x.batch(statements);
      cut = true;
      for (const i of keep) await db.prepare(statements[i].sql).bind(...statements[i].params).run();
      throw new Error("answer lost");
    },
  };
};
/** Every subset of the indices 0..n-1, in order. */
const subsets = (n) => Array.from({ length: 2 ** n }, (_, m) => [...Array(n).keys()].filter((i) => m & (1 << i)));
const BUMP_GEN = "UPDATE guard_env SET gen = gen + 1";
/** guard_health, production and guard_bill in the state `arm` accepts at NOW. */
async function armable() {
  await db.batch([
    db.prepare("UPDATE guard_health SET last_measurable_s = ?1 WHERE id = 1").bind(NOW - 60),
    db.prepare("UPDATE guard_env SET open_until_s = ?1 WHERE env = 'production'").bind(NOW + cfg.RENEW_WARN_S + 3_600),
    db.prepare("INSERT INTO guard_bill_accepts VALUES (?1, ?2, ?3, 'op')").bind(NOW - 3 * DAY, NOW - 2 * DAY, NOW - 2 * DAY),
    db.prepare("UPDATE guard_bill SET from_s = ?1, to_s = ?2 WHERE id = 1").bind(NOW - 2 * DAY, NOW - DAY),
  ]);
}

describe("guard.sh commands", () => {
  before(async () => {
    mf = new Miniflare({
      modules: true,
      script: "export default { fetch() { return new Response(''); } };",
      compatibilityDate: "2026-07-28",
      d1Databases: { GUARD_DB: "guard-operator-test" },
    });
    db = await mf.getD1Database("GUARD_DB");
    x = bindingExecutor(db);
  });
  after(() => mf.dispose());
  beforeEach(async () => {
    const tables = await all("SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'guard%'");
    await db.batch([...tables.map((t) => db.prepare(`DROP TABLE ${t.name}`)), ...migrationStatements(MIGRATIONS).map((s) => db.prepare(s))]);
  });

  describe("values", () => {
    test("inlineSql writes integers, null and quoted strings, and refuses anything else", () => {
      assert.equal(inlineSql("SELECT ?1, ?2, ?3, ?1", [5, null, "o'k"]), "SELECT 5, NULL, 'o''k', 5");
      assert.throws(() => inlineSql("SELECT ?1", [1.5]), TypeError);
      assert.throws(() => inlineSql("SELECT ?2", [1]), RangeError);
    });
    test("usdToMicros and durationToSeconds read only the written forms", () => {
      assert.equal(usdToMicros("1"), 1_000_000);
      assert.equal(usdToMicros("0.25"), 250_000);
      assert.equal(usdToMicros("1.0000001"), null);
      assert.equal(usdToMicros("-1"), null);
      assert.equal(durationToSeconds("90m"), 5_400);
      assert.equal(durationToSeconds("2h"), 7_200);
      assert.equal(durationToSeconds("2d"), null);
    });
  });

  describe("status", () => {
    test("reports the state and writes nothing", async () => {
      const before = await snapshot();
      const s = await status(x);
      assert.deepEqual(s.env.map((r) => [r.env, r.mode]), [["production", "open"], ["staging", "closed"]]);
      assert.equal(s.bill.to_s, null);
      assert.equal(s.bill_accepts, 0);
      assert.equal(s.holes, 0);
      assert.deepEqual(await snapshot(), before);
    });
  });

  describe("open", () => {
    test("open staging writes the window and the allowance and moves gen", async () => {
      const r = await openEnv(x, { env: "staging", allowanceMicros: 1_000_000, forS: 7_200, gen: 0, nowSec: NOW, by: "op", cfg });
      assert.equal(r.done, true);
      const s = await env("staging");
      assert.deepEqual(
        [s.mode, s.stage_a, s.pending_allowance_micros, s.open_until_s, s.opened_at_s, s.opened_by, s.gen],
        ["open", 0, 1_000_000, NOW + 7_200, NOW, "op", 1],
      );
    });
    test("open production writes no open_until_s and refuses --for", async () => {
      await db.prepare("UPDATE guard_env SET mode = 'tripped', open_until_s = 123 WHERE env = 'production'").run();
      assert.ok((await openEnv(x, { env: "production", allowanceMicros: 1, forS: 60, gen: 0, nowSec: NOW, by: "op", cfg })).refuse);
      assert.equal((await openEnv(x, { env: "production", allowanceMicros: 2_000_000, gen: 0, nowSec: NOW, by: "op", cfg })).done, true);
      const p = await env("production");
      assert.deepEqual([p.mode, p.pending_allowance_micros, p.open_until_s], ["open", 2_000_000, 123]);
    });
    test("a staging window longer than 8 hours, a missing --for or --gen, or a zero allowance is refused and writes nothing", async () => {
      const before = await snapshot();
      for (const a of [
        { env: "staging", allowanceMicros: 1, forS: cfg.STAGING_WINDOW_MAX_S + 1 },
        { env: "staging", allowanceMicros: 1 },
        { env: "staging", allowanceMicros: 0, forS: 60 },
        { env: "staging", allowanceMicros: 1, forS: 60, gen: undefined },
      ]) {
        assert.ok((await openEnv(x, { gen: 0, ...a, nowSec: NOW, by: "op", cfg })).refuse, JSON.stringify(a));
      }
      assert.deepEqual(await snapshot(), before);
    });
    test("an open environment is refused even under its current gen, so no second allowance is added to the first", async () => {
      await openEnv(x, { env: "staging", allowanceMicros: 1_000_000, forS: 3_600, gen: 0, nowSec: NOW, by: "op", cfg });
      const before = await snapshot();
      const r = await openEnv(x, { env: "staging", allowanceMicros: 1_000_000, forS: 3_600, gen: 1, nowSec: NOW + 5, by: "op", cfg });
      assert.ok(r.refuse);
      assert.deepEqual(await snapshot(), before);
    });
    test("an open whose answer was lost, repeated after the guard tripped the environment, grants nothing", async () => {
      await db.prepare("UPDATE guard_env SET mode = 'tripped', gen = 3 WHERE env = 'production'").run();
      const open = (nowSec) => openEnv(x, { env: "production", allowanceMicros: 2_000_000, gen: 3, nowSec, by: "op", cfg });
      assert.equal((await open(NOW)).done, true); // took effect; its answer is lost
      // The guard consumes the allowance and, at the limit, trips production again (one transition).
      await db
        .prepare("UPDATE guard_env SET mode = 'tripped', limit_micros = 2_000_000, pending_allowance_micros = NULL, tripped_at_s = ?1, gen = gen + 1 WHERE env = 'production'")
        .bind(NOW + 600)
        .run();
      const before = await snapshot();
      const r = await open(NOW + 900); // the operator repeats the command
      assert.deepEqual(r, { lost: true });
      assert.deepEqual(await snapshot(), before);
    });
    test("open loses to a writer that moved gen and writes nothing", async () => {
      const r = await openEnv(racing(BUMP_GEN), { env: "staging", allowanceMicros: 1_000_000, forS: 3_600, gen: 0, nowSec: NOW, by: "op", cfg });
      assert.deepEqual(r, { lost: true });
      const s = await env("staging");
      assert.deepEqual([s.mode, s.pending_allowance_micros, s.gen], ["closed", null, 1]);
    });
  });

  describe("close", () => {
    test("close writes closed and moves gen; repeating it writes nothing", async () => {
      assert.equal((await closeEnv(x, { env: "production", nowSec: NOW })).done, true);
      const p = await env("production");
      assert.deepEqual([p.mode, p.gen], ["closed", 1]);
      const before = await snapshot();
      assert.equal((await closeEnv(x, { env: "production", nowSec: NOW + 5 })).noop, true);
      assert.deepEqual(await snapshot(), before);
    });
    test("a tripped environment stays tripped", async () => {
      await db.prepare("UPDATE guard_env SET mode = 'tripped' WHERE env = 'production'").run();
      assert.equal((await closeEnv(x, { env: "production", nowSec: NOW })).noop, true);
      assert.equal((await env("production")).mode, "tripped");
    });
    test("close loses to a writer that moved gen and writes nothing", async () => {
      assert.deepEqual(await closeEnv(racing(BUMP_GEN), { env: "production", nowSec: NOW }), { lost: true });
      assert.equal((await env("production")).mode, "open");
    });
  });

  describe("limit", () => {
    test("limit writes base_limit_micros only, and moves gen", async () => {
      assert.equal((await limitBase(x, { env: "production", baseMicros: 20_000_000, nowSec: NOW })).done, true);
      const p = await env("production");
      assert.deepEqual([p.base_limit_micros, p.limit_micros, p.gen], [20_000_000, 10_000_000, 1]);
      assert.equal((await limitBase(x, { env: "production", baseMicros: 20_000_000, nowSec: NOW })).noop, true);
    });
    test("limit on staging is refused", async () => {
      assert.ok((await limitBase(x, { env: "staging", baseMicros: 1, nowSec: NOW })).refuse);
    });
    test("limit loses to a writer that moved gen and writes nothing", async () => {
      assert.deepEqual(await limitBase(racing(BUMP_GEN), { env: "production", baseMicros: 20_000_000, nowSec: NOW }), { lost: true });
      assert.equal((await env("production")).base_limit_micros, 10_000_000);
    });
  });

  describe("arm", () => {
    test("arm records the request once", async () => {
      await armable();
      assert.deepEqual(await arm(x, { nowSec: NOW, cfg }), { done: true });
      assert.equal((await all("SELECT arm_requested_s FROM guard_health"))[0].arm_requested_s, NOW);
      assert.equal((await arm(x, { nowSec: NOW + 60, cfg })).noop, true);
      assert.equal((await all("SELECT arm_requested_s FROM guard_health"))[0].arm_requested_s, NOW);
    });
    test("the initial state is refused", async () => {
      assert.ok((await arm(x, { nowSec: NOW, cfg })).refuse);
    });
    for (const [name, sql] of [
      ["a guard not measurable in the last 10 minutes", `UPDATE guard_health SET last_measurable_s = ${NOW - CFG.ARM_FRESH_S - 1}`],
      ["production's open_until_s closer than RENEW_WARN_S", `UPDATE guard_env SET open_until_s = ${NOW + CFG.RENEW_WARN_S - 1} WHERE env = 'production'`],
      ["a reach no further than the last recon-accept", `UPDATE guard_bill SET to_s = ${NOW - 2 * DAY}`],
    ]) {
      test(`arm is refused for ${name} and writes nothing`, async () => {
        await armable();
        await db.prepare(sql).run();
        const before = await snapshot();
        assert.ok((await arm(x, { nowSec: NOW, cfg })).refuse);
        assert.deepEqual(await snapshot(), before);
      });
    }
    test("arm whose condition fails between its read and its write writes nothing", async () => {
      await armable();
      const r = await arm(racing(`UPDATE guard_health SET last_measurable_s = ${NOW - CFG.ARM_FRESH_S - 1}`), { nowSec: NOW, cfg });
      assert.deepEqual(r, { lost: true });
      assert.equal((await all("SELECT arm_requested_s FROM guard_health"))[0].arm_requested_s, null);
    });
  });

  describe("ledger-bridge", () => {
    const seedLedger = (toS) =>
      db.batch(["workers", "d1"].map((d) => db.prepare("INSERT INTO guard_ledger VALUES (?1, ?2, ?3)").bind(d, toS - DAY, toS)));
    test("a stalled ledger is bridged once; repeating it writes nothing", async () => {
      const old = NOW - 30 * 3_600;
      await seedLedger(old);
      const r = await ledgerBridge(x, { nowSec: NOW, by: "op", cfg });
      const to = Math.floor((NOW - cfg.H_W_S) / 60) * 60;
      assert.deepEqual(r.bridged.map((b) => [b.dataset, b.old, b.new, b.moved]), [["workers", old, to, true], ["d1", old, to, true]]);
      assert.deepEqual((await all("SELECT dataset, to_s FROM guard_ledger ORDER BY dataset")).map((l) => l.to_s), [to, to]);
      assert.equal((await all("SELECT COUNT(*) AS n FROM guard_holes"))[0].n, 2);
      const before = await snapshot();
      assert.equal((await ledgerBridge(x, { nowSec: NOW + 60, by: "op", cfg })).noop, true);
      assert.deepEqual(await snapshot(), before);
    });
    test("a ledger that is not stalled is left as it is", async () => {
      await seedLedger(NOW - 600);
      const before = await snapshot();
      assert.equal((await ledgerBridge(x, { nowSec: NOW, by: "op", cfg })).noop, true);
      assert.deepEqual(await snapshot(), before);
    });
    test("without guard_ledger rows it is refused", async () => {
      assert.ok((await ledgerBridge(x, { nowSec: NOW, by: "op", cfg })).refuse);
    });
    test("a bridge that loses to the guard moving to_s records no hole", async () => {
      await seedLedger(NOW - 30 * 3_600);
      const r = await ledgerBridge(racing("UPDATE guard_ledger SET to_s = to_s + 60"), { nowSec: NOW, by: "op", cfg });
      assert.equal(r.bridged[0].moved, false);
      assert.equal((await all("SELECT COUNT(*) AS n FROM guard_holes WHERE dataset = ?1", r.bridged[0].dataset))[0].n, 0);
    });
    test("a bridge stopped after any of its statements moves no ledger past its hole, and repeating it reaches the state of one that ran whole", async () => {
      const old = NOW - 30 * 3_600;
      const reached = async () => ({
        ledger: await all("SELECT dataset, from_s, to_s FROM guard_ledger ORDER BY dataset"),
        holes: await all("SELECT dataset, from_s, to_s FROM guard_holes ORDER BY dataset"),
      });
      await seedLedger(old);
      await ledgerBridge(x, { nowSec: NOW, by: "op", cfg });
      const whole = await reached();
      for (const keep of subsets(2)) {
        await db.batch([db.prepare("DELETE FROM guard_ledger"), db.prepare("DELETE FROM guard_holes")]);
        await seedLedger(old);
        await assert.rejects(ledgerBridge(partial(keep), { nowSec: NOW, by: "op", cfg }));
        const { ledger, holes } = await reached();
        for (const l of ledger.filter((l) => l.to_s !== old)) {
          // A ledger that moved lets the guard measure again; it may only move over a recorded hole.
          assert.ok(holes.some((h) => h.dataset === l.dataset && h.from_s === old && h.to_s >= l.to_s), `${keep}: ${l.dataset} moved without its hole`);
        }
        await ledgerBridge(x, { nowSec: NOW, by: "op", cfg });
        assert.deepEqual(await reached(), whole, `${keep}`);
      }
    });
  });

  describe("recon-accept", () => {
    test("accepts through a past day, and repeating it writes nothing", async () => {
      const r = await reconAccept(x, { env: "production", through: "2026-11-01", nowSec: NOW, by: "op", cfg });
      assert.equal(r.done, true);
      const end = dayStart("2026-11-02");
      assert.equal((await env("production")).open_until_s, end + cfg.T_R_S);
      const before = await snapshot();
      assert.equal((await reconAccept(x, { env: "production", through: "2026-11-01", nowSec: NOW + 60, by: "op", cfg })).noop, true);
      assert.deepEqual(await snapshot(), before);
    });
    test("a day not ended, a day before the reach and staging are refused", async () => {
      await reconAccept(x, { env: "production", through: "2026-11-01", nowSec: NOW, by: "op", cfg });
      const before = await snapshot();
      for (const a of [{ env: "production", through: "2026-11-02" }, { env: "production", through: "2026-10-31" }, { env: "staging", through: "2026-11-01" }]) {
        assert.ok((await reconAccept(x, { ...a, nowSec: NOW, by: "op", cfg })).refuse, JSON.stringify(a));
      }
      assert.deepEqual(await snapshot(), before);
    });
    test("recon-accept loses to a writer that moved guard_bill.to_s and writes nothing", async () => {
      const r = await reconAccept(racing(`UPDATE guard_bill SET to_s = ${dayStart("2026-10-31")}`), {
        env: "production",
        through: "2026-11-01",
        nowSec: NOW,
        by: "op",
        cfg,
      });
      assert.deepEqual(r, { lost: true });
      assert.equal((await all("SELECT COUNT(*) AS n FROM guard_bill_accepts"))[0].n, 0);
      assert.equal((await env("production")).open_until_s, 0);
    });
    test("a recon-accept stopped after any of its statements extends nothing it has not recorded, and repeating it reaches the state of one that ran whole", async () => {
      const accept = (ex) => reconAccept(ex, { env: "production", through: "2026-11-01", nowSec: NOW, by: "op", cfg });
      const reached = async () => ({
        accepts: await all("SELECT from_s, to_s FROM guard_bill_accepts ORDER BY from_s"),
        bill: await all("SELECT from_s, to_s FROM guard_bill"),
        open_until_s: (await env("production")).open_until_s,
      });
      const initial = await reached();
      await accept(x);
      const whole = await reached();
      for (const keep of subsets(3)) {
        await db.batch([
          db.prepare("DELETE FROM guard_bill_accepts"),
          db.prepare("UPDATE guard_bill SET from_s = NULL, to_s = NULL"),
          db.prepare("UPDATE guard_env SET open_until_s = 0 WHERE env = 'production'"),
        ]);
        await assert.rejects(accept(partial(keep)));
        const s = await reached();
        const reach = s.bill[0].to_s;
        // A reach no record covers would let arm through on days the guard never reconciled.
        if (reach !== initial.bill[0].to_s) assert.ok(s.accepts.some((a) => a.to_s >= reach), `${keep}: reach without its record`);
        // open_until_s is the guard's extension: it may move only with the reach it belongs to.
        if (s.open_until_s !== initial.open_until_s) assert.equal(s.open_until_s, reach + cfg.T_R_S, `${keep}`);
        await accept(x);
        assert.deepEqual(await reached(), whole, `${keep}`);
      }
    });
  });
});
