// The images of a shared record. A sharer who chooses to share them declares, with the share
// (POST /api/shares), one bundle: the record's reduced JPEGs joined in the order of PART_KINDS, named by
// the SHA-256 of its bytes, each part listed with its size, its SHA-256 and, for the screenshots, the
// geometry the app shows it with. The share's row holds the declaration (migrations/0009), so the
// images live and go with the share. The sharer's app then puts the bundle
// (PUT /api/shares/<id>/images), which is checked against the declaration and stored in B2 under
// s/<account id>/<share id>/<bundle name>; the import endpoint (GET /api/shares/<id>) lists the parts
// and the bundle's GET (GET /api/shares/<id>/images) serves the bytes, both without a session. Nothing
// else serves them: the public page, its card, the public JSON and the account's list do not.
//
// A put writes to B2 only after recording the write in the write ledger (sync_writes, space "s"), and
// the batch that records the bundle as stored clears the record while the account is not being
// deleted. Unsharing records the bundle's removal in the same ledger in the batch that removes the row,
// then deletes the share's versions. So whatever order a put, an unshare and an account deletion meet
// in, a version no share accounts for has a record, and the hourly run (`share_writes` in
// scheduled.mjs) deletes it once the record is old enough that its request is abandoned.
//
// vars SHARE_IMAGES_ENABLED (`shareImagesEnabled` in api.mjs) stops images coming in and going out.

import { clock, envelope, fail, json, sharingEnabled, shareImagesEnabled } from "./api.mjs";
import { requireSession } from "./auth.mjs";
import { Bucket, sha256Hex, shareImageKey, shareImageName, shareImagePrefix, StorageFailed } from "./b2.mjs";
import * as limits from "./limits.mjs";
import { InvalidPayload } from "./posted_form.mjs";
import { readShareImages, Unavailable, withdrawShareImages } from "./store.mjs";
import { d1 } from "./sync.mjs";
import { writingIn } from "./sync_refs.mjs";

/** A SHA-256 as 64 lowercase hex digits: a bundle's name, and a part's `sha256`. */
const SHA256 = /^[0-9a-f]{64}$/;

/**
 * The parts of a bundle, in the order they are joined: the three screenshots, each with the geometry
 * (`intersection`) the app shows it with, and the trainee's portrait, which a record may lack and which
 * has no geometry.
 */
const PART_KINDS = ["skill", "factor", "campaign", "trainee"];
const OPTIONAL_KINDS = ["trainee"];
const GEOMETRY_KINDS = ["skill", "factor", "campaign"];

/** A coordinate of an `intersection`, in the JPEG's pixels: a JPEG's side is 65,535 pixels at most. */
const MAX_COORDINATE = 65_535;

/** A layout anchor of an `intersection` point, as the app's geometry files name one: a word. */
const ANCHOR = /^[A-Za-z]{1,32}$/;

/** What `check` returns, an InvalidPayload it throws named under `field` (its "body" as `field` itself). */
function within(field, check) {
  try {
    return check();
  } catch (error) {
    if (error instanceof InvalidPayload) throw new InvalidPayload(error.field === "body" ? field : `${field}.${error.field}`);
    throw error;
  }
}

/** Point `value` of an intersection, rebuilt from its checked fields. */
function point(value, field) {
  const { x, y, anchor } = within(field, () => envelope(value, ["x", "y"], ["anchor"]));
  for (const [key, v] of [["x", x], ["y", y]]) {
    if (!Number.isSafeInteger(v) || v < 0 || v > MAX_COORDINATE) throw new InvalidPayload(`${field}.${key}`);
  }
  if (anchor === undefined) return { x, y };
  const { h, v } = within(`${field}.anchor`, () => envelope(anchor, ["h", "v"]));
  if (typeof h !== "string" || !ANCHOR.test(h)) throw new InvalidPayload(`${field}.anchor.h`);
  if (typeof v !== "string" || !ANCHOR.test(v)) throw new InvalidPayload(`${field}.anchor.v`);
  return { x, y, anchor: { h, v } };
}

/** Part `value` of a declaration at `index` (its kind PART_KINDS[index]), rebuilt from its checked fields. */
function part(value, index, field) {
  const kind = PART_KINDS[index];
  const geometry = GEOMETRY_KINDS.includes(kind);
  const checked = within(field, () => envelope(value, ["kind", "size", "sha256", ...(geometry ? ["intersection"] : [])]));
  if (checked.kind !== kind) throw new InvalidPayload(`${field}.kind`);
  // Four bytes at least: a JPEG's start and end markers.
  if (!Number.isSafeInteger(checked.size) || checked.size < 4 || checked.size > limits.MAX_SHARE_IMAGE_PART) {
    throw new InvalidPayload(`${field}.size`);
  }
  if (typeof checked.sha256 !== "string" || !SHA256.test(checked.sha256)) throw new InvalidPayload(`${field}.sha256`);
  const out = { kind, size: checked.size, sha256: checked.sha256 };
  if (!geometry) return out;
  const box = within(`${field}.intersection`, () => envelope(checked.intersection, ["top_left", "bottom_right"]));
  out.intersection = {
    top_left: point(box.top_left, `${field}.intersection.top_left`),
    bottom_right: point(box.bottom_right, `${field}.intersection.bottom_right`),
  };
  return out;
}

/**
 * The declaration `value` of a share's `images` (`{name, size, parts}`) checked and rebuilt from its
 * checked fields, as `{name, size, parts}` with `parts` the JSON the share's row stores, or null when the
 * share declares none. `size` is the sum of the parts', within MAX_SHARE_IMAGE_BUNDLE. The bundle's
 * name cannot be checked until its bytes arrive (`putShareImages`). Throws InvalidPayload naming the
 * field under `images`.
 */
export function declaration(value) {
  if (value === undefined || value === null) return null;
  const { name, size, parts } = within("images", () => envelope(value, ["name", "size", "parts"]));
  if (typeof name !== "string" || !SHA256.test(name)) throw new InvalidPayload("images.name");
  const required = PART_KINDS.length - OPTIONAL_KINDS.length;
  if (!Array.isArray(parts) || parts.length < required || parts.length > PART_KINDS.length) throw new InvalidPayload("images.parts");
  const checked = parts.map((p, i) => part(p, i, `images.parts[${i}]`));
  const total = checked.reduce((sum, p) => sum + p.size, 0);
  if (size !== total || total > limits.MAX_SHARE_IMAGE_BUNDLE) throw new InvalidPayload("images.size");
  return { name, size, parts: JSON.stringify(checked) };
}

/**
 * What the import endpoint answers for `images` (a share's declared images from `readRecord`, or null):
 * null for a share that declares none, which it never does later; `{state: "unavailable"}` while the
 * image switch is off; `{state: "pending"}` until the bundle is stored; and once it is, `{state:
 * "stored", name, size, parts}`, the parts in the bundle's order.
 */
export function importedImages(env, images) {
  if (images === null) return null;
  if (!shareImagesEnabled(env)) return { state: "unavailable" };
  if (images.state !== "stored") return { state: "pending" };
  return { state: "stored", name: images.name, size: images.size, parts: images.parts };
}

/** Answers `response` once the request's body, which it does not read, is let go. */
async function unread(request, response) {
  await request.body?.cancel();
  return response;
}

/**
 * The first part of `parts` that bundle `bytes` (their sizes' sum long) does not hold as declared: its
 * index, or -1 when every part has its declared SHA-256 and the markers a JPEG starts and ends with.
 */
async function firstMismatch(bytes, parts) {
  let offset = 0;
  for (const [i, p] of parts.entries()) {
    const slice = bytes.subarray(offset, offset + p.size);
    offset += p.size;
    const jpeg = slice[0] === 0xff && slice[1] === 0xd8 && slice[p.size - 2] === 0xff && slice[p.size - 1] === 0xd9;
    if (!jpeg || (await sha256Hex(slice)) !== p.sha256) return i;
  }
  return -1;
}

/**
 * PUT /api/shares/<id>/images with the bundle's bytes as the body and a Content-Length of the declared
 * size: stores the bundle of a share the session's account holds and declared images for. 200
 * `{status}`, "stored", or "exists" when the share's bundle was stored already, without reading the body.
 * 404 not_found when no such share is left (unshared meanwhile included), 403 forbidden when another
 * account holds it, 409 no_images_declared when it declares no images. 400 invalid_payload when the
 * bytes are not the declared ones: `field` "content-length" for their length, `parts[i]` for the first
 * part whose SHA-256 or JPEG markers differ, "name" when the whole is not the declared name. 503
 * sharing_paused or image_sharing_paused while a switch is off. 502 storage_unavailable when B2 failed
 * and storage_refused when it refused the key, which a later put may retry.
 */
export async function putShareImages(request, env, id, now) {
  if (!sharingEnabled(env)) return unread(request, fail(503, "sharing_paused"));
  if (!shareImagesEnabled(env)) return unread(request, fail(503, "image_sharing_paused"));
  const at = clock(now);
  let session;
  try {
    session = await requireSession(request, env, at.now);
  } catch (error) {
    await request.body?.cancel();
    throw error;
  }
  const share = await readShareImages(env.DB, id);
  if (share === null) return unread(request, fail(404, "not_found"));
  if (share.owner !== session.accountId) return unread(request, fail(403, "forbidden"));
  const { images } = share;
  if (images === null) return unread(request, fail(409, "no_images_declared"));
  if (images.state === "stored") return unread(request, json(200, { status: "exists" }));
  if (Number(request.headers.get("Content-Length")) !== images.size) {
    return unread(request, fail(400, "invalid_payload", { field: "content-length" }));
  }
  // Read whole, so that a PUT B2 fails for a moment can send the bytes again (`Bucket.put`).
  const bytes = new Uint8Array(await request.arrayBuffer());
  if (bytes.length !== images.size) return fail(400, "invalid_payload", { field: "content-length" });
  const mismatch = await firstMismatch(bytes, images.parts);
  if (mismatch !== -1) return fail(400, "invalid_payload", { field: `parts[${mismatch}]` });
  if ((await sha256Hex(bytes)) !== images.name) return fail(400, "invalid_payload", { field: "name" });

  const db = env.DB;
  const owner = session.accountId;
  const by = crypto.randomUUID();
  await d1(() => writingIn(db, "s", owner, by, [shareImageName(id, images.name)], at.now).run());
  let stored;
  try {
    stored = await new Bucket(env, now).put(shareImageKey(owner, id, images.name), bytes, images.name);
  } catch (error) {
    // B2 may have stored it: the record stays, for the hourly run to take if no put records it stored.
    if (error instanceof StorageFailed) return fail(502, "storage_unavailable");
    throw error;
  }
  // B2 refused the key on the last attempt, but an earlier attempt it answered 429 or 5xx may have
  // stored it: the record stays, for the hourly run to take if no put records it stored.
  if (!stored) return fail(502, "storage_refused");
  const bundle = "id = ?1 AND owner_id = ?2 AND images_name = ?3";
  const [, , row] = await d1(() =>
    db.batch([
      db.prepare(`UPDATE records SET images_stored_at = ?4 WHERE ${bundle} AND images_stored_at IS NULL`).bind(id, owner, images.name, at.now),
      // The record is cleared only once a row accounts for what this put wrote, and never while the
      // account is being deleted, whose deletion may already have listed the prefix.
      db
        .prepare(
          `DELETE FROM sync_writes WHERE account_id = ?2 AND write_by = ?4 AND space = 's'
             AND EXISTS (SELECT 1 FROM accounts WHERE id = ?2 AND deleting_since IS NULL)
             AND EXISTS (SELECT 1 FROM records WHERE ${bundle} AND images_stored_at IS NOT NULL)`,
        )
        .bind(id, owner, images.name, by),
      db.prepare(`SELECT images_stored_at FROM records WHERE ${bundle}`).bind(id, owner, images.name),
    ]),
  );
  // Unshared while it was putting: what it wrote is left to the hourly run, under its record.
  if (row.results.length === 0) return fail(404, "not_found");
  return json(200, { status: "stored" });
}

/**
 * GET /api/shares/<id>/images, with no session: the bytes the share's bundle was stored with, while the
 * share records it stored and the image switch is on; 404 not_found otherwise. They are served as a
 * download, never as a page or an image, and not cached anywhere, so they go the moment the share does.
 * 502 storage_unavailable when B2 failed.
 */
export async function getShareImages(env, id, now) {
  if (!shareImagesEnabled(env)) return fail(404, "not_found");
  const share = await readShareImages(env.DB, id);
  if (share === null || share.images === null || share.images.state !== "stored") return fail(404, "not_found");
  let res;
  try {
    res = await new Bucket(env, now).get(shareImageKey(share.owner, id, share.images.name));
  } catch (error) {
    if (error instanceof StorageFailed) return fail(502, "storage_unavailable");
    throw error;
  }
  if (res === null) return fail(404, "not_found");
  return new Response(res.body, {
    headers: {
      "Content-Type": "application/octet-stream",
      "Content-Disposition": "attachment",
      "X-Content-Type-Options": "nosniff",
      "Cross-Origin-Resource-Policy": "same-origin",
      "Cache-Control": "no-store",
      "X-Robots-Tag": "noindex",
    },
  });
}

/** The B2 requests `removeBundle` sends at most: one listing and one deletion. */
export const REMOVE_BUNDLE_B2_REQUESTS = 2;

/**
 * After request `by` unshared share `id` of account `owner`, or withdrew its images, whose batch recorded
 * the removal of its bundle in the write ledger: deletes every version under the share's prefix, by
 * version, through `bucket`, and clears the record once B2 listed them all and deleted every one. A
 * failure leaves the record for the hourly run and fails nothing the batch did. A version a put adds
 * after the listing is that put's to record.
 */
export async function removeBundle(env, bucket, owner, id, by) {
  try {
    const { entries, next } = await bucket.listVersions(shareImagePrefix(owner, id));
    const errors = entries.length === 0 ? [] : await bucket.deleteObjects(entries.map((e) => ({ key: e.key, versionId: e.versionId })));
    if (errors.length > 0 || next !== null) return;
    await d1(() =>
      env.DB.prepare("DELETE FROM sync_writes WHERE account_id = ?1 AND write_by = ?2 AND space = 's'").bind(owner, by).run(),
    );
  } catch (error) {
    if (!(error instanceof StorageFailed || error instanceof Unavailable)) throw error;
  }
}

/**
 * Withdraws the images of share `id` of account `owner` at clock `now` (`withdrawShareImages`) and
 * deletes its bundle through `bucket` (`removeBundle`): from the commit the import endpoint answers
 * `images: null` and the bundle's GET 404, and what B2 fails to delete is left to the hourly run.
 * Returns whether it withdrew them. Throws Unavailable when D1 fails before the commit.
 */
export async function withdrawImages(env, bucket, id, owner, now) {
  const by = crypto.randomUUID();
  const name = await withdrawShareImages(env.DB, id, owner, by, clock(now).now);
  if (name === null) return false;
  await removeBundle(env, bucket, owner, id, by);
  return true;
}
