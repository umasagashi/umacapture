// The confirmation page /api/verify?h=<ticket hash>. The app opens it in a browser; the visitor
// passes Turnstile here and the page registers the ticket hash with POST /api/tickets. Only the hash
// travels in the URL, so the ticket itself never leaves the app until it is spent.
//
// The Worker serves this page, so the COEP header the app's static files carry does not reach it
// and the Turnstile iframe can load.

import { esc } from "./page.mjs";

const TURNSTILE_ORIGIN = "https://challenges.cloudflare.com";

/** A per-response nonce for the page's one inline script. */
function nonce() {
  return btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16))));
}

/** The response for a confirmation page carrying the already-checked ticket hash `hash`. */
export function verifyPageResponse(hash, env) {
  const n = nonce();
  const html = `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>公開の確認 | umacapture</title>
<style>
body { font-family: sans-serif; max-width: 36rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.6; }
</style>
</head>
<body>
<h1>公開の確認</h1>
<p>アプリで公開を押した覚えが無ければ、このページを閉じてください。</p>
<div class="cf-turnstile" data-sitekey="${esc(env.TURNSTILE_SITEKEY)}" data-action="${esc(env.TURNSTILE_ACTION)}" data-callback="onTurnstile"></div>
<p id="result" role="status"></p>
<script nonce="${n}">
const MESSAGES = {
  204: "確認できました。アプリに戻ってください。",
  429: "今日の確認の上限に達しました。時間をおいてお試しください。",
  503: "公開は一時停止しています。",
};
window.onTurnstile = async (token) => {
  const result = document.getElementById("result");
  let status = 0;
  try {
    const res = await fetch("/api/tickets", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ h: ${JSON.stringify(hash)}, token }),
    });
    status = res.status;
  } catch {}
  result.textContent = MESSAGES[status] ?? "確認できませんでした。ページを開き直してください。";
};
</script>
<script src="${TURNSTILE_ORIGIN}/turnstile/v0/api.js" async defer></script>
</body>
</html>
`;
  return new Response(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy": [
        "default-src 'none'",
        `script-src 'nonce-${n}' ${TURNSTILE_ORIGIN}`,
        `frame-src ${TURNSTILE_ORIGIN}`,
        "connect-src 'self'",
        "style-src 'unsafe-inline'",
      ].join("; "),
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
      "X-Robots-Tag": "noindex",
    },
  });
}
