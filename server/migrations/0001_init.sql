-- Published records and the bookkeeping that bounds them. Every limit the Worker enforces is a
-- row here (totals, daily), not a D1 error it waits for.

CREATE TABLE records (
  id              TEXT PRIMARY KEY,      -- public id: 10 lowercase Crockford base32 characters
  delete_key_hash BLOB NOT NULL UNIQUE,  -- SHA-256 of the client-generated delete key (32 bytes)
  schema          INTEGER NOT NULL,      -- version of the posted form (1)
  payload         BLOB NOT NULL,         -- gzip of the canonical JSON of the posted form
  charge          INTEGER NOT NULL,      -- budget charge at publish time: length(payload) + ROW_CHARGE
  published_day   INTEGER NOT NULL       -- UTC days since 1970-01-01
);

CREATE TABLE tickets (
  hash       BLOB PRIMARY KEY,           -- SHA-256 of the ticket
  remaining  INTEGER NOT NULL,           -- publishes left on this ticket
  expires_at INTEGER NOT NULL            -- expiry, seconds since the epoch
);
-- Lets the sweep of expired tickets use an index instead of a table scan.
CREATE INDEX tickets_expires_at ON tickets (expires_at);

CREATE TABLE daily (
  day           INTEGER PRIMARY KEY,     -- UTC days since 1970-01-01
  publish_bytes INTEGER NOT NULL DEFAULT 0,
  publish_count INTEGER NOT NULL DEFAULT 0,
  tickets       INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE totals (
  id    INTEGER PRIMARY KEY CHECK (id = 1),
  bytes INTEGER NOT NULL,
  count INTEGER NOT NULL
);
-- The single totals row exists from the start, so publishing and withdrawing only ever UPDATE it.
INSERT INTO totals (id, bytes, count) VALUES (1, 0, 0);
