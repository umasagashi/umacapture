// The login start page /api/auth/start, the pages the begin and the callback answer a refusal
// with, and the page a web login's callback ends on. The app opens
// the start page in a browser; the visitor passes Turnstile there, and the page submits a top-level
// form POST to /api/auth/begin, whose 302 the browser follows to the provider. A top-level form is
// what lets the browser follow that redirect: a fetch would only follow it as a request, and the
// authorisation URL is never put where the page or its script could show it.
//
// The Worker serves these pages, so the COEP header the app's static files carry does not reach
// them and the Turnstile iframe can load. They wear the public pages' look: the shared stylesheet
// (web/site/site.css), its header and colour switch, and its document column.

import { PAGE_CSP, esc, siteHeader } from "./page.mjs";

export const TURNSTILE_ORIGIN = "https://challenges.cloudflare.com";

/** A per-response nonce for a page's one inline script. */
export function scriptNonce() {
  return btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16))));
}

const PAGE_HEAD = (title) => `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${esc(title)} | umacapture</title>
<link rel="stylesheet" href="/site/site.css">
<link rel="icon" type="image/png" href="/favicon.png">
</head>`;

/** The body of a login page: the site header, then `content` in the document column. */
const PAGE_BODY = (content) => `<body>
${siteHeader("ログイン")}
<main class="site-doc">
<h1>ログイン</h1>
${content}
</main>
</body>
</html>
`;

/**
 * The start page for a login whose query was already checked: `h` (the app's secret hash), `p`
 * (the provider) and `port` (the Windows app's loopback port, or null on the web).
 *
 * Its Referrer-Policy is same-origin, not no-referrer: the begin form inherits the page's policy,
 * and under no-referrer the browser sends `Origin: null` on that POST, which the begin's Origin check
 * refuses. same-origin still sends no Referer to Turnstile's cross-origin requests.
 */
export function loginPageResponse({ h, p, port }, env) {
  const n = scriptNonce();
  const portField = port === null ? "" : `\n<input type="hidden" name="port" value="${esc(String(port))}">`;
  // data-theme="auto" follows the system's light or dark, which is what the page shows until the
  // visitor uses the colour switch. Following the switch too would need a script that re-renders the
  // widget, and a re-render discards a challenge already in progress.
  const html = `${PAGE_HEAD("ログイン")}
${PAGE_BODY(`<p>アプリでログインを押した覚えが無ければ、このページを閉じてください。</p>
<form id="begin" method="POST" action="/api/auth/begin">
<input type="hidden" name="h" value="${esc(h)}">
<input type="hidden" name="p" value="${esc(p)}">${portField}
<input type="hidden" name="token" value="">
</form>
<div class="cf-turnstile" data-sitekey="${esc(env.TURNSTILE_SITEKEY)}" data-action="${esc(env.TURNSTILE_ACTION)}" data-callback="onTurnstile" data-theme="auto"></div>
<script nonce="${n}">
window.onTurnstile = (token) => {
  const form = document.getElementById("begin");
  form.elements.token.value = token;
  form.submit();
};
</script>
<script src="${TURNSTILE_ORIGIN}/turnstile/v0/api.js" async defer></script>`)}`;
  return new Response(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy": [
        "default-src 'none'",
        `script-src 'nonce-${n}' ${TURNSTILE_ORIGIN}`,
        `frame-src ${TURNSTILE_ORIGIN}`,
        "connect-src 'self'",
        "img-src 'self'",
        "style-src 'self' 'unsafe-inline'",
        "font-src 'self'",
        // Stated rather than left to form-action's lack of a default-src fallback, so the begin's
        // redirect to the provider stays allowed where a browser applies form-action to it.
        "form-action 'self' https://accounts.google.com",
      ].join("; "),
      "Cache-Control": "no-store",
      "Referrer-Policy": "same-origin",
      "X-Robots-Tag": "noindex",
    },
  });
}

const FAILURES = {
  400: "ログインを始められませんでした。アプリからログインをやり直してください。",
  403: "確認できませんでした。アプリからログインをやり直してください。",
  429: "今日のログインの上限に達しました。時間をおいてお試しください。",
  503: "一時的にログインできません。時間をおいてお試しください。",
};

/** Refusals that tell the visitor more than their status does, by error code. */
const REASONS = {
  login_browser_mismatch: "ログインを始めたブラウザで開いてください。",
  login_in_progress: "このログインは別のブラウザで進んでいます。アプリからログインをやり直してください。",
  sharing_paused: "共有を一時的に止めているため、ログインできません。時間をおいてお試しください。",
};

/**
 * A refusal of the start page, the begin or the callback, as a page with status `status`; `error`
 * names a refusal of REASONS, and the page carries it as `data-error`. no-referrer: the page's URL
 * (and a begin's request) is not passed on to wherever the visitor goes next.
 */
export function loginFailureResponse(status, headers = {}, error = null) {
  const message = error === null ? FAILURES[status] : REASONS[error];
  if (message === undefined) throw new Error(`no login failure page for status ${status}, error ${error}`);
  const marker = error === null ? "" : ` data-error="${esc(error)}"`;
  return loginMessageResponse(status, `<p${marker}>${esc(message)}</p>`, headers);
}

/** The page a web login's callback ends on; the app's tab claims the session. */
export function loginDoneResponse() {
  return loginMessageResponse(200, `<p>${esc("ログインしました。元のタブに戻ってください。")}</p>`);
}

function loginMessageResponse(status, paragraph, headers = {}) {
  const html = `${PAGE_HEAD("ログイン")}
${PAGE_BODY(paragraph)}`;
  return new Response(html, {
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
