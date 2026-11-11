// The text a sharer writes for readers: a share's tagline, and the account's public profile (trainer
// name and the game's trainer id). The server is the only guard: what is stored is rebuilt from the
// checked value, never the posted string as it came.

import { fail, untilTomorrow } from "./api.mjs";
import * as limits from "./limits.mjs";
import { InvalidPayload } from "./posted_form.mjs";

/**
 * Characters refused anywhere in a text once its ends are trimmed: control characters (C0 and C1, line
 * breaks and tabs among them), the line and paragraph separators, the bidirectional controls, the
 * invisible zero-width space, word joiner and byte order mark, private use characters and
 * noncharacters. The zero-width joiner and the variation selectors pass: emoji are made with them.
 */
const REFUSED =
  /[\p{Cc}\u2028\u2029\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069\u200B\u2060\uFEFF\p{Co}\p{Noncharacter_Code_Point}]/u;

/**
 * `value` checked as a sharer's text named `field`: null (not written, or nothing left once trimmed)
 * or the canonical string, NFC with its ends trimmed. Anything but a string or null, a string with an
 * unpaired surrogate, one holding a REFUSED character, and one longer than `maxCodePoints` code points
 * is InvalidPayload(field).
 */
export function canonicalText(value, field, maxCodePoints) {
  if (value === null) return null;
  if (typeof value !== "string" || !value.isWellFormed()) throw new InvalidPayload(field);
  const text = value.normalize("NFC").trim();
  if (text === "") return null;
  if (REFUSED.test(text) || [...text].length > maxCodePoints) throw new InvalidPayload(field);
  return text;
}

// The separators a trainer id may be written with, as the game groups its digits: spaces (the
// ideographic one included), hyphens and commas.
const ID_SEPARATORS = /[ \u3000,-]/g;
const GAME_TRAINER_ID = /^(?:\d{9}|\d{12})$/;

/**
 * `value` checked as the game's trainer id: null, or its digits alone, 9 or 12 of them, once the
 * separators the game groups them with are removed. Anything else is InvalidPayload(field).
 */
export function canonicalGameTrainerId(value, field) {
  const text = canonicalText(value, field, 32);
  if (text === null) return null;
  const digits = text.replace(ID_SEPARATORS, "");
  if (!GAME_TRAINER_ID.test(digits)) throw new InvalidPayload(field);
  return digits;
}

/** The game's trainer id as it is shown: its digits grouped by three from the left, "123 456 789". */
export function groupedGameTrainerId(digits) {
  return digits.replace(/(\d{3})(?=\d)/g, "$1 ");
}

/**
 * The sharer of a public page, as public JSON v1 carries it: `{trainer_name, game_trainer_id}` of the
 * account's profile, or null when neither is written.
 */
export function publicSharer(trainerName, gameTrainerId) {
  if (trainerName === null && gameTrainerId === null) return null;
  return { trainer_name: trainerName, game_trainer_id: gameTrainerId };
}

/**
 * The text-write limits (ACCOUNT_TEXT_WRITES_PER_DAY, TEXT_WRITES_PER_DAY) on the UTC day of `at`
 * (`clock`), as `writeProfile` and `writeTagline` in store.mjs take them.
 */
export const textWriteQuota = (at) => ({
  day: at.day,
  accountLimit: limits.ACCOUNT_TEXT_WRITES_PER_DAY,
  dailyLimit: limits.TEXT_WRITES_PER_DAY,
});

/**
 * The refusal of a text write past a daily limit: 429 daily_limit `{scope}` ("account" or "service"),
 * with a Retry-After to the next UTC day, as sync's daily limits answer.
 */
export const textWriteRefused = (scope, at) =>
  fail(429, "daily_limit", { scope }, { "Retry-After": String(untilTomorrow(at)) });
