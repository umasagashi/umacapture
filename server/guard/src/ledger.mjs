// The ledger: what the guard believes was used, cell by cell, and the spend it adds up to.
//
// A cell's usage enters the ledger only from a response that itself proved the cell complete: the
// cells that end at or before that dataset's t_p, read from the very response the control was checked
// in. Cells after t_p are dropped, never taken from another response. Writes only assign or keep the
// larger value, so writing one response twice, or an older response after a newer one, leaves the ledger
// as it was or larger. The spend of the budget window is the ledger's sum.
//
// Each function takes the D1 binding of the guard's database (`db`) where it reads or writes; the
// interpretation of a response (`readDataset`, `combineRead`) and the cost are pure.

import { DATASETS } from "./analytics.mjs";
import { cellFloor, cellOf, dayOf, dayStart, windowStart } from "./time.mjs";
import { ledgerStalled, rangeCells, scanDataset } from "./witness.mjs";

const ENVS = Object.freeze(["production", "staging"]);
/** The ledger columns each dataset supplies. */
const COLUMNS = Object.freeze({ workers: ["requests", "cpu_ms"], d1: ["rows_read", "rows_written"] });
const ALL_COLUMNS = Object.freeze([...COLUMNS.workers, ...COLUMNS.d1]);

/** The environment a row of `dataset` is billed to: staging's script and database are staging, everything else (the guard, unknown scripts) production. */
const envOf = (dataset, key, cfg) => ((dataset === "workers" ? cfg.STAGING_SCRIPTS : cfg.STAGING_DATABASES).includes(key) ? "staging" : "production");

/** The number of the guard's own events a row counts: its script's invocations, or the rows its database wrote. */
const controlOf = (dataset, row, cfg) => {
  if (dataset === "workers") return row.key === cfg.GUARD_SCRIPT ? row.requests : 0;
  return row.key === cfg.GUARD_DATABASE_ID ? row.rows_written : 0;
};

/** The control count `need` per run: one invocation, or PROBE_ROWS written rows. */
const needOf = (dataset, cfg) => (dataset === "workers" ? 1 : cfg.PROBE_ROWS);

/**
 * What one dataset's response proves (pure). `rows` are parseAnalytics' rows at minute granularity (null
 * when the response was refused), `range` the `{ qFrom, qTo }` the query was sent for, `ledger` the
 * dataset's guard_ledger row, `runs` guard_runs.started_s within the range, `gaps` every guard_gaps row
 * (`{ dataset, cell, seen_s }`) as read at the start of the run; only this dataset's are used, the
 * K_GAP limit included.
 *
 * Returns `{ readable, tp, gapRows, lost, missing, stalled, hold, cells, unknownScripts }`: `cells` are the
 * counted cells to write to the ledger (`{ env, cell, ...columns }`, cells ending at or before tp and starting
 * at or after the ledger's from_s); `missing` is true when the response lacks a cell the ledger already holds
 * (scanDataset); `hold` is true when this run must extend no lease on this dataset's evidence (it records a
 * gap, the response lacks a cell, it is catching up, or the ledger is stalled); `stalled` is null when the
 * response could not be read, since the run then cannot judge it.
 */
export function readDataset({ dataset, rows, range, ledger, runs, gaps: allGaps, nowSec, cfg }) {
  const gaps = allGaps.filter((g) => g.dataset === dataset);
  const refused = { readable: false, tp: null, gapRows: [], lost: false, missing: false, stalled: null, hold: true, cells: [], unknownScripts: [] };
  if (rows === null) return refused;
  const cells = rangeCells(range, cfg);
  const first = cells[0];
  const last = cells[cells.length - 1];
  if (rows.some((r) => cells.length === 0 || cellOf(r.t, cfg) < first || cellOf(r.t, cfg) > last)) return refused;

  const a = new Map();
  for (const r of rows) a.set(cellOf(r.t, cfg), (a.get(cellOf(r.t, cfg)) ?? 0) + controlOf(dataset, r, cfg));
  const { tp, gapRows, lost, missing } = scanDataset({ runs, a, need: needOf(dataset, cfg), cells, gaps, ledger, nowSec, cfg });
  const stalled = ledgerStalled({ toS: ledger.to_s, nowSec, runs, gaps: new Set(gaps.map((g) => g.cell)), cfg });

  const counted = new Map();
  if (tp !== null) {
    for (const r of rows) {
      const start = cellFloor(r.t, cfg);
      if (start + cfg.CELL_S > tp || start < ledger.from_s) continue;
      const env = envOf(dataset, r.key, cfg);
      const id = `${env}:${start}`;
      const cell = counted.get(id) ?? { env, cell: cellOf(r.t, cfg), ...Object.fromEntries(COLUMNS[dataset].map((k) => [k, 0])), cpu_us: 0 };
      if (dataset === "workers") {
        cell.requests += r.requests;
        cell.cpu_us += r.cpu_us;
      } else {
        cell.rows_read += r.rows_read;
        cell.rows_written += r.rows_written;
      }
      counted.set(id, cell);
    }
  }
  const out = [...counted.values()].map(({ cpu_us, ...c }) => (dataset === "workers" ? { ...c, cpu_ms: Math.ceil(cpu_us / 1000) } : c));
  const unknownScripts = dataset === "workers" ? [...new Set(rows.map((r) => r.key))].filter((k) => !cfg.KNOWN_SCRIPTS.includes(k)) : [];
  const hold = gapRows.length > 0 || missing || range.qTo < nowSec || stalled;
  return { readable: true, tp, gapRows, lost, missing, stalled, hold, cells: out, unknownScripts };
}

/** The run's reading of both datasets: t_p is the smaller of the two (null if either is), and any dataset's hold holds the run. */
export function combineRead(datasets) {
  const tps = DATASETS.map((d) => datasets[d].tp);
  const tp = tps.includes(null) ? null : Math.min(...tps);
  return { tp, hold: DATASETS.some((d) => datasets[d].hold), datasets };
}

/** The cost in micro-USD of a usage, rounded up: requests x 0.30 + CPU ms x 0.02 + rows written x 1.00 + rows read x 0.001. Included allowances are not subtracted. */
export function costMicros(q, cfg) {
  let milli = 0;
  for (const k of ALL_COLUMNS) milli += (q[k] ?? 0) * Math.round(cfg.PRICE_MICROS[k] * 1000);
  return Math.ceil(milli / 1000);
}

/**
 * Inserts the two guard_ledger rows on the guard's first run, at the start of the run's cell, but only
 * before billing reconciliation has begun (guard_bill.to_s NULL). Once it has, a missing row is not put
 * back: the run is not measurable and the dataset is reported stalled until the operator restores it.
 * `ledger` maps a dataset to its row as read (absent when missing). Returns the rows to use and the
 * datasets that stay without one.
 */
export async function initLedger(db, { ledger, billToS }, nowSec, cfg) {
  const missing = DATASETS.filter((d) => ledger[d] === undefined);
  if (missing.length === 0) return { ledger, stalled: [] };
  if (billToS !== null) return { ledger, stalled: missing };
  const c = cellFloor(nowSec, cfg);
  await db.batch([
    db.prepare("INSERT OR IGNORE INTO guard_ledger (dataset, from_s, to_s) VALUES ('workers', ?1, ?1), ('d1', ?1, ?1)").bind(c),
  ]);
  const { results } = await db.prepare("SELECT dataset, from_s, to_s FROM guard_ledger").all();
  const rows = Object.fromEntries(results.map((r) => [r.dataset, r]));
  return { ledger: rows, stalled: DATASETS.filter((d) => rows[d] === undefined) };
}

// Rows go in as one JSON array bound to one parameter, so a statement's size does not grow with the
// number of its bound parameters (D1 allows 100) however many cells a catching-up run writes.
const item = (i) => `json_extract(value, '$[${i}]')`;

const insertGaps =
  "INSERT OR IGNORE INTO guard_gaps (dataset, cell, runs, counted, seen_s) " +
  `SELECT ?2, ${item(0)}, ${item(1)}, ${item(2)}, ${item(3)} FROM json_each(?1)`;

const upsertCells = (dataset) => {
  const [x, y] = COLUMNS[dataset];
  return (
    `INSERT INTO guard_cells (env, cell, ${x}, ${y}) SELECT ${item(0)}, ${item(1)}, ${item(2)}, ${item(3)} FROM json_each(?1) WHERE true ` +
    `ON CONFLICT (env, cell) DO UPDATE SET ${x} = max(guard_cells.${x}, excluded.${x}), ${y} = max(guard_cells.${y}, excluded.${y}) ` +
    `WHERE excluded.${x} > guard_cells.${x} OR excluded.${y} > guard_cells.${y}`
  );
};

/**
 * Writes one dataset's reading in one batch (one transaction): its gaps, and when it has a t_p, its
 * counted cells (only where larger than the ledger) and guard_ledger.to_s = max(to_s, t_p). Returns
 * whether the batch succeeded and how many gap rows it added.
 */
export async function writeLedger(db, dataset, ds) {
  const statements = [];
  if (ds.gapRows.length > 0) {
    statements.push(db.prepare(insertGaps).bind(JSON.stringify(ds.gapRows.map((g) => [g.cell, g.runs, g.counted, g.seen_s])), dataset));
  }
  const gapStatements = statements.length;
  if (ds.tp !== null) {
    const [x, y] = COLUMNS[dataset];
    const cells = ds.cells.filter((c) => c[x] > 0 || c[y] > 0); // a cell with no row used nothing
    if (cells.length > 0) statements.push(db.prepare(upsertCells(dataset)).bind(JSON.stringify(cells.map((c) => [c.env, c.cell, c[x], c[y]]))));
    statements.push(db.prepare("UPDATE guard_ledger SET to_s = max(to_s, ?1) WHERE dataset = ?2").bind(ds.tp, dataset));
  }
  if (statements.length === 0) return { ok: true, gapsInserted: 0 };
  try {
    const results = await db.batch(statements);
    return { ok: true, gapsInserted: results.slice(0, gapStatements).reduce((n, r) => n + (r.meta?.changes ?? 0), 0) };
  } catch {
    return { ok: false, gapsInserted: 0 };
  }
}

/**
 * The spend per environment over the budget window [W0, tp), W0 = max(start of the budget window,
 * ledger start): guard_daily for the days it holds, guard_cells for the rest. Throws when D1 cannot be read.
 */
export async function readSpend(db, { fromS, tp }, nowSec, cfg) {
  const w0 = Math.max(windowStart(nowSec, cfg), fromS);
  const zero = Object.fromEntries(ENVS.map((e) => [e, 0]));
  if (tp <= w0) return zero;
  const sums = ALL_COLUMNS.map((k) => `SUM(${k}) AS ${k}`).join(", ");
  const cols = ALL_COLUMNS.join(", ");
  const { results } = await db
    .prepare(
      `SELECT env, ${sums} FROM (` +
        `SELECT env, ${cols} FROM guard_daily WHERE day >= ?1 AND day <= ?2 ` +
        `UNION ALL SELECT c.env, ${ALL_COLUMNS.map((k) => `c.${k}`).join(", ")} FROM guard_cells c ` +
        `WHERE c.cell >= ?3 AND c.cell < ?4 AND NOT EXISTS (SELECT 1 FROM guard_daily d WHERE d.env = c.env AND d.day = strftime('%Y-%m-%d', c.cell * ?5, 'unixepoch'))` +
        `) GROUP BY env`,
    )
    .bind(dayOf(w0), dayOf(tp - 1), cellOf(w0, cfg), cellOf(tp, cfg), cfg.CELL_S)
    .all();
  const spend = { ...zero };
  for (const r of results) if (ENVS.includes(r.env)) spend[r.env] = costMicros(r, cfg);
  return spend;
}

/**
 * Writes the run's reading to the ledger and reads the spend. Every readable dataset is written, its gaps
 * included, even when the other dataset gave no t_p: a gap the run does not record would stop every
 * later run on the same cell. The spend is read only when the run has a t_p and both batches succeeded;
 * otherwise it is null (not measurable). `ledger` holds both guard_ledger rows.
 */
export async function postLedger(db, { read, ledger }, nowSec, cfg) {
  const ok = {};
  const gapsInserted = {};
  for (const d of DATASETS) {
    const ds = read.datasets[d];
    const w = ds.readable ? await writeLedger(db, d, ds) : { ok: false, gapsInserted: 0 };
    ok[d] = w.ok;
    gapsInserted[d] = w.gapsInserted;
  }
  let spend = null;
  if (read.tp !== null && DATASETS.every((d) => ok[d])) {
    try {
      spend = await readSpend(db, { fromS: Math.min(...DATASETS.map((d) => ledger[d].from_s)), tp: read.tp }, nowSec, cfg);
    } catch {
      spend = null;
    }
  }
  return { spend, ok, gapsInserted };
}

/**
 * The daily fold: every day that ended at least H_W_S before the ledger's end (the smaller to_s of the two
 * datasets) is summed into guard_daily per environment (column by column, the larger of the sum and what
 * the row holds), and the cells of the days before the newest folded day are deleted. The spend prefers a
 * day's guard_daily row to its cells, so a folded day's remaining cells change nothing.
 */
export async function foldDays(db, { minToS }, nowSec, cfg) {
  const cutoff = dayStart(dayOf(minToS - cfg.H_W_S)); // days ending at or before minToS - H_W_S lie before this
  const cutoffCell = cellOf(cutoff, cfg);
  const sums = ALL_COLUMNS.map((k) => `SUM(${k})`).join(", ");
  const keep = ALL_COLUMNS.map((k) => `${k} = max(guard_daily.${k}, excluded.${k})`).join(", ");
  await db.batch([
    db
      .prepare(
        `INSERT INTO guard_daily (env, day, ${ALL_COLUMNS.join(", ")}, cpu_basis, read_s) ` +
          `SELECT env, strftime('%Y-%m-%d', cell * ?1, 'unixepoch') AS d, ${sums}, 'measured', ?2 FROM guard_cells WHERE cell < ?3 GROUP BY env, d ` +
          `ON CONFLICT (env, day) DO UPDATE SET ${keep}, read_s = excluded.read_s`,
      )
      .bind(cfg.CELL_S, nowSec, cutoffCell),
    db.prepare("DELETE FROM guard_cells WHERE cell < ?1").bind(cellOf(cutoff - 86_400, cfg)),
  ]);
}

/** The range of the hourly re-read: the budget window from W0 to now. */
export const rereadRange = ({ fromS }, nowSec, cfg) => ({ fromS: Math.max(windowStart(nowSec, cfg), fromS), toS: nowSec });

/**
 * The hourly re-read of one dataset: `rows` are parseAnalytics' rows at hour granularity (null when the read
 * failed, which changes nothing), summed per environment and UTC day. Every folded day (a guard_daily row)
 * where the re-read is larger in a column is raised to it; nothing is lowered. Returns the raised columns as
 * `{ env, day, column, ledger, read }` (null when the read failed). The re-read is not evidence for any
 * decision: whether it fails or how much it raises, the run's lease is decided from the ledger alone.
 */
export async function rereadRaise(db, { dataset, rows }, nowSec, cfg) {
  if (rows === null) return null;
  const totals = new Map();
  for (const r of rows) {
    const env = envOf(dataset, r.key, cfg);
    const day = dayOf(r.t);
    const id = `${env}|${day}`;
    const t = totals.get(id) ?? { env, day, requests: 0, cpu_us: 0, rows_read: 0, rows_written: 0 };
    for (const k of ["requests", "cpu_us", "rows_read", "rows_written"]) t[k] += r[k] ?? 0;
    totals.set(id, t);
  }
  const [x, y] = COLUMNS[dataset];
  const raised = [];
  const statements = [];
  for (const t of totals.values()) {
    const read = { requests: t.requests, cpu_ms: Math.ceil(t.cpu_us / 1000), rows_read: t.rows_read, rows_written: t.rows_written };
    const row = await db.prepare(`SELECT ${x}, ${y} FROM guard_daily WHERE env = ?1 AND day = ?2`).bind(t.env, t.day).first();
    if (row === null) continue; // not folded yet
    const up = [x, y].filter((k) => read[k] > row[k]);
    if (up.length === 0) continue;
    for (const k of up) raised.push({ env: t.env, day: t.day, column: k, ledger: row[k], read: read[k] });
    statements.push(
      db
        .prepare(`UPDATE guard_daily SET ${x} = max(${x}, ?1), ${y} = max(${y}, ?2), read_s = ?3 WHERE env = ?4 AND day = ?5`)
        .bind(read[x], read[y], nowSec, t.env, t.day),
    );
  }
  if (statements.length > 0) await db.batch(statements);
  return raised;
}

/**
 * The bridges ledger-bridge makes, decided on the current data alone: every dataset whose ledger is
 * stalled now (ledgerStalled on its to_s, guard_runs and guard_gaps) moves on to the cell boundary of
 * nowSec - H_W_S, provided that lies after its to_s. `ledger` holds both guard_ledger rows, `runs` are
 * guard_runs.started_s, `gaps` every guard_gaps row (`{ dataset, cell }`).
 */
export function bridgePlan({ ledger, runs, gaps, nowSec, cfg }) {
  const to = cellFloor(nowSec - cfg.H_W_S, cfg);
  const gapsOf = (d) => new Set(gaps.filter((g) => g.dataset === d).map((g) => g.cell));
  return DATASETS.filter((d) => ledgerStalled({ toS: ledger[d].to_s, nowSec, runs, gaps: gapsOf(d), cfg }) && to > ledger[d].to_s).map((d) => ({
    dataset: d,
    old: ledger[d].to_s,
    new: to,
  }));
}

/**
 * The statements of one bridge, one batch: the hole is recorded and the ledger moved on only while to_s is
 * still the value the plan read, so a bridge another writer beat records nothing, and a bridge repeated
 * after it took effect finds the ledger no longer stalled.
 *
 * The batch goes to the remote D1 as one `wrangler d1 execute --command`, which is not known to run as one
 * transaction, so each statement must leave a state that extends nothing should the batch stop after it.
 * The hole comes first: it only withholds the days it touches from billing reconciliation. The ledger moves
 * on last, and only over a hole already recorded up to its new to_s; a ledger that moved would let the guard
 * measure again. A hole left by a batch that stopped is widened, not refused, by the bridge that repeats it.
 */
export const bridgeStatements = ({ dataset, old, new: to }, nowSec, by) => [
  {
    sql:
      "INSERT INTO guard_holes (dataset, from_s, to_s, bridged_at_s, bridged_by) SELECT ?1, ?2, ?3, ?4, ?5 " +
      "WHERE (SELECT to_s FROM guard_ledger WHERE dataset = ?1) = ?2 " +
      "ON CONFLICT (dataset, from_s) DO UPDATE SET to_s = max(guard_holes.to_s, excluded.to_s)",
    params: [dataset, old, to, nowSec, by],
  },
  {
    sql:
      "UPDATE guard_ledger SET to_s = ?1 WHERE dataset = ?2 AND to_s = ?3 " +
      "AND EXISTS (SELECT 1 FROM guard_holes WHERE dataset = ?2 AND from_s = ?3 AND to_s >= ?1)",
    params: [to, dataset, old],
  },
];

/** Runs every bridge of `plan`, one batch each. Returns, per bridge, whether it moved the ledger. */
export async function applyBridge(db, plan, nowSec, by) {
  const done = [];
  for (const b of plan) {
    const results = await db.batch(bridgeStatements(b, nowSec, by).map((s) => db.prepare(s.sql).bind(...s.params)));
    done.push({ dataset: b.dataset, moved: (results[1].meta?.changes ?? 0) === 1 });
  }
  return done;
}
