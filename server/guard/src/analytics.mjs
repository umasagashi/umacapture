// The GraphQL Analytics queries the guard sends and the reading of their answers. Pure: building a query
// and reading a response never fetch.
//
// The run reads each dataset once: Workers by minute x script, D1 by minute x database. The hourly re-read
// reads the budget window by hour x script and hour x database. No query filters on or groups by
// eventType: Cloudflare has relabelled the guard's own cron invocations before (from "unknown" to
// "cron"), and a filter on a label that changes reads an empty answer.

export const DATASETS = Object.freeze(["workers", "d1"]);

/** The time dimension of each granularity and the length of its bucket in seconds. */
const GRANULARITY = Object.freeze({
  minute: { dimension: "datetimeMinute", seconds: 60 },
  hour: { dimension: "datetimeHour", seconds: 3_600 },
});

/** Per dataset: the GraphQL node, the dimension naming the script or database, and the sums read (as fields of a row). */
const SHAPE = Object.freeze({
  workers: { node: "workersInvocationsAdaptive", key: "scriptName", sums: { requests: "requests", cpu_us: "cpuTimeUs" } },
  d1: { node: "d1AnalyticsAdaptiveGroups", key: "databaseId", sums: { rows_read: "rowsRead", rows_written: "rowsWritten" } },
});

const iso = (s) => new Date(s * 1000).toISOString().replace(".000Z", "Z");

/**
 * The query reading `dataset` over [fromS, toS) at `granularity` ("minute" or "hour"), as the body of a
 * GraphQL POST: `{ query, variables }`.
 */
export function analyticsQuery({ dataset, granularity, fromS, toS, accountId, cfg }) {
  const shape = SHAPE[dataset];
  const time = GRANULARITY[granularity].dimension;
  const sums = Object.values(shape.sums).join(" ");
  const query =
    "query($a: string!, $f: Time!, $t: Time!, $lim: uint64!) { viewer { accounts(filter: {accountTag: $a}) { " +
    `${shape.node}(limit: $lim, filter: {datetime_geq: $f, datetime_lt: $t}, orderBy: [${time}_ASC]) { ` +
    `dimensions { ${time} ${shape.key} } sum { ${sums} } } } } }`;
  return { query, variables: { a: accountId, f: iso(fromS), t: iso(toS), lim: cfg.QUERY_LIMIT } };
}

/** The query of a run's reading of `dataset`: by minute, the granularity of the cells. */
export const cellsQuery = ({ dataset, fromS, toS, accountId, cfg }) => analyticsQuery({ dataset, granularity: "minute", fromS, toS, accountId, cfg });

/**
 * The query of the hourly re-read of `dataset`: by hour, then summed per UTC day by the reader. Not by
 * day: Analytics samples a day's aggregate, which then lies anywhere from about half to more than twice
 * what is billed, while hourly aggregates add up to the bill.
 */
export const rereadQuery = ({ dataset, fromS, toS, accountId, cfg }) => analyticsQuery({ dataset, granularity: "hour", fromS, toS, accountId, cfg });

const isCount =(x) => Number.isSafeInteger(x) && x >= 0;

/**
 * The rows of an Analytics answer, as `{ t, key, ...sums }` with `t` the UNIX second its bucket starts,
 * or null when the answer is refused: an HTTP status other than 200, any `errors`, a body of another
 * shape, as many rows as the query's limit (more may have been cut off), a bucket time that does not
 * parse or does not start a bucket, or a sum that is not a non-negative whole number.
 */
export function parseAnalytics({ dataset, granularity, status, body, cfg }) {
  if (status !== 200 || body === null || typeof body !== "object") return null;
  if (body.errors !== undefined && body.errors !== null && !(Array.isArray(body.errors) && body.errors.length === 0)) return null;
  const accounts = body.data?.viewer?.accounts;
  if (!Array.isArray(accounts) || accounts.length !== 1) return null;
  const shape = SHAPE[dataset];
  const { dimension, seconds } = GRANULARITY[granularity];
  const raw = accounts[0]?.[shape.node];
  if (!Array.isArray(raw) || raw.length >= cfg.QUERY_LIMIT) return null;
  const rows = [];
  for (const r of raw) {
    const time = r?.dimensions?.[dimension];
    const key = r?.dimensions?.[shape.key];
    if (typeof time !== "string" || typeof key !== "string") return null;
    const ms = Date.parse(time);
    if (!Number.isFinite(ms) || ms % (seconds * 1000) !== 0) return null;
    const row = { t: ms / 1000, key };
    for (const [field, name] of Object.entries(shape.sums)) {
      const x = r?.sum?.[name];
      if (!isCount(x)) return null;
      row[field] = x;
    }
    rows.push(row);
  }
  return rows;
}
