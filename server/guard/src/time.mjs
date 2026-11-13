// Time conversions of the guard. Every instant is UNIX seconds; a day is a UTC calendar day written
// `YYYY-MM-DD`. Local time (JST or any other) is never used.

const DAY_S = 86_400;

/** The cell number holding instant `t`: cells are CELL_S long and start on multiples of CELL_S (OFFSET is 0). */
export const cellOf = (t, cfg) => Math.floor(t / cfg.CELL_S);

/** The start of the cell holding instant `t`. */
export const cellFloor = (t, cfg) => cellOf(t, cfg) * cfg.CELL_S;

/** The UTC day holding instant `s`, as `YYYY-MM-DD`. */
export const dayOf = (s) => new Date(s * 1000).toISOString().slice(0, 10);

/** The first instant of UTC day `d` (`YYYY-MM-DD`). */
export const dayStart = (d) => Date.parse(`${d}T00:00:00Z`) / 1000;

/** The first instant after UTC day `d`. */
export const dayEnd = (d) => dayStart(d) + DAY_S;

/**
 * The start (00:00 UTC of the anchor day) of the billing period holding `nowSec`. The anchor day must
 * exist in every month, so it is at most 28.
 */
export function periodStart(nowSec, cfg) {
  const day = cfg.BILLING_ANCHOR_DAY;
  if (!Number.isInteger(day) || day < 1 || day > 28) throw new RangeError(`BILLING_ANCHOR_DAY ${day} is not a day every month has`);
  const now = new Date(nowSec * 1000);
  let start = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), day) / 1000;
  if (start > nowSec) start = Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 1, day) / 1000;
  return start;
}

/** The start of the budget window: 00:00 UTC of the day before the billing period's first day. */
export const windowStart = (nowSec, cfg) => periodStart(nowSec, cfg) - DAY_S;
