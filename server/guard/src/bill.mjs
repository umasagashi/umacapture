// Billing reconciliation: the Billable Usage API's rows (the bill) compared with the guard's ledger, one
// UTC day and one metric at a time. A day whose four metrics all agree moves guard_bill.to_s past it, and
// production's open_until_s to that point + T_R_S. A day that disagrees or lacks evidence stops the walk;
// no day is skipped. Production stays open until open_until_s, so a bill the guard cannot read or match
// closes production T_R_S after the last day that matched.
//
// The request to the API is made by a function the caller hands in (`fetchBill`); nothing here sends one.

import { dayOf, dayStart, periodStart } from "./time.mjs";

const DAY_S = 86_400;
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
const MIDNIGHT_RE = /^(\d{4}-\d{2}-\d{2})T00:00:00Z$/;

/** The key of a row kind in cfg.BILL_CLASS: ServiceName and ConsumedUnit, exactly as the row has them. */
export const billKey = (serviceName, consumedUnit) => `${serviceName}\u0000${consumedUnit}`;

/** The class entry of a row, or null when its kind is unknown (a missing or non-string name or unit is unknown). */
const classOf = (row, cfg) => {
  if (typeof row?.ServiceName !== "string" || typeof row.ConsumedUnit !== "string") return null;
  return Object.hasOwn(cfg.BILL_CLASS, billKey(row.ServiceName, row.ConsumedUnit)) ? cfg.BILL_CLASS[billKey(row.ServiceName, row.ConsumedUnit)] : null;
};

/** The day (its first instant) a row covers when its period is exactly one UTC day, 00:00:00Z to the next 00:00:00Z; else null. */
function dayOfRow(row) {
  const s = MIDNIGHT_RE.exec(row.ChargePeriodStart ?? "");
  const e = MIDNIGHT_RE.exec(row.ChargePeriodEnd ?? "");
  if (s === null || e === null) return null;
  const start = dayStart(s[1]);
  if (!Number.isFinite(start) || dayOf(start) !== s[1] || dayStart(e[1]) !== start + DAY_S) return null;
  return start;
}

/** A unit description of a row for bill_unmapped: its kind and the day it starts, nothing else of the row. */
const describe = (row) => ({
  ServiceName: typeof row?.ServiceName === "string" ? row.ServiceName : null,
  ConsumedUnit: typeof row?.ConsumedUnit === "string" ? row.ConsumedUnit : null,
  day: typeof row?.ChargePeriodStart === "string" ? row.ChargePeriodStart.slice(0, 10) : null,
});

/**
 * The query range for a reconciliation from `toS`: from the first day of the billing period holding the
 * candidate day, up to and excluding tomorrow (UTC), so today's rows are included. Days as `YYYY-MM-DD`.
 */
export const billRange = (toS, nowSec, cfg) => ({ from: dayOf(periodStart(toS, cfg)), to: dayOf(dayStart(dayOf(nowSec)) + DAY_S) });

/** The request path for a range: `GET /accounts/{id}/billable-usage?from=F&to=T`. */
export const billPath = (accountId, { from, to }) => `/accounts/${accountId}/billable-usage?from=${from}&to=${to}`;

/**
 * Reads a Billable Usage response. Refuses it (`unreadable`) when the status is not 200, `success` is not
 * true, `errors` is not an empty array, `result` is not a non-empty array, or the response says there are
 * more pages. Refuses it (`unmapped`, with the first such row's kind and day) when any row, on any day, is of
 * a kind cfg.BILL_CLASS does not hold, or of a retired kind on a day from BILL_RETIRED_END_S on. Refuses
 * it (`unreadable`) when a row of a reconciled kind is not in USD, has a ConsumedQuantity that is not a
 * finite number >= 0, or a period that is not one UTC day. Storage and retired rows are not read further.
 */
export function parseBill({ status, body, cfg }) {
  const unreadable = { ok: false, reason: "unreadable" };
  if (status !== 200 || body === null || typeof body !== "object") return unreadable;
  if (body.success !== true || !Array.isArray(body.errors) || body.errors.length !== 0) return unreadable;
  if (!Array.isArray(body.result) || body.result.length === 0) return unreadable;
  const info = body.result_info;
  if (info !== undefined && info !== null && (info.cursor || (Number.isFinite(info.total_pages) && Number.isFinite(info.page) && info.page < info.total_pages))) return unreadable;
  for (const row of body.result) {
    const c = classOf(row, cfg);
    if (c === null) return { ok: false, reason: "unmapped", row: describe(row) };
    if (c.class === "retired") {
      const start = Date.parse(row.ChargePeriodStart);
      if (typeof row.ChargePeriodStart !== "string" || !Number.isFinite(start) || start / 1000 >= cfg.BILL_RETIRED_END_S) {
        return { ok: false, reason: "unmapped", row: describe(row) };
      }
    }
  }
  for (const row of body.result) {
    if (classOf(row, cfg).class !== "reconcile") continue;
    const q = row.ConsumedQuantity;
    if (row.BillingCurrency !== "USD" || typeof q !== "number" || !Number.isFinite(q) || q < 0 || dayOfRow(row) === null) return unreadable;
  }
  return { ok: true, rows: body.result };
}

/**
 * The bill's quantity per day and metric, from the rows of reconciled kinds only: a Map from a day's first
 * instant to `{ metric: ConsumedQuantity x multiplier, summed }`. A (day, metric) with no row has no entry;
 * it is never 0. `rows` passed parseBill.
 */
export function groupByDayAndMetric(rows, cfg) {
  const bill = new Map();
  for (const row of rows) {
    const c = classOf(row, cfg);
    if (c === null || c.class !== "reconcile") continue;
    const d = dayOfRow(row);
    const day = bill.get(d) ?? {};
    day[c.metric] = (day[c.metric] ?? 0) + row.ConsumedQuantity * c.multiplier;
    bill.set(d, day);
  }
  return bill;
}

/**
 * One metric of one day: "pass" when the bill has the day's row and a newer day's row of the same metric
 * and both sides agree within BILL_TAU x ledger + BILL_A_MICROS (in micro-USD at the metric's price, both
 * directions); "fail" when both rows are there and they do not agree; "none" otherwise.
 */
export function judge(m, d, bill, led, cfg) {
  const q = bill.get(d)?.[m];
  if (q === undefined) return "none";
  let newer = false;
  for (const [day, metrics] of bill) if (day > d && metrics[m] !== undefined) newer = true;
  if (!newer) return "none";
  const xBill = q * cfg.PRICE_MICROS[m];
  const xLed = led[m] * cfg.PRICE_MICROS[m];
  return Math.abs(xBill - xLed) <= cfg.BILL_TAU * xLed + cfg.BILL_A_MICROS ? "pass" : "fail";
}

/**
 * Walks the days from `toS` (00:00 UTC) while every metric of a day passes, stopping at the first day that
 * has not ended, whose ledger is incomplete (`ledgerDay(d)` null), that disagrees (`mismatch`, with the
 * first disagreeing metric) or that lacks a row (`no_row`). Returns the new reach `to`, `openUntil` (`to +
 * T_R_S` when `to` moved, else null) and the verdict of the day it stopped at. `to` never passes nowSec, so
 * openUntil never passes nowSec + T_R_S. A `toS` that is not 00:00 UTC moves nothing.
 */
export function reconcile({ toS, rows, ledgerDay, nowSec, cfg }) {
  if (!Number.isSafeInteger(toS) || toS % DAY_S !== 0) return { to: toS, openUntil: null, verdict: "bad_reach", detail: null };
  const bill = groupByDayAndMetric(rows, cfg);
  let to = toS;
  let verdict = "none";
  let detail = null;
  for (;;) {
    const d = to;
    if (d + DAY_S > nowSec) break;
    const led = ledgerDay(d);
    if (led === null) {
      verdict = "ledger_incomplete";
      break;
    }
    const js = cfg.METRICS.map((m) => judge(m, d, bill, led, cfg));
    const failed = js.indexOf("fail");
    if (failed >= 0) {
      const m = cfg.METRICS[failed];
      verdict = "mismatch";
      detail = { day: dayOf(d), metric: m, bill: bill.get(d)[m], ledger: led[m] };
      break;
    }
    if (js.includes("none")) {
      verdict = "no_row";
      break;
    }
    to = d + DAY_S;
  }
  return { to, openUntil: to > toS ? to + cfg.T_R_S : null, verdict, detail };
}

/**
 * The ledger's side of every day from `fromS` (00:00 UTC) that ends at or before `untilS`: a Map from the
 * day's first instant to its four metrics summed over every environment (an environment's guard_daily row
 * when it has one, else its guard_cells of the day), or to null when the ledger cannot speak for the day —
 * the day ends after min(guard_ledger.to_s) - H_W_S, starts before either dataset's from_s, or overlaps a
 * guard_holes stretch. With fewer than two guard_ledger rows every day is null.
 */
export async function readLedgerDays(db, { fromS, untilS }, cfg) {
  const days = new Map();
  if (untilS - fromS < DAY_S) return days;
  const ledger = (await db.prepare("SELECT from_s, to_s FROM guard_ledger").all()).results;
  const holes = (await db.prepare("SELECT from_s, to_s FROM guard_holes WHERE to_s > ?1 AND from_s < ?2").bind(fromS, untilS).all()).results;
  const cols = cfg.METRICS;
  const sums = cols.map((k) => `SUM(${k}) AS ${k}`).join(", ");
  const { results } = await db
    .prepare(
      `SELECT day, ${sums} FROM (` +
        `SELECT day, ${cols.join(", ")} FROM guard_daily WHERE day >= ?1 AND day < ?2 ` +
        `UNION ALL SELECT strftime('%Y-%m-%d', c.cell * ?5, 'unixepoch') AS day, ${cols.map((k) => `c.${k}`).join(", ")} FROM guard_cells c ` +
        `WHERE c.cell >= ?3 AND c.cell < ?4 AND NOT EXISTS (SELECT 1 FROM guard_daily g WHERE g.env = c.env AND g.day = strftime('%Y-%m-%d', c.cell * ?5, 'unixepoch'))` +
        `) GROUP BY day`,
    )
    .bind(dayOf(fromS), dayOf(untilS), Math.floor(fromS / cfg.CELL_S), Math.floor(untilS / cfg.CELL_S), cfg.CELL_S)
    .all();
  const byDay = new Map(results.map((r) => [r.day, r]));
  const complete = ledger.length === 2;
  const reach = complete ? Math.min(...ledger.map((r) => r.to_s)) - cfg.H_W_S : -Infinity;
  const start = complete ? Math.max(...ledger.map((r) => r.from_s)) : Infinity;
  for (let d = fromS; d + DAY_S <= untilS; d += DAY_S) {
    const covered = d + DAY_S <= reach && d >= start && !holes.some((h) => h.from_s < d + DAY_S && h.to_s > d);
    const r = byDay.get(dayOf(d));
    days.set(d, covered ? Object.fromEntries(cols.map((k) => [k, r?.[k] ?? 0])) : null);
  }
  return days;
}

/**
 * One reconciliation attempt, run at the end of a guard run. Does nothing while guard_bill.to_s is NULL
 * (before the operator's first recon-accept) or less than BILL_STEP_S after the last attempt. Otherwise it
 * first claims the attempt (last_try_s, compare-and-set on the value read); only the run that wins calls
 * `fetchBill(path)` — which returns `{ status, body }` and may throw — once. A day range that moved is
 * written in one batch, guard_bill.to_s and production's open_until_s together, conditional on the to_s
 * read; otherwise only last_verdict and last_day are written.
 *
 * Returns what the notifications need: `{ tried, verdict, day, unreadable, unmapped, mismatch, advanced }`,
 * where `unreadable` is true when the API failed or its answer was refused, `unmapped` is the kind and day
 * of an unknown or retired row, and `mismatch` the day, metric and both quantities that disagreed.
 */
export async function reconcileBilling(db, { fetchBill, accountId, nowSec, cfg }) {
  const none = { tried: false, verdict: null, day: null, unreadable: false, unmapped: null, mismatch: null, advanced: false };
  const st = await db.prepare("SELECT to_s, last_try_s FROM guard_bill WHERE id = 1").first();
  if (st === null || st.to_s === null) return none;
  if (st.last_try_s !== null && nowSec - st.last_try_s < cfg.BILL_STEP_S) return none;
  let claimed;
  try {
    const r = await db
      .prepare("UPDATE guard_bill SET last_try_s = ?1 WHERE id = 1 AND last_try_s IS ?2 AND to_s IS NOT NULL")
      .bind(nowSec, st.last_try_s)
      .run();
    claimed = r.meta.changes === 1;
  } catch {
    claimed = false;
  }
  if (!claimed) return none;
  const toS = st.to_s;
  const note = (verdict, day) =>
    db.prepare("UPDATE guard_bill SET last_verdict = ?1, last_day = ?2 WHERE id = 1").bind(verdict, day).run().catch(() => null);
  let answer;
  try {
    answer = await fetchBill(billPath(accountId, billRange(toS, nowSec, cfg)));
  } catch {
    answer = null;
  }
  const parsed = answer === null ? { ok: false, reason: "unreadable" } : parseBill({ status: answer.status, body: answer.body, cfg });
  if (!parsed.ok) {
    await note(parsed.reason, dayOf(toS));
    return { ...none, tried: true, verdict: parsed.reason, day: dayOf(toS), unreadable: parsed.reason === "unreadable", unmapped: parsed.row ?? null };
  }
  const days = await readLedgerDays(db, { fromS: toS, untilS: nowSec }, cfg);
  const r = reconcile({ toS, rows: parsed.rows, ledgerDay: (d) => days.get(d) ?? null, nowSec, cfg });
  const result = { ...none, tried: true, verdict: r.verdict, day: dayOf(r.to), mismatch: r.detail };
  if (r.openUntil === null) {
    await note(r.verdict, dayOf(r.to));
    return result;
  }
  try {
    const [bill] = await db.batch(advanceStatements({ old: toS, ...r }, nowSec, cfg).map((s) => db.prepare(s.sql).bind(...s.params)));
    return { ...result, advanced: bill.meta.changes === 1 };
  } catch {
    return result;
  }
}

/**
 * The batch that moves the reach from `old` to `to` after a reconciliation: guard_bill.to_s conditional on
 * the to_s read, and production's open_until_s conditional on guard_bill.to_s being `to` (so it is written
 * only alongside that reach, by this run or by one that wrote the same value). guard_env.gen is not moved.
 */
export const advanceStatements = ({ old, to, verdict }, nowSec, cfg) => [
  { sql: "UPDATE guard_bill SET to_s = ?1, last_verdict = ?2, last_day = ?3 WHERE id = 1 AND to_s = ?4", params: [to, verdict, dayOf(to), old] },
  {
    sql: "UPDATE guard_env SET open_until_s = ?1 + ?2, updated_at_s = ?3 WHERE env = 'production' AND (SELECT to_s FROM guard_bill WHERE id = 1) = ?1",
    params: [to, cfg.T_R_S, nowSec],
  },
];

/**
 * `guard.sh recon-accept production --through <day>`: what accepting every day up to and including `through`
 * (UTC, `YYYY-MM-DD`) would do, given guard_bill.to_s as read (`old`). Returns `{ refuse: reason }`,
 * `{ noop: true }` when `through` is already the reach, or `{ old, new }` to write.
 */
export function reconAcceptPlan({ through, old, nowSec }) {
  if (typeof through !== "string" || !DAY_RE.test(through) || !Number.isFinite(dayStart(through)) || dayOf(dayStart(through)) !== through) {
    return { refuse: "not a UTC day written YYYY-MM-DD" };
  }
  const to = dayStart(through) + DAY_S;
  if (to > nowSec) return { refuse: "the day has not ended" };
  if (old !== null && to === old) return { noop: true };
  if (old !== null && to < old) return { refuse: "the day lies before the current reach" };
  return { old, new: to };
}

/**
 * The batch of a recon-accept: the acceptance record, guard_bill.to_s (and from_s when unset) and
 * production's open_until_s, every statement conditional on guard_bill.to_s still being `old`, so a lost
 * race writes nothing at all.
 */
export const reconAcceptStatements = ({ old, new: to }, nowSec, by, cfg) => [
  {
    sql: "INSERT INTO guard_bill_accepts (from_s, to_s, accepted_at_s, accepted_by) SELECT COALESCE(?1, ?2 - 86400), ?2, ?3, ?4 WHERE (SELECT to_s FROM guard_bill WHERE id = 1) IS ?1",
    params: [old, to, nowSec, by],
  },
  { sql: "UPDATE guard_bill SET to_s = ?2, from_s = COALESCE(from_s, ?2) WHERE id = 1 AND to_s IS ?1", params: [old, to] },
  {
    sql: "UPDATE guard_env SET open_until_s = ?1 + ?2, updated_at_s = ?3 WHERE env = 'production' AND (SELECT to_s FROM guard_bill WHERE id = 1) = ?1",
    params: [to, cfg.T_R_S, nowSec],
  },
];

/** Runs a recon-accept on a D1 binding. Returns the plan's refusal or no-op, `{ accepted: true }`, or `{ lost: true }` when another writer moved to_s first. */
export async function applyReconAccept(db, { through, nowSec, by, cfg }) {
  const row = await db.prepare("SELECT to_s FROM guard_bill WHERE id = 1").first();
  const plan = reconAcceptPlan({ through, old: row?.to_s ?? null, nowSec });
  if (plan.refuse !== undefined || plan.noop) return plan;
  const results = await db.batch(reconAcceptStatements(plan, nowSec, by, cfg).map((s) => db.prepare(s.sql).bind(...s.params)));
  return results[1].meta.changes === 1 ? { accepted: true } : { lost: true };
}
