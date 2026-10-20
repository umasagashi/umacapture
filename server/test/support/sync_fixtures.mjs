// What the sync tests build and send: bodies, images, record parts and roots in the wire format of
// docs/sync-protocol.md, and a client of the sync endpoints for one session.

import { createHash, randomBytes } from "node:crypto";

export const sha256 = (data) => createHash("sha256").update(data).digest("hex");
export const PARTS = 128;

/** The record part of id `id`, as the protocol defines it. */
export const partOf = (id) => createHash("sha256").update(id, "utf8").digest().readUInt16BE(0) % PARTS;

/** A fresh record id falling in part `n`. */
export function idIn(n) {
  for (;;) {
    const id = randomBytes(8).toString("hex");
    if (partOf(id) === n) return id;
  }
}

/** A body text carrying image binding `binding`, as `{name, body}`. */
export function bodyOf(binding) {
  const body = JSON.stringify({ metadata: { binding }, nonce: randomBytes(8).toString("hex") });
  return { name: sha256(Buffer.from(body, "utf8")), body };
}

/**
 * A fresh record in part `n` (archive state `state`, image binding `binding`, by default two fresh
 * PNG names): its body (`{name, body}`) and its list row.
 */
export function newRecord(n, { state = "normal", binding } = {}) {
  const image = binding ?? { skill_png: sha256(randomBytes(8)), skill_jpeg: null, factor_png: sha256(randomBytes(8)) };
  const body = bodyOf(image);
  const row = { id: idIn(n), body: { name: body.name, written_at: 1 }, archive: { state, written_at: 1 }, image, ratings: {} };
  return { body, row };
}

/** `row` with archive state `state`. */
export const archived = (row, state) => ({ ...row, archive: { state, written_at: 2 } });

/** A part text and its name. */
export function part(value) {
  const text = JSON.stringify({ format: 1, ...value });
  return { name: sha256(Buffer.from(text, "utf8")), text };
}
export const recordPart = (n, rows) => part({ part: n, records: rows });

/** A root text naming `parts` (slot → part name), and its name. */
export function root(parts) {
  const text = JSON.stringify({ format: 1, parts });
  return { name: sha256(Buffer.from(text, "utf8")), text };
}

/** Fresh image bytes and their name. */
export function newImage() {
  const bytes = randomBytes(256);
  return { name: sha256(bytes), bytes };
}

/** Status and parsed body of one response (null for a body that is not JSON). */
export async function answer(resPromise) {
  const res = await resPromise;
  const text = await res.text();
  const body = res.headers.get("content-type")?.startsWith("application/json") ? JSON.parse(text) : null;
  return { status: res.status, body, text, headers: res.headers };
}

/** Requests of the sync endpoints with the session `token` (none when null). */
export function syncClient(worker, token) {
  const auth = token === null ? {} : { Authorization: `Bearer ${token}` };
  const post = (path, value) =>
    answer(worker.fetch(path, { method: "POST", headers: { "Content-Type": "application/json", ...auth }, body: JSON.stringify(value) }));
  return {
    generation: () => answer(worker.fetch("/api/sync/generation", { headers: auth })),
    settings: () => answer(worker.fetch("/api/sync/settings", { headers: auth })),
    setImageForm: (form) =>
      answer(
        worker.fetch("/api/sync/settings", {
          method: "PUT",
          headers: { "Content-Type": "application/json", ...auth },
          body: JSON.stringify({ image_form: form }),
        }),
      ),
    putBodies: (bodies) => post("/api/sync/bodies", { bodies }),
    getBodies: (names) => post("/api/sync/bodies/get", { names }),
    held: (names) => post("/api/sync/held", { names }),
    putImage: (name, bytes, type = "image/png") =>
      answer(
        worker.fetch(`/api/sync/images/${name}`, {
          method: "PUT",
          headers: { "Content-Type": type, "Content-Length": String(bytes.length), ...auth },
          body: bytes,
        }),
      ),
    getImage: async (name) => {
      const res = await worker.fetch(`/api/sync/images/${name}`, { headers: auth });
      return { status: res.status, type: res.headers.get("content-type"), bytes: Buffer.from(await res.arrayBuffer()) };
    },
    putPart: ({ name, text }) => post("/api/sync/parts", { name, part: text }),
    replace: (generation, { name, text }) => post("/api/sync/root", { generation, name, root: text }),
    getPart: (name) => answer(worker.fetch(`/api/sync/parts/${name}`, { headers: auth })),
    getRoot: (name) => answer(worker.fetch(`/api/sync/roots/${name}`, { headers: auth })),
  };
}
