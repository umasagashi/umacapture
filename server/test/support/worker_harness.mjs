// Runs the real Worker entry (src/index.mjs) in workerd through Miniflare, with an in-memory D1
// that carries migrations/0001_init.sql, and the synthetic tables in place of the generated ones.
// The Worker's outbound fetch (Turnstile's siteverify) is answered here and never leaves the process.

import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash, randomBytes } from "node:crypto";
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
  ACTION: "publish",
});

// A test-only entry that builds the Worker the way index.mjs does, with two hooks.
//
// The batch gate: the Worker gets a D1 whose `batch()` can be made to wait until a given number of
// batches have arrived. Arming it before sending N requests concurrently guarantees that every one
// of them has done all its work up to the batch (its reads included) before any batch runs, so the
// interleaving a concurrency test claims to cover is the one it gets. `GET /__test/gate` reports
// how many batches arrived, so a test can assert the overlap happened.
//
// Forced public ids: `POST /__test/public-ids` with a JSON array makes the next publish attempts
// draw those ids, in order, before falling back to the real generator. `GET` returns the ones not
// drawn yet, so a test can assert its forced id was used.
const TEST_ENTRY = `
import tables from "./tables.generated.json";
import { newPublicId } from "./secrets.mjs";
import { createWorker } from "./worker.mjs";
let forcedIds = [];
const worker = createWorker(tables, { newId: () => forcedIds.shift() ?? newPublicId() });
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

function migrationStatements() {
  const sql = readFileSync(join(ROOT, "migrations", "0001_init.sql"), "utf8")
    .split("\n")
    .map((line) => line.replace(/--.*$/, ""))
    .join("\n");
  return sql
    .split(";")
    .map((s) => s.trim())
    .filter(Boolean);
}

/** A fresh delete key in the shape the app sends: 128 random bits as unpadded base64url. */
export const newDeleteKey = () => randomBytes(16).toString("base64url");
/** A fresh ticket: 256 random bits as unpadded base64url. */
export const newTicket = () => randomBytes(32).toString("base64url");
/** SHA-256 of a secret's UTF-8 text, as the server stores it. */
export const secretHash = (text) => createHash("sha256").update(text, "utf8").digest();

/** The siteverify answer for a token that passed on this environment. */
const passing = () => ({ success: true, hostname: TURNSTILE.HOSTNAME, action: TURNSTILE.ACTION });

/**
 * Starts the Worker. `migrate: false` leaves D1 without any table, so any query the Worker makes
 * throws: a request answered 404 there provably never reached D1. `testEntry: true` runs the
 * test-only entry described above (the batch gate and forced public ids). `vars` overrides the
 * environment variables.
 */
export async function startWorker({ ogImageMode = "static", migrate = true, testEntry = false, vars = {} } = {}) {
  const siteverify = { answer: passing, calls: [] };
  const mf = new Miniflare({
    modules: modules(testEntry),
    modulesRoot: SRC,
    compatibilityDate: "2026-07-28",
    d1Databases: { DB: "share-test" },
    bindings: {
      PUBLIC_ORIGIN: ORIGIN,
      OG_IMAGE_MODE: ogImageMode,
      OG_IMAGE_ORIGIN: OG_ORIGIN,
      PUBLISH_ENABLED: "true",
      TURNSTILE_SITEKEY: TURNSTILE.SITEKEY,
      TURNSTILE_SECRET: TURNSTILE.SECRET,
      TURNSTILE_HOSTNAME: TURNSTILE.HOSTNAME,
      TURNSTILE_ACTION: TURNSTILE.ACTION,
      TURNSTILE_TESTING_KEY: "false",
      ...vars,
    },
    // Every outbound fetch lands here. Only siteverify is expected; anything else is a 599 the
    // Worker would see as a failure.
    outboundService: async (request) => {
      const url = request.url;
      const form = new URLSearchParams(await request.text());
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

    /** Stores `form` as published record `id`, the way the publish endpoint stores it. */
    async insertRecord(id, form, publishedDay = 20_000) {
      const payload = gzipSync(Buffer.from(JSON.stringify(form)));
      await db
        .prepare(
          "INSERT INTO records (id, delete_key_hash, schema, payload, charge, published_day) VALUES (?, ?, 1, ?, ?, ?)",
        )
        .bind(id, randomBytes(32), payload, payload.length, publishedDay)
        .run();
    },

    /** A ticket registered through POST /api/tickets (siteverify answering as it is set to). */
    async issueTicket() {
      const ticket = newTicket();
      const h = secretHash(ticket).toString("hex");
      const res = await post("/api/tickets", { h, token: "turnstile-token" });
      await res.arrayBuffer();
      if (res.status !== 204) throw new Error(`issuing a ticket answered ${res.status}`);
      return ticket;
    },

    publish: (body) => post("/api/records", body),
    withdraw: (id, deleteKey) =>
      fetch(`/api/records/${id}`, { method: "DELETE", headers: { Authorization: `Bearer ${deleteKey}` } }),

    /** Makes the next `n` D1 batches wait for each other (needs `testEntry: true`). */
    async armGate(n) {
      (await fetch(`/__test/gate?n=${n}`, { method: "POST" })).body?.cancel();
    },
    /** Makes the next publish attempts draw `ids` as their public ids (needs `testEntry: true`). */
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
    async remaining(ticket) {
      return (await db.prepare("SELECT remaining FROM tickets WHERE hash = ?").bind(secretHash(ticket)).first())?.remaining;
    },
    async totals() {
      return db.prepare("SELECT bytes, count FROM totals WHERE id = 1").first();
    },
    async daily() {
      return db.prepare("SELECT day, publish_bytes, publish_count, tickets FROM daily ORDER BY day").all().then((r) => r.results);
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
