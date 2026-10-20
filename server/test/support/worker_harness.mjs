// Runs the real Worker entry (src/index.mjs) in workerd through Miniflare, with an in-memory D1
// that carries every file of migrations/ applied in name order, and the synthetic tables in place
// of the generated ones. The Worker's outbound fetches (Turnstile's siteverify, Google's token
// endpoint) are answered here and never leave the process.

import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash, createHmac, randomBytes } from "node:crypto";
import { gzipSync } from "node:zlib";
import { Miniflare, Response as MfResponse } from "miniflare";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SRC = join(ROOT, "src");
export const FIXTURE_TABLES = JSON.parse(readFileSync(join(ROOT, "test", "fixtures", "tables.json"), "utf8"));

export const ORIGIN = "https://share.test";
export const OG_ORIGIN = "https://og.share.test";
export const TURNSTILE = Object.freeze({
  SITEKEY: "test-sitekey",
  SECRET: "test-secret",
  HOSTNAME: "share.test",
  ACTION: "login",
  /** The token the login helpers send. */
  LOGIN_TOKEN: "turnstile-login-token",
});
export const GOOGLE = Object.freeze({
  CLIENT_ID: "test-client.apps.googleusercontent.com",
  /** AUTH_REDIRECT_ORIGIN: another origin than PUBLIC_ORIGIN, as on staging's own Worker. */
  REDIRECT_ORIGIN: "https://auth.share.test",
  TOKEN_URL: "https://oauth2.googleapis.com/token",
  CLIENT_SECRET: "test-client-secret",
  SUB: "100000000000000000001",
});
/** The Worker's identity HMAC key in tests: a fixed 32 bytes as hex, never a real key. */
export const IDENTITY_HMAC_KEY = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

/** What `identities.subject_hmac` holds for subject `sub` of `provider` under IDENTITY_HMAC_KEY. */
export const subjectHmac = (sub, provider = "google") =>
  createHmac("sha256", Buffer.from(IDENTITY_HMAC_KEY, "hex")).update(`${provider}\u0000${sub}`, "utf8").digest();

// A test-only entry that builds the Worker the way index.mjs does, with two hooks.
//
// The batch gate: the Worker gets a D1 whose `batch()` can be made to wait until a given number of
// batches have arrived. Arming it before sending N requests concurrently guarantees that every one
// of them has done all its work up to the batch (its reads included) before any batch runs, so the
// interleaving a concurrency test claims to cover is the one it gets. `GET /__test/gate` reports
// how many batches arrived, so a test can assert the overlap happened.
//
// Forced public ids: `POST /__test/public-ids` with a JSON array makes the next share attempts
// draw those ids, in order, before falling back to the real generator. `GET` returns the ones not
// drawn yet, so a test can assert its forced id was used.
//
// The clock: the Worker reads time from the real clock plus an offset. `POST /__test/clock?advance=<s>`
// moves it forward by s seconds; `GET` returns `{now}`, the Worker's current time in seconds.
const TEST_ENTRY = `
import tables from "./tables.generated.json";
import { newPublicId } from "./secrets.mjs";
import { createWorker } from "./worker.mjs";
let forcedIds = [];
let offsetMs = 0;
const now = () => Date.now() + offsetMs;
const worker = createWorker(tables, { newId: () => forcedIds.shift() ?? newPublicId(), now });
let armed = null;
let last = { expected: 0, arrived: 0 };
function gatedBatch(db) {
  return async (statements) => {
    const gate = armed;
    if (gate !== null) {
      gate.arrived++;
      if (gate.arrived >= gate.expected) armed = null;
      const deadline = Date.now() + 5000;
      while (gate.arrived < gate.expected && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 2));
      }
    }
    return db.batch(statements);
  };
}
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/__test/gate") {
      if (request.method === "POST") {
        last = armed = { expected: Number(url.searchParams.get("n")), arrived: 0 };
        return new Response(null, { status: 204 });
      }
      return Response.json(last);
    }
    if (url.pathname === "/__test/public-ids") {
      if (request.method === "POST") {
        forcedIds = await request.json();
        return new Response(null, { status: 204 });
      }
      return Response.json(forcedIds);
    }
    if (url.pathname === "/__test/clock") {
      if (request.method === "POST") {
        offsetMs += Number(url.searchParams.get("advance")) * 1000;
        return new Response(null, { status: 204 });
      }
      return Response.json({ now: Math.floor(now() / 1000) });
    }
    const db = env.DB;
    const gated = { prepare: (sql) => db.prepare(sql), batch: gatedBatch(db), exec: (sql) => db.exec(sql) };
    return worker.fetch(request, { ...env, DB: gated }, ctx);
  },
};
`;

function modules(testEntry) {
  const own = readdirSync(SRC)
    .filter((f) => f.endsWith(".mjs"))
    .map((f) => ({ type: "ESModule", path: join(SRC, f), contents: readFileSync(join(SRC, f), "utf8") }));
  // workerd has no JSON module type. wrangler's bundler turns the JSON import into a default
  // export, and so does this module.
  const tables = {
    type: "ESModule",
    path: join(SRC, "tables.generated.json"),
    contents: `export default ${JSON.stringify(FIXTURE_TABLES)};`,
  };
  const isEntry = (m) => m.path.endsWith("index.mjs");
  const entry = own.find(isEntry);
  const rest = [...own.filter((m) => !isEntry(m)), tables];
  if (!testEntry) return [entry, ...rest];
  return [{ type: "ESModule", path: join(SRC, "test_entry.mjs"), contents: TEST_ENTRY }, entry, ...rest];
}

/**
 * The statements of every migration, files in name order (the order wrangler applies them in).
 * Each file is cut at every ";" after dropping "--" comments, so a migration must not hold either
 * inside a string literal, nor a trigger body; 0002_accounts.sql states the same constraint. Lines
 * end at LF or CRLF alike, so a checkout that writes CRLF yields the same statements.
 */
export function migrationStatements(dir = join(ROOT, "migrations")) {
  return readdirSync(dir)
    .filter((f) => f.endsWith(".sql"))
    .sort()
    .flatMap((f) =>
      readFileSync(join(dir, f), "utf8")
        .split(/\r?\n/)
        .map((line) => line.replace(/--.*$/, ""))
        .join("\n")
        .split(";")
        .map((s) => s.trim())
        .filter(Boolean),
    );
}

/**
 * One browser's cookies for ORIGIN, as a browser keeps them: a Set-Cookie replaces the cookie of the
 * same name, and Max-Age=0 removes it. Attributes are kept for the test to read. A test holds as many
 * jars as it has browsers.
 */
export class CookieJar {
  #cookies = new Map();

  /** Takes in every Set-Cookie of `response`. */
  store(response) {
    for (const line of response.headers.getSetCookie()) {
      const [pair, ...attributes] = line.split(";").map((part) => part.trim());
      const eq = pair.indexOf("=");
      const name = pair.slice(0, eq);
      const attrs = Object.fromEntries(
        attributes.map((a) => {
          const at = a.indexOf("=");
          return at === -1 ? [a.toLowerCase(), true] : [a.slice(0, at).toLowerCase(), a.slice(at + 1)];
        }),
      );
      if (attrs["max-age"] !== undefined && Number(attrs["max-age"]) <= 0) this.#cookies.delete(name);
      else this.#cookies.set(name, { value: pair.slice(eq + 1), attrs });
    }
    return response;
  }

  /** The cookie `name` as `{value, attrs}`, or undefined. */
  get(name) {
    return this.#cookies.get(name);
  }

  names() {
    return [...this.#cookies.keys()].sort();
  }

  /** The Cookie request header carrying every cookie held. */
  header() {
    return [...this.#cookies].map(([name, { value }]) => `${name}=${value}`).join("; ");
  }
}

/** A fresh login secret hash `h`: SHA-256 of 256 random bits, as 64 hex digits. */
export const newLoginHash = () => createHash("sha256").update(randomBytes(32)).digest("hex");

/** A fresh client key in the shape the app sends: 128 random bits as unpadded base64url. */
export const newClientKey = () => randomBytes(16).toString("base64url");
/** A fresh login secret `s`: 256 random bits as unpadded base64url. */
export const newLoginSecret = () => randomBytes(32).toString("base64url");
/** SHA-256 of a secret's UTF-8 text, as the server stores it. */
export const secretHash = (text) => createHash("sha256").update(text, "utf8").digest();

/** The siteverify answer for a token that passed the login start page on this environment. */
const passing = () => ({ success: true, hostname: TURNSTILE.HOSTNAME, action: TURNSTILE.ACTION });

const base64urlJson = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");

/**
 * The token endpoint's answer for a code Google issued for `{sub, nonce}`, at `now` (seconds): an ID
 * token carrying them. The signature is filler; the Worker receives the token over TLS from Google
 * and does not verify it.
 */
function tokenAnswer({ sub, nonce, claims: overrides }, now) {
  const claims = { iss: "https://accounts.google.com", aud: GOOGLE.CLIENT_ID, sub, iat: now, exp: now + 3600, nonce, ...overrides };
  const idToken = `${base64urlJson({ alg: "RS256", typ: "JWT" })}.${base64urlJson(claims)}.c2lnbmF0dXJl`;
  return { access_token: "test-access-token", expires_in: 3599, token_type: "Bearer", scope: "openid email", id_token: idToken };
}

/**
 * Starts the Worker. `migrate: false` leaves D1 without any table, so any query the Worker makes
 * throws: a request answered 404 there provably never reached D1. `testEntry: true` runs the
 * test-only entry described above (the batch gate and forced public ids). `vars` overrides the
 * environment variables.
 */
export async function startWorker({ ogImageMode = "static", migrate = true, testEntry = false, vars = {} } = {}) {
  const siteverify = { answer: passing, calls: [] };
  // `codes` maps each authorization code Google issued to the `{sub, nonce}` its ID token carries (an
  // unknown code is refused as Google refuses one); `calls` records each request to the token
  // endpoint with its form body, redirect_uri included.
  const google = { codes: new Map(), calls: [] };
  // The Worker's clock offset (testEntry), so an ID token is fresh on the Worker's clock.
  let clockOffset = 0;
  const mf = new Miniflare({
    modules: modules(testEntry),
    modulesRoot: SRC,
    compatibilityDate: "2026-07-28",
    d1Databases: { DB: "share-test" },
    bindings: {
      PUBLIC_ORIGIN: ORIGIN,
      OG_IMAGE_MODE: ogImageMode,
      OG_IMAGE_ORIGIN: OG_ORIGIN,
      SHARING_ENABLED: "true",
      TURNSTILE_SITEKEY: TURNSTILE.SITEKEY,
      TURNSTILE_SECRET: TURNSTILE.SECRET,
      TURNSTILE_HOSTNAME: TURNSTILE.HOSTNAME,
      TURNSTILE_ACTION: TURNSTILE.ACTION,
      TURNSTILE_TESTING_KEY: "false",
      GOOGLE_CLIENT_ID: GOOGLE.CLIENT_ID,
      GOOGLE_CLIENT_SECRET: GOOGLE.CLIENT_SECRET,
      AUTH_REDIRECT_ORIGIN: GOOGLE.REDIRECT_ORIGIN,
      IDENTITY_HMAC_KEY: IDENTITY_HMAC_KEY,
      ...vars,
    },
    // Every outbound fetch lands here. siteverify and Google's token endpoint are expected; anything
    // else is a 599 the Worker would see as a failure.
    outboundService: async (request) => {
      const url = request.url;
      const form = new URLSearchParams(await request.text());
      if (url === GOOGLE.TOKEN_URL) {
        google.calls.push({ url, form });
        const issued = google.codes.get(form.get("code"));
        if (issued === undefined) return new MfResponse(JSON.stringify({ error: "invalid_grant" }), { status: 400 });
        const now = Math.floor(Date.now() / 1000) + clockOffset;
        return new MfResponse(JSON.stringify(tokenAnswer(issued, now)), { headers: { "Content-Type": "application/json" } });
      }
      siteverify.calls.push({ url, form });
      if (url !== "https://challenges.cloudflare.com/turnstile/v0/siteverify") return new MfResponse("", { status: 599 });
      const answer = siteverify.answer(form);
      if (answer instanceof Error) throw answer;
      return new MfResponse(JSON.stringify(answer), { headers: { "Content-Type": "application/json" } });
    },
  });
  const db = await mf.getD1Database("DB");
  if (migrate) await db.batch(migrationStatements().map((s) => db.prepare(s)));
  const fetch = (path, init) => mf.dispatchFetch(`${ORIGIN}${path}`, init);
  const post = (path, body) =>
    fetch(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });

  return {
    fetch,
    post,
    db,
    dispose: () => mf.dispose(),
    /** What siteverify answers: an object (sent as JSON) or an Error (a failed fetch). */
    siteverify,
    /** Google's token endpoint: the nonce its next ID token carries, and the requests it received. */
    google,

    /**
     * POST /api/auth/begin as the start page's form sends it: from PUBLIC_ORIGIN, urlencoded, with
     * LOGIN_TOKEN. `fields` overrides or adds form fields; `headers` overrides request headers. With
     * a browser `jar`, the request carries the jar's cookies, as a browser's form post does, and the
     * jar keeps what the answer sets; without one it is a browser holding no cookie.
     */
    async begin(fields = {}, headers = {}, jar = null) {
      const form = new URLSearchParams({ p: "google", token: TURNSTILE.LOGIN_TOKEN, ...fields });
      const cookie = jar === null ? {} : { Cookie: jar.header() };
      const res = await fetch("/api/auth/begin", {
        method: "POST",
        headers: { Origin: ORIGIN, "Content-Type": "application/x-www-form-urlencoded", ...cookie, ...headers },
        body: form.toString(),
        redirect: "manual",
      });
      return jar === null ? res : jar.store(res);
    },
    /** The login row stored under `h` (64 hex digits), or null. */
    async login(h) {
      return db.prepare("SELECT * FROM logins WHERE h = ?").bind(Buffer.from(h, "hex")).first();
    },
    /** The Worker's clock in seconds (needs `testEntry: true`). */
    async now() {
      return (await (await fetch("/__test/clock")).json()).now;
    },
    /** Moves the Worker's clock forward by `seconds` (needs `testEntry: true`). */
    async advanceClock(seconds) {
      (await fetch(`/__test/clock?advance=${seconds}`, { method: "POST" })).body?.cancel();
      clockOffset += seconds;
    },

    /**
     * Plays Google's screens for a begin's 302 `location`: issues a fresh code for subject `sub` with
     * the authorisation URL's nonce (or `nonce`), its ID token's other claims replaced by `claims`
     * (`exp` there is read as given, in seconds), and returns the callback path Google sends the
     * browser back to, with the URL's state.
     */
    authorize(location, { sub = GOOGLE.SUB, nonce, claims = {} } = {}) {
      const q = new URL(location).searchParams;
      const code = randomBytes(16).toString("base64url");
      google.codes.set(code, { sub, nonce: nonce ?? q.get("nonce"), claims });
      return `/api/auth/callback/google?${new URLSearchParams({ state: q.get("state"), code })}`;
    },
    /** GET `path` (a callback) from the browser `jar`, keeping what it sets. */
    async visit(path, jar) {
      return jar.store(await fetch(path, { headers: { Cookie: jar.header() }, redirect: "manual" }));
    },
    /** POST /api/auth/claim `body` from the browser `jar` (or with no cookie when jar is null). */
    async claim(body, jar = null) {
      const headers = { "Content-Type": "application/json", ...(jar === null ? {} : { Cookie: jar.header() }) };
      const res = await fetch("/api/auth/claim", { method: "POST", headers, body: JSON.stringify(body) });
      return jar === null ? res : jar.store(res);
    },
    logout: (token) => fetch("/api/auth/logout", { method: "POST", headers: { Authorization: `Bearer ${token}` } }),

    /** Stores `form` as shared record `id` of a fresh account, the way the share endpoint stores it. */
    async insertRecord(id, form, sharedDay = 20_000) {
      const payload = gzipSync(Buffer.from(JSON.stringify(form)));
      const owner = randomBytes(10).toString("hex").slice(0, 16);
      await db.batch([
        db.prepare("INSERT INTO accounts (id, created_day, share_count) VALUES (?, ?, 1)").bind(owner, sharedDay),
        db
          .prepare("INSERT INTO records (id, owner_id, client_key, schema, payload, charge, shared_day) VALUES (?, ?, ?, 1, ?, ?, ?)")
          .bind(id, owner, randomBytes(32), payload, payload.length, sharedDay),
      ]);
    },

    /**
     * A session token for subject `sub`, claimed through a web login: the start page's begin, Google's
     * screens, the callback and the claim, in a browser of its own.
     */
    async signIn(sub = GOOGLE.SUB) {
      const jar = new CookieJar();
      const s = newLoginSecret();
      const begun = await this.begin({ h: secretHash(s).toString("hex") }, {}, jar);
      await begun.arrayBuffer();
      const back = await this.visit(this.authorize(begun.headers.get("location"), { sub }), jar);
      await back.arrayBuffer();
      const claimed = await this.claim({ s }, jar);
      if (claimed.status !== 200) throw new Error(`the claim answered ${claimed.status}`);
      return (await claimed.json()).token;
    },
    /** The account id of the session `token`. */
    async accountOf(token) {
      return (await db.prepare("SELECT account_id FROM sessions WHERE token_hash = ?").bind(secretHash(token)).first())
        .account_id;
    },

    /** POST /api/shares `{shares}` with the session `token`. */
    share: (token, shares) =>
      fetch("/api/shares", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: JSON.stringify({ shares }),
      }),
    unshare: (token, id) => fetch(`/api/shares/${id}`, { method: "DELETE", headers: { Authorization: `Bearer ${token}` } }),
    myShares: (token) => fetch("/api/me/shares", { headers: { Authorization: `Bearer ${token}` } }),

    /** Makes the next `n` D1 batches wait for each other (needs `testEntry: true`). */
    async armGate(n) {
      (await fetch(`/__test/gate?n=${n}`, { method: "POST" })).body?.cancel();
    },
    /** Makes the next share attempts draw `ids` as their public ids (needs `testEntry: true`). */
    async forcePublicIds(ids) {
      (await fetch("/__test/public-ids", { method: "POST", body: JSON.stringify(ids) })).body?.cancel();
    },
    /** The forced public ids not drawn yet. */
    async forcedPublicIdsLeft() {
      return (await fetch("/__test/public-ids")).json();
    },
    /** `{expected, arrived}` of the last armed gate. */
    async gate() {
      return (await fetch("/__test/gate")).json();
    },

    async count(table) {
      return (await db.prepare(`SELECT count(*) AS n FROM ${table}`).first()).n;
    },
    /** `{share_count, quota_day, quota_bytes}` of account `id`. */
    async account(id) {
      return db.prepare("SELECT share_count, quota_day, quota_bytes FROM accounts WHERE id = ?").bind(id).first();
    },
    async totals() {
      return db.prepare("SELECT bytes, count FROM totals WHERE id = 1").first();
    },
    async daily() {
      return db.prepare("SELECT day, share_bytes, share_count FROM daily ORDER BY day").all().then((r) => r.results);
    },
  };
}

const chara = (n) => ({ character: n, card: n });

/** A posted form v1 that reads every table; `overrides` replaces top-level keys. */
export function postedForm(overrides = {}) {
  return {
    schema: 1,
    region: "JPN",
    module_version: "2026-01-01T00:00:00Z",
    recognizer_version: "2026-01-01T00:00:00Z",
    record_type: "Standard",
    strategy: 1,
    relation_bonus: 42,
    trainee: { character: 3, card: 3, rank: 2 },
    evaluation_value: 12345,
    status: { speed: 1200, stamina: 800, power: 900, guts: 400, intelligence: 1000 },
    aptitudes: {
      ground: { turf: 7, dirt: 0 },
      distance: { short_range: 1, mile_range: 2, middle_range: 6, long_range: 5 },
      style: { lead_pace: 3, with_pace: 7, off_pace: 4, late_charge: 0 },
    },
    skills: [{ id: 2, level: 3 }, { id: 0 }],
    factors: { self: [{ id: 1, star: 3 }], parent1: [{ id: 2, star: 1 }], parent2: [{ id: 3, star: 2 }] },
    support_cards: [{ id: 1, rank: 4, level: 50 }],
    family: {
      parent1: { self: chara(1), parent1: chara(0), parent2: chara(2), rental: true },
      parent2: { self: chara(2), parent1: chara(0), parent2: chara(1) },
    },
    fans: 123456,
    scenario: { id: 1 },
    trained_date: "2026/09/30",
    races: [
      { title: 2, place: 1, ground: 0, distance: 1, variation: 1, weather: 1, strategy: 2, turn: 2, position: 1 },
      { title: 0, place: 0, ground: 1, distance: 0, variation: 0, weather: 0, strategy: 0, turn: 0, position: 18 },
    ],
    ...overrides,
  };
}
