// Reporting a share to the operator: the report page /r/<id>/report and its form's POST /api/reports.
//
// The share page /r/<id> stays without a script; it only links here. This page carries Turnstile, as
// the login start page does, and posts a top-level form whose answer is a page. An accepted report is
// sent to Sentry as one event and nothing of it is kept in D1 but the day's count. The reporter's name,
// contact, account, IP and browser are neither asked for nor sent: there is no reply to a report.

import { TooLarge, clock, isTurnstileToken, readText } from "./api.mjs";
import * as limits from "./limits.mjs";
import { TURNSTILE_ORIGIN } from "./login_page.mjs";
import { PAGE_CSP, esc, renderNotFoundPage, siteHeader } from "./page.mjs";
import { InvalidPayload } from "./posted_form.mjs";
import { dayToIso } from "./public_record.mjs";
import { countReport, readSharedDay, Unavailable } from "./store.mjs";
import { verifyTurnstile } from "./turnstile.mjs";

/** The Turnstile action of the report page; siteverify must report it. Not a var: no environment changes it. */
export const REPORT_ACTION = "report";

/** The reasons a report gives, in the order the page lists them. The key is what Sentry receives. */
export const REPORT_REASONS = {
  own_trainer: "自分の育成が、ほかの人に共有されている",
  personal_info: "画像に名前などの個人の情報が写っている",
  inappropriate: "不適切な内容",
  other: "その他",
};

const ID = /^[0-9a-hjkmnp-tv-z]{10}$/;
const FORM = "application/x-www-form-urlencoded";
const FIELDS = ["id", "reason", "text", "token"];
const KIND = "問題を報告";
const CONTACT = `<a href="/privacy/">プライバシーポリシー</a>の連絡先からご連絡ください。`;

/** The answers of the report's POST (and of the page while reports are off), by outcome. */
const OUTCOMES = {
  accepted: [200, "報告を受け付けました。"],
  invalid: [400, "報告の内容を確かめられませんでした。報告のページからやり直してください。"],
  unverified: [403, "確認できませんでした。もう一度お試しください。"],
  limit: [429, `今日の受け付けの上限に達しました。${CONTACT}`],
  unsent: [502, `送れませんでした。時間をおいてお試しいただくか、${CONTACT}`],
  unavailable: [503, `送れませんでした。時間をおいてお試しいただくか、${CONTACT}`],
  off: [503, `今は受け付けていません。${CONTACT}`],
};

/**
 * `vars.REPORT_SENTRY_DSN` read as Sentry's envelope endpoint and key, or null when it is empty, which
 * is how an environment declares that it takes no reports. A value that is not a DSN is a
 * configuration error.
 */
function reportSink(env) {
  const dsn = env.REPORT_SENTRY_DSN ?? "";
  if (dsn === "") return null;
  const url = new URL(dsn);
  const project = url.pathname.replace(/^\//, "");
  if (url.username === "" || !/^\d+$/.test(project)) throw new Error(`REPORT_SENTRY_DSN is not a DSN: ${JSON.stringify(dsn)}`);
  return { dsn, key: url.username, endpoint: `${url.protocol}//${url.host}/api/${project}/envelope/` };
}

const PAGE_HEAD = `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${KIND} | umacapture</title>
<link rel="stylesheet" href="/site/site.css">
<link rel="icon" type="image/png" href="/favicon.png">
</head>`;

const page = (content) => `${PAGE_HEAD}
<body>
${siteHeader(KIND)}
<main class="site-doc">
<h1>${KIND}</h1>
${content}
</main>
</body>
</html>
`;

const notFound = () =>
  new Response(renderNotFoundPage(KIND), {
    status: 404,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy": PAGE_CSP,
      "Cache-Control": "no-store",
      "X-Robots-Tag": "noindex",
    },
  });

/** An outcome of OUTCOMES as a page without a script. no-referrer: the report's URL is passed on nowhere. */
function outcomePage(outcome, headers = {}) {
  const [status, message] = OUTCOMES[outcome];
  return new Response(page(`<p data-outcome="${outcome}">${message}</p>`), {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy": PAGE_CSP,
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
      "X-Robots-Tag": "noindex",
      ...headers,
    },
  });
}

/**
 * GET /r/<id>/report: the form, for a share that exists. Its Referrer-Policy is same-origin for the
 * reason the login start page's is: under no-referrer the form's POST carries `Origin: null`, which
 * the POST refuses.
 */
export async function reportPage(env, id) {
  let sharedDay;
  try {
    sharedDay = await readSharedDay(env.DB, id);
  } catch (error) {
    if (error instanceof Unavailable) return outcomePage("unavailable");
    throw error;
  }
  if (sharedDay === null) return notFound();
  if (reportSink(env) === null) return outcomePage("off");
  const reasons = Object.entries(REPORT_REASONS)
    .map(
      ([key, label], i) =>
        `<label class="report-choice"><input type="radio" name="reason" value="${key}"${i === 0 ? " required" : ""}> ${esc(label)}</label>`,
    )
    .join("\n");
  // Turnstile puts its token into the form itself, under the name data-response-field-name gives, so
  // the page needs no script of its own.
  const html = page(`<p>この共有について、運営者に知らせます。名前や連絡先は送られず、返信はしません。返信が必要なときは、${CONTACT}</p>
<form class="report-form" method="POST" action="/api/reports">
<input type="hidden" name="id" value="${esc(id)}">
<fieldset><legend>理由</legend>
${reasons}
</fieldset>
<label for="report-text">詳しい内容（任意・${limits.MAX_REPORT_TEXT.toLocaleString("en-US")} 字まで）</label>
<textarea id="report-text" name="text" rows="6" maxlength="${limits.MAX_REPORT_TEXT}"></textarea>
<div class="cf-turnstile" data-sitekey="${esc(env.TURNSTILE_SITEKEY)}" data-action="${REPORT_ACTION}" data-response-field-name="token" data-theme="auto"></div>
<button type="submit">送信</button>
</form>
<script src="${TURNSTILE_ORIGIN}/turnstile/v0/api.js" async defer></script>`);
  return new Response(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy": [
        "default-src 'none'",
        `script-src ${TURNSTILE_ORIGIN}`,
        `frame-src ${TURNSTILE_ORIGIN}`,
        "connect-src 'self'",
        "img-src 'self'",
        "style-src 'self' 'unsafe-inline'",
        "font-src 'self'",
        "form-action 'self'",
      ].join("; "),
      "Cache-Control": "no-store",
      "Referrer-Policy": "same-origin",
      "X-Robots-Tag": "noindex",
    },
  });
}

/** The report's fields, each present exactly once and none other, or null. */
function reportForm(text) {
  const params = new URLSearchParams(text);
  for (const key of new Set(params.keys())) if (!FIELDS.includes(key)) return null;
  if (FIELDS.some((key) => params.getAll(key).length !== 1)) return null;
  const form = Object.fromEntries(FIELDS.map((key) => [key, params.get(key)]));
  if (!ID.test(form.id) || !Object.hasOwn(REPORT_REASONS, form.reason)) return null;
  if (form.text.length > limits.MAX_REPORT_TEXT || !isTurnstileToken(form.token)) return null;
  return form;
}

const hex = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");

/**
 * Sends one report to Sentry as one event and returns whether Sentry took it (a 2xx). The event names
 * the share, the reason and the text, and carries no user, request or IP: the Worker sends it, so
 * nothing of the reporter's connection is in it.
 */
async function sendReport(sink, env, report, sharedOn) {
  const eventId = hex(crypto.getRandomValues(new Uint8Array(16)));
  const sentAt = new Date().toISOString();
  const event = {
    event_id: eventId,
    timestamp: sentAt,
    platform: "other",
    level: "warning",
    logger: "share-report",
    message: { formatted: "share report" },
    environment: env.REPORT_SENTRY_ENVIRONMENT,
    tags: { kind: "share_report", reason: report.reason },
    extra: { share_id: report.id, text: report.text, shared_on: sharedOn },
    // One issue a share: Sentry's "new issue" alert fires once for a share, and later reports of it
    // add to that issue's count.
    fingerprint: ["share-report", report.id],
  };
  const body = [{ event_id: eventId, sent_at: sentAt, dsn: sink.dsn }, { type: "event" }, event]
    .map((line) => JSON.stringify(line))
    .join("\n");
  try {
    const res = await fetch(sink.endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-sentry-envelope",
        "X-Sentry-Auth": `Sentry sentry_version=7, sentry_client=umacapture-share-report/1, sentry_key=${sink.key}`,
      },
      body,
    });
    await res.body?.cancel();
    return res.ok;
  } catch {
    return false;
  }
}

/**
 * POST /api/reports, the report page's form. Accepted while sharing, sync or shared images are paused:
 * a paused switch stops new shares, not the reading of the ones that stay public.
 */
export async function postReport(request, env, now) {
  // Only the report page posts here: a form POST from any other origin carries that origin.
  if (request.headers.get("Origin") !== env.PUBLIC_ORIGIN) return outcomePage("unverified");
  const sink = reportSink(env);
  if (sink === null) return outcomePage("off");
  const type = request.headers.get("Content-Type") ?? "";
  if (type.split(";")[0].trim().toLowerCase() !== FORM) return outcomePage("invalid");
  let report;
  try {
    report = reportForm(await readText(request, limits.MAX_REPORT_BODY));
  } catch (error) {
    if (error instanceof TooLarge || error instanceof InvalidPayload) return outcomePage("invalid");
    throw error;
  }
  if (report === null) return outcomePage("invalid");
  if (!(await verifyTurnstile(report.token, env, REPORT_ACTION))) return outcomePage("unverified");
  const at = clock(now);
  let sharedDay;
  try {
    sharedDay = await readSharedDay(env.DB, report.id);
    if (sharedDay === null) return notFound();
    // Counted before sending, and not given back when sending fails: a failing Sentry must not let
    // retries past the day's limit.
    if (!(await countReport(env.DB, at.day, limits.REPORT_DAILY_LIMIT))) return outcomePage("limit");
  } catch (error) {
    if (error instanceof Unavailable) return outcomePage("unavailable");
    throw error;
  }
  return outcomePage((await sendReport(sink, env, report, dayToIso(sharedDay))) ? "accepted" : "unsent");
}
