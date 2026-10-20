// session — login-flow helpers.
//
// The cells the row→done boundary used to smuggle now live in orisha/ctx:
// what was `auth_uid` + `email_buf` threadlocals is `set-int`/`take-int-or`
// and `set-text`/`take-text` on per-purpose names. The scoping argument is
// unchanged — a handler runs to completion on one worker thread — it is just
// orisha's mechanism now, not ours.
//
// What stays in the companion (index.kz): the token mint (crypto random),
// the `?string` narrowing launderers (a `!= null` guard still doesn't narrow
// for tor params — str-or/opt-or/raw-or are the vocabulary for that wall),
// and the response-head builders, whose results must outlive later fmt:ln
// calls and so keep dedicated buffers rather than borrow fmt's scratch.

import orisha/ctx

// The authenticated user id, stashed from the SELECT user + bcrypt verify
// row arm for the `| done` continuation to read.
pub tor stash-if { ok: bool, uid: i64 }
stash-if = if(ok)
    | then |> orisha/ctx:set-int(name: "session.uid", v: uid)

pub tor take-uid {} -> i64
take-uid = orisha/ctx:take-int-or(name: "session.uid", default: -1): v -> v

// Rails `has_secure_token` is SecureRandom.base58(24). Implemented in the
// companion — needs crypto random bytes.
pub tor new-token {} -> string

// The CSRF-bound raw token for a form-serving GET: the verified session
// token when the request carried a signed cookie, else a fresh mint for the
// anonymous "session" — Rails's session cookie exists pre-login for exactly
// this reason; the anon value signs nothing in the sessions table, it only
// gives the CSRF token a cookie to bind to.
pub tor raw-or { token: ?string } -> string

// extra_headers for a page that binds CSRF to a cookie: a Set-Cookie only
// when the request arrived without a verifiable one (Rails's jar already
// exists otherwise — re-setting it would rotate the session out from under
// the presented token). Nullable answer: a null extra_headers is omitted,
// while an empty string fails orisha's well-formed check.
pub tor set-cookie-hdr { cookie: string, present: ?string } -> ?string

// The authed-POST verdict: proceed when the CSRF pair matched, or when the
// request carried no verifiable session cookie at all — the handler's own
// auth lookup then answers the 302, matching the reference's
// require_authentication-first ordering (no-cookie POSTs redirect, they do
// not 422).
pub tor csrf-allow { token: ?string, ok: bool } -> bool
csrf-allow = if(ok or token == null)
    | then -> true
    | else -> false

// Optional payload unwrap for required-param gates — an `!= null` guard
// doesn't narrow `?string` to `string` for tor params, so the payload
// crosses through a proc. Missing -> "".
pub tor str-or { s: ?string } -> string

// The nullable passthrough — str-or collapses null to "", but a verified
// session token must STAY null (absent != empty) so downstream `x != null`
// guards keep meaning "no session". Produces its input unchanged so a flow
// can rebind a ?string across a `|>` boundary.
pub tor opt-or { s: ?string } -> ?string
opt-or -> s

// The 302's extra_headers block — Location + Set-Cookie spliced into the
// response head. Companion-implemented: the produced string must outlive
// later fmt:ln calls (they share one scratch buffer), so it keeps a
// dedicated buffer and carries no <allocated!> obligation.
pub tor redirect-headers { token: string } -> string

// Bare redirect — Location only. WelcomeController#show and the auth gate
// both spell redirects this way.
pub tor redirect-to { path: string } -> string

// Room id -> "/rooms/<id>" — its own buffer: `redirect-to` consumes the
// path while writing hdr_buf, so the two can't share.
pub tor room-path { rid: i64 } -> string

// The column-text stash for the row→done boundary: row borrows die with the
// row, so the cell owns a copy. Absent cell = no session row matched
// (bad/expired cookie).
pub tor stash-text { text: string<*> }
stash-text = orisha/ctx:set-text(name: "session.email", v: text)
    | ok |> _
    | truncated |> _

pub tor take-text {} -> ?string
take-text = orisha/ctx:take-text(name: "session.email"): v -> v

// The signed-cookie variant of redirect-headers — the Set-Cookie value
// arrives already built by signing:cookie-header (Rack's attribute order:
// path, expires, httponly, samesite — lowercase, escaped value).
pub tor redirect-signed { cookie: string } -> string
