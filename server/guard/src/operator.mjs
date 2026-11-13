// The operator's commands (tool/cloudflare/guard.sh): what each one reads, refuses and writes on the
// guard's D1. Every command talks to D1 through an executor, `{ query(sql, params) -> rows,
// batch([{ sql, params }]) -> [{ changes }] }`, so the same statements run on a D1 binding in the tests
// and through `wrangler d1 execute --remote` in the shell (guard/tool/guard_cli.mjs).
//
// Every write is an assignment guarded by the values it was planned on (compare-and-set), so a command
// another writer beat writes nothing, and a command repeated after it took effect finds nothing to do.
// The commands that change guard_env move gen forward with the change: the guard's run commits only while
// gen is still the value it read, so a run that decided on the state before the operator's change writes
// no rule from that decision.

import { bridgePlan, bridgeStatements } from "./ledger.mjs";
import { reconAcceptPlan, reconAcceptStatements } from "./bill.mjs";

const ENVS = ["production", "staging"];

/** A D1 binding as an executor (the tests, and anything else that holds the binding). */
export const bindingExecutor = (db) => ({
  query: async (sql, params = []) => (await db.prepare(sql).bind(...params).all()).results,
  batch: async (statements) =>
    (await db.batch(statements.map((s) => db.prepare(s.sql).bind(...s.params)))).map((r) => ({ changes: r.meta?.changes ?? 0 })),
});

/**
 * `sql` with its `?N` parameters written in as SQL literals, for a channel that takes no parameters
 * (`wrangler d1 execute --command`). Only safe integers, null and strings are accepted; strings are quoted
 * with '' doubled. The guard's statements carry no `?` inside a literal.
 */
export function inlineSql(sql, params = []) {
  return sql.replace(/\?(\d+)/g, (_, n) => {
    const i = Number(n) - 1;
    if (i < 0 || i >= params.length) throw new RangeError(`parameter ?${n} has no value`);
    const v = params[i];
    if (v === null) return "NULL";
    if (typeof v === "number" && Number.isSafeInteger(v)) return String(v);
    if (typeof v === "string") return `'${v.replace(/'/g, "''")}'`;
    throw new TypeError(`parameter ?${n} is neither a safe integer, a string nor null`);
  });
}

/** USD written as a decimal with at most 6 places, as integer micro-USD; null when it is not one. */
export function usdToMicros(text) {
  const m = /^(\d{1,9})(?:\.(\d{1,6}))?$/.exec(String(text));
  if (m === null) return null;
  return Number(m[1]) * 1_000_000 + Number((m[2] ?? "").padEnd(6, "0"));
}

/** A duration written `<n>s`, `<n>m` or `<n>h`, in seconds; null when it is not one. */
export function durationToSeconds(text) {
  const m = /^(\d{1,6})([smh])$/.exec(String(text));
  if (m === null) return null;
  return Number(m[1]) * { s: 1, m: 60, h: 3_600 }[m[2]];
}

const envRow = async (x, env) => (await x.query("SELECT * FROM guard_env WHERE env = ?1", [env]))[0] ?? null;

/** guard_env's statement for `set` on `env`, a compare-and-set on the gen read, which it moves on. */
const envUpdate = (env, gen, set, nowSec) => {
  const keys = Object.keys(set);
  return {
    sql: `UPDATE guard_env SET ${keys.map((k, i) => `${k} = ?${i + 3}`).join(", ")}, updated_at_s = ?${keys.length + 3}, gen = gen + 1 WHERE env = ?1 AND gen = ?2`,
    params: [env, gen, ...keys.map((k) => set[k]), nowSec],
  };
};

/** Runs one guard_env change: `{ done: true, set }` or `{ lost: true }` when gen moved since it was read. */
async function commitEnv(x, row, set, nowSec) {
  const [r] = await x.batch([envUpdate(row.env, row.gen, set, nowSec)]);
  return r.changes === 1 ? { done: true, set } : { lost: true };
}

/**
 * `open production --allowance <USD>` / `open staging --allowance <USD> --for <duration>`. Refused while the
 * environment is already open: an allowance is consumed by the guard (limit = spent + allowance), so granting
 * it again on an open environment, or repeating a command whose answer was lost, would add a second
 * allowance on top of the first. To grant a new one, close the environment first.
 */
export async function openEnv(x, { env, allowanceMicros, forS, nowSec, by, cfg }) {
  if (!ENVS.includes(env)) return { refuse: "unknown environment" };
  if (!Number.isSafeInteger(allowanceMicros) || allowanceMicros <= 0) return { refuse: "the allowance must be a positive amount of USD" };
  if (env === "production" && forS !== undefined) return { refuse: "production takes no --for: the guard extends its open_until_s" };
  if (env === "staging" && !(Number.isSafeInteger(forS) && forS > 0 && forS <= cfg.STAGING_WINDOW_MAX_S)) {
    return { refuse: `staging needs --for, longer than 0 and at most ${cfg.STAGING_WINDOW_MAX_S} seconds` };
  }
  const row = await envRow(x, env);
  if (row === null) return { refuse: "guard_env has no row for the environment" };
  if (row.mode === "open") return { refuse: "already open; close it first to grant a new allowance" };
  const set = { mode: "open", stage_a: 0, pending_allowance_micros: allowanceMicros, opened_at_s: nowSec, opened_by: by };
  if (env === "staging") set.open_until_s = nowSec + forS;
  return commitEnv(x, row, set, nowSec);
}

/** `close <env>`. An environment that is not open (closed, or tripped, whose record is kept) is left as it is. */
export async function closeEnv(x, { env, nowSec }) {
  if (!ENVS.includes(env)) return { refuse: "unknown environment" };
  const row = await envRow(x, env);
  if (row === null) return { refuse: "guard_env has no row for the environment" };
  if (row.mode !== "open") return { noop: true, mode: row.mode };
  return commitEnv(x, row, { mode: "closed" }, nowSec);
}

/** `limit production --base <USD>`: the base limit, which the guard applies from the next billing period. */
export async function limitBase(x, { env, baseMicros, nowSec }) {
  if (env !== "production") return { refuse: "only production has a base limit to set" };
  if (!Number.isSafeInteger(baseMicros) || baseMicros <= 0) return { refuse: "the base must be a positive amount of USD" };
  const row = await envRow(x, env);
  if (row === null) return { refuse: "guard_env has no row for the environment" };
  if (row.base_limit_micros === baseMicros) return { noop: true };
  return commitEnv(x, row, { base_limit_micros: baseMicros }, nowSec);
}

/** What `arm` checks, read in one query. */
const ARM_FACTS =
  "SELECT h.arm_requested_s, h.last_measurable_s, " +
  "(SELECT open_until_s FROM guard_env WHERE env = 'production') AS open_until_s, " +
  "(SELECT to_s FROM guard_bill WHERE id = 1) AS bill_to_s, " +
  "(SELECT MAX(to_s) FROM guard_bill_accepts) AS accepted_to_s FROM guard_health h WHERE h.id = 1";

/** The refusals of `arm` on the facts read. Null when it may go ahead. */
export function armRefusal(f, nowSec, cfg) {
  if (f.last_measurable_s === null || f.last_measurable_s < nowSec - cfg.ARM_FRESH_S) return "the guard has not been measurable within the last 10 minutes";
  if (f.open_until_s === null || f.open_until_s - nowSec < cfg.RENEW_WARN_S) return "production's open_until_s is less than RENEW_WARN_S away";
  if (f.bill_to_s === null || f.accepted_to_s === null || f.bill_to_s <= f.accepted_to_s) {
    return "billing reconciliation has not passed a day of its own past the last recon-accept";
  }
  return null;
}

/**
 * `arm`: records the operator's request (guard_health.arm_requested_s). The write repeats every refusal
 * condition in its WHERE, so a state that changed between the read and the write refuses it too, and it
 * writes only while no request is recorded, so a repeated arm keeps the first request.
 */
export async function arm(x, { nowSec, cfg }) {
  const [f] = await x.query(ARM_FACTS);
  if (f === undefined) return { refuse: "guard_health has no row" };
  if (f.arm_requested_s !== null) return { noop: true, arm_requested_s: f.arm_requested_s };
  const refusal = armRefusal(f, nowSec, cfg);
  if (refusal !== null) return { refuse: refusal };
  const [r] = await x.batch([
    {
      sql:
        "UPDATE guard_health SET arm_requested_s = ?1 WHERE id = 1 AND arm_requested_s IS NULL AND last_measurable_s >= ?1 - ?2 " +
        "AND (SELECT open_until_s FROM guard_env WHERE env = 'production') - ?1 >= ?3 " +
        "AND (SELECT to_s FROM guard_bill WHERE id = 1) > (SELECT MAX(to_s) FROM guard_bill_accepts)",
      params: [nowSec, cfg.ARM_FRESH_S, cfg.RENEW_WARN_S],
    },
  ]);
  return r.changes === 1 ? { done: true } : { lost: true };
}

/** `ledger-bridge`: bridges every dataset whose ledger is stalled now (bridgePlan), one batch each. */
export async function ledgerBridge(x, { nowSec, by, cfg }) {
  const rows = await x.query("SELECT dataset, to_s FROM guard_ledger");
  const ledger = Object.fromEntries(rows.map((r) => [r.dataset, r]));
  if (!ledger.workers || !ledger.d1) return { refuse: "guard_ledger has no row for a dataset; the ledger has not started" };
  const since = Math.min(...rows.map((r) => Math.min(r.to_s, nowSec - cfg.H_W_S))) - cfg.CELL_S;
  const runs = (await x.query("SELECT started_s FROM guard_runs WHERE started_s >= ?1", [since])).map((r) => r.started_s);
  const gaps = await x.query("SELECT dataset, cell FROM guard_gaps");
  const plan = bridgePlan({ ledger, runs, gaps, nowSec, cfg });
  if (plan.length === 0) return { noop: true };
  const done = [];
  for (const b of plan) {
    const r = await x.batch(bridgeStatements(b, nowSec, by));
    done.push({ ...b, moved: r[1].changes === 1 });
  }
  return { bridged: done };
}

/** `recon-accept production --through <day>` (reconAcceptPlan, reconAcceptStatements). */
export async function reconAccept(x, { env, through, nowSec, by, cfg }) {
  if (env !== "production") return { refuse: "only production is reconciled" };
  const [row] = await x.query("SELECT to_s FROM guard_bill WHERE id = 1");
  const plan = reconAcceptPlan({ through, old: row?.to_s ?? null, nowSec });
  if (plan.refuse !== undefined || plan.noop) return plan;
  const r = await x.batch(reconAcceptStatements(plan, nowSec, by, cfg));
  return r[1].changes === 1 ? { done: true, old: plan.old, new: plan.new } : { lost: true };
}

/** `status`: the values the guard's D1 holds. Writes nothing. */
export async function status(x) {
  const one = async (sql) => (await x.query(sql))[0] ?? null;
  return {
    env: await x.query(
      "SELECT env, gen, mode, stage_a, base_limit_micros, limit_micros, pending_allowance_micros, warn_permille, open_until_s, " +
        "tripped_at_s, trip_reason, spent_at_trip_micros FROM guard_env ORDER BY env",
    ),
    health: await one("SELECT * FROM guard_health WHERE id = 1"),
    runs_last_hour: (await one("SELECT COUNT(*) AS n FROM guard_runs WHERE started_s >= unixepoch() - 3600")).n,
    gaps: (await one("SELECT COUNT(*) AS n FROM guard_gaps")).n,
    ledger: await x.query("SELECT dataset, from_s, to_s FROM guard_ledger ORDER BY dataset"),
    holes: (await one("SELECT COUNT(*) AS n FROM guard_holes")).n,
    bill: await one("SELECT from_s, to_s, last_try_s, last_verdict, last_day FROM guard_bill WHERE id = 1"),
    bill_accepts: (await one("SELECT COUNT(*) AS n FROM guard_bill_accepts")).n,
    alerts: await x.query("SELECT key, since_s FROM guard_alerts ORDER BY key"),
  };
}
