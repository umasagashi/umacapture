# Login protocol: the account hint

The contract between the Worker's login endpoints (`server/src/auth.mjs`,
`server/src/account_hint.mjs`) and the apps for one thing a login hands over besides the session:
the **account hint**, a masked form of the email address of the account the login came back as, so
that an app whose session has ended can show which account it was logged in with. How the Worker is
deployed and keyed is [`web-deploy.md`](web-deploy.md).

## The handover it rides on

A login is named by `h`, the SHA-256 of a secret `s` only the app holds. The provider sends the
browser back to `GET /api/auth/callback/<provider>`, which completes the login and issues a
single-use **proof**; the app then exchanges `s` and the proof for a session at
`POST /api/auth/claim`. The proof reaches the app differently on the two platforms, because the
Windows app is not a browser and cannot read a cookie the callback sets:

| | Web | Windows |
|---|---|---|
| Proof | HttpOnly cookie `uc_login_<h>`, `Path=/api/auth`, lives as long as a login (`LOGIN_TTL_SECONDS`) | `code` in the redirect to the app's loopback listener, `http://127.0.0.1:<port>/cb?h=…&code=…` |
| Claim body | `{s}` (the cookie goes along) | `{s, code}` |

Which of the two a claim reads is decided by whether the login was begun with a loopback port, never
by what the claim sends.

## The hint

**Value.** A string: the local part masked, the domain kept whole.

| Local part | Kept | Example |
|---|---|---|
| 5 characters or more | the first 2 | `kenji.hata@gmail.com` → `ke****@gmail.com` |
| 3 or 4 characters | the first 1 | `abc@example.jp` → `a****@example.jp` |
| 1 or 2 characters | none | `ab@example.jp` → `****@example.jp` |

The mask is always four asterisks, so it does not tell the local part's exact length; how many
characters are kept still tells which of the three bands above it falls in. Characters are counted
as Unicode code points. There is no hint when the ID token carries no `email` claim, or one that is
not an address (no `@`, an empty side, whitespace or a control character, longer than 320
characters).

**Where it comes from.** The callback reads `email` from the provider's ID token and masks it at
once (`maskEmail`). The full address goes no further than that function: it is not returned, written
to D1, logged, or sent anywhere. The masked form is not written to D1 or logged either.

**How it travels.** The masked form is sealed (AES-256-GCM under a key derived from
`IDENTITY_HMAC_KEY`, bound to the hash of the proof the same callback issued) and travels exactly
where the proof does. The browser, its history and the Cookie header therefore carry only
ciphertext, and only the claim that presents that proof opens it.

| | Web | Windows |
|---|---|---|
| Callback sets | HttpOnly cookie `uc_hint_<h>` beside `uc_login_<h>`, same attributes and lifetime; set only when there is a hint | `hint=<sealed>` in the loopback redirect's query, beside `h` and `code`; present only when there is a hint |
| App sends to the claim | nothing (the cookie goes along) | `hint`: the loopback query's `hint` exactly as received, **only when the redirect carried one** |
| Claim removes | `uc_hint_<h>` (when the request carried it), with `uc_login_<h>` | nothing |

The sealed value is opaque: unpadded base64url, at most a few hundred characters. An app does not
parse it.

**What the app receives.** The claim's `200` answer gains one field:

```json
{"token": "…", "expires_at": 1767225600, "account_id": "…", "deleting": false, "account_hint": "ke****@gmail.com"}
```

`account_hint` is the masked string, or `null` when there is none: no email in the ID token, a
Windows claim without `hint`, or a `hint` that does not open (another login's, or tampered with —
the login still succeeds). A `hint` that is not base64url, or is too long, is refused like a
malformed `code`: `400 {"error":"invalid_payload","field":"hint"}`, and the login stays claimable.

## What the app does with it

- **Keep** the hint in the app's own storage, beside the session and outside it, so that dropping
  the session leaves it.
- **Replace** it on every successful claim: a string replaces the kept one, and `null` **or an
  absent field** removes it. A login is to whatever account the user picked this time, and a hint
  left from another account would name the wrong one.
- **Remove** it on account deletion only (both the deletion the app completes and one it learns the
  server finished): the account it names is gone.
- **Keep** it when the session ends any other way — a logout, the server's `401 session_required`, an
  expired session. That is the case it exists for: the account the device was last logged in as
  stays the same after the session ends, whoever ended it.
- **Show** it only while logged out.
- **Never log it**, nor the sealed `hint`, nor the loopback URL: every app log line becomes a crash
  report breadcrumb.

## Clearing

Nothing on the server outlives the claim: the hint is never stored, the web cookie is removed by the
claim (and expires with the login otherwise), and the sealed value in a Windows browser's history
opens only for a claim of a login that the claim itself consumed. Account deletion therefore has
nothing to clear on the server's side; clearing the kept hint is the app's.

## Compatibility

- **An app that predates the hint, against a Worker that sends it.** The Windows loopback listener
  matches `h` and reads `code`, ignoring other query parameters; such an app sends no `hint` and gets
  `account_hint: null`, which it does not read. A web app ignores the extra cookie and field.
- **An app that knows the hint, against a Worker that predates it.** No `hint` reaches the loopback
  and the claim answers no `account_hint`; the app treats the absent field as `null`. The app must
  not send `hint` when the redirect carried none: a Worker that predates the hint refuses any field
  of the claim body it does not know (`400 invalid_payload`).
