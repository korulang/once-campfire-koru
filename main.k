// once-campfire-koru — Campfire-shaped app in Koru/Orisha.
//
// Target: bench/compare_http.rb surface — /up, sign-in flow, room page,
// messages, sidebar, search — against the Rails SQLite schema (db/schema.sql,
// verbatim from once-campfire-rust's crates/db/src/schema.sql).

import orisha
import koru/sqlite3
import pages
import std/io
import std/fmt

// ============================================================================
// PAGES — stubs until templates land; shape is the point
// ============================================================================

pub tor sign-in-page {} -> string
pub tor room-page { id: string } -> string

sign-in-page -> "<!DOCTYPE html><html><head><meta name=\"csrf-token\" content=\"dev-token\"></head><body><h1>Sign in</h1><form action=\"/session\" method=\"post\"><input name=\"email_address\"><input name=\"password\" type=\"password\"><button>Sign in</button></form></body></html>"

// Room page: messages joined to their ActionText bodies for one room.
// Per-request buffer: ! row fires per row, the handler produces one body.
room-page = pages:page-begin()
    |> koru/sqlite3:open(path: "seed/dev.db")
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT rt.body FROM messages m
            JOIN action_text_rich_texts rt
              ON rt.record_type = 'Message' AND rt.record_id = m.id
            WHERE m.room_id = {{id}}
            ORDER BY m.created_at
        }
        ! row r |> koru/sqlite3:col.text(stmt: r, index: 0): b |> pages:page-write(text: b)
        | done d2 |> koru/sqlite3:close(conn: d2) |> pages:page-take(): body |> room-wrap(id, body): page -> page
        | err e |> koru/sqlite3:close(e.conn) |> pages:page-take(): partial -> "query failed"
    | err _ -> "db open failed"

pub tor room-wrap { id: string, body: string } -> string
room-wrap = std/fmt:ln("<!DOCTYPE html><html><body><h1>Room {{id:s}}</h1>{{body:s}}</body></html>"): l -> l.text

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
