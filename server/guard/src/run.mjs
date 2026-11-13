// One run of the guard, in the order the guard's correctness rests on:
//
//   read the state -> record the control event -> (first run) start the ledger -> read each dataset once
//   -> write the ledger, read the spend -> decide -> commit the transitions (compare-and-set) -> GET the
//   rule -> write the rule (only when the commit held, the run is on time and no other run changed the
//   state) -> daily sweep, hourly re-read -> notifications -> billing reconciliation.
//
// A run ends early in three cases only: the state or the control record cannot be written or read
// (nothing can be latched either), the control INSERT wrote a row count other than PROBE_ROWS (only
// probe_rows_mismatch is sent), and api_backoff_until_s lies ahead (no request to Cloudflare at all; only
// the notifications the state alone yields are sent). The gate before the rule write guards the rule only:
// the sweep, the re-read, the notifications and billing reconciliation do not depend on this run's decision
// and run after it either way.
//
// Every outside call comes in through `deps`, so the run itself reaches nothing:
//   graphql(body) -> { status, body }                       GraphQL Analytics
//   cf({ method, path, body }) -> { status, body, retryAfter }  the rulesets API
//   fetchBill(path) -> { status, body }                     Billable Usage
//   send({ name, extra }) -> boolean                        Sentry
// Each may throw (a timeout, a lost answer); the run reads a throw as "could not be read".

import { DATASETS, cellsQuery, parseAnalytics, rereadQuery } from "./analytics.mjs";
import { reconcileBilling } from "./bill.mjs";
import { decide } from "./decide.mjs";
import { combineRead, foldDays, initLedger, postLedger, readDataset, rereadRaise, rereadRange } from "./ledger.mjs";
import {
  billConditions,
  closeConditions,
  leaseConditions,
  notify,
  probeConditions,
  readConditions,
  ruleConditions,
  stateConditions,
  undercountConditions,
} from "./notify.mjs";
import { classifyRules, converge, entrypointPath, noteBackoff, observeRule, patchNeeded, wantLease } from "./rules.mjs";
import { cellOf, dayOf } from "./time.mjs";
import { queryRange } from "./witness.mjs";

const DAY_S = 86_400;

/** The run's state: both guard_env rows, guard_health, the guard_ledger rows (by dataset), guard_bill.to_s and the latches. Throws when D1 cannot be read. */
export async function loadState(db) {
  const [env, health, ledger, bill, alerts] = await db.batch([
    db.prepare("SELECT * FROM guard_env"),
    db.prepare("SELECT * FROM guard_health WHERE id = 1"),
    db.prepare("SELECT dataset, from_s, to_s FROM guard_ledger"),
    db.prepare("SELECT to_s FROM guard_bill WHERE id = 1"),
    db.prepare("SELECT key, since_s FROM guard_alerts"),
  ]);
  const envs = Object.fromEntries(env.results.map((r) => [r.env, r]));
  if (envs.production === undefined || envs.staging === undefined || health.results.length !== 1 || bill.results.length !== 1) {
    throw new Error("the guard's state rows are missing");
  }
  return {
    env: envs,
    health: health.results[0],
    ledger: Object.fromEntries(ledger.results.map((r) => [r.dataset, r])),
    bill: bill.results[0],
    alerts: new Map(alerts.results.map((r) => [r.key, r.since_s])),
  };
}

/** The control INSERT, the run's first write. `inserted` false when it failed; `rowsMatch` whether it wrote PROBE_ROWS rows. */
export async function recordRun(db, runId, nowSec, cfg) {
  try {
    const r = await db.prepare("INSERT INTO guard_runs (run_id, started_s) VALUES (?1, ?2)").bind(runId, nowSec).run();
    const rowsWritten = r.meta?.rows_written;
    return { inserted: true, rowsWritten, rowsMatch: rowsWritten === cfg.PROBE_ROWS };
  } catch {
    return { inserted: false, rowsWritten: null, rowsMatch: false };
  }
}

/**
 * Reads each dataset whose ledger row exists with one query over its range, and judges it against
 * guard_runs and guard_gaps as they stand before the run writes anything. A dataset without a ledger row,
 * an answer that fails, and D1 that cannot be read all count as unreadable. Returns combineRead's result.
 */
async function readCells(deps, ledger, nowSec) {
  const { db, cfg } = deps;
  const refused = { readable: false, tp: null, gapRows: [], lost: false, missing: false, stalled: null, hold: true, cells: [], unknownScripts: [] };
  const present = DATASETS.filter((d) => ledger[d] !== undefined);
  const ranges = Object.fromEntries(present.map((d) => [d, queryRange(ledger[d].to_s, nowSec, cfg)]));
  let runs = null;
  let gaps = null;
  if (present.length > 0) {
    const lo = Math.min(...present.map((d) => ranges[d].qFrom));
    const inRange = present.map((_, i) => `(started_s >= ?${2 * i + 1} AND started_s < ?${2 * i + 2})`).join(" OR ");
    try {
      const [r, g] = await db.batch([
        db.prepare(`SELECT started_s FROM guard_runs WHERE ${inRange}`).bind(...present.flatMap((d) => [ranges[d].qFrom, ranges[d].qTo])),
        db.prepare("SELECT dataset, cell, seen_s FROM guard_gaps WHERE cell >= ?1 OR seen_s > ?2").bind(cellOf(lo, cfg), nowSec - cfg.H_W_S),
      ]);
      runs = r.results.map((x) => x.started_s);
      gaps = g.results;
    } catch {
      runs = null;
    }
  }
  const datasets = {};
  for (const d of DATASETS) {
    if (ledger[d] === undefined || runs === null) {
      datasets[d] = refused;
      continue;
    }
    const range = ranges[d];
    let rows = null;
    try {
      const answer = await deps.graphql(cellsQuery({ dataset: d, fromS: range.qFrom, toS: range.qTo, accountId: deps.accountId, cfg }));
      rows = parseAnalytics({ dataset: d, granularity: "minute", status: answer?.status, body: answer?.body, cfg });
    } catch {
      rows = null;
    }
    datasets[d] = readDataset({ dataset: d, rows, range, ledger: ledger[d], runs, gaps, nowSec, cfg });
  }
  return combineRead(datasets);
}

/** The guard_env columns a transition may set. */
const ENV_COLUMNS = new Set([
  "mode",
  "stage_a",
  "limit_micros",
  "limit_period_start_s",
  "pending_allowance_micros",
  "tripped_at_s",
  "trip_reason",
  "spent_at_trip_micros",
  "updated_at_s",
]);

/**
 * Commits the decision's transitions, each a compare-and-set on its row's gen (gen + 1 when it holds).
 * Returns whether every one of them held. A transition that held stays committed even when another did
 * not: each was decided from its own row.
 */
async function commit(db, transitions) {
  const statements = transitions.map(({ env, gen, set }) => {
    const keys = Object.keys(set).filter((k) => ENV_COLUMNS.has(k));
    const assign = keys.map((k, i) => `${k} = ?${i + 3}`).join(", ");
    return db.prepare(`UPDATE guard_env SET ${assign}, gen = gen + 1 WHERE env = ?1 AND gen = ?2`).bind(env, gen, ...keys.map((k) => set[k]));
  });
  try {
    const results = await db.batch(statements);
    return results.every((r) => r.meta.changes === 1);
  } catch {
    return false;
  }
}

/** Whether both guard_env rows still carry the gen this run left them at (no other writer since). */
async function sameGen(db, st, transitions) {
  try {
    const { results } = await db.prepare("SELECT env, gen FROM guard_env").all();
    const moved = new Set(transitions.map((t) => t.env));
    return ["production", "staging"].every((e) => results.find((r) => r.env === e)?.gen === st.env[e].gen + (moved.has(e) ? 1 : 0));
  } catch {
    return false;
  }
}

/** Claims a once-per-`stepS` task through a compare-and-set on its guard_health column. */
async function claim(db, column, last, nowSec, stepS) {
  if (last !== null && nowSec - last < stepS) return false;
  return db
    .prepare(`UPDATE guard_health SET ${column} = ?1 WHERE id = 1 AND ${column} IS ?2`)
    .bind(nowSec, last)
    .run()
    .then((r) => r.meta.changes === 1, () => false);
}

/** The daily sweep: the fold into guard_daily, guard_runs older than RUNS_KEEP_S, and ledger_undercount keys of earlier days. */
async function sweep(db, st, ledger, nowSec, cfg) {
  if (!(await claim(db, "last_sweep_s", st.health.last_sweep_s, nowSec, DAY_S))) return;
  try {
    await foldDays(db, { minToS: Math.min(...DATASETS.map((d) => ledger[d].to_s)) }, nowSec, cfg);
    await db.batch([
      db.prepare("DELETE FROM guard_runs WHERE started_s < ?1").bind(nowSec - cfg.RUNS_KEEP_S),
      db.prepare("DELETE FROM guard_alerts WHERE key LIKE 'ledger_undercount:%' AND key < ?1").bind(`ledger_undercount:${dayOf(nowSec)}`),
    ]);
  } catch {
    // The next day's sweep does it: a fold only ever catches up.
  }
}

/** The hourly re-read of the budget window by hour: raises guard_daily only. Returns the raised columns (empty when not due or failed). */
async function reread(deps, st, ledger, nowSec) {
  const { db, cfg } = deps;
  if (!(await claim(db, "last_reread_s", st.health.last_reread_s, nowSec, cfg.REREAD_STEP_S))) return [];
  const range = rereadRange({ fromS: Math.min(...DATASETS.map((d) => ledger[d].from_s)) }, nowSec, cfg);
  const raised = [];
  for (const d of DATASETS) {
    try {
      const answer = await deps.graphql(rereadQuery({ dataset: d, fromS: range.fromS, toS: range.toS, accountId: deps.accountId, cfg }));
      const rows = parseAnalytics({ dataset: d, granularity: "hour", status: answer?.status, body: answer?.body, cfg });
      raised.push(...((await rereadRaise(db, { dataset: d, rows }, nowSec, cfg)) ?? []));
    } catch {
      // Not evidence for anything: a failed re-read changes nothing.
    }
  }
  return raised;
}

/**
 * One run at `deps.nowSec` (UNIX seconds) for the cron firing at `deps.scheduledMs`. `deps` also holds the
 * D1 binding `db`, `cfg`, `runId`, `accountId`, `zoneId`, `clock()` (milliseconds, read at the rule gate)
 * and the outside calls listed above. Returns what the run did, for the caller's log and the tests.
 */
export async function runGuard(deps) {
  const { db, cfg, nowSec } = deps;
  let st;
  try {
    st = await loadState(db);
  } catch {
    return { ended: "state" };
  }
  const rec = await recordRun(db, deps.runId, nowSec, cfg);
  if (!rec.inserted) return { ended: "record" };
  if (!rec.rowsMatch) {
    await notify(db, deps.send, st.alerts, [probeConditions(true, rec.rowsWritten, cfg)], nowSec);
    return { ended: "probe_rows" };
  }
  const probe = probeConditions(false, rec.rowsWritten, cfg);

  let init;
  try {
    init = await initLedger(db, { ledger: st.ledger, billToS: st.bill.to_s }, nowSec, cfg);
  } catch {
    init = { ledger: st.ledger, stalled: [] };
  }
  const ledger = init.ledger;

  if (st.health.api_backoff_until_s !== null && st.health.api_backoff_until_s > nowSec) {
    await notify(db, deps.send, st.alerts, [probe, ...stateConditions(st.env, nowSec, cfg)], nowSec);
    return { ended: "backoff" };
  }

  const read = await readCells(deps, ledger, nowSec);
  const complete = DATASETS.every((d) => ledger[d] !== undefined);
  let post = { spend: null, gapsInserted: {} };
  if (complete) {
    try {
      post = await postLedger(db, { read, ledger }, nowSec, cfg);
    } catch {
      post = { spend: null, gapsInserted: {} };
    }
  }
  const plan = decide({ state: st, read: { tp: read.tp, spend: post.spend, hold: read.hold }, nowSec, cfg });
  const committed = plan.transitions.length === 0 || (await commit(db, plan.transitions));
  const envNow = committed ? plan.env : st.env;

  let answer;
  try {
    answer = await deps.cf({ method: "GET", path: entrypointPath(deps.zoneId) });
  } catch {
    answer = null;
  }
  let backoff = await noteBackoff(db, answer, nowSec, cfg);
  const cls = classifyRules(answer, nowSec, cfg);
  await observeRule(db, st.health, cls, nowSec);
  const armed = st.health.arm_requested_s !== null;
  const onTime = deps.clock() - deps.scheduledMs <= cfg.RUN_DEADLINE_MS;
  // Whether envNow is guard_env as it stands after this GET: the commit held and no other writer moved gen.
  // The notifications that turn on mode are judged only then; a late run is still fresh.
  const fresh = committed && (await sameGen(db, st, plan.transitions));
  const mayWriteRules = onTime && fresh;
  let conv = null;
  if (mayWriteRules && armed && cls.kind === "rules") {
    conv = await converge(db, deps.cf, { zoneId: deps.zoneId, cls, lease: plan.lease, env: plan.env, health: st.health, nowSec, cfg });
    backoff ||= conv.failure?.backoff === true;
  }
  const patchWanted = cls.kind === "rules" && cls.count === 1 ? patchNeeded(cls, wantLease(plan.lease, cls.cur, plan.env, nowSec, cfg), cfg) : null;

  let raised = [];
  if (complete && !backoff) {
    await sweep(db, st, ledger, nowSec, cfg);
    raised = await reread(deps, st, ledger, nowSec);
  }

  const hadBlind = st.alerts.has("blind");
  await notify(
    db,
    deps.send,
    st.alerts,
    [
      probe,
      ...stateConditions(envNow, nowSec, cfg),
      ...readConditions({ read, ledgerMissing: init.stalled, gapsInserted: post.gapsInserted, measurable: plan.measurable }),
      ...ruleConditions({ cls, conv, armed, patchWanted, alerts: st.alerts, nowSec, cfg }),
      ...leaseConditions({ cls, conv, fresh, armed, env: envNow, health: st.health, alerts: st.alerts, nowSec, cfg }),
      ...closeConditions({ cls, conv, fresh, armed, env: envNow, alerts: st.alerts, nowSec }),
      ...undercountConditions(raised, dayOf(nowSec)),
    ],
    nowSec,
  );
  const last = st.health.last_measurable_s;
  if (plan.measurable && (last === null || nowSec - last >= cfg.STATUS_STEP_S || hadBlind !== st.alerts.has("blind"))) {
    await db.prepare("UPDATE guard_health SET last_measurable_s = ?1 WHERE id = 1").bind(nowSec).run().catch(() => null);
  }

  let bill = { tried: false };
  if (!backoff) {
    try {
      bill = await reconcileBilling(db, { fetchBill: deps.fetchBill, accountId: deps.accountId, nowSec, cfg });
    } catch {
      bill = { tried: false };
    }
    await notify(db, deps.send, st.alerts, billConditions(bill), nowSec);
  }
  return { ended: null, read, spend: post.spend, plan, committed, fresh, mayWriteRules, cls, conv, bill };
}
