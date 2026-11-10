// Runs the real Worker entry (src/index.mjs) in workerd through Miniflare, with an in-memory D1
// that carries every file of migrations/ applied in name order and the synthetic tables
// (test/fixtures/tables.json) loaded into it as the publishing step loads a module set. The Worker's outbound fetches (Turnstile's siteverify, Google's token
// endpoint, the B2 bucket) are answered here and never leave the process.

import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash, createHmac, randomBytes } from "node:crypto";
import { gzipSync } from "node:zlib";
import { Miniflare, Response as MfResponse } from "miniflare";
import * as limits from "../../src/limits.mjs";

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
/** The Sentry a report is sent to in tests: a host no real request could reach. */
export const SENTRY = Object.freeze({
  DSN: "https://test-public-key@sentry.share.test/42",
  ENDPOINT: "https://sentry.share.test/api/42/envelope/",
  ENVIRONMENT: "test",
});
/** The Worker's identity HMAC key in tests: a fixed 32 bytes as hex, never a real key. */
export const IDENTITY_HMAC_KEY = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

/** The B2 bucket in tests: a host no real request could reach, and fixed key values, never a real key. */
export const B2 = Object.freeze({
  ENDPOINT: "s3.b2.test",
  REGION: "test-region-1",
  BUCKET: "sync-test",
  KEY_ID: "test-key-id",
  APPLICATION_KEY: "test-application-key",
});

const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const xml = (body, status = 200) => new MfResponse(body, { status, headers: { "Content-Type": "application/xml" } });
const xmlText = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const unXml = (s) => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");

/**
 * An in-memory, versioned B2 bucket answering the S3 calls the Worker makes, with B2's own behaviour
 * as measured on the real service and nothing more. A PUT whose x-amz-content-sha256 is not the
 * SHA-256 of the bytes is refused 403 and stores nothing; UNSIGNED-PAYLOAD is accepted unchecked.
 * Conditional writes (If-None-Match, If-Match) are 501. A DELETE naming no version adds a delete
 * marker whatever the latest version is; one naming a version removes it for good. DeleteObjects
 * takes at most 1,000 objects and marks names that do not exist too. GET is 404 when the latest
 * version is a marker. The signature itself is not verified, only that the request carries one.
 * `requests` records every call as `{method, key, query}`.
 *
 * `hold` stops one operation on one key before it takes effect, so a test can order B2's side of
 * two requests apart from their D1 side (whose batches the batch gate orders). `fail` makes B2 fail
 * one DeleteObjects, `failTarget` one target of one, and `failPuts` the next PUTs of one key.
 *
 * The bucket's lifecycle rule (`daysFromHidingToDeleting`) runs only when a test runs it, in its two
 * steps apart: `pickExpired` picks every version hidden that many days on the Worker's clock (`now`,
 * seconds), and `deleteExpired` deletes the picked versions for good, including any shown again since
 * it picked them. Real B2 is not known to delete in that order; it is the worst order there is.
 */
export class FakeB2 {
  /** key → versions, oldest first: `{versionId, marker, bytes, at}`, `at` the Worker's clock when added. */
  objects = new Map();
  requests = [];
  /**
   * Versions a ListObjectVersions page holds at most. S3 lists up to 1,000 and may list fewer, so a
   * test can make pages shorter to put their ends where it needs them.
   */
  pageSize = 1000;
  #next = 0;
  #holds = [];
  #fails = [];
  #failsOne = [];
  #failedPuts = [];
  /** `{key, versionId}` the lifecycle picked and has not deleted yet. */
  #picked = [];

  constructor(now = () => Math.floor(Date.now() / 1000)) {
    this.now = now;
  }

  /**
   * Holds the next `op` on `key` until `release()`: "PUT", "HIDE" (a DELETE naming no version),
   * "DELETE_VERSION", or "DELETE_OBJECTS" (any DeleteObjects one of whose targets is `key`).
   * `entered` resolves when the request arrives and waits.
   */
  hold(op, key) {
    let release;
    let entered;
    const gate = new Promise((resolve) => (release = resolve));
    const arrived = new Promise((resolve) => (entered = resolve));
    this.#holds.push({ op, key, gate, entered });
    return { entered: arrived, release };
  }

  /** Answers the next DeleteObjects one of whose targets is `key` 500, as B2 failing does, before it takes effect. */
  fail(key) {
    this.#fails.push(key);
  }

  /**
   * Answers the next PUTs of `key`, one each, with `answers` in turn (`{status, code, retryAfter}`, the
   * Retry-After header when given) before they take effect, as B2 failing does: `503` `SlowDown` when
   * it is busy. The error names the key, as B2's does. With `cut`, the connection drops after the
   * headers and the start of the error, before the rest of it arrives.
   */
  failPuts(key, answers) {
    this.#failedPuts.push(...answers.map((a) => ({ key, ...a })));
  }

  /** Reports the next DeleteObjects target naming `key` as an error, as B2 may for one object of many, and leaves it. */
  failTarget(key) {
    this.#failsOne.push(key);
  }

  async #wait(op, keys) {
    const at = this.#holds.findIndex((h) => h.op === op && keys.includes(h.key));
    if (at === -1) return;
    const [h] = this.#holds.splice(at, 1);
    h.entered();
    await h.gate;
  }

  /** The versions of `key`, oldest first, as `"v"` (an object) or `"m"` (a delete marker). */
  versions(key) {
    return (this.objects.get(key) ?? []).map((v) => (v.marker ? "m" : "v"));
  }

  #add(key, version) {
    const versionId = `v${++this.#next}`;
    if (!this.objects.has(key)) this.objects.set(key, []);
    this.objects.get(key).push({ versionId, ...version, at: this.now() });
    return versionId;
  }

  /**
   * The lifecycle's first step: picks every object version hidden (by the marker or the version added
   * next above it) at least `days` days ago on the Worker's clock. Returns the keys it picked, sorted.
   */
  pickExpired(days = limits.B2_DAYS_FROM_HIDING_TO_DELETING) {
    const by = this.now() - days * 86_400;
    const keys = new Set();
    for (const [key, versions] of this.objects) {
      versions.forEach((v, i) => {
        if (v.marker || i === versions.length - 1 || versions[i + 1].at > by) return;
        if (this.#picked.some((p) => p.key === key && p.versionId === v.versionId)) return;
        this.#picked.push({ key, versionId: v.versionId });
        keys.add(key);
      });
    }
    return [...keys].sort();
  }

  /** The lifecycle's second step: deletes every version `pickExpired` picked, whatever it is now. Returns how many it deleted. */
  deleteExpired() {
    const picked = this.#picked.splice(0);
    let deleted = 0;
    for (const { key, versionId } of picked) {
      if ((this.objects.get(key) ?? []).some((v) => v.versionId === versionId)) deleted++;
      this.#deleteVersion(key, versionId);
    }
    return deleted;
  }

  #latest(key) {
    const versions = this.objects.get(key);
    return versions === undefined || versions.length === 0 ? null : versions.at(-1);
  }

  #deleteVersion(key, versionId) {
    const versions = this.objects.get(key) ?? [];
    const at = versions.findIndex((v) => v.versionId === versionId);
    if (at !== -1) versions.splice(at, 1);
    if (versions.length === 0) this.objects.delete(key);
  }

  /** The bytes of `key`'s latest version, or null when it has none or the latest is a marker. */
  visible(key) {
    const latest = this.#latest(key);
    return latest === null || latest.marker ? null : latest.bytes;
  }

  /** Every key holding any version or marker under `prefix`. */
  keys(prefix = "") {
    return [...this.objects.keys()].filter((k) => k.startsWith(prefix)).sort();
  }

  /** How many recorded requests had `method` (and `key`, when given). */
  count(method, key) {
    return this.requests.filter((r) => r.method === method && (key === undefined || r.key === key)).length;
  }

  async handle(request) {
    const url = new URL(request.url);
    const prefix = `/${B2.BUCKET}`;
    if (!url.pathname.startsWith(prefix)) return xml("<Error><Code>NoSuchBucket</Code></Error>", 404);
    const key = decodeURIComponent(url.pathname.slice(prefix.length + 1));
    const query = Object.fromEntries(url.searchParams);
    const method = request.method;
    this.requests.push({ method, key, query });
    const claimed = request.headers.get("x-amz-content-sha256");
    if (!request.headers.get("authorization")?.startsWith("AWS4-HMAC-SHA256 ") || claimed === null || !request.headers.get("x-amz-date")) {
      return xml("<Error><Code>AccessDenied</Code></Error>", 403);
    }
    if (request.headers.has("if-none-match") || request.headers.has("if-match")) {
      return xml("<Error><Code>NotImplemented</Code></Error>", 501);
    }
    const bytes = new Uint8Array(await request.arrayBuffer());
    if (claimed !== "UNSIGNED-PAYLOAD" && claimed !== sha256(bytes)) {
      return xml("<Error><Code>AccessDenied</Code><Message>Signature validation failed</Message></Error>", 403);
    }
    if (method === "PUT" && key !== "") {
      const failed = this.#failedPuts.findIndex((f) => f.key === key);
      if (failed !== -1) {
        const [{ status, code, retryAfter, cut }] = this.#failedPuts.splice(failed, 1);
        const res = cut
          ? new MfResponse(
              new ReadableStream({
                start: (c) => c.enqueue(new TextEncoder().encode("<Error>")),
                pull: (c) => c.error(new Error("connection reset")),
              }),
              { status, headers: { "Content-Type": "application/xml", "Content-Length": "512" } },
            )
          : xml(`<Error><Code>${code}</Code><Message>Please reduce your request rate.</Message><Resource>/${B2.BUCKET}/${xmlText(key)}</Resource></Error>`, status);
        if (retryAfter !== undefined) res.headers.set("Retry-After", retryAfter);
        return res;
      }
      await this.#wait("PUT", [key]);
      const versionId = this.#add(key, { marker: false, bytes });
      return new MfResponse("", { headers: { "x-amz-version-id": versionId } });
    }
    if ((method === "GET" || method === "HEAD") && key !== "") {
      const visible = this.visible(key);
      if (visible === null) return xml("<Error><Code>NoSuchKey</Code></Error>", 404);
      return new MfResponse(method === "HEAD" ? null : visible, { headers: { "Content-Length": String(visible.length) } });
    }
    if (method === "DELETE" && key !== "") {
      await this.#wait(query.versionId === undefined ? "HIDE" : "DELETE_VERSION", [key]);
      if (query.versionId !== undefined) {
        this.#deleteVersion(key, query.versionId);
        return new MfResponse(null, { status: 204, headers: { "x-amz-version-id": query.versionId } });
      }
      const versionId = this.#add(key, { marker: true, bytes: null });
      return new MfResponse(null, { status: 204, headers: { "x-amz-version-id": versionId, "x-amz-delete-marker": "true" } });
    }
    if (method === "POST" && key === "" && "delete" in query) {
      const targets = [...new TextDecoder().decode(bytes).matchAll(/<Object>([\s\S]*?)<\/Object>/g)].map(([, o]) => ({
        key: unXml(/<Key>([\s\S]*?)<\/Key>/.exec(o)[1]),
        versionId: /<VersionId>([\s\S]*?)<\/VersionId>/.exec(o)?.[1],
      }));
      if (targets.length > 1000) return xml("<Error><Code>InvalidRequest</Code></Error>", 400);
      const quiet = /<Quiet>true<\/Quiet>/.test(new TextDecoder().decode(bytes));
      await this.#wait("DELETE_OBJECTS", targets.map((t) => t.key));
      const failing = this.#fails.findIndex((key) => targets.some((t) => t.key === key));
      if (failing !== -1) {
        this.#fails.splice(failing, 1);
        return xml("<Error><Code>InternalError</Code></Error>", 500);
      }
      // Without Quiet, each target is reported as S3 documents it: a version named, or the marker
      // added over a name. That B2 reports the marker's version id this way is an assumption. A target
      // reported as an error is reported with or without Quiet.
      const errors = [];
      const deleted = targets.map((t) => {
        const one = this.#failsOne.indexOf(t.key);
        if (one !== -1) {
          this.#failsOne.splice(one, 1);
          errors.push(`<Error><Key>${xmlText(t.key)}</Key><Code>InternalError</Code></Error>`);
          return "";
        }
        if (t.versionId !== undefined) {
          this.#deleteVersion(t.key, t.versionId);
          return `<Deleted><Key>${xmlText(t.key)}</Key><VersionId>${t.versionId}</VersionId></Deleted>`;
        }
        const versionId = this.#add(t.key, { marker: true, bytes: null });
        return `<Deleted><Key>${xmlText(t.key)}</Key><DeleteMarker>true</DeleteMarker><DeleteMarkerVersionId>${versionId}</DeleteMarkerVersionId></Deleted>`;
      });
      return xml(`<DeleteResult>${quiet ? "" : deleted.join("")}${errors.join("")}</DeleteResult>`);
    }
    if (method === "GET" && key === "" && "versions" in query) {
      // In key order, as S3 lists; a page begins after key-marker (after its version
      // version-id-marker, when given) and ends at pageSize versions.
      const all = this.keys(query.prefix ?? "").flatMap((k) => {
        const versions = this.objects.get(k);
        return versions.map((v, i) => ({ key: k, versionId: v.versionId, marker: v.marker, latest: i === versions.length - 1, at: v.at }));
      });
      const after = query["key-marker"];
      const start =
        after === undefined
          ? 0
          : query["version-id-marker"] === undefined
            ? all.findIndex((e) => e.key > after)
            : all.findIndex((e) => e.key === after && e.versionId === query["version-id-marker"]) + 1;
      const page = start === -1 ? [] : all.slice(start, start + this.pageSize);
      const truncated = start !== -1 && start + this.pageSize < all.length;
      const last = page.at(-1);
      const entries = page.map((e) => {
        const tag = e.marker ? "DeleteMarker" : "Version";
        const modified = new Date(e.at * 1000).toISOString();
        return `<${tag}><Key>${xmlText(e.key)}</Key><VersionId>${e.versionId}</VersionId><IsLatest>${e.latest}</IsLatest><LastModified>${modified}</LastModified></${tag}>`;
      });
      const next = truncated ? `<NextKeyMarker>${xmlText(last.key)}</NextKeyMarker><NextVersionIdMarker>${last.versionId}</NextVersionIdMarker>` : "";
      return xml(`<ListVersionsResult><IsTruncated>${truncated}</IsTruncated>${next}${entries.join("")}</ListVersionsResult>`);
    }
    return xml("<Error><Code>InvalidRequest</Code></Error>", 400);
  }
}

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
//
// A cut-off request: `POST /__test/d1-fault` with `{match}` makes the next D1 statement whose SQL
// contains `match` fail when it runs, as a request stopped at that point (past its CPU limit, or
// disconnected) leaves D1: what it committed before stays, nothing after runs. With `cut`, every
// statement and batch after it fails too, until a POST with `{match: null}`, so a request whose
// failure has a way back (a rolled-back batch) cannot take it: `cut: "before"` fails the matching
// statement, `cut: "after"` runs it and fails once it has committed. `GET` returns the match not
// reached yet, or null. A statement found inside a batch acts the same way: the batch fails, or
// commits and then the request is cut off. Statements a caller names (a leading \`/* name */\`, see
// \`named\` in sync_refs.mjs) are found by that name, whatever their SQL says otherwise.
//
// The database's size: \`POST /__test/d1-size\` with \`{add}\` makes every statement and batch the Worker
// runs from then on report \`add\` bytes more in \`meta.size_after\` than the in-memory D1 holds, as a
// database that much fuller would; \`{add: 0}\` ends it.
//
// A write landing between two reads: \`POST /__test/d1-before\` with \`{match, sql}\` makes the next D1
// statement whose SQL contains \`match\` run the statements \`sql\` (an array of SQL strings, one batch)
// just before it runs, as another writer committing at that moment would.
//
// The scheduled handler gets the same D1, so the daily run can be ordered against requests too.
const TEST_ENTRY = `
import { newPublicId } from "./secrets.mjs";
import { createWorker } from "./worker.mjs";
let forcedIds = [];
let offsetMs = 0;
const now = () => Date.now() + offsetMs;
const worker = createWorker({ newId: () => forcedIds.shift() ?? newPublicId(), now });
let armed = null;
let last = { expected: 0, arrived: 0 };
let fault = null;
let cut = false;
let sizeAdded = 0;
function sized(result) {
  if (typeof result?.meta?.size_after === "number") result.meta.size_after += sizeAdded;
  return result;
}
function resized(statement) {
  return {
    bind: (...args) => resized(statement.bind(...args)),
    all: async (...args) => sized(await statement.all(...args)),
    run: async (...args) => sized(await statement.run(...args)),
    first: (...args) => statement.first(...args),
    raw: (...args) => statement.raw(...args),
    real: statement,
  };
}
function failing(sql) {
  const fail = () => Promise.reject(new Error("D1 fault injected at " + sql));
  const statement = { bind: () => statement, all: fail, run: fail, first: fail, raw: fail, fault: "fail" };
  return statement;
}
function committedThenCut(real) {
  const wrap = (statement) => {
    const run = (op) => async (...args) => {
      await statement[op](...args);
      cut = true;
      throw new Error("D1 fault injected: the request was cut off after a statement committed");
    };
    return { bind: (...args) => wrap(statement.bind(...args)), all: run("all"), run: run("run"), first: run("first"), raw: run("raw"), fault: "after", real: statement };
  };
  return wrap(real);
}
let writeBefore = null;
function precededBy(db, writes, statement) {
  const run = (op) => async (...args) => {
    await db.batch(writes.map((sql) => db.prepare(sql)));
    return statement[op](...args);
  };
  return { bind: (...args) => precededBy(db, writes, statement.bind(...args)), all: run("all"), run: run("run"), first: run("first"), raw: run("raw"), real: statement };
}
function gated(db) {
  const prepare = (sql) => {
    if (cut) return failing(sql);
    if (writeBefore !== null && sql.includes(writeBefore.match)) {
      const writes = writeBefore.sql;
      writeBefore = null;
      return precededBy(db, writes, db.prepare(sql));
    }
    if (fault !== null && sql.includes(fault.match)) {
      const mode = fault.cut;
      fault = null;
      if (mode === "after") return committedThenCut(db.prepare(sql));
      cut = mode === "before";
      return failing(sql);
    }
    return sizeAdded === 0 ? db.prepare(sql) : resized(db.prepare(sql));
  };
  return { prepare, batch: gatedBatch(db), exec: (sql) => db.exec(sql) };
}
function gatedBatch(db) {
  return async (statements) => {
    if (cut) throw new Error("D1 fault injected: the request was cut off");
    const gate = armed;
    if (gate !== null) {
      gate.arrived++;
      if (gate.arrived >= gate.expected) armed = null;
      const deadline = Date.now() + 5000;
      while (gate.arrived < gate.expected && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 2));
      }
    }
    if (statements.some((s) => s.fault === "fail")) throw new Error("D1 fault injected in a batch");
    const results = await db.batch(statements.map((s) => s.real ?? s));
    if (statements.some((s) => s.fault === "after")) {
      cut = true;
      throw new Error("D1 fault injected: the request was cut off after a batch committed");
    }
    return results.map(sized);
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
    if (url.pathname === "/__test/d1-fault") {
      if (request.method === "POST") {
        const { match, cut: mode = false } = await request.json();
        fault = match === null ? null : { match, cut: mode };
        if (match === null) cut = false;
        return new Response(null, { status: 204 });
      }
      return Response.json(fault?.match ?? null);
    }
    if (url.pathname === "/__test/d1-before" && request.method === "POST") {
      writeBefore = await request.json();
      return new Response(null, { status: 204 });
    }
    if (url.pathname === "/__test/d1-size" && request.method === "POST") {
      sizeAdded = (await request.json()).add;
      return new Response(null, { status: 204 });
    }
    return worker.fetch(request, { ...env, DB: gated(env.DB) }, ctx);
  },
  async scheduled(controller, env, ctx) {
    return worker.scheduled(controller, { ...env, DB: gated(env.DB) }, ctx);
  },
};
`;

function modules(testEntry) {
  const own = readdirSync(SRC)
    .filter((f) => f.endsWith(".mjs"))
    .map((f) => ({ type: "ESModule", path: join(SRC, f), contents: readFileSync(join(SRC, f), "utf8") }));
  const isEntry = (m) => m.path.endsWith("index.mjs");
  const entry = own.find(isEntry);
  const rest = own.filter((m) => !isEntry(m));
  if (!testEntry) return [entry, ...rest];
  return [{ type: "ESModule", path: join(SRC, "test_entry.mjs"), contents: TEST_ENTRY }, entry, ...rest];
}

/**
 * The statements of every migration, files in name order (the order wrangler applies them in).
 * Each file is cut at every ";" after dropping "--" comments, except that a CREATE TRIGGER runs on
 * to the ";" after its END, so a migration must not hold either inside a string literal;
 * 0002_accounts.sql states the same constraint. Lines end at LF or CRLF alike, so a checkout that
 * writes CRLF yields the same statements.
 */
export function migrationStatements(dir = join(ROOT, "migrations")) {
  return readdirSync(dir)
    .filter((f) => f.endsWith(".sql"))
    .sort()
    .flatMap((f) => {
      const pieces = readFileSync(join(dir, f), "utf8")
        .split(/\r?\n/)
        .map((line) => line.replace(/--.*$/, ""))
        .join("\n")
        .split(";");
      const statements = [];
      let open = null;
      for (const piece of pieces) {
        open = open === null ? piece : `${open};${piece}`;
        if (/^\s*CREATE\s+TRIGGER\b/i.test(open) && !/\bEND\s*$/i.test(open)) continue;
        statements.push(open.trim());
        open = null;
      }
      return statements.filter(Boolean);
    });
}

/**
 * Appends to D1's name tables what `raw` (`{version, names, gids, tags}`, the shape tables.mjs reads
 * back; `tags` may be absent, as from a module set loaded before 0007) holds past their end, then records the load, as the publishing step does: rows first, the load row
 * last, one generation past the greatest. Returns the number of rows added; a load adding none
 * writes nothing.
 */
export async function appendTables(db, raw, archiveSha256 = "0".repeat(64)) {
  const rows = [];
  // Tags are written as load_share_tables.py writes them: a JSON array with no spaces.
  const tags = Object.fromEntries(Object.entries(raw.tags ?? {}).map(([key, list]) => [key, list.map((t) => JSON.stringify(t))]));
  for (const [table, field, lists] of [
    ["share_table_name", "name", raw.names],
    ["share_table_gid", "gid", raw.gids],
    ["share_table_tags", "tags", tags],
  ]) {
    for (const [key, list] of Object.entries(lists)) {
      const { held } = await db.prepare(`SELECT COUNT(*) AS held FROM ${table} WHERE key = ?`).bind(key).first();
      for (let pos = held; pos < list.length; pos++) {
        rows.push(db.prepare(`INSERT INTO ${table} (key, pos, ${field}) VALUES (?, ?, ?)`).bind(key, pos, list[pos]));
      }
    }
  }
  if (rows.length === 0) return 0;
  await db.batch(rows);
  await db
    .prepare(
      `INSERT INTO share_table_load (generation, archive_sha256, recognizer_version, rows_added, loaded_at)
       VALUES ((SELECT COALESCE(MAX(generation), 0) + 1 FROM share_table_load), ?, ?, ?, ?)`,
    )
    .bind(archiveSha256, raw.version, rows.length, Math.floor(Date.now() / 1000))
    .run();
  return rows.length;
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
 * Starts the Worker, its D1 migrated and holding FIXTURE_TABLES. `migrate: false` leaves D1 without
 * any table, so any query the Worker makes throws: a request answered 404 there provably never reached D1. `testEntry: true` runs the
 * test-only entry described above (the batch gate and forced public ids). `vars` overrides the
 * environment variables.
 */
export async function startWorker({ ogImageMode = "static", migrate = true, testEntry = false, vars = {} } = {}) {
  const siteverify = { answer: passing, calls: [] };
  // `codes` maps each authorization code Google issued to the `{sub, nonce}` its ID token carries (an
  // unknown code is refused as Google refuses one); `calls` records each request to the token
  // endpoint with its form body, redirect_uri included.
  const google = { codes: new Map(), calls: [] };
  // Sentry's envelope endpoint: answers `status`, and records each request with its headers and body.
  const sentry = { status: 200, calls: [] };
  // The Worker's clock offset (testEntry), so an ID token is fresh on the Worker's clock, and the
  // bucket's lifecycle counts days on it.
  let clockOffset = 0;
  const b2 = new FakeB2(() => Math.floor((Date.now() + clockOffset * 1000) / 1000));
  // What the Worker writes to its log (console), as text, and passed on to this process's own.
  const logs = [];
  const mf = new Miniflare({
    handleRuntimeStdio(stdout, stderr) {
      for (const [stream, out] of [[stdout, process.stdout], [stderr, process.stderr]]) {
        stream.on("data", (chunk) => {
          logs.push(String(chunk));
          out.write(chunk);
        });
      }
    },
    modules: modules(testEntry),
    modulesRoot: SRC,
    compatibilityDate: "2026-07-28",
    d1Databases: { DB: "share-test" },
    // Lets a test run the scheduled handler: GET /cdn-cgi/handler/scheduled.
    unsafeTriggerHandlers: true,
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
      SYNC_ENABLED: "true",
      SHARE_IMAGES_ENABLED: "true",
      B2_ENDPOINT: B2.ENDPOINT,
      B2_REGION: B2.REGION,
      B2_BUCKET: B2.BUCKET,
      B2_KEY_ID: B2.KEY_ID,
      B2_APPLICATION_KEY: B2.APPLICATION_KEY,
      REPORT_SENTRY_DSN: SENTRY.DSN,
      REPORT_SENTRY_ENVIRONMENT: SENTRY.ENVIRONMENT,
      ...vars,
    },
    // Every outbound fetch lands here. siteverify, Google's token endpoint, the B2 bucket and Sentry's
    // envelope endpoint are expected; anything else is a 599 the Worker would see as a failure.
    outboundService: async (request) => {
      const url = request.url;
      if (new URL(url).host === B2.ENDPOINT) return b2.handle(request);
      if (new URL(url).host === new URL(SENTRY.ENDPOINT).host) {
        sentry.calls.push({ url, headers: Object.fromEntries(request.headers), body: await request.text() });
        return new MfResponse(JSON.stringify({ id: "0".repeat(32) }), { status: sentry.status, headers: { "Content-Type": "application/json" } });
      }
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
  if (migrate) {
    await db.batch(migrationStatements().map((s) => db.prepare(s)));
    await appendTables(db, FIXTURE_TABLES);
  }
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
    /** Sentry's envelope endpoint, which reports are sent to: the status it answers and the requests it received. */
    sentry,
    /** The B2 bucket the Worker stores synced objects in (a FakeB2). */
    b2,
    /** Everything the Worker wrote to its log so far, joined. */
    logs: () => logs.join(""),

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
    /** PUT /api/shares/<id>/images with `bytes` as the body (its length as Content-Length) and the session `token`. */
    putImages: (token, id, bytes) =>
      fetch(`/api/shares/${id}/images`, {
        method: "PUT",
        headers: { "Content-Type": "application/octet-stream", "Content-Length": String(bytes.length), Authorization: `Bearer ${token}` },
        body: bytes,
      }),
    /** GET /api/shares/<id>/images, with no session. */
    getImages: (id) => fetch(`/api/shares/${id}/images`),
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
    /**
     * Makes the next D1 statement whose SQL contains `match` fail (needs `testEntry: true`): the
     * request running it stops there, with what it committed before.
     */
    async failD1At(match) {
      (await fetch("/__test/d1-fault", { method: "POST", body: JSON.stringify({ match }) })).body?.cancel();
    },
    /**
     * Cuts the next request that runs a D1 statement whose SQL contains `match` off there: that
     * statement and every D1 statement and batch after it fail, until `restoreD1()`.
     */
    async cutD1At(match) {
      (await fetch("/__test/d1-fault", { method: "POST", body: JSON.stringify({ match, cut: "before" }) })).body?.cancel();
    },
    /** As `cutD1At`, but the matching statement runs and commits first. */
    async cutD1After(match) {
      (await fetch("/__test/d1-fault", { method: "POST", body: JSON.stringify({ match, cut: "after" }) })).body?.cancel();
    },
    /**
     * Makes the next D1 statement whose SQL contains `match` run the statements `sql` (SQL strings,
     * one batch) just before it runs (needs `testEntry: true`).
     */
    async writeD1Before(match, sql) {
      (await fetch("/__test/d1-before", { method: "POST", body: JSON.stringify({ match, sql }) })).body?.cancel();
    },
    /** Ends what `cutD1At` or `cutD1After` started: D1 answers again. */
    async restoreD1() {
      (await fetch("/__test/d1-fault", { method: "POST", body: JSON.stringify({ match: null }) })).body?.cancel();
    },
    /**
     * Makes the database report `bytes` more than it holds to every statement the Worker runs from now
     * on (needs `testEntry: true`); 0 ends it.
     */
    async addToDatabaseSize(bytes) {
      (await fetch("/__test/d1-size", { method: "POST", body: JSON.stringify({ add: bytes }) })).body?.cancel();
    },
    /** The fault `failD1At` armed and no statement reached yet, or null. */
    async d1FaultLeft() {
      return (await fetch("/__test/d1-fault")).json();
    },
    /** Runs the scheduled handler once, as its cron trigger does; its outcome, "ok" when it finished. */
    async scheduled() {
      const res = await fetch("/cdn-cgi/handler/scheduled?format=json");
      return (await res.json()).outcome;
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

/** Bytes shaped as a JPEG for the server's checks: its start and end markers around `length - 4` bytes of `fill`. */
export function fakeJpeg(length, fill) {
  const bytes = new Uint8Array(length).fill(fill);
  bytes.set([0xff, 0xd8], 0);
  bytes.set([0xff, 0xd9], length - 2);
  return bytes;
}

/**
 * A share's images: `{images, bytes}`, the declaration a POST /api/shares carries and the bundle its PUT
 * sends. The parts' bytes differ with `seed`, so two bundles of different seeds have different names.
 * Without `trainee`, the bundle has the three screenshots alone.
 */
export function imageBundle({ seed = 1, trainee = true } = {}) {
  const box = (x) => ({ top_left: { x, y: 0 }, bottom_right: { x: x + 540, y: 960, anchor: { h: "ScreenStart", v: "ScreenStart" } } });
  const kinds = [
    ["skill", fakeJpeg(301, seed), box(0)],
    ["factor", fakeJpeg(203, seed + 1), box(10)],
    ["campaign", fakeJpeg(157, seed + 2), box(20)],
    ...(trainee ? [["trainee", fakeJpeg(41, seed + 3), null]] : []),
  ];
  const bytes = new Uint8Array(Buffer.concat(kinds.map(([, b]) => b)));
  const parts = kinds.map(([kind, b, intersection]) => ({
    kind,
    size: b.length,
    sha256: sha256(b),
    ...(intersection === null ? {} : { intersection }),
  }));
  return { images: { name: sha256(bytes), size: bytes.length, parts }, bytes };
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
