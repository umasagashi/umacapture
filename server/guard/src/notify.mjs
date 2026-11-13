// The guard's notifications: condition x latch.
//
// Each notification that has a lasting condition has a key in guard_alerts while its start was sent. A run
// judges every condition it could read the facts of:
//  - true with no row: the start is sent first, and the row is written only once Sentry took it;
//  - false with a row: a condition with an end notification sends it first and deletes the row only once
//    Sentry took it; any other condition deletes the row;
//  - not judged (its input could not be read): the row is left as it is.
// A failed send writes nothing, so the next run sends again. The order guards against a lost notification,
// not against a doubled one: a run stopping between the send and the write, or two runs overlapping, can
// send the same start twice. decide() and converge() never read guard_alerts.
//
// Events of something that happened once (probe_lost, bill_mismatch) have no latch: each is sent once by
// the run it happened in.

/** A lasting condition: `holds` true, false, or undefined (not judged); `start` and the optional `end(sinceS)` are `{ name, extra }`. */
export const condition = (key, holds, start, end = null) => ({ key, holds, start, end });

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
      if (!(await sendSafe(c.start))) continue;
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
 * without a guard_ledger row; `gapsInserted` per dataset) and measurability.
 */
export function readConditions({ read, ledgerMissing, gapsInserted, measurable, nowSec }) {
  const items = [
    condition(
      "blind",
      !measurable,
      { name: "blind_start", extra: {} },
      (since) => ({ name: "blind_end", extra: { blind_s: nowSec - since } }),
    ),
  ];
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
 * one rule G needs a PATCH (patchNeeded), for patch_failed's end.
 */
export function ruleConditions({ cls, conv, armed, patchWanted }) {
  const items = [condition("rules_unreadable", cls.kind === "unreadable", { name: "rules_unreadable", extra: {} })];
  if (!armed || cls.kind === "unreadable") return items;
  items.push(condition("entrypoint_missing", cls.kind === "missing", { name: "entrypoint_missing", extra: {} }));
  if (cls.kind !== "rules") return items;
  items.push(condition("rule_missing", cls.count === 0, { name: "rule_missing", extra: {} }));
  items.push(condition("rule_ambiguous", cls.count >= 2, { name: "rule_ambiguous", extra: { count: cls.count } }));
  if (cls.count === 1) items.push(condition("rule_tampered", !cls.protecting, { name: "rule_tampered", extra: {} }));
  const failed = conv?.action === "patch" && conv.failure !== null;
  const fine = cls.count === 1 && cls.protecting && !patchWanted;
  items.push(condition("patch_failed", failed ? true : fine ? false : undefined, { name: "patch_failed", extra: { status: conv?.failure?.status ?? null } }));
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
