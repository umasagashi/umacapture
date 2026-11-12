// The login start page /api/auth/start and the pages the begin and the callback answer a refusal
// with. The web app replaces itself with the start page in its own tab, and the Windows app opens it
// in the default browser; the visitor passes Turnstile there and presses 「Google でログイン」,
// and the page submits a top-level form POST to /api/auth/begin, whose 302 the browser follows to
// the provider. The press is asked for rather than submitting once Turnstile passes, so a password
// manager's "Sign in with" (which finds a site's Google sign-in button and presses it) can start the
// login. A top-level form is
// what lets the browser follow that redirect: a fetch would only follow it as a request, and the
// authorisation URL is never put where the page or its script could show it.
//
// The Worker serves these pages, so the COEP header the app's static files carry does not reach
// them and the Turnstile iframe can load. They wear the public pages' look: the shared stylesheet
// (web/site/site.css), its header and colour switch, and its document column.

import { PAGE_CSP, esc, siteHeader } from "./page.mjs";

export const TURNSTILE_ORIGIN = "https://challenges.cloudflare.com";

// The Turnstile widget sits outside the begin form: it adds its own response field to a form it is
// in, and the begin refuses a field it does not know.
//
// The sign-in button follows Google's branding guidelines for a button the site draws itself: the
// standard-colour "G" on the guidelines' light or dark fill, stroke and text colour, 12 px left of
// the "G", 10 px between it and the text, 12 px right of the text, text at 14/20. The site's font
// stands in for Google Sans, which the site does not serve.
const GOOGLE_G = `<svg aria-hidden="true" width="18" height="18" viewBox="0 0 48 48"><path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/><path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/><path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/><path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/></svg>`;

const GOOGLE_BUTTON_CSS = `
#begin { margin-top: 1rem; }
.google-sign-in { display: inline-flex; align-items: center; gap: 10px; max-width: 100%; padding: 9px 12px; font: 500 14px/20px var(--font); cursor: pointer; border-radius: 4px; background: light-dark(#FFFFFF, #131314); color: light-dark(#1F1F1F, #E3E3E3); border: 1px solid light-dark(#747775, #8E918F); }
.google-sign-in svg { flex: none; }
.google-sign-in[aria-busy="true"] { cursor: progress; opacity: .7; }
`;

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
<div class="cf-turnstile" data-sitekey="${esc(env.TURNSTILE_SITEKEY)}" data-action="${esc(env.TURNSTILE_ACTION)}" data-callback="onTurnstile" data-expired-callback="onTurnstileLost" data-error-callback="onTurnstileLost" data-theme="auto"></div>
<form id="begin" method="POST" action="/api/auth/begin">
<input type="hidden" name="h" value="${esc(h)}">
<input type="hidden" name="p" value="${esc(p)}">${portField}
<input type="hidden" name="token" value="">
<button type="submit" class="google-sign-in">${GOOGLE_G}<span>Google でログイン</span></button>
</form>
<style>${GOOGLE_BUTTON_CSS}</style>
<script nonce="${n}">
// The button stays enabled: a press before Turnstile has passed is kept and sent when it passes, so
// a press by a password manager is not lost on a disabled button.
const form = document.getElementById("begin");
let pressed = false;
form.addEventListener("submit", (event) => {
  if (form.elements.token.value !== "") return;
  event.preventDefault();
  pressed = true;
  form.querySelector("button").setAttribute("aria-busy", "true");
});
window.onTurnstile = (token) => {
  form.elements.token.value = token;
  if (pressed) form.submit();
};
// An expired or failed check takes its answer back; the widget itself tells the visitor which.
window.onTurnstileLost = () => {
  form.elements.token.value = "";
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
