// once-campfire-koru — Campfire-shaped app in Koru/Orisha.
//
// Target: bench/compare_http.rb surface — /up, sign-in flow, room page,
// messages, sidebar, search — against the Rails SQLite schema (db/schema.sql,
// verbatim from once-campfire-rust's crates/db/src/schema.sql).

import orisha
import koru/sqlite3
import bcrypt
import pages
import session
import std/io
import std/fmt
import std/build

// A build flag picks the LOOP; it does not pick the machine. --build=linux
// on a Linux host builds native + epoll; on macOS it emits the epoll loop
// in a Mach-O (harmless trap, documented). No build:config target is set —
// any explicit triple flips zig to cross-compile mode where system lib
// paths are empty and `-lsqlite3`/`-lz` cannot resolve.

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
pub tor sidebar-page { user_email: ?string } -> string
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
pub tor search-page { user_email: ?string, q: ?string } -> string
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

// SessionsController#create: authenticate_by(email, password) -> insert a
// sessions row (has_secure_token = base58(24)) -> 302 to / with a
// session_token cookie, or re-render the form at 401. The authenticated
// uid crosses the row/done boundary in session's request-local cell; the
// `if` lives here (a tor continuation, the sanctioned place) rather than
// in the route arm where __koru_continue splices leak.
// extra_headers carries Location + Set-Cookie; NULL user_agent binds NULL.
pub tor session-login { email: ?string, password: ?string, user_agent: ?string } -> orisha:Response
session-login =
    koru/sqlite3:open(path: "seed/production.sqlite3")
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT id, password_digest FROM users
            WHERE email_address = {{email}} AND status = 0
        }
        ! row r |> koru/sqlite3:col.text(stmt: r, index: 1): dg
                |> bcrypt:verify(password, digest: dg): ok
                |> koru/sqlite3:col.int(stmt: r, index: 0): uid
                |> session:stash-if(ok, uid)
        | done d2 |> session:take-uid(): uid2
                  |> if(uid2 > 0)
                    | then |> session:new-token(): tok
                           |> session:redirect-headers(token: tok): hdr
                           |> koru/sqlite3:default(conn: d2) {
                               INSERT INTO sessions
                                   (user_id, token, user_agent, ip_address,
                                    last_active_at, created_at, updated_at)
                               VALUES ({{uid2}}, {{tok}}, {{user_agent}}, '',
                                       datetime('now'), datetime('now'), datetime('now'))
                           }
                           | done d3 |> koru/sqlite3:close(conn: d3) -> { status: 302, body: "", content_type: "text/plain", extra_headers: hdr }
                           | err e3 |> koru/sqlite3:close(e3.conn) -> { status: 500, body: "session insert failed", content_type: "text/plain", extra_headers: null }
                    | else |> koru/sqlite3:close(conn: d2) -> { status: 401, body: "unauthorized", content_type: "text/html", extra_headers: null }
        | err e |> koru/sqlite3:close(e.conn) -> { status: 500, body: "query failed", content_type: "text/plain", extra_headers: null }
    | err _ -> { status: 500, body: "db open failed", content_type: "text/plain", extra_headers: null }

// find_session_by_cookie: session_token -> sessions.token -> user's
// email. NULL/unknown token -> NULL -> downstream queries return nothing
// (Rails would redirect to /session/new; a 204-for-anonymous is the
// visible divergence until a real auth gate exists).
// No cookie -> no session lookup: sqlite open+query+close is ~25µs of
// wasted work per anonymous hit (measured: anon /rooms fell to 21.6k rps
// against rust-direct's 58k before this guard).
pub tor current-email { token: ?string } -> ?string
current-email =
    if(token != null)
    | then |> session-email(token): ue -> ue
    | else -> null

pub tor session-email { token: ?string } -> ?string
session-email =
    koru/sqlite3:open(path: "seed/production.sqlite3")
    | db d2 |> koru/sqlite3:default(conn: d2) {
            SELECT u.email_address FROM sessions s
            JOIN users u ON u.id = s.user_id
            WHERE s.token = {{token}}
        }
        ! row r |> koru/sqlite3:col.text(stmt: r, index: 0): e |> session:stash-text(text: e)
        | done d3 |> koru/sqlite3:close(conn: d3) |> session:take-text(): ue -> ue
        | err e2 |> koru/sqlite3:close(e2.conn) |> std/io:print.ln("current-email query err {{ e2.code:d }} {{ e2.msg:s }}") -> null
    | err oe |> std/io:print.ln("current-email open err {{ oe.code:d }} {{ oe.msg:s }}") -> null

// WelcomeController#show: signed in -> redirect to a room (last-room
// cookie unimplemented; first non-direct membership stands in for
// default_room). Anonymous -> /session/new, matching
// require_authentication's redirect.
pub tor landing { token: ?string } -> orisha:Response
landing =
    koru/sqlite3:open(path: "seed/production.sqlite3")
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT r.id FROM memberships m
            JOIN rooms r ON r.id = m.room_id
            WHERE m.user_id = (SELECT u.id FROM users u
                               JOIN sessions s ON s.user_id = u.id
                               WHERE s.token = {{token}})
              AND r.type != 'Rooms::Direct'
            ORDER BY LOWER(r.name) LIMIT 1
        }
        ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): rid |> session:stash-if(ok: true, uid: rid)
        | done d2 |> koru/sqlite3:close(conn: d2) |> session:take-uid(): rid2
                  |> if(rid2 > 0)
                    | then |> session:room-path(rid: rid2): p |> session:redirect-to(path: p): hdr -> { status: 302, body: "", content_type: "text/plain", extra_headers: hdr }
                    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
        | err e -> { status: 500, body: "query failed", content_type: "text/plain", extra_headers: null }
    | err _ -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }

// ============================================================================
// HANDLER
// ============================================================================

orisha:handler = orisha:router(req)
! [GET /]            |> orisha:cookie(req, name: "session_token"): tok |> landing(token: tok): res -> res
! [GET /up]          -> { status: 200, body: "OK",   content_type: "text/plain" }
! [GET /session/new] |> sign-in-page(): page -> { status: 200, body: page, content_type: "text/html" }
! [POST /session] |> orisha:form(req, name: "email_address"): email
                  |> orisha:form(req, name: "password"): password
                  |> orisha:header(req, name: "User-Agent"): ua
                  |> session-login(email, password, user_agent: ua): res -> res
! [GET /rooms/:id] p |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> room-page(p.id): page -> { status: 200, body: page, content_type: "text/html" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [GET /rooms/:id/messages] p |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> orisha:query-param(req, name: "before"): before
    |> if(ue != null)
    | then |> messages-page(p.id, before): page |> pages:page-status(): code -> { status: code, body: page, content_type: "text/html" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [GET /users/me/sidebar] |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> sidebar-page(user_email: ue): page |> pages:page-status(): code -> { status: code, body: page, content_type: "text/html" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [GET /searches] |> orisha:cookie(req, name: "session_token"): tok |> orisha:query-param(req, name: "q"): q |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> search-page(user_email: ue, q): page |> pages:page-status(): code -> { status: code, body: page, content_type: "text/html" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [*]                -> { status: 404, body: "Not Found", content_type: "text/plain" }

orisha:serve(port: 3109)
| shutdown s |> std/io:print.ln(s)
| failed   f |> std/io:print.ln(f)
