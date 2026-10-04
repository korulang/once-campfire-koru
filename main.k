// once-campfire-koru — Campfire-shaped app in Koru/Orisha.
//
// Target: bench/compare_http.rb surface — /up, sign-in flow, room page,
// messages, sidebar, search — against the Rails SQLite schema (db/schema.sql,
// verbatim from once-campfire-rust's crates/db/src/schema.sql).

import orisha
import std/io
import std/fmt

// ============================================================================
// PAGES — stubs until templates land; shape is the point
// ============================================================================

pub tor sign-in-page {} -> string
pub tor room-page { id: string } -> string

sign-in-page -> "<!DOCTYPE html><html><head><meta name=\"csrf-token\" content=\"dev-token\"></head><body><h1>Sign in</h1><form action=\"/session\" method=\"post\"><input name=\"email_address\"><input name=\"password\" type=\"password\"><button>Sign in</button></form></body></html>"

room-page = std/fmt:ln("<!DOCTYPE html><html><body><h1>Room {{id:s}}</h1></body></html>"): l -> l.text

// ============================================================================
// HANDLER
// ============================================================================

orisha:handler = orisha:router(req)
! [GET /up]          -> { status: 200, body: "OK",   content_type: "text/plain" }
! [GET /session/new] |> sign-in-page(): page -> { status: 200, body: page, content_type: "text/html" }
! [GET /rooms/:id] p |> room-page(p.id): page -> { status: 200, body: page, content_type: "text/html" }
! [*]                -> { status: 404, body: "Not Found", content_type: "text/plain" }

orisha:serve(port: 3109)
| shutdown s |> std/io:print.ln(s)
| failed   f |> std/io:print.ln(f)
