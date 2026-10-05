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
// DB: the real parity seed (reference app, db:prepare + seeds/default.rb).
room-page = pages:page-begin()
    |> pages:page-write(text: "<!DOCTYPE html><html><body><h1>Room ")
    |> pages:page-write(text: id)
    |> pages:page-write(text: "</h1>")
    |> koru/sqlite3:open(path: "seed/production.sqlite3")
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT u.name, rt.body FROM messages m
            JOIN action_text_rich_texts rt
              ON rt.record_type = 'Message' AND rt.record_id = m.id
            JOIN users u ON u.id = m.creator_id
            WHERE m.room_id = {{id}}
            ORDER BY m.created_at
        }
        ! row r |> koru/sqlite3:col.text(stmt: r, index: 0): n
                |> pages:page-write(text: "<div><b>")
                |> pages:page-write(text: n)
                |> pages:page-write(text: "</b>")
                |> koru/sqlite3:col.text(stmt: r, index: 1): b
                |> pages:page-write(text: b)
                |> pages:page-write(text: "</div>")
        | done d2 |> koru/sqlite3:close(conn: d2) |> pages:page-write(text: "</body></html>") |> pages:page-take(): body -> body
        | err e |> koru/sqlite3:close(e.conn) |> pages:page-take(): partial -> "query failed"
    | err _ -> "db open failed"

// Messages index (Message::Pagination): last PAGE_SIZE=40 ordered by
// created_at. `before=<id>` narrows to created_at < that message's — wired
// when orisha:query-param lands in the route arm. Empty page -> 204,
// matching the controller's head :no_content. (`if` inside a route-branch
// continuation leaks __koru_continue_N splices — repro/if-in-route-branch.k —
// so the 200/204 decision lives in pages:page-status.)
pub tor messages-page { id: string, before: ?string } -> string
messages-page = pages:page-begin()
    |> koru/sqlite3:open(path: "seed/production.sqlite3")
    | db d |> koru/sqlite3:default(conn: d) {
        SELECT u.name, rt.body FROM (
            SELECT m.id, m.creator_id, m.created_at FROM messages m
            WHERE m.room_id = {{id}}
              AND ({{before}} IS NULL OR m.created_at < (SELECT created_at FROM messages WHERE id = {{before}}))
            ORDER BY m.created_at DESC LIMIT 40
        ) m
        JOIN action_text_rich_texts rt
          ON rt.record_type = 'Message' AND rt.record_id = m.id
        JOIN users u ON u.id = m.creator_id
        ORDER BY m.created_at
        }
        ! row r |> koru/sqlite3:col.text(stmt: r, index: 0): n
                |> pages:page-write(text: n)
                |> pages:page-write(text: ": ")
                |> koru/sqlite3:col.text(stmt: r, index: 1): b
                |> pages:page-write(text: b)
                |> pages:page-write(text: "\n")
        | done d2 |> koru/sqlite3:close(conn: d2) |> pages:page-take(): body -> body
        | err e |> koru/sqlite3:close(e.conn) -> "query failed"
    | err _ -> "db open failed"

// Sidebar (Users::SidebarsController): visible memberships for the user,
// directs (Rooms::Direct) sorted by room.updated_at desc, the rest by
// LOWER(name); then placeholder users not already in a direct room.
// user_email stands in for Current.user until sessions land.
pub tor sidebar-page { user_email: string } -> string
sidebar-page = pages:page-begin()
    |> pages:page-write(text: "<nav><h2>Pings</h2><ul>")
    |> koru/sqlite3:open(path: "seed/production.sqlite3")
    | db d |> koru/sqlite3:default(conn: d) {
        SELECT r.id, r.name FROM memberships m
        JOIN rooms r ON r.id = m.room_id
        WHERE m.user_id = (SELECT id FROM users WHERE email_address = {{user_email}})
          AND m.involvement != 'invisible'
          AND r.type = 'Rooms::Direct'
        ORDER BY r.updated_at DESC
        }
        ! row r |> pages:page-write(text: "<li>")
                |> koru/sqlite3:col.text(stmt: r, index: 1): n |> pages:page-write(text: n)
                |> pages:page-write(text: "</li>")
        | done d2 |> pages:page-write(text: "</ul><h2>Rooms</h2><ul>")
                |> koru/sqlite3:default(conn: d2) {
                    SELECT r.id, r.name FROM memberships m
                    JOIN rooms r ON r.id = m.room_id
                    WHERE m.user_id = (SELECT id FROM users WHERE email_address = {{user_email}})
                      AND m.involvement != 'invisible'
                      AND r.type != 'Rooms::Direct'
                    ORDER BY LOWER(r.name)
                    }
                    ! row r2 |> pages:page-write(text: "<li>")
                            |> koru/sqlite3:col.text(stmt: r2, index: 1): n2 |> pages:page-write(text: n2)
                            |> pages:page-write(text: "</li>")
                    | done d3 |> pages:page-write(text: "</ul><h2>People</h2><ul>")
                            |> koru/sqlite3:default(conn: d3) {
                                SELECT u.id, u.name FROM users u
                                WHERE u.status = 0
                                  AND u.id != (SELECT id FROM users WHERE email_address = {{user_email}})
                                  AND u.id NOT IN (
                                    SELECT m2.user_id FROM memberships m2
                                    WHERE m2.room_id IN (
                                      SELECT m3.room_id FROM memberships m3
                                      JOIN rooms r3 ON r3.id = m3.room_id
                                      WHERE m3.user_id = (SELECT id FROM users WHERE email_address = {{user_email}})
                                        AND r3.type = 'Rooms::Direct'))
                                ORDER BY u.created_at LIMIT 20
                                }
                                ! row r3 |> pages:page-write(text: "<li>")
                                        |> koru/sqlite3:col.text(stmt: r3, index: 1): n3 |> pages:page-write(text: n3)
                                        |> pages:page-write(text: "</li>")
                                | done d4 |> koru/sqlite3:close(conn: d4) |> pages:page-write(text: "</ul></nav>") |> pages:page-take(): body -> body
                                | err e4 |> koru/sqlite3:close(e4.conn) -> "q3 failed"
                    | err e3 |> koru/sqlite3:close(e3.conn) -> "q2 failed"
        | err e2 |> koru/sqlite3:close(e2.conn) -> "q1 failed"
    | err _ -> "db open failed"

// Search (SearchesController): FTS5 phrase match over message_search_index,
// scoped to rooms the user is a member of (reachable_messages), last 100.
// NULL query -> no rows -> 204, matching `@messages = Message.none`.
pub tor search-page { user_email: string, q: ?string } -> string
search-page = pages:page-begin()
    |> koru/sqlite3:open(path: "seed/production.sqlite3")
    | db d |> koru/sqlite3:default(conn: d) {
        SELECT u.name, rt.body FROM messages m
        JOIN message_search_index idx ON m.id = idx.rowid
        JOIN action_text_rich_texts rt
          ON rt.record_type = 'Message' AND rt.record_id = m.id
        JOIN users u ON u.id = m.creator_id
        JOIN memberships mem ON mem.room_id = m.room_id
        WHERE mem.user_id = (SELECT id FROM users WHERE email_address = {{user_email}})
          AND {{q}} IS NOT NULL
          AND idx.body MATCH '"' || replace({{q}}, '"', '""') || '"'
        ORDER BY m.created_at DESC LIMIT 100
        }
        ! row r |> pages:page-write(text: "<div><b>")
                |> koru/sqlite3:col.text(stmt: r, index: 0): n |> pages:page-write(text: n)
                |> pages:page-write(text: "</b>")
                |> koru/sqlite3:col.text(stmt: r, index: 1): b |> pages:page-write(text: b)
                |> pages:page-write(text: "</div>")
        | done d2 |> koru/sqlite3:close(conn: d2) |> pages:page-take(): body -> body
        | err e |> koru/sqlite3:close(e.conn) -> "query failed"
    | err _ -> "db open failed"

// ============================================================================
// HANDLER
// ============================================================================

orisha:handler = orisha:router(req)
! [GET /up]          -> { status: 200, body: "OK",   content_type: "text/plain" }
! [GET /session/new] |> sign-in-page(): page -> { status: 200, body: page, content_type: "text/html" }
! [GET /rooms/:id] p |> room-page(p.id): page -> { status: 200, body: page, content_type: "text/html" }
! [GET /rooms/:id/messages] p |> orisha:query-param(req, name: "before"): before |> messages-page(p.id, before): page |> pages:page-status(): code -> { status: code, body: page, content_type: "text/html" }
! [GET /users/me/sidebar] |> sidebar-page(user_email: "david@37signals.com"): page |> pages:page-status(): code -> { status: code, body: page, content_type: "text/html" }
! [GET /searches] |> orisha:query-param(req, name: "q"): q |> search-page(user_email: "david@37signals.com", q): page |> pages:page-status(): code -> { status: code, body: page, content_type: "text/html" }
! [*]                -> { status: 404, body: "Not Found", content_type: "text/plain" }

orisha:serve(port: 3109)
| shutdown s |> std/io:print.ln(s)
| failed   f |> std/io:print.ln(f)
