// once-campfire-koru — Campfire-shaped app in Koru/Orisha.
//
// Target: bench/compare_http.rb surface — /up, sign-in flow, room page,
// messages, sidebar, search — against the Rails SQLite schema (db/schema.sql,
// verbatim from once-campfire-rust's crates/db/src/schema.sql).

import orisha
import orisha/pump
import koru/sqlite3
import avatar
import bcrypt
import cable
import config
import messages
import pages
import session
import signing
import views
import std/io
import std/fmt
import std/build

// A build flag picks the LOOP; it does not pick the machine. --build=linux
// on a Linux host builds native + epoll; on macOS it emits the epoll loop
// in a Mach-O (harmless trap, documented). No build:config target is set —
// any explicit triple flips zig to cross-compile mode where system lib
// paths are empty and `-lsqlite3`/`-lz` cannot resolve.

// ============================================================================
// PAGES — the room page lives in views/ on koru/dom components; sign-in is
// still a stub string (a real component when it earns one).
// ============================================================================

pub tor sign-in-page {} -> string

sign-in-page -> "<!DOCTYPE html><html><head><meta name=\"csrf-token\" content=\"dev-token\"></head><body><h1>Sign in</h1><form action=\"/session\" method=\"post\"><input name=\"email_address\"><input name=\"password\" type=\"password\"><button>Sign in</button></form></body></html>"

// Messages index (Message::Pagination): last PAGE_SIZE=40 ordered by
// created_at. `before=<id>` narrows to created_at < that message's. Same
// visibility scope and same Msg partial as the room page — the contract
// audits data-message-id and the message_<cmid> DOM identity on every row.
// Empty page -> 204, matching the controller's head :no_content. (`if`
// inside a route-branch continuation leaks __koru_continue_N splices —
// repro/if-in-route-branch.k — so the 200/204 decision lives in
// pages:page-status.)
pub tor messages-page { id: string, before: ?string, email: ?string } -> string
messages-page = pages:page-begin()
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
        SELECT m.id, m.client_message_id, m.created_at, m.updated_at,
               u.name, u.id, u.updated_at, rt.body, u.bio, r.name
        FROM (
            SELECT m2.id, m2.client_message_id, m2.created_at,
                   m2.updated_at, m2.creator_id, m2.room_id
            FROM messages m2
            WHERE m2.room_id = {{id}}
              AND ({{before}} IS NULL OR m2.created_at < (SELECT created_at FROM messages WHERE id = {{before}}))
              AND EXISTS(SELECT 1 FROM memberships mm
                         JOIN users uu ON uu.id = mm.user_id
                         WHERE mm.room_id = m2.room_id
                           AND uu.email_address = {{email}}
                           AND mm.involvement != 'invisible')
            ORDER BY m2.created_at DESC LIMIT 40
        ) m
        JOIN action_text_rich_texts rt
          ON rt.record_type='Message' AND rt.record_id = m.id
        JOIN users u ON u.id = m.creator_id
        JOIN rooms r ON r.id = m.room_id
        ORDER BY m.created_at
        }
        ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): mid
                |> koru/sqlite3:col.text(stmt: r, index: 1): cid
                |> koru/sqlite3:col.text(stmt: r, index: 2): cat
                |> koru/sqlite3:col.text(stmt: r, index: 3): uat
                |> koru/sqlite3:col.text(stmt: r, index: 4): anm
                |> koru/sqlite3:col.int(stmt: r, index: 5): uid
                |> koru/sqlite3:col.text(stmt: r, index: 6): auat
                |> koru/sqlite3:col.text(stmt: r, index: 7): body
                |> koru/sqlite3:col.text(stmt: r, index: 8): abio
                |> koru/sqlite3:col.text(stmt: r, index: 9): rname
                |> views:user-title(name: anm, bio: abio): atitle
                |> views:ts-iso(ts: cat): iso
                |> views:ts-ms(ts: cat): ms
                |> views:ts-ms(ts: uat): ums
                |> views:ts-ver(ts: auat): uver
                |> signing:user-sgid(id: uid): usg
                |> views:message-render(cmid: cid, mid, uid, rid: id, ms, ums, iso,
                                        author: anm, atitle, uver, usgid: usg,
                                        roomname: rname, body, boosts: ""): mt
                |> pages:page-write(text: mt)
                |> std/io:free(content: mt)
        | done d2 |> koru/sqlite3:close.pooled(conn: d2) |> pages:page-take(): body -> body
        | err e |> koru/sqlite3:close.pooled(e.conn) -> "query failed"
    | err _ -> "db open failed"

// Sidebar (Users::SidebarsController): visible memberships for the user,
// directs (Rooms::Direct) sorted by room.updated_at desc, the rest by
// LOWER(name); then placeholder users not already in a direct room.
// user_email stands in for Current.user until sessions land.
// Sidebar (Users::SidebarsController): the turbo-frame carries the two
// Turbo::StreamsChannel sources the loadgen scrapes — shared "rooms" plus
// the per-user room stream — then directs, shared rooms, and placeholders.
// Contract surface: the literal shared_rooms section id and every visible
// Rooms::Open name, escaped.
pub tor sidebar-page { user_email: ?string } -> string
sidebar-page = pages:page-begin()
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT u.id, u.name, u.role, u.updated_at FROM users u
            WHERE u.email_address = {{user_email}} AND u.status = 0
        }
        ! row ur |> koru/sqlite3:col.int(stmt: ur, index: 0): uuid
                 |> koru/sqlite3:col.text(stmt: ur, index: 1): unm
                 |> koru/sqlite3:col.int(stmt: ur, index: 2): urole
                 |> koru/sqlite3:col.text(stmt: ur, index: 3): uat0
                 |> views:ts-ver(ts: uat0): uver1
                 |> views:stash-user(uid: uuid, name: unm, role: urole, ver: uver1)
        | done d2 |> pages:page-write(text: "<!DOCTYPE html><html><body><turbo-frame id=\"user_sidebar\" target=\"_top\">")
                  |> signing:rooms-stream(): rs
                  |> pages:page-write(text: "<turbo-cable-stream-source channel=\"Turbo::StreamsChannel\" signed-stream-name=\"")
                  |> pages:page-write(text: rs)
                  |> pages:page-write(text: "\"></turbo-cable-stream-source>")
                  |> views:user-id(): uid0
                  |> signing:user-rooms-stream(id: uid0): urs
                  |> pages:page-write(text: "<turbo-cable-stream-source channel=\"Turbo::StreamsChannel\" signed-stream-name=\"")
                  |> pages:page-write(text: urs)
                  |> pages:page-write(text: "\"></turbo-cable-stream-source><div class=\"sidebar__container\"><div id=\"direct_rooms\" contents>")
                  |> koru/sqlite3:default(conn: d2) {
                      SELECT r.id, COALESCE(r.name, ou.name, '')
                      FROM memberships m
                      JOIN rooms r ON r.id = m.room_id
                      LEFT JOIN memberships om ON om.room_id = r.id AND om.user_id != m.user_id
                      LEFT JOIN users ou ON ou.id = om.user_id
                      WHERE m.user_id = (SELECT id FROM users WHERE email_address = {{user_email}})
                        AND m.involvement != 'invisible'
                        AND r.type = 'Rooms::Direct'
                      ORDER BY r.updated_at DESC
                      }
                      ! row dr |> koru/sqlite3:col.text(stmt: dr, index: 0): drid
                              |> koru/sqlite3:col.text(stmt: dr, index: 1): dn
                              |> views:html-esc(text: dn): dne
                              |> pages:page-write(text: "<a class=\"direct\" id=\"list_rooms_direct_")
                              |> pages:page-write(text: drid)
                              |> pages:page-write(text: "\" href=\"/rooms/")
                              |> pages:page-write(text: drid)
                              |> pages:page-write(text: "\"><span class=\"direct__author\">")
                              |> pages:page-write(text: dne)
                              |> pages:page-write(text: "</span></a>")
                      | done d3 |> pages:page-write(text: "</div><div class=\"rooms\"><div id=\"shared_rooms\" contents>")
                              |> koru/sqlite3:default(conn: d3) {
                                  SELECT r.id, r.name,
                                    CASE r.type WHEN 'Rooms::Open' THEN 'open'
                                                WHEN 'Rooms::Closed' THEN 'closed'
                                                ELSE 'room' END
                                  FROM memberships m
                                  JOIN rooms r ON r.id = m.room_id
                                  WHERE m.user_id = (SELECT id FROM users WHERE email_address = {{user_email}})
                                    AND m.involvement != 'invisible'
                                    AND r.type != 'Rooms::Direct'
                                  ORDER BY LOWER(r.name)
                                  }
                                  ! row r2 |> koru/sqlite3:col.text(stmt: r2, index: 0): srid
                                          |> koru/sqlite3:col.text(stmt: r2, index: 1): rn2
                                          |> views:html-esc(text: rn2): rne
                                          |> koru/sqlite3:col.text(stmt: r2, index: 2): rk
                                          |> pages:page-write(text: "<a id=\"list_rooms_")
                                          |> pages:page-write(text: rk)
                                          |> pages:page-write(text: "_")
                                          |> pages:page-write(text: srid)
                                          |> pages:page-write(text: "\" data-room-id=\"")
                                          |> pages:page-write(text: srid)
                                          |> pages:page-write(text: "\" href=\"/rooms/")
                                          |> pages:page-write(text: srid)
                                          |> pages:page-write(text: "\"><span class=\"overflow-ellipsis\">")
                                          |> pages:page-write(text: rne)
                                          |> pages:page-write(text: "</span></a>")
                                  | done d4 |> pages:page-write(text: "</div></div><div class=\"directs__placeholder\"><h2>People</h2>")
                                          |> koru/sqlite3:default(conn: d4) {
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
                                              ! row r3 |> koru/sqlite3:col.text(stmt: r3, index: 0): puid
                                                      |> koru/sqlite3:col.text(stmt: r3, index: 1): pn
                                                      |> views:html-esc(text: pn): pne
                                                      |> pages:page-write(text: "<span class=\"direct__author\" data-user-id=\"")
                                                      |> pages:page-write(text: puid)
                                                      |> pages:page-write(text: "\">")
                                                      |> pages:page-write(text: pne)
                                                      |> pages:page-write(text: "</span>")
                                              | done d5 |> koru/sqlite3:close.pooled(conn: d5)
                                                      |> pages:page-write(text: "</div></div></turbo-frame></body></html>")
                                                      |> pages:page-take(): body -> body
                                              | err e4 |> koru/sqlite3:close.pooled(e4.conn) -> "q3 failed"
                                  | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> "q2 failed"
                      | err e2 |> koru/sqlite3:close.pooled(e2.conn) -> "q1 failed"
        | err eu |> koru/sqlite3:close.pooled(eu.conn) -> "user query failed"
    | err _ -> "db open failed"

// Search (SearchesController): FTS5 phrase match over message_search_index,
// scoped to rooms the user is a member of (reachable_messages), last 100.
// The window and order mirror the contract's own SQL: m.id DESC LIMIT 100,
// rendered ascending. NULL query -> no rows -> 204, matching
// `@messages = Message.none`. Rows render through the same Msg partial as
// the room page — DOM identity and data-message-id ride along.
pub tor search-page { user_email: ?string, q: ?string } -> string
search-page = pages:page-begin()
    |> if(q == null)
    | then -> ""
    | else |> pages:page-write(text: "<!DOCTYPE html><html><body><div class=\"search-results\">")
           |> search-rows(user_email, q): body -> body

tor search-rows { user_email: ?string, q: ?string } -> string
search-rows = config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
        SELECT m.id, m.client_message_id, m.created_at, m.updated_at,
               u.name, u.id, u.updated_at, rt.body, u.bio, r.name
        FROM (
            SELECT m2.id, m2.client_message_id, m2.created_at,
                   m2.updated_at, m2.creator_id, m2.room_id
            FROM messages m2
            JOIN message_search_index idx ON m2.id = idx.rowid
            JOIN memberships mm ON mm.room_id = m2.room_id
            JOIN users uu ON uu.id = mm.user_id
            WHERE uu.email_address = {{user_email}}
              AND {{q}} IS NOT NULL
              AND idx.body MATCH '"' || replace({{q}}, '"', '""') || '"'
            ORDER BY m2.id DESC LIMIT 100
        ) m
        JOIN action_text_rich_texts rt
          ON rt.record_type='Message' AND rt.record_id = m.id
        JOIN users u ON u.id = m.creator_id
        JOIN rooms r ON r.id = m.room_id
        ORDER BY m.id
        }
        ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): mid
                |> koru/sqlite3:col.text(stmt: r, index: 1): cid
                |> koru/sqlite3:col.text(stmt: r, index: 2): cat
                |> koru/sqlite3:col.text(stmt: r, index: 3): uat
                |> koru/sqlite3:col.text(stmt: r, index: 4): anm
                |> koru/sqlite3:col.int(stmt: r, index: 5): uid
                |> koru/sqlite3:col.text(stmt: r, index: 6): auat
                |> koru/sqlite3:col.text(stmt: r, index: 7): body
                |> koru/sqlite3:col.text(stmt: r, index: 8): abio
                |> koru/sqlite3:col.text(stmt: r, index: 9): rname
                |> views:user-title(name: anm, bio: abio): atitle
                |> views:ts-iso(ts: cat): iso
                |> views:ts-ms(ts: cat): ms
                |> views:ts-ms(ts: uat): ums
                |> views:ts-ver(ts: auat): uver
                |> signing:user-sgid(id: uid): usg
                |> views:message-render(cmid: cid, mid, uid, rid: "", ms, ums, iso,
                                        author: anm, atitle, uver, usgid: usg,
                                        roomname: rname, body, boosts: ""): mt
                |> pages:page-write(text: mt)
                |> std/io:free(content: mt)
        | done d2 |> koru/sqlite3:close.pooled(conn: d2)
                |> pages:page-write(text: "</div></body></html>")
                |> pages:page-take(): body -> body
        | err e |> koru/sqlite3:close.pooled(e.conn) -> "query failed"
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
    config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
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
                           |> signing:cookie-header(token: tok): cv
                           |> session:redirect-signed(cookie: cv): hdr
                           |> koru/sqlite3:default(conn: d2) {
                               INSERT INTO sessions
                                   (user_id, token, user_agent, ip_address,
                                    last_active_at, created_at, updated_at)
                               VALUES ({{uid2}}, {{tok}}, {{user_agent}}, '',
                                       datetime('now'), datetime('now'), datetime('now'))
                           }
                           | done d3 |> koru/sqlite3:close.pooled(conn: d3) -> { status: 302, body: "", content_type: "text/plain", extra_headers: hdr }
                           | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> { status: 500, body: "session insert failed", content_type: "text/plain", extra_headers: null }
                    | else |> koru/sqlite3:close.pooled(conn: d2) -> { status: 401, body: "unauthorized", content_type: "text/html", extra_headers: null }
        | err e |> koru/sqlite3:close.pooled(e.conn) -> { status: 500, body: "query failed", content_type: "text/plain", extra_headers: null }
    | err _ -> { status: 500, body: "db open failed", content_type: "text/plain", extra_headers: null }

// find_session_by_cookie: session_token -> sessions.token -> user's
// email. The cookie value is the Rails-signed blob — cookie-verify answers
// the raw token or nil for absent/tampered/expired; nil -> NULL -> no rows
// (Rails would redirect to /session/new; a 204-for-anonymous is the
// visible divergence until a real auth gate exists).
// No cookie -> no session lookup: sqlite open+query+close is ~25µs of
// wasted work per anonymous hit (measured: anon /rooms fell to 21.6k rps
// against rust-direct's 58k before this guard).
pub tor current-email { token: ?string } -> ?string
current-email =
    if(token != null)
    | then |> signing:cookie-verify(raw: token): vt |> session-email(token: vt): ue -> ue
    | else -> null

pub tor session-email { token: ?string } -> ?string
session-email =
    config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d2 |> koru/sqlite3:default(conn: d2) {
            SELECT u.email_address FROM sessions s
            JOIN users u ON u.id = s.user_id
            WHERE s.token = {{token}}
        }
        ! row r |> koru/sqlite3:col.text(stmt: r, index: 0): e |> session:stash-text(text: e)
        | done d3 |> koru/sqlite3:close.pooled(conn: d3) |> session:take-text(): ue -> ue
        | err e2 |> koru/sqlite3:close.pooled(e2.conn) |> std/io:print.ln("current-email query err {{ e2.code:d }} {{ e2.msg:s }}") -> null
    | err oe |> std/io:print.ln("current-email open err {{ oe.code:d }} {{ oe.msg:s }}") -> null

// WelcomeController#show: signed in -> redirect to a room (last-room
// cookie unimplemented; first non-direct membership stands in for
// default_room). Anonymous -> /session/new, matching
// require_authentication's redirect.
pub tor landing { token: ?string } -> orisha:Response
landing =
    signing:cookie-verify(raw: token): vtok
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT r.id FROM memberships m
            JOIN rooms r ON r.id = m.room_id
            WHERE m.user_id = (SELECT u.id FROM users u
                               JOIN sessions s ON s.user_id = u.id
                               WHERE s.token = {{vtok}})
              AND r.type != 'Rooms::Direct'
            ORDER BY LOWER(r.name) LIMIT 1
        }
        ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): rid |> session:stash-if(ok: true, uid: rid)
        | done d2 |> koru/sqlite3:close.pooled(conn: d2) |> session:take-uid(): rid2
                  |> if(rid2 > 0)
                    | then |> session:room-path(rid: rid2): p |> session:redirect-to(path: p): hdr -> { status: 302, body: "", content_type: "text/plain", extra_headers: hdr }
                    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
        | err e |> koru/sqlite3:close.pooled(e.conn) -> { status: 500, body: "query failed", content_type: "text/plain", extra_headers: null }
    | err _ -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }

// ============================================================================
// AVATAR — Users::AvatarsController#show. The route verifies the signed id
// (signing:sgid-verify) then this lookup walks users → User/avatar
// attachment → :square variant record → VariantRecord/image attachment →
// blob key, and serves the disk file as image/webp. No attachment renders
// the initials SVG (or the default bot avatar when role = bot); a signed
// token naming no user 404s — find_signed! raises RecordNotFound there.
// ============================================================================

pub tor avatar-lookup { uid: i64 } -> orisha:Response
avatar-lookup =
    avatar:av-reset()
    |> config:db-path(): dbp
    |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT u.role, u.name, vb.key FROM users u
              LEFT JOIN active_storage_attachments aa
                ON aa.record_type = 'User' AND aa.record_id = u.id AND aa.name = 'avatar'
              LEFT JOIN active_storage_variant_records vr
                ON vr.blob_id = aa.blob_id
               AND vr.variation_digest = '6gwfjNKv9eUy9jNUtEZvQFLU0hQ='
              LEFT JOIN active_storage_attachments va
                ON va.record_type = 'ActiveStorage::VariantRecord' AND va.record_id = vr.id AND va.name = 'image'
              LEFT JOIN active_storage_blobs vb ON vb.id = va.blob_id
            WHERE u.id = {{uid}}
        }
        ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): role
                |> koru/sqlite3:col.text(stmt: r, index: 1): nm
                |> koru/sqlite3:col.text(stmt: r, index: 2): key
                |> avatar:av-stash(role, name: nm, key)
        | done d2 |> koru/sqlite3:close.pooled(conn: d2) |> avatar-respond(uid): res -> res
        | err e |> koru/sqlite3:close.pooled(e.conn) -> { status: 500, body: "avatar query failed", content_type: "text/plain", extra_headers: null }
    | err _ -> { status: 500, body: "db open failed", content_type: "text/plain", extra_headers: null }

// done side: av-role -1 = signed token for a user that isn't there
// (RecordNotFound → 404). A variant key reads the blob file off the disk
// root; missing file on disk is a broken install → 500, not a fallback.
// No attachment: bots (role 2) get default-bot-avatar.svg from the embedded
// asset dir, everyone else gets the initials render.
pub tor avatar-respond { uid: i64 } -> orisha:Response
avatar-respond =
    avatar:av-role(): role
    |> avatar:av-key(): key
    |> if(role < 0)
    | then -> { status: 404, body: "", content_type: "text/plain", extra_headers: null }
    | else |> if(key != "")
        | then |> avatar:blob-path(key): fp
               |> avatar:read-blob(path: fp)
               | ok blob -> { status: 200, body: blob, content_type: "image/webp", body_allocated: true, extra_headers: "Cache-Control: max-age=1800, public, stale-while-revalidate=604800\r\n" }
               | missing -> { status: 500, body: "blob missing on disk", content_type: "text/plain", extra_headers: null }
               | failed -> { status: 500, body: "blob read failed", content_type: "text/plain", extra_headers: null }
        | else |> if(role == 2)
            | then |> avatar:read-blob(path: "public/assets/default-bot-avatar-de1d12f7.svg")
                   | ok svg -> { status: 200, body: svg, content_type: "image/svg+xml", body_allocated: true, extra_headers: null }
                   | missing -> { status: 404, body: "", content_type: "text/plain", extra_headers: null }
                   | failed -> { status: 500, body: "asset read failed", content_type: "text/plain", extra_headers: null }
            | else |> avatar:initials-svg(uid): svg -> { status: 200, body: svg, content_type: "image/svg+xml; charset=utf-8", extra_headers: "Cache-Control: max-age=1800, public, stale-while-revalidate=604800\r\n" }

// ============================================================================
// HANDLER
// ============================================================================

// Propshaft's digested tree, materialized into public/assets/ at build time
// and embedded by orisha:static — the embed root maps to /, so the files land
// at the /assets/* paths the pages emit. A miss 404s (no fallback — an asset
// miss is a bug, not a route).
orisha:static(name: "assets", root: "public")

orisha:handler = orisha:router(req)
! [GET /]            |> orisha:cookie(req, name: "session_token"): tok |> landing(token: tok): res -> res
! [GET /up]          -> { status: 200, body: "<!DOCTYPE html><html><body style=\"background-color: green\"></body></html>", content_type: "text/html" }
! [GET /session/new] |> sign-in-page(): page -> { status: 200, body: page, content_type: "text/html" }
! [POST /session] |> orisha:form(req, name: "email_address"): email
                  |> orisha:form(req, name: "password"): password
                  |> orisha:header(req, name: "User-Agent"): ua
                  |> session-login(email, password, user_agent: ua): res -> res
! [GET /rooms/:id] p |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> orisha:header(req, name: "Host"): hst |> views:room-page(rid: p.id, email: ue, host: hst): page |> pages:page-status-or(status: 404): code -> { status: code, body: page, content_type: "text/html", cacheable: true }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [GET /rooms/:id/messages] p |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> orisha:query-param(req, name: "before"): before
    |> if(ue != null)
    | then |> messages-page(p.id, before, email: ue): page |> pages:page-status(): code -> { status: code, body: page, content_type: "text/html", cacheable: true }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [POST /rooms/:id/messages] p |> orisha:cookie(req, name: "session_token"): tok
    |> signing:cookie-verify(raw: tok): vtok
    |> orisha:form(req, name: "message[body]"): mbody
    |> orisha:form(req, name: "message[client_message_id]"): mcmid
    |> messages:create(rid: p.id, token: vtok, body: mbody, cmid: mcmid): res -> res
! [GET /users/me/sidebar] |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> sidebar-page(user_email: ue): page |> pages:page-status(): code -> { status: code, body: page, content_type: "text/html", cacheable: true }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [GET /searches] |> orisha:cookie(req, name: "session_token"): tok |> orisha:query-param(req, name: "q"): q |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> search-page(user_email: ue, q): page |> pages:page-status(): code -> { status: code, body: page, content_type: "text/html", cacheable: true }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [GET /cable]       |> cable:route(req): res -> res
! [GET /users/:token/avatar] p |> signing:sgid-verify(raw: p.token): uid
    |> if(uid > 0)
    | then |> avatar-lookup(uid): res -> res
    | else -> { status: 404, body: "", content_type: "text/plain" }
! [*] |> orisha:static-router(name: "assets")

// Cable seams — a complete client message dispatches on the connection's fd;
// teardown owes Membership#disconnected per presence sub via ! gone-room.
orisha/pump:ws-frame = orisha/pump:raw(x: f): payload
    |> orisha/pump:fileno(x: f): fd
    |> cable:dispatch(fd, payload)

orisha/pump:ws-closed = cable:dropped(fd)
    ! gone-room g |> cable:gone(g)
    | ok |> _
    | stale |> _

config:port(): http-port
|> orisha:serve(port: http-port)
| shutdown s |> std/io:print.ln(s)
| failed   f |> std/io:print.ln(f)
