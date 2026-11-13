// The instrument check. Every run of the guard leaves two control events: one invocation of its own
// script (Workers) and one INSERT of PROBE_ROWS rows into its own D1 database (D1), recorded in guard_runs.
// A response from Analytics is believed for a 60-second cell only when the same response counts at least
// need x R of the guard's own events in that cell, R being the runs guard_runs holds for the cell. The
// scan walks the response's cells from the oldest: a cell with no run (or an accepted gap) proves
// nothing either way, a cell counted short stops the scan, and t_p is the start of the last cell that
// passed. Each cell is judged on its own count only, never on a running total, so a surplus in one cell
// never makes up for a shortfall in another.

import { cellFloor, cellOf } from "./time.mjs";

/** The range one run reads for a dataset whose ledger reaches `toS`: from the ledger (or the horizon, if older) for at most Q_MAX_S. */
export function queryRange(toS, nowSec, cfg) {
  const qFrom = cellFloor(Math.min(toS, nowSec - cfg.H_W_S), cfg);
  return { qFrom, qTo: Math.min(nowSec, qFrom + cfg.Q_MAX_S) };
}

/** The cell numbers of [qFrom, qTo), oldest first. The last may be cut short by qTo. */
export function rangeCells({ qFrom, qTo }, cfg) {
  const cells = [];
  for (let c = cellOf(qFrom, cfg); c * cfg.CELL_S < qTo; c++) cells.push(c);
  return cells;
}

/** The number of runs (guard_runs.started_s) per cell. */
export function runsPerCell(runs, cfg) {
  const per = new Map();
  for (const s of runs) per.set(cellOf(s, cfg), (per.get(cellOf(s, cfg)) ?? 0) + 1);
  return per;
}

const validNeed = (need) => Number.isSafeInteger(need) && need >= 1;

/** The scan: t_p (null when no cell passed) and the cell it stopped on (null when no cell fell short). */
function scan({ runs, a, need, cells, gaps, cfg }) {
  const R = runsPerCell(runs, cfg);
  let tp = null;
  for (const c of cells) {
    const r = R.get(c) ?? 0;
    if (r === 0 || gaps.has(c)) continue; // no evidence (an accepted gap included)
    if ((a.get(c) ?? 0) < need * r) return { tp, stop: c, R }; // evidence against
    tp = c * cfg.CELL_S; // evidence for: the cell's start
  }
  return { tp, stop: null, R };
}

/**
 * t_p of one dataset: the start of the last cell of `cells` (cell numbers, ascending) that passed before
 * the first cell counted short, or null when none passed. `runs` are guard_runs.started_s, `a` maps a cell
 * to the guard's own events the response counted in it, `gaps` is the set of this dataset's guard_gaps
 * cells. A `need` that is not a positive whole number (PROBE_ROWS before it is measured) proves nothing.
 */
export function witness({ runs, a, need, cells, gaps, cfg }) {
  if (!validNeed(need)) return null;
  return scan({ runs, a, need, cells, gaps, cfg }).tp;
}

/**
 * The scan of one readable response together with the gaps the run records. When the scan stops on a
 * cell c counted short:
 *  - c started before nowSec - H_W_S (the horizon): every cell of the range counted short that started
 *    before the horizon is recorded, and the loss is reported (`lost`).
 *  - otherwise, c started before nowSec - GAP_ACCEPT_S, a later cell of the same response passed (it has
 *    runs and enough events: the response counted past c, so c's events are lost, not late), and fewer
 *    than K_GAP of this dataset's gaps were seen within the last H_W_S: c alone is recorded (accepted
 *    at once, not reported).
 * A run that records a gap extends no lease; the next run passes over the recorded cells.
 * `gaps` are this dataset's guard_gaps rows as read at the start of the run (`{ cell, seen_s }`).
 */
export function scanDataset({ runs, a, need, cells, gaps, nowSec, cfg }) {
  if (!validNeed(need)) return { tp: null, gapRows: [], lost: false };
  const gapCells = new Set(gaps.map((g) => g.cell));
  const { tp, stop, R } = scan({ runs, a, need, cells, gaps: gapCells, cfg });
  if (stop === null) return { tp, gapRows: [], lost: false };
  const short = (c) => (R.get(c) ?? 0) > 0 && !gapCells.has(c) && (a.get(c) ?? 0) < need * (R.get(c) ?? 0);
  const row = (c) => ({ cell: c, runs: R.get(c) ?? 0, counted: a.get(c) ?? 0, seen_s: nowSec });
  const startsBefore = (c, t) => c * cfg.CELL_S < t;
  if (startsBefore(stop, nowSec - cfg.H_W_S)) {
    const rows = cells.filter((c) => short(c) && startsBefore(c, nowSec - cfg.H_W_S)).map(row);
    return { tp, gapRows: rows, lost: true };
  }
  const laterPasses = cells.some((c) => c > stop && (R.get(c) ?? 0) >= 1 && (a.get(c) ?? 0) >= need * (R.get(c) ?? 0));
  const recent = gaps.filter((g) => g.seen_s > nowSec - cfg.H_W_S).length;
  if (startsBefore(stop, nowSec - cfg.GAP_ACCEPT_S) && laterPasses && recent < cfg.K_GAP) {
    return { tp, gapRows: [row(stop)], lost: false };
  }
  return { tp, gapRows: [], lost: false };
}

/**
 * Whether a dataset's ledger cannot move on (ledger_stalled): the run is catching up (its range ends
 * before nowSec) and no cell of the range after the ledger's cell holds a run that is not an accepted gap,
 * so no response for this range can ever prove a cell past the ledger. Only the operator's ledger-bridge
 * moves such a ledger on. `runs` are guard_runs.started_s, `gaps` this dataset's guard_gaps cells (a Set).
 */
export function ledgerStalled({ toS, nowSec, runs, gaps, cfg }) {
  const range = queryRange(toS, nowSec, cfg);
  if (range.qTo >= nowSec) return false;
  const R = runsPerCell(runs, cfg);
  const toCell = cellOf(toS, cfg);
  return !rangeCells(range, cfg).some((c) => c > toCell && (R.get(c) ?? 0) > 0 && !gaps.has(c));
}
