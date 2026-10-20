// The Backblaze B2 bucket through its S3-compatible API, signed with AWS Signature Version 4.
//
// Every object of an account lives under a/<account id>/<name>, where name is the SHA-256 of the
// object's bytes as 64 lowercase hex digits. A PUT signs that name as x-amz-content-sha256 and never
// UNSIGNED-PAYLOAD: B2 checks the bytes it receives against the signed hash and refuses a mismatch
// (403, the same answer as a wrong key) without storing anything, which is what keeps "name = SHA-256
// of the bytes" true for images the Worker streams through without reading. With UNSIGNED-PAYLOAD,
// B2 stores whatever arrives.
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

/** A B2 answer the Worker cannot act on: anything other than what the operation expects. */
export class StorageFailed extends Error {
  constructor(operation, status) {
    super(`B2 ${operation} answered ${status}`);
    this.status = status;
  }
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
   * Stores `body` (bytes or a stream of `length` bytes) at `key`, signed with `sha256` as its content
   * hash. Returns true when stored, false when B2 refused it with 403: the bytes did not hash to
   * `sha256`, or the key is wrong, which B2 does not tell apart. Throws StorageFailed otherwise.
   */
  async put(key, body, sha256, length) {
    const res = await this.#send({ method: "PUT", key, body, payloadHash: sha256, headers: { "content-length": length } });
    await res.body?.cancel();
    if (res.status === 200) return true;
    if (res.status === 403) return false;
    throw new StorageFailed("PUT", res.status);
  }

  /** The response of GET `key` when its latest version is an object, or null when there is none. */
  async get(key) {
    const res = await this.#send({ method: "GET", key, payloadHash: await sha256Hex("") });
    if (res.status === 200) return res;
    await res.body?.cancel();
    if (res.status === 404) return null;
    throw new StorageFailed("GET", res.status);
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
    const res = await this.#send({
      method: "POST",
      query: [["delete", ""]],
      body,
      payloadHash: await sha256Hex(body),
      headers: { "content-md5": md5, "content-type": "application/xml", "content-length": body.length },
    });
    const text = await res.text();
    if (res.status !== 200) throw new StorageFailed("DeleteObjects", res.status);
    return text;
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
    const res = await this.#send({ method: "GET", query, payloadHash: await sha256Hex("") });
    const text = await res.text();
    if (res.status !== 200) throw new StorageFailed("ListObjectVersions", res.status);
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
