// The decision of one guard run (guard/src/decide.mjs): the budget, stage A, the billing period, staging's
// test window and the lease each environment's part of rule G gets. Pure.

import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { CFG } from "../../guard/src/config.mjs";
import { decide } from "../../guard/src/decide.mjs";
import { KEEP } from "../../guard/src/lease.mjs";
import { periodStart } from "../../guard/src/time.mjs";

const cfg = CFG;
const NOW = 1_800_000_000; // 2027-01-15T08:00:00Z
const P0 = periodStart(NOW, cfg);
const TP = NOW - 180;

const row = (env, o) => ({
  env,
  gen: 7,
  mode: "open",
  stage_a: 0,
  base_limit_micros: 10_000_000,
  limit_micros: 10_000_000,
  limit_period_start_s: P0,
  pending_allowance_micros: null,
  warn_permille: 800,
  open_until_s: NOW + 5 * 86_400,
  opened_at_s: null,
  opened_by: null,
  tripped_at_s: null,
  trip_reason: null,
  spent_at_trip_micros: null,
  updated_at_s: 0,
  ...o,
});
const state = (production = {}, staging = {}) => ({
  env: {
    production: row("production", production),
    staging: row("staging", { mode: "closed", base_limit_micros: 0, limit_micros: null, open_until_s: null, ...staging }),
  },
});
const read = (o = {}) => ({ tp: TP, spend: { production: 1_000_000, staging: 0 }, hold: false, ...o });
const run = (st, r = read(), nowSec = NOW) => decide({ state: st, read: r, nowSec, cfg });
const setOf = (plan, env) => plan.transitions.find((t) => t.env === env)?.set;

describe("decide", () => {
  test("below the limit, the lease is t_p + D", () => {
    const plan = run(state());
    assert.equal(plan.lease.Ep, TP + cfg.D_S);
    assert.equal(plan.lease.Es, 0);
    assert.deepEqual(plan.transitions, []);
  });

  test("a null t_p writes no lease", () => {
    const plan = run(state({}, { mode: "open", limit_micros: 1_000_000, open_until_s: NOW + 3_600 }), read({ tp: null }));
    assert.equal(plan.measurable, false);
    assert.equal(plan.lease.Ep, KEEP);
    assert.equal(plan.lease.Es, KEEP);
  });

  test("an unreadable spend writes no lease", () => {
    const plan = run(state(), read({ spend: null }));
    assert.equal(plan.measurable, false);
    assert.equal(plan.lease.Ep, KEEP);
    assert.deepEqual(plan.transitions, []);
  });

  test("reaching the limit trips the environment and closes it", () => {
    const plan = run(state(), read({ spend: { production: 10_000_000, staging: 0 } }));
    assert.deepEqual(setOf(plan, "production"), {
      mode: "tripped",
      tripped_at_s: NOW,
      trip_reason: "budget",
      spent_at_trip_micros: 10_000_000,
      updated_at_s: NOW,
    });
    assert.equal(plan.transitions[0].gen, 7);
    assert.equal(plan.lease.Ep, 0);
    // Just below it does not trip.
    assert.equal(run(state(), read({ spend: { production: 9_999_999, staging: 0 } })).env.production.mode, "open");
  });

  test("the guard never takes an environment out of tripped", () => {
    for (const r of [read({ spend: { production: 0, staging: 0 } }), read({ tp: null }), read()]) {
      const plan = run(state({ mode: "tripped", pending_allowance_micros: 5_000_000 }, { mode: "tripped", open_until_s: NOW - 1 }), r);
      assert.equal(plan.env.production.mode, "tripped");
      assert.equal(plan.env.staging.mode, "tripped");
      for (const t of plan.transitions) assert.equal("mode" in t.set, false);
      assert.equal(plan.lease.Ep, 0);
      assert.equal(plan.lease.Es, 0);
    }
  });

  test("staging closes at the end of its test window", () => {
    const st = state({}, { mode: "open", limit_micros: 1_000_000, open_until_s: NOW });
    const plan = run(st, read({ spend: { production: 0, staging: 10 } }));
    assert.equal(setOf(plan, "staging").mode, "closed");
    assert.equal(plan.lease.Es, 0);
    // A second before the end it is still open.
    assert.equal(run(st, read({ spend: { production: 0, staging: 10 } }), NOW - 1).env.staging.mode, "open");
  });

  test("the lease never goes past the end of the window", () => {
    const plan = run(state({}, { mode: "open", limit_micros: 1_000_000, open_until_s: NOW + 300 }));
    assert.equal(plan.lease.Es, NOW + 300);
    assert.equal(plan.lease.Ep, TP + cfg.D_S);
  });

  test("at alpha x M production latches stage A", () => {
    const plan = run(state(), read({ spend: { production: 8_000_000, staging: 0 } }));
    assert.equal(setOf(plan, "production").stage_a, 1);
    assert.equal(plan.lease.Ea, 0);
    assert.equal(plan.lease.Ep, TP + cfg.D_S);
    const below = run(state(), read({ spend: { production: 7_999_999, staging: 0 } }));
    assert.equal(below.env.production.stage_a, 0);
    assert.equal(below.lease.Ea, cfg.EA_OFF);
  });

  test("a new billing period puts the limit back to the base and leaves tripped as it is", () => {
    const st = state({ mode: "tripped", limit_micros: 3_000_000, limit_period_start_s: P0 - 30 * 86_400 });
    for (const r of [read(), read({ tp: null })]) {
      const plan = run(st, r);
      assert.deepEqual(setOf(plan, "production"), { limit_micros: 10_000_000, limit_period_start_s: P0, updated_at_s: NOW });
      assert.equal(plan.env.production.mode, "tripped");
    }
  });

  test("a lease that would already be past is not written", () => {
    const plan = run(state(), read({ tp: NOW - cfg.D_S - 60 }));
    assert.equal(plan.lease.Ep, KEEP);
    assert.equal(run(state(), read({ tp: NOW - cfg.D_S })).lease.Ep, KEEP);
  });

  test("production too, measured and below the limit, never gets a lease past open_until_s", () => {
    const plan = run(state({ open_until_s: NOW + 100 }));
    assert.equal(plan.lease.Ep, NOW + 100);
  });

  test("decide never changes open_until_s, in either environment", () => {
    const cases = [
      run(state({ pending_allowance_micros: 1_000_000 }, { mode: "open", limit_micros: 1, open_until_s: NOW - 10 })),
      run(state({ open_until_s: NOW - 10 }, { mode: "open", pending_allowance_micros: 100, limit_micros: null, open_until_s: NOW + 600 })),
      run(state({ limit_period_start_s: 0 }), read({ spend: { production: 20_000_000, staging: 0 } })),
      run(state({ open_until_s: 0 })),
    ];
    for (const plan of cases) {
      assert.ok(plan.transitions.length > 0 || plan === cases[3]);
      for (const t of plan.transitions) assert.equal("open_until_s" in t.set, false);
    }
  });

  test("past its open_until_s production stays open: its lease is just not extended", () => {
    for (const until of [NOW - 10, 0]) {
      const plan = run(state({ open_until_s: until }));
      assert.equal(plan.env.production.mode, "open");
      assert.deepEqual(plan.transitions, []);
      assert.equal(plan.lease.Ep, KEEP);
    }
  });
});
