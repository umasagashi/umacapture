// The guard's notifications: condition x latch.
//
// Each lasting condition has a key in guard_alerts. A condition that is sent holds its row while its start
// was sent; a condition that is recorded only (no start: blind, rules_unreadable, patch_failed,
// close_applied) holds its row while the condition holds, and is sent to no one. A run judges every
// condition it could read the facts of:
//  - true with no row: a sent condition sends its start first, and the row is written only once Sentry took
//    it; a recorded condition writes the row;
//  - false with a row: a condition with an end notification sends it first and deletes the row only once
//    Sentry took it; any other condition deletes the row;
//  - not judged (its input could not be read): the row is left as it is.
// A failed send writes nothing, so the next run sends again. The order guards against a lost notification,
// not against a doubled one: a run stopping between the send and the write, or two runs overlapping, can
// send the same start twice. decide() and converge() never read guard_alerts.
//
// Events of something that happened once (probe_lost, bill_mismatch) have no latch: each is sent once by
// the run it happened in.

import { leaseHorizonS } from "./lease.mjs";

/** A lasting condition: `holds` true, false, or undefined (not judged); `start` and the optional `end(sinceS)` are `{ name, extra }`, `start` null for a condition recorded only. */
export const condition = (key, holds, start, end = null) => ({ key, holds, start, end });

/** A lasting condition recorded in guard_alerts and sent to no one. */
export const record = (key, holds) => condition(key, holds, null);

/** A one-off event. */
export const once = (name, extra) => ({ once: { name, extra } });

/**
 * Sends and latches `items` (conditions and one-off events) for the run at nowSec. `alerts` maps a key to
 * its row's since_s as the run read guard_alerts, and is updated as rows are written. `send({ name, extra })`
 * resolves to whether the notification was taken.
 */
export async function notify(db, send, alerts, items, nowSec) {
  const sendSafe = (event) => send(event).then((ok) => ok === true, () => false);
  for (const c of items) {
    if (c.once !== undefined) {
      await sendSafe(c.once);
      continue;
    }
    const since = alerts.get(c.key);
    if (c.holds === true && since === undefined) {
      if (c.start !== null && !(await sendSafe(c.start))) continue;
      const ok = await db
        .prepare("INSERT OR IGNORE INTO guard_alerts (key, since_s) VALUES (?1, ?2)")
        .bind(c.key, nowSec)
        .run()
        .then(() => true, () => false);
      if (ok) alerts.set(c.key, nowSec);
    } else if (c.holds === false && since !== undefined) {
      if (c.end !== null && !(await sendSafe(c.end(since)))) continue;
      const ok = await db
        .prepare("DELETE FROM guard_alerts WHERE key = ?1 AND since_s = ?2")
        .bind(c.key, since)
        .run()
        .then(() => true, () => false);
      if (ok) alerts.delete(c.key);
    }
  }
}

const ENVS = Object.freeze(["production", "staging"]);

/**
 * The conditions a run can judge from guard_env alone (`env`: both rows as they stand after the run's
 * committed transitions): trip and stage_a per environment, and lease_closing_soon for production. The
 * conditions an api_backoff run still sends.
 */
export function stateConditions(env, nowSec, cfg) {
  const items = [];
  for (const e of ENVS) {
    const s = env[e];
    items.push(
      condition(`trip:${e}`, s.mode === "tripped", {
        name: "trip",
        extra: { env: e, spent_at_trip_micros: s.spent_at_trip_micros, limit_micros: s.limit_micros },
      }),
    );
    items.push(condition(`stage_a:${e}`, s.stage_a === 1, { name: "stage_a", extra: { env: e, limit_micros: s.limit_micros } }));
  }
  // Production only: staging's open_until_s is the end the operator chose for a test window.
  const p = env.production;
  const closing = p.mode === "open" && p.open_until_s !== null && nowSec < p.open_until_s && p.open_until_s <= nowSec + cfg.RENEW_WARN_S;
  items.push(condition("lease_closing_soon", closing, { name: "lease_closing_soon", extra: { open_until_s: p.open_until_s } }));
  return items;
}

/** The probe_rows_mismatch condition: whether the run's guard_runs INSERT wrote PROBE_ROWS rows. */
export const probeConditions = (mismatch, rowsWritten, cfg) =>
  condition("probe_rows_mismatch", mismatch, { name: "probe_rows_mismatch", extra: { rows_written: rowsWritten, probe_rows: cfg.PROBE_ROWS } });

/**
 * The conditions of the run's reading (`read`, combineRead's result), the ledger (`ledgerMissing`: datasets
 * without a guard_ledger row; `gapsInserted` per dataset) and measurability. Not measuring is recorded
 * only (blind): what it costs is the lease running out, which lease_expired reports.
 */
export function readConditions({ read, ledgerMissing, gapsInserted, measurable }) {
  const items = [record("blind", !measurable)];
  for (const d of Object.keys(read.datasets)) {
    const ds = read.datasets[d];
    const stalled = ledgerMissing.includes(d) ? true : ds.stalled === null ? undefined : ds.stalled;
    items.push(condition(`ledger_stalled:${d}`, stalled, { name: "ledger_stalled", extra: { dataset: d } }));
    if (ds.lost && (gapsInserted[d] ?? 0) > 0) items.push(once("probe_lost", { dataset: d, cells: gapsInserted[d] }));
  }
  for (const name of read.datasets.workers?.unknownScripts ?? []) {
    items.push(condition(`unknown_script:${name}`, true, { name: "unknown_script", extra: { script: name } }));
  }
  return items;
}

/**
 * The conditions of the GET of the entry point (`cls`, classifyRules' result) and of the run's write
 * (`conv`, converge's result or null when nothing was attempted). `armed` is whether the operator asked
 * for the rule; before that, only whether the GET could be read is judged. `patchWanted` is whether the
 * one rule G needs a PATCH (patchNeeded), for patch_failed's end. `alerts` is guard_alerts as the run read
 * it.
 *
 * An unreadable GET and a failed PATCH are recorded only (rules_unreadable, patch_failed): what a failure
 * costs is reported by what it left — lease_expired, close_unapplied, the per-environment arms of
 * closeConditions, rule_*. rules_unreadable:lasting is sent once the GET has been unreadable for
 * leaseHorizonS (from the rules_unreadable row's since_s): the guard has then neither read nor written G
 * for longer than any lease it writes lasts, whether or not G was in the protecting form.
 */
export function ruleConditions({ cls, conv, armed, patchWanted, alerts, nowSec, cfg }) {
  const unreadable = cls.kind === "unreadable";
  const since = alerts.get("rules_unreadable");
  const lasting = unreadable && since !== undefined && nowSec >= since + leaseHorizonS(cfg);
  const items = [
    record("rules_unreadable", unreadable),
    condition("rules_unreadable:lasting", lasting, { name: "rules_unreadable", extra: { since_s: since ?? null } }),
  ];
  if (!armed || unreadable) return items;
  items.push(condition("entrypoint_missing", cls.kind === "missing", { name: "entrypoint_missing", extra: {} }));
  if (cls.kind !== "rules") return items;
  items.push(condition("rule_missing", cls.count === 0, { name: "rule_missing", extra: {} }));
  items.push(condition("rule_ambiguous", cls.count >= 2, { name: "rule_ambiguous", extra: { count: cls.count } }));
  if (cls.count === 1) items.push(condition("rule_tampered", !cls.protecting, { name: "rule_tampered", extra: {} }));
  const failed = conv?.action === "patch" && conv.failure !== null;
  const fine = cls.count === 1 && cls.protecting && !patchWanted;
  items.push(record("patch_failed", failed ? true : fine ? false : undefined));
  return items;
}

/**
 * The lease rule G holds after the run, as far as the run knows it: the lease its POST or PATCH wrote when
 * the API answered a success, else the times its GET read from one G in the protecting form; null when
 * neither is known.
 */
export const leftLease = (cls, conv) => conv?.wrote ?? (cls.kind === "rules" && cls.count === 1 && cls.protecting ? cls.cur : null);

/**
 * lease_expired: production is open, but rule G closes (or closed) it because its lease ran out — whatever
 * kept the guard from extending it (not measuring, a hold, open_until_s, a failed write, a backoff, an
 * unreadable GET). Judged only by a run whose view of guard_env is current (`fresh`: its commit held and no
 * other writer moved gen since), and only once the rule is armed. `env` is guard_env after the run's
 * transitions, `health` and `alerts` guard_health and guard_alerts as the run read them. The basis:
 *  - after_run: the lease G is left holding has run out;
 *  - before_write: the GET read a positive Ep that ran out after production was last opened (opened_at_s;
 *    mode cannot have left 'open' since, as only `open` writes 'open' and it always writes opened_at_s), so
 *    production was closed while open even when this run extended it again;
 *  - inferred: the GET is unreadable, G was last read in the protecting form (rule_seen_since_s), and the
 *    GET has been unreadable for leaseHorizonS: every time G holds was written before that and has passed.
 * No end notification: whether production opened again is what `status` shows.
 */
export function leaseConditions({ cls, conv, fresh, armed, env, health, alerts, nowSec, cfg }) {
  if (!armed) return [];
  const p = env.production;
  const left = leftLease(cls, conv);
  const seen = cls.kind === "rules" && cls.count === 1 && cls.protecting ? cls.cur.Ep : null;
  const opened = p.opened_at_s ?? 0;
  const unreadableSince = alerts.get("rules_unreadable");
  let basis;
  let holds;
  if (!fresh) holds = undefined;
  else if (p.mode !== "open") holds = false;
  else if (left !== null && left.Ep <= nowSec) [holds, basis] = [true, "after_run"];
  else if (seen !== null && seen > 0 && seen <= nowSec && seen >= opened) [holds, basis] = [true, "before_write"];
  else if (left !== null) holds = false;
  else if (
    cls.kind === "unreadable" &&
    health.rule_seen_since_s !== null &&
    unreadableSince !== undefined &&
    nowSec >= unreadableSince + leaseHorizonS(cfg)
  ) {
    [holds, basis] = [true, "inferred"];
  } else holds = undefined;
  const extra = {
    basis: basis ?? null,
    ep: left?.Ep ?? null,
    seen_ep: seen,
    opened_at_s: p.opened_at_s ?? null,
    open_until_s: p.open_until_s ?? null,
    blind_since_s: alerts.get("blind") ?? null,
    rules_unreadable_since_s: unreadableSince ?? null,
  };
  return [condition("lease_expired", holds, { name: "lease_expired", extra })];
}

const ENV_NAMES = Object.freeze(["production", "staging"]);

/**
 * What rule G can be asked to close of each environment, each with the close_applied record that G was
 * seen carrying it, and whether a lease `l` still lets it through at nowSec:
 *  - "env": every request to the environment — production closed or tripped (blocked once Ep has passed),
 *    staging not open (blocked once Ep or Es has passed);
 *  - "stage_a": production's dynamic paths, while production is open with stage A latched (blocked once Ep
 *    or Ea has passed). Ep may lie ahead while Ea is 0, so G carrying stage A is no evidence that it
 *    carries production's closing.
 */
const TARGETS = Object.freeze({
  production: Object.freeze({
    env: { applied: "close_applied:production", passes: (l, nowSec) => l.Ep > nowSec },
    stage_a: { applied: "close_applied:production:stage_a", passes: (l, nowSec) => l.Ep > nowSec && l.Ea > nowSec },
  }),
  staging: Object.freeze({
    env: { applied: "close_applied:staging", passes: (l, nowSec) => l.Ep > nowSec && l.Es > nowSec },
  }),
});

/** What rule G is to close of environment `e` in state `s` (a TARGETS entry), or null when nothing. */
const closingTarget = (e, s) => (s.mode !== "open" ? TARGETS[e].env : e === "production" && s.stage_a === 1 ? TARGETS[e].stage_a : null);

/**
 * The conditions of an environment that is to be closed (closingTarget): trip, close, the end of staging's
 * window, or production's stage A. Judged only for an armed rule and by a `fresh` run; `env`, `alerts`,
 * `cls` and `conv` as for the other conditions. Per environment, each keyed and sent with its name:
 *  - close_unapplied:<env> (sent): the lease G is left holding (leftLease) still lets through what is to be
 *    closed. Not judged while that lease is unknown.
 *  - close_applied:<env>, and close_applied:production:stage_a for stage A (recorded only): G was seen
 *    carrying that closing — the run's leftLease closes it. Each is deleted once its closing is no longer
 *    the one to carry, so the absence of the record of the closing now intended means the guard has not
 *    yet seen G carry it; G carrying stage A says nothing of production's later close or trip.
 *  - rules_unreadable:<env> and patch_failed:<env> (sent): the GET could not be read, or the PATCH failed,
 *    while the closing is not known to be in G (G's known lease passes, or, with no known lease, the
 *    closing's close_applied record is absent). While nothing is to be closed, or once G carries the
 *    closing, these failures are recorded only (ruleConditions).
 * Every event carries the environment as extra.env, so each environment groups into its own issue.
 */
export function closeConditions({ cls, conv, fresh, armed, env, alerts, nowSec }) {
  if (!armed) return [];
  const left = leftLease(cls, conv);
  const failed = conv?.action === "patch" && conv.failure !== null;
  const items = [];
  for (const e of ENV_NAMES) {
    const s = env[e];
    const target = closingTarget(e, s);
    // Through the lease G is left holding: whether it still lets the target through (undefined: not known).
    const through = !fresh || target === null || left === null ? undefined : target.passes(left, nowSec);
    const unapplied = !fresh ? undefined : target === null ? false : through;
    const pending = !fresh ? undefined : target === null ? false : through ?? !alerts.has(target.applied);
    const state = { env: e, mode: s.mode, stage_a: s.stage_a };
    items.push(
      condition(`close_unapplied:${e}`, unapplied, {
        name: "close_unapplied",
        extra: { ...state, ep: left?.Ep ?? null, es: left?.Es ?? null, ea: left?.Ea ?? null },
      }),
      ...Object.values(TARGETS[e]).map((t) =>
        record(t.applied, !fresh ? undefined : t !== target ? false : through === undefined ? undefined : !through),
      ),
      condition(`rules_unreadable:${e}`, cls.kind === "unreadable" ? pending : false, { name: "rules_unreadable", extra: state }),
      condition(`patch_failed:${e}`, failed ? pending : pending === false ? false : undefined, {
        name: "patch_failed",
        extra: { ...state, status: conv?.failure?.status ?? null },
      }),
    );
  }
  return items;
}

/**
 * The conditions of a billing reconciliation attempt (`bill`, reconcileBilling's result). Nothing is judged
 * when no attempt was made; an unreadable answer judges nothing about unmapped rows.
 */
export function billConditions(bill) {
  if (!bill.tried) return [];
  const items = [condition("bill_unreadable", bill.unreadable, { name: "bill_unreadable", extra: { day: bill.day } })];
  const unmapped = bill.verdict === "unmapped" ? true : bill.unreadable ? undefined : false;
  items.push(condition("bill_unmapped", unmapped, { name: "bill_unmapped", extra: { ...(bill.unmapped ?? {}) } }));
  if (bill.mismatch !== null) items.push(once("bill_mismatch", { ...bill.mismatch }));
  return items;
}

/**
 * ledger_undercount, at most once a day: the key carries the day, and the daily sweep removes earlier
 * days' keys. `raised` are rereadRaise's raised columns of this run; the largest difference is attached.
 */
export function undercountConditions(raised, day) {
  if (raised.length === 0) return [];
  const top = raised.reduce((a, b) => (b.read - b.ledger > a.read - a.ledger ? b : a));
  return [condition(`ledger_undercount:${day}`, true, { name: "ledger_undercount", extra: { ...top, raised: raised.length } })];
}
