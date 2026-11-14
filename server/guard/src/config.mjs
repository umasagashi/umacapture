// The guard Worker's constants: one object, CFG, that every pure function of the guard takes as `cfg`,
// so a test can hand a function a different value without touching module state.
//
// Units (the guard's unit contract): times are UNIX seconds (`_S`, integers); the one millisecond value
// is RUN_DEADLINE_MS; money is integer micro-USD (`_MICROS`). Values marked provisional are placeholders
// the rollout measures and resets; they are not requirements.

/** The guard's own script and D1 database: their rows are the control events (`witness`) and count towards production. */
export const GUARD_SCRIPT = "umacapture-guard";
/**
 * The id of the D1 database `umacapture-guard`, the same as `database_id` in wrangler.guard.jsonc: the two
 * change together.
 */
export const GUARD_DATABASE_ID = "3284839e-cb75-4520-9653-5abeb055bf5e";

export const CFG = Object.freeze({
  /** Length of one cell: the guard compares its own events with Analytics one 60-second cell at a time. */
  CELL_S: 60,
  /** D: how far past the last cell Analytics proved complete a lease may reach. Provisional. */
  D_S: 1_200,
  /** The horizon: a missing control event older than this is recorded as lost. Provisional; must exceed D_S. */
  H_W_S: 3_600,
  /** A missing control event older than this may be accepted at once when a later cell proves the response complete. Provisional. */
  GAP_ACCEPT_S: 300,
  /** At most this many gaps per dataset within the last H_W_S are accepted at once; past it a gap waits for the horizon. Provisional. */
  K_GAP: 3,
  /** The longest range one Analytics response covers while the ledger catches up. Provisional. */
  Q_MAX_S: 21_600,
  /** The row limit every Analytics query sends: the datasets' maxPageSize. A response that reaches it is refused. */
  QUERY_LIMIT: 10_000,
  /** A lease is rewritten only when it moves forward by at least this much. Provisional. */
  RENEW_STEP_S: 300,
  /** A run later than this after its scheduled time writes no rule. Provisional. */
  RUN_DEADLINE_MS: 30_000,
  /** Margin a written lease may lie beyond nowSec + D_S, for the time between computing and writing it. */
  WRITE_MARGIN_S: 60,
  /** Ea while stage A is not latched: a time no request reaches (2100-01-01T00:00:00Z). */
  EA_OFF: 4_102_444_800,
  /** The hosts the rule never blocks: hosts no request can make a Worker run on. */
  ALLOW_HOSTS: Object.freeze(["data.umacapture.com"]),
  /** The production host, whose dynamic paths stage A closes. */
  PRODUCTION_HOST: "umacapture.com",
  /** Rows one guard_runs INSERT writes (k). Measured at rollout; null until then, which no count meets. */
  PROBE_ROWS: null,
  /** The interval of the hourly re-read of the budget window. Provisional. */
  REREAD_STEP_S: 3_600,
  /** Time from the first sight of the rule in its protecting form until it is taken to have reached every edge. Provisional. */
  SETTLE_S: 86_400,
  /** After a create attempt, no new attempt for this long, so a late POST can still show up. Provisional. */
  CREATE_HOLD_S: 600,
  /** guard_health's observation is written at most this often, or when measurability switches. */
  STATUS_STEP_S: 300,
  /** Every outbound call is abandoned after this long and not retried within the run. */
  CALL_TIMEOUT_MS: 10_000,
  /** guard_runs rows older than this are deleted once a day. */
  RUNS_KEEP_S: 31 * 86_400,
  /** `arm` is refused unless the guard was measurable within this long. */
  ARM_FRESH_S: 600,
  /** The longest test window `open staging --for` accepts. Provisional. */
  STAGING_WINDOW_MAX_S: 8 * 3_600,
  /** lease_closing_soon is sent once production's open_until_s is this close. */
  RENEW_WARN_S: 172_800,
  /** Billing reconciliation is tried at most once per this interval. */
  BILL_STEP_S: 86_400,
  /** T_R: production stays open until this long after the end of the last reconciled day. */
  T_R_S: 604_800,
  /** Reconciliation tolerance per metric and day: |bill - ledger| <= BILL_TAU * ledger + BILL_A_MICROS. Provisional. */
  BILL_TAU: 0.1,
  BILL_A_MICROS: 10_000,
  /** The day of the month (UTC) a billing period starts on. */
  BILLING_ANCHOR_DAY: 22,
  /**
   * Production is closed in two stages: at guard_env.warn_permille of its limit the dynamic paths (stage A),
   * at the limit everything. The limits and the share themselves are state (guard_env), set by the
   * migration and changed by the operator.
   */
  TWO_STAGE: true,
  /** The script and D1 database billed as staging; every other script and database counts as production. */
  STAGING_SCRIPTS: Object.freeze(["umacapture-web-staging"]),
  STAGING_DATABASES: Object.freeze(["b79b37f9-1beb-49ed-a144-1e1084d84146"]),
  /** Every script the account is expected to run; any other script name is reported. */
  KNOWN_SCRIPTS: Object.freeze(["umacapture-web", "umacapture-web-staging", GUARD_SCRIPT]),
  GUARD_SCRIPT,
  GUARD_DATABASE_ID,
  /** Unit prices in micro-USD per unit (requests, CPU milliseconds, rows written, rows read). */
  PRICE_MICROS: Object.freeze({ requests: 0.3, cpu_ms: 0.02, rows_written: 1, rows_read: 0.001 }),
  /** The ledger's metrics billing reconciliation compares, day by day. */
  METRICS: Object.freeze(["requests", "cpu_ms", "rows_read", "rows_written"]),
  /**
   * Every kind of Billable Usage row the account is expected to see, keyed by `billKey(ServiceName,
   * ConsumedUnit)` (exact match; an empty unit is the empty string). A kind not listed stops reconciliation.
   *  - `reconcile`: the same quantity as one ledger metric; `ConsumedQuantity x multiplier` is compared with it.
   *    ConsumedQuantity is counted before included allowances and in the ledger's units (requests, CPU ms, rows),
   *    so the multiplier is 1.
   *  - `storage`: bounded by a named term of the budget (D1 storage, F_D1: every database of the account,
   *    at most 10 GB each); neither evidence nor a reason to stop.
   *  - `retired`: R2, whose bucket was deleted on 2026-11-03: a row of a day starting at or after
   *    BILL_RETIRED_END_S is a new way of being billed outside the ledger and stops reconciliation.
   */
  BILL_CLASS: Object.freeze({
    "Workers Standard Requests (first 10M are included)\u0000": Object.freeze({ class: "reconcile", metric: "requests", multiplier: 1 }),
    "Workers CPU ms (first 30M are included)\u0000": Object.freeze({ class: "reconcile", metric: "cpu_ms", multiplier: 1 }),
    "D1 - Rows Read (first 25 billion included)\u0000": Object.freeze({ class: "reconcile", metric: "rows_read", multiplier: 1 }),
    "D1 - Rows Written (first 50 million included)\u0000": Object.freeze({ class: "reconcile", metric: "rows_written", multiplier: 1 }),
    "D1 - Storage GB-mo (first 5GB included)\u0000GB-months": Object.freeze({ class: "storage", term: "F_D1" }),
    "R2 Data Storage (First 10GB-Month included)\u0000GB-months": Object.freeze({ class: "retired" }),
    "R2 Storage Class A Operations (First 1M included)\u0000": Object.freeze({ class: "retired" }),
    "R2 Storage Class B Operations (First 10M included)\u0000": Object.freeze({ class: "retired" }),
  }),
  /** The first instant a retired kind may not be billed for: the day after its last observed row (2026-11-04T00:00:00Z). */
  BILL_RETIRED_END_S: 1_793_750_400,
});
