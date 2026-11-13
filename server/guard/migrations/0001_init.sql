-- The guard's own D1 database (umacapture-guard): its state, its control records and its ledger.
--
-- Nothing here models rule G. The rule's id, its times and whether it exists are read back from the
-- zone's ruleset on every run; this database holds only what the guard and the operator intend
-- (arm_requested_s, create_attempt_s, the environments' modes and limits), what the guard observed, and
-- the ledger of usage. Times are UNIX seconds in columns ending _s; money is micro-USD in columns ending
-- _micros; a day is a UTC calendar day written YYYY-MM-DD.
--
-- No statement here may hold ";" or "--" inside a string literal: the tests cut this file at every ";"
-- after dropping "--" comments.

-- One row per environment. mode 'tripped' is left only by the operator. gen is the compare-and-set
-- counter of every change the guard commits.
CREATE TABLE guard_env (
  env TEXT PRIMARY KEY CHECK (env IN ('production', 'staging')),
  gen INTEGER NOT NULL,
  mode TEXT NOT NULL CHECK (mode IN ('open', 'closed', 'tripped')),
  stage_a INTEGER NOT NULL DEFAULT 0,
  base_limit_micros INTEGER NOT NULL,
  limit_micros INTEGER,
  limit_period_start_s INTEGER NOT NULL,
  pending_allowance_micros INTEGER,
  warn_permille INTEGER NOT NULL,
  open_until_s INTEGER,
  opened_at_s INTEGER,
  opened_by TEXT,
  tripped_at_s INTEGER,
  trip_reason TEXT,
  spent_at_trip_micros INTEGER,
  updated_at_s INTEGER NOT NULL,
  CHECK (mode <> 'open' OR open_until_s IS NOT NULL)
);

-- Intentions and observations only, one row.
CREATE TABLE guard_health (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  arm_requested_s INTEGER,
  create_attempt_s INTEGER,
  rule_seen_since_s INTEGER,
  last_measurable_s INTEGER,
  last_patch_error TEXT,
  api_backoff_until_s INTEGER
);

-- The control records: one row per run, written by the run's first statement. Rows older than 31 days
-- are deleted once a day. No index beyond the key: a run reads the last hour by started_s.
CREATE TABLE guard_runs (
  run_id TEXT PRIMARY KEY,
  started_s INTEGER NOT NULL
);

-- Cells (cell numbers, not times) whose control events Analytics never returned, per dataset
-- ('workers', 'd1'): the scan passes over them as cells with no evidence.
CREATE TABLE guard_gaps (
  dataset TEXT NOT NULL,
  cell INTEGER NOT NULL,
  runs INTEGER NOT NULL,
  counted INTEGER NOT NULL,
  seen_s INTEGER NOT NULL,
  PRIMARY KEY (dataset, cell)
);

-- A day's guard_cells summed once the day lies an hour behind the ledger, raised by the hourly re-read
-- where Analytics later reported more. Never lowered.
CREATE TABLE guard_daily (
  env TEXT NOT NULL,
  day TEXT NOT NULL,
  requests INTEGER NOT NULL,
  cpu_ms INTEGER NOT NULL,
  cpu_basis TEXT NOT NULL CHECK (cpu_basis IN ('measured', 'bound')),
  rows_read INTEGER NOT NULL,
  rows_written INTEGER NOT NULL,
  read_s INTEGER NOT NULL,
  PRIMARY KEY (env, day)
);

-- The ledger's extent per dataset: every cell in [from_s, to_s) was written from a response that proved
-- the cell complete, except the stretches in guard_holes. The guard's first run inserts both rows.
CREATE TABLE guard_ledger (
  dataset TEXT PRIMARY KEY CHECK (dataset IN ('workers', 'd1')),
  from_s INTEGER NOT NULL,
  to_s INTEGER NOT NULL
);

-- The usage of one cell (cell number) per environment: the largest value any proving response gave.
-- A cell with no row used nothing.
CREATE TABLE guard_cells (
  env TEXT NOT NULL,
  cell INTEGER NOT NULL,
  requests INTEGER NOT NULL DEFAULT 0,
  cpu_ms INTEGER NOT NULL DEFAULT 0,
  rows_read INTEGER NOT NULL DEFAULT 0,
  rows_written INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (env, cell)
);

-- Stretches of the ledger the operator accepted as unrecorded (ledger-bridge).
CREATE TABLE guard_holes (
  dataset TEXT NOT NULL,
  from_s INTEGER NOT NULL,
  to_s INTEGER NOT NULL,
  bridged_at_s INTEGER NOT NULL,
  bridged_by TEXT,
  PRIMARY KEY (dataset, from_s)
);

-- How far billing reconciliation reached, one row: every day in [from_s, to_s) was reconciled or
-- accepted by the operator. to_s is NULL until the operator's first recon-accept. last_* only feed status.
CREATE TABLE guard_bill (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  from_s INTEGER,
  to_s INTEGER,
  last_try_s INTEGER,
  last_verdict TEXT,
  last_day TEXT
);

-- Day ranges the operator accepted without reconciliation (recon-accept).
CREATE TABLE guard_bill_accepts (
  from_s INTEGER PRIMARY KEY,
  to_s INTEGER NOT NULL,
  accepted_at_s INTEGER NOT NULL,
  accepted_by TEXT
);

-- The latch of each notification: a row while its condition holds and its start was sent.
CREATE TABLE guard_alerts (
  key TEXT PRIMARY KEY,
  since_s INTEGER NOT NULL
);

-- The initial state. Production is open with a limit of $10 per billing period and alpha 0.8, but
-- open_until_s is 0 (no reconciled day yet), so no lease is extended until the operator's first
-- recon-accept. Staging is closed with a base limit of 0: a test window brings its own allowance.
-- limit_period_start_s 0 is "no period yet": the first run moves it to the current billing period.
INSERT INTO guard_env (env, gen, mode, stage_a, base_limit_micros, limit_micros, limit_period_start_s, pending_allowance_micros, warn_permille, open_until_s, updated_at_s)
VALUES
  ('production', 0, 'open', 0, 10000000, 10000000, 0, NULL, 800, 0, unixepoch()),
  ('staging', 0, 'closed', 0, 0, NULL, 0, NULL, 800, NULL, unixepoch());
INSERT INTO guard_health (id) VALUES (1);
INSERT INTO guard_bill (id) VALUES (1);
