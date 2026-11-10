// The Backblaze B2 bucket through its S3-compatible API, signed with AWS Signature Version 4.
//
// Every object of an account lives under a/<account id>/<name>, where name is the SHA-256 of the
// object's bytes as 64 lowercase hex digits; the image bundle of each of its shares under
// s/<account id>/<share id>/<name>, named the same way. A PUT signs that name as x-amz-content-sha256 and never
// UNSIGNED-PAYLOAD: B2 checks the bytes it receives against the signed hash and refuses a mismatch
// (403, the same answer as a wrong key) without storing anything, which is what keeps "name = SHA-256
// of the bytes" true for images the Worker passes on without hashing them. With UNSIGNED-PAYLOAD,
// B2 stores whatever arrives.
//
// A PUT or GET B2 answers 429 or 5xx is sent again, up to B2_ATTEMPTS times in all (`#ask`): both are
// idempotent, a PUT storing the same bytes under the same name. DeleteObjects and ListObjectVersions
// are sent once. Every answer B2 fails is logged, one line each, with B2's status and error code and
// nothing of the key, which names the account and the object.
//
// vars B2_ENDPOINT (a host name), B2_REGION and B2_BUCKET; secrets B2_KEY_ID and B2_APPLICATION_KEY.

import * as limits from "./limits.mjs";

const enc = new TextEncoder();

/** Objects one DeleteObjects names at most: B2 refuses 1,001 with 400 InvalidRequest. */
export const DELETE_OBJECTS_MAX = 1000;

/** The key of object `name` of account `accountId`. */
export const objectKey = (accountId, name) => `a/${accountId}/${name}`;

/** The key prefix every object of account `accountId` shares. */
export const accountPrefix = (accountId) => `a/${accountId}/`;

/**
 * The key prefix of space `space` of account `accountId`: "a" the account's synced objects
 * (`accountPrefix`), "s" the images of its shares (`sharePrefix`). The write ledger (sync_writes)
 * records the space of each write, and a name there is the key less this prefix.
 */
export const spacePrefix = (space, accountId) => {
  if (space !== "a" && space !== "s") throw new RangeError(`no space ${JSON.stringify(space)}`);
  return `${space}/${accountId}/`;
};

/**
 * The key prefix of the images of every share of account `accountId`. A share's bundle is at
 * `shareImageKey`, under the share's own prefix (`shareImagePrefix`), so unsharing one share lists and
 * deletes that share's versions alone, and deleting the account those of every share.
 */
export const sharePrefix = (accountId) => spacePrefix("s", accountId);

/** The key prefix of the images of share `shareId` of account `accountId`. */
export const shareImagePrefix = (accountId, shareId) => `${sharePrefix(accountId)}${shareId}/`;

/** The name of bundle `bundleName` of share `shareId` in the write ledger: its key less `sharePrefix`. */
export const shareImageName = (shareId, bundleName) => `${shareId}/${bundleName}`;

/** The key of bundle `bundleName` of share `shareId` of account `accountId`. */
export const shareImageKey = (accountId, shareId, bundleName) => `${sharePrefix(accountId)}${shareImageName(shareId, bundleName)}`;

/** A B2 answer the Worker cannot act on: anything other than what the operation expects. */
export class StorageFailed extends Error {
  constructor(operation, status) {
    super(`B2 ${operation} answered ${status}`);
    this.status = status;
  }
}

/**
 * Whether B2 answered `status` for a moment only: 429, or 500 to 599 (`503 SlowDown` among them), the
 * answers Backblaze's documentation asks a client to retry with exponential backoff.
 */
const transient = (status) => status === 429 || (status >= 500 && status <= 599);

/**
 * Seconds to wait after transient answer `attempt` (1 for the first) whose Retry-After header is
 * `retryAfter` (null when absent) before the next, or null when the Worker does not retry it: what it
 * asks in seconds or as a date on the Worker's clock `now` (ms), up to B2_RETRY_WAIT_MAX; without one,
 * or with one it cannot read, B2_RETRY_FIRST_WAIT doubled for every attempt before.
 */
function retryWait(retryAfter, attempt, now) {
  const backoff = limits.B2_RETRY_FIRST_WAIT * 2 ** (attempt - 1);
  if (retryAfter === null) return backoff;
  const asked = /^[0-9]+$/.test(retryAfter.trim()) ? Number(retryAfter) : (Date.parse(retryAfter) - now) / 1000;
  if (Number.isNaN(asked)) return backoff;
  return asked <= limits.B2_RETRY_WAIT_MAX ? Math.max(0, asked) : null;
}

/** B2's error code in the XML of a failed answer `text` when it has the form of one (letters only), else null. */
function errorCode(text) {
  const code = xmlField(text, "Code");
  return code !== null && /^[A-Za-z]{1,64}$/.test(code) ? code : null;
}

const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");

/** SHA-256 of `data` (a string, read as UTF-8, or bytes) as 64 lowercase hex digits. */
export async function sha256Hex(data) {
  return hex(await crypto.subtle.digest("SHA-256", typeof data === "string" ? enc.encode(data) : data));
}

async function hmac(key, message) {
  const k = await crypto.subtle.importKey("raw", typeof key === "string" ? enc.encode(key) : key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return crypto.subtle.sign("HMAC", k, enc.encode(message));
}

function uriEncode(text, keepSlash) {
  let out = "";
  for (const ch of text) {
    if (/[A-Za-z0-9\-_.~]/.test(ch) || (ch === "/" && keepSlash)) out += ch;
    else for (const b of enc.encode(ch)) out += `%${b.toString(16).toUpperCase().padStart(2, "0")}`;
  }
  return out;
}

const xmlEscape = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const xmlUnescape = (s) => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, "&");
const xmlField = (block, tag) => {
  const m = new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`).exec(block);
  return m === null ? null : xmlUnescape(m[1]);
};

/** The bucket of `env`, the target of every call below. */
export class Bucket {
  constructor(env, now = Date.now) {
    this.endpoint = `https://${env.B2_ENDPOINT}`;
    this.region = env.B2_REGION;
    this.bucket = env.B2_BUCKET;
    this.keyId = env.B2_KEY_ID;
    this.secret = env.B2_APPLICATION_KEY;
    this.now = now;
    /** Requests sent through this bucket so far. */
    this.sent = 0;
  }

  /**
   * Signs and sends one request; `payloadHash` is the hex SHA-256 of `body` (never UNSIGNED-PAYLOAD).
   * Past B2_REQUESTS_PER_INVOCATION it throws instead, as the platform would: every caller counts
   * what it asks before asking, so reaching this is a miscount.
   */
  async #send({ method, key = "", query = [], headers = {}, body, payloadHash }) {
    if (this.sent >= limits.B2_REQUESTS_PER_INVOCATION) {
      throw new Error(`more than ${limits.B2_REQUESTS_PER_INVOCATION} B2 requests in one invocation`);
    }
    this.sent++;
    const url = new URL(this.endpoint);
    const path = `/${this.bucket}${key === "" ? "" : `/${uriEncode(key, true)}`}`;
    const amzDate = new Date(this.now()).toISOString().replace(/[:-]|\.\d{3}/g, "");
    const date = amzDate.slice(0, 8);
    const h = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k.toLowerCase(), String(v).trim()]));
    h.host = url.host;
    h["x-amz-date"] = amzDate;
    h["x-amz-content-sha256"] = payloadHash;
    const signed = Object.keys(h).sort();
    const canonQuery = query
      .map(([k, v]) => [uriEncode(k, false), uriEncode(v, false)])
      .sort((a, b) => (a[0] === b[0] ? (a[1] < b[1] ? -1 : 1) : a[0] < b[0] ? -1 : 1))
      .map(([k, v]) => `${k}=${v}`)
      .join("&");
    const canonical = [method, path, canonQuery, signed.map((k) => `${k}:${h[k]}\n`).join(""), signed.join(";"), payloadHash].join("\n");
    const scope = `${date}/${this.region}/s3/aws4_request`;
    const toSign = ["AWS4-HMAC-SHA256", amzDate, scope, await sha256Hex(canonical)].join("\n");
    let k = await hmac(`AWS4${this.secret}`, date);
    for (const part of [this.region, "s3", "aws4_request"]) k = await hmac(k, part);
    h.authorization = `AWS4-HMAC-SHA256 Credential=${this.keyId}/${scope}, SignedHeaders=${signed.join(";")}, Signature=${hex(await hmac(k, toSign))}`;
    delete h.host;
    return fetch(`${url.origin}${path}${canonQuery === "" ? "" : `?${canonQuery}`}`, { method, headers: h, body });
  }

  /**
   * Sends `request` (see #send) for operation `operation` and returns B2's response once it answers 200,
   * a refusal the caller acts on (`refused`) or an answer that the object is not there (`absent`). A
   * transient answer is sent again after `retryWait`, up to `attempts` times in all; any other answer,
   * or the last transient one, throws StorageFailed. Every answer but 200 and `absent` is logged, one
   * line each. A response returned with a status other than 200 has had its body read, or lost while it arrived.
   */
  async #ask(operation, request, { refused = [], absent = [], attempts = 1 } = {}) {
    for (let attempt = 1; ; attempt++) {
      const res = await this.#send(request);
      if (res.status === 200) return res;
      // The error only names B2's code for the log; a connection lost while it arrives leaves the status to act on.
      const text = await res.text().catch(() => null);
      if (absent.includes(res.status)) return res;
      const retryAfter = res.headers.get("Retry-After");
      const wait = transient(res.status) && attempt < attempts ? retryWait(retryAfter, attempt, this.now()) : null;
      const code = text === null ? null : errorCode(text);
      console.warn(
        `B2 ${operation} answered ${res.status}${text === null ? " (error unread)" : code === null ? "" : ` ${code}`}` +
          `${retryAfter === null ? "" : ` (Retry-After ${JSON.stringify(retryAfter.slice(0, 64))})`}` +
          `, attempt ${attempt} of ${attempts}${wait === null ? "" : `, retrying in ${wait} s`}`,
      );
      if (refused.includes(res.status)) return res;
      if (wait === null) throw new StorageFailed(operation, res.status);
      await new Promise((resolve) => setTimeout(resolve, wait * 1000));
    }
  }

  /**
   * Stores bytes `body` at `key`, signed with `sha256` as their content hash, retrying a transient
   * failure (B2_ATTEMPTS). Returns true when stored, false when B2 refused it with 403: the bytes did
   * not hash to `sha256`, or the key is wrong, which B2 does not tell apart. Throws StorageFailed
   * otherwise.
   */
  async put(key, body, sha256) {
    const request = { method: "PUT", key, body, payloadHash: sha256, headers: { "content-length": body.length } };
    const res = await this.#ask("PUT", request, { refused: [403], attempts: limits.B2_ATTEMPTS });
    if (res.status === 403) return false;
    await res.body?.cancel();
    return true;
  }

  /**
   * The response of GET `key` when its latest version is an object, or null when there is none,
   * retrying a transient failure (B2_ATTEMPTS).
   */
  async get(key) {
    const res = await this.#ask("GET", { method: "GET", key, payloadHash: await sha256Hex("") }, { absent: [404], attempts: limits.B2_ATTEMPTS });
    return res.status === 404 ? null : res;
  }

  /**
   * Hides `keys` (at most DELETE_OBJECTS_MAX) with one DeleteObjects naming no version, which adds a
   * delete marker over each. Returns key → the version id of its marker, for every key B2 reported
   * deleted with one; a key it reported as an error, or without a marker's version id, is absent.
   */
  async hideObjects(keys) {
    const text = await this.#deleteObjects(keys.map((key) => ({ key })), false);
    const markers = new Map();
    for (const [, block] of text.matchAll(/<Deleted>([\s\S]*?)<\/Deleted>/g)) {
      const marker = xmlField(block, "DeleteMarkerVersionId");
      if (marker !== null) markers.set(xmlField(block, "Key"), marker);
    }
    return markers;
  }

  /**
   * Deletes `targets` (`{key, versionId}`, at most DELETE_OBJECTS_MAX) for good with one DeleteObjects;
   * deleting a delete marker shows the version under it again. Returns the targets B2 reported as errors.
   */
  async deleteObjects(targets) {
    const text = await this.#deleteObjects(targets, true);
    return [...text.matchAll(/<Error>([\s\S]*?)<\/Error>/g)].map(([, e]) => ({ key: xmlField(e, "Key"), code: xmlField(e, "Code") }));
  }

  /** One DeleteObjects over `targets` (`{key, versionId?}`); the response's text. */
  async #deleteObjects(targets, quiet) {
    if (targets.length > DELETE_OBJECTS_MAX) throw new RangeError(`DeleteObjects takes at most ${DELETE_OBJECTS_MAX} objects`);
    const objects = targets.map(({ key, versionId }) =>
      `<Object><Key>${xmlEscape(key)}</Key>${versionId === undefined ? "" : `<VersionId>${xmlEscape(versionId)}</VersionId>`}</Object>`,
    );
    const body = enc.encode(`<?xml version="1.0" encoding="UTF-8"?><Delete><Quiet>${quiet}</Quiet>${objects.join("")}</Delete>`);
    const md5 = btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.digest("MD5", body))));
    const res = await this.#ask("DeleteObjects", {
      method: "POST",
      query: [["delete", ""]],
      body,
      payloadHash: await sha256Hex(body),
      headers: { "content-md5": md5, "content-type": "application/xml", "content-length": body.length },
    });
    return res.text();
  }

  /**
   * One page of ListObjectVersions under `prefix`, in key order: `{entries, next}`, entries `{key,
   * versionId, marker, latest, modified}` (marker: a delete marker; modified: when B2 added it, in
   * seconds since the epoch on B2's clock), next the `{keyMarker, versionIdMarker}` of
   * the following page or null. The page begins after `from`: after its version `versionIdMarker` of
   * key `keyMarker`, or, with `versionIdMarker` null, after every version of every key up to
   * `keyMarker`, which need not exist. A truncated page may end inside the versions of its last key.
   */
  async listVersions(prefix, from = null) {
    const query = [["versions", ""], ["prefix", prefix]];
    if (from !== null) query.push(["key-marker", from.keyMarker]);
    if (from !== null && from.versionIdMarker !== null) query.push(["version-id-marker", from.versionIdMarker]);
    const res = await this.#ask("ListObjectVersions", { method: "GET", query, payloadHash: await sha256Hex("") });
    const text = await res.text();
    const entries = [...text.matchAll(/<(Version|DeleteMarker)>([\s\S]*?)<\/\1>/g)].map(([, kind, block]) => ({
      key: xmlField(block, "Key"),
      versionId: xmlField(block, "VersionId"),
      marker: kind === "DeleteMarker",
      latest: xmlField(block, "IsLatest") === "true",
      modified: Math.floor(Date.parse(xmlField(block, "LastModified")) / 1000),
    }));
    const truncated = xmlField(text, "IsTruncated") === "true";
    return {
      entries,
      next: truncated ? { keyMarker: xmlField(text, "NextKeyMarker"), versionIdMarker: xmlField(text, "NextVersionIdMarker") } : null,
    };
  }
}
