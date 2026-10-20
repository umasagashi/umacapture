-- Accounts and logins. A person is an account; the providers they sign in with are identity rows
-- that point at it, so another provider can be added later without changing these tables. Every
-- secret the server keeps is a hash: the provider's subject, session tokens, and the values a login
-- in flight is checked against.
--
-- The test harness applies migrations by cutting them at every ";" after dropping "--" comments,
-- so no statement here may hold a ";" or "--" inside a string literal, and no trigger body.

CREATE TABLE accounts (
  id             TEXT PRIMARY KEY,           -- 16 lowercase Crockford base32 characters; the public id of /u/<id>
  created_day    INTEGER NOT NULL,           -- UTC days since 1970-01-01
  share_count    INTEGER NOT NULL DEFAULT 0, -- records currently shared (the per-account cap)
  quota_day      INTEGER NOT NULL DEFAULT 0, -- the UTC day quota_bytes belongs to
  quota_bytes    INTEGER NOT NULL DEFAULT 0, -- charge this account shared on quota_day
  deleting_since INTEGER                     -- seconds since the epoch the deletion began; NULL when not being deleted
);

CREATE TABLE identities (
  provider     TEXT NOT NULL,                -- 'google'
  subject_hmac BLOB NOT NULL,                -- HMAC-SHA256(IDENTITY_HMAC_KEY, provider || 0x00 || sub); the raw sub is never stored
  account_id   TEXT NOT NULL REFERENCES accounts(id),
  PRIMARY KEY (provider, subject_hmac)
);
CREATE INDEX identities_account ON identities (account_id);

CREATE TABLE sessions (
  token_hash BLOB PRIMARY KEY,               -- SHA-256 of the 256-bit bearer token
  account_id TEXT NOT NULL REFERENCES accounts(id),
  expires_at INTEGER NOT NULL,               -- seconds since the epoch
  scope      TEXT NOT NULL DEFAULT 'full'    -- 'full', or 'delete': usable only to continue deleting the account
);
CREATE INDEX sessions_account ON sessions (account_id);
CREATE INDEX sessions_expires_at ON sessions (expires_at);

-- A login in flight, from the begin until the claim or LOGIN_TTL_SECONDS.
CREATE TABLE logins (
  h             BLOB PRIMARY KEY,            -- SHA-256 of the app's secret s
  provider      TEXT NOT NULL,
  state_hash    BLOB NOT NULL UNIQUE,        -- SHA-256 of the OAuth state; the callback looks the login up by it
  pkce_verifier TEXT NOT NULL,
  nonce_hash    BLOB NOT NULL,               -- SHA-256 of the OIDC nonce, matched against the ID token's
  begin_hash    BLOB NOT NULL,               -- SHA-256 of the begin cookie uc_begin_<h>, matched by the callback
  port          INTEGER,                     -- the Windows app's loopback port; NULL on the web
  stage         INTEGER NOT NULL,            -- 0 started, 1 completed
  account_id    TEXT,                        -- set at stage 1
  proof_hash    BLOB,                        -- set at stage 1: SHA-256 of the one-time proof
  expires_at    INTEGER NOT NULL             -- seconds since the epoch
);
CREATE INDEX logins_expires_at ON logins (expires_at);

-- The trainer ids an account's devices registered, at most ACCOUNT_TRAINERS_CAP per account.
CREATE TABLE account_trainers (
  account_id TEXT NOT NULL REFERENCES accounts(id),
  trainer_id TEXT NOT NULL,                  -- a UUID the device makes; not checked further
  PRIMARY KEY (account_id, trainer_id)
);

-- Shared records belong to an account. The account's session is what allows sharing and unsharing,
-- so there is no ticket and no delete key. Production held no record when this migration was
-- written, so the table is recreated rather than migrated.
DROP TABLE tickets;
DROP TABLE records;
CREATE TABLE records (
  id         TEXT PRIMARY KEY,               -- public id: 10 lowercase Crockford base32 characters
  owner_id   TEXT NOT NULL REFERENCES accounts(id),
  client_key BLOB NOT NULL UNIQUE,           -- SHA-256 of the app-made client key: a resend of the same share finds its id
  schema     INTEGER NOT NULL,               -- version of the posted form (1)
  payload    BLOB NOT NULL,                  -- gzip of the canonical JSON of the posted form
  charge     INTEGER NOT NULL,               -- budget charge at share time: length(payload) + ROW_CHARGE
  shared_day INTEGER NOT NULL                -- UTC days since 1970-01-01
);
CREATE INDEX records_owner ON records (owner_id, shared_day DESC);

ALTER TABLE daily RENAME COLUMN publish_bytes TO share_bytes;
ALTER TABLE daily RENAME COLUMN publish_count TO share_count;
ALTER TABLE daily DROP COLUMN tickets;
ALTER TABLE daily ADD COLUMN logins INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily ADD COLUMN accounts_created INTEGER NOT NULL DEFAULT 0;
