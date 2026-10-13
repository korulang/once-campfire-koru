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
import qr
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
pub tor messages-page { id: string, before: ?string, email: ?string,
                        host: ?string } -> string
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
                                        roomname: rname, body, boosts: "",
                                        host): mt
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
            SELECT u.id, u.name, u.role, u.updated_at,
                   COALESCE(json_extract(a.settings,'$.restrict_room_creation_to_administrators'),0)
            FROM users u CROSS JOIN accounts a
            WHERE u.email_address = {{user_email}} AND u.status = 0
        }
        ! row ur |> koru/sqlite3:col.int(stmt: ur, index: 0): uuid
                 |> koru/sqlite3:col.text(stmt: ur, index: 1): unm
                 |> koru/sqlite3:col.int(stmt: ur, index: 2): urole
                 |> koru/sqlite3:col.text(stmt: ur, index: 3): uat0
                 |> koru/sqlite3:col.int(stmt: ur, index: 4): urst
                 |> views:ts-ver(ts: uat0): uver1
                 |> views:stash-user(uid: uuid, name: unm, role: urole, ver: uver1)
                 |> views:acct-stash(name: "", join: "", restrict: urst)
        | done d2 |> pages:page-write(text: "<!DOCTYPE html><html><body><turbo-frame data-turbo-permanent=\"true\" data-controller=\"rooms-list read-rooms turbo-frame\" data-rooms-list-unread-class=\"unread\" data-action=\"presence:present@window-&gt;rooms-list#read read-rooms:read-&gt;rooms-list#read turbo:frame-load-&gt;rooms-list#loaded refresh-room:visible@window-&gt;turbo-frame#reload\" id=\"user_sidebar\" target=\"_top\">")
                  |> signing:rooms-stream(): rs
                  |> pages:page-write(text: "<turbo-cable-stream-source channel=\"Turbo::StreamsChannel\" signed-stream-name=\"")
                  |> pages:page-write(text: rs)
                  |> pages:page-write(text: "\"></turbo-cable-stream-source>")
                  |> views:user-id(): uid0
                  |> signing:user-rooms-stream(id: uid0): urs
                  |> pages:page-write(text: "<turbo-cable-stream-source channel=\"Turbo::StreamsChannel\" signed-stream-name=\"")
                  |> pages:page-write(text: urs)
                  |> pages:page-write(text: "\"></turbo-cable-stream-source><div class=\"sidebar__container overflow-y overflow-hide-scrollbar\" data-controller=\"badge-dot\" data-badge-dot-unread-class=\"unread\" data-action=\"rooms-list:unread@window-&gt;badge-dot#update rooms-list:read@window-&gt;badge-dot#update turbo:submit-start-&gt;turbo-frame#unpermanize\"><turbo-frame id=\"direct_rooms_control\" target=\"_top\"><div class=\"directs gap overflow-x overflow-hide-scrollbar\"><a class=\"direct direct__new\" data-turbo-frame=\"_self\" href=\"/rooms/directs/new\"><span class=\"avatar avatar--icon\"><img aria-hidden=\"true\" class=\"colorize--black\" src=\"/assets/messages-add-d229e6c2.svg\" width=\"20\" height=\"20\" /></span><span class=\"direct__author flex max-width min-width border-radius pad-inline-half\"><span class=\"for-screen-reader\">New</span><span class=\"txt-small overflow-clip\">Ping</span></span></a><div id=\"direct_rooms\" contents data-controller=\"sorted-list\" data-action=\"rooms-list:unread@window-&gt;sorted-list#updateItem\">")
                  |> koru/sqlite3:default(conn: d2) {
                      SELECT r.id, COALESCE(ou.name, ''), ou.id, ou.updated_at
                      FROM memberships m
                      JOIN rooms r ON r.id = m.room_id
                      LEFT JOIN memberships om ON om.room_id = r.id AND om.user_id != m.user_id
                      LEFT JOIN users ou ON ou.id = om.user_id
                      WHERE m.user_id = (SELECT id FROM users WHERE email_address = {{user_email}})
                        AND m.involvement != 'invisible'
                        AND r.type = 'Rooms::Direct'
                      ORDER BY r.updated_at DESC
                      }
                      ! row dr |> koru/sqlite3:col.int(stmt: dr, index: 0): drid
                              |> koru/sqlite3:col.text(stmt: dr, index: 1): dn
                              |> koru/sqlite3:col.int(stmt: dr, index: 2): duid
                              |> koru/sqlite3:col.text(stmt: dr, index: 3): duat
                              |> views:ts-ver(ts: duat): dver
                              |> signing:user-sgid(id: duid): dsg
                              |> views:first-name(name: dn): dfn
                              |> views:itoa(n: drid): drids
                              |> views:direct-link(rid: drids, name: dfn, sgid: dsg, ver: dver): dlink
                              |> pages:page-write(text: dlink)
                      | done d3 |> pages:page-write(text: "</div><div contents>")
                              |> koru/sqlite3:default(conn: d3) {
                                  SELECT u.id, u.name, u.updated_at FROM users u
                                  WHERE u.status = 0 AND u.role != 2
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
                                  ! row r3 |> koru/sqlite3:col.int(stmt: r3, index: 0): puid
                                          |> koru/sqlite3:col.text(stmt: r3, index: 1): pn
                                          |> koru/sqlite3:col.text(stmt: r3, index: 2): puat
                                          |> views:ts-ver(ts: puat): pver
                                          |> signing:user-sgid(id: puid): psg
                                          |> views:first-name(name: pn): pfn
                                          |> views:ping-btn(uid: puid, name: pfn, sgid: psg, ver: pver): pbtn
                                          |> pages:page-write(text: pbtn)
                                  | done d4 |> pages:page-write(text: "</div></div></turbo-frame><div class=\"rooms position-relative flex flex-column gap\"><div id=\"shared_rooms\" contents data-controller=\"sorted-list\">")
                                          |> koru/sqlite3:default(conn: d4) {
                                              SELECT r.id, r.name,
                                                CASE r.type WHEN 'Rooms::Open' THEN 'rooms_open'
                                                            WHEN 'Rooms::Closed' THEN 'rooms_closed'
                                                            ELSE 'rooms_room' END
                                              FROM memberships m
                                              JOIN rooms r ON r.id = m.room_id
                                              WHERE m.user_id = (SELECT id FROM users WHERE email_address = {{user_email}})
                                                AND m.involvement != 'invisible'
                                                AND r.type != 'Rooms::Direct'
                                              ORDER BY LOWER(r.name)
                                              }
                                              ! row r2 |> koru/sqlite3:col.int(stmt: r2, index: 0): srid
                                                      |> koru/sqlite3:col.text(stmt: r2, index: 1): rn2
                                                      |> koru/sqlite3:col.text(stmt: r2, index: 2): rk
                                                      |> views:itoa(n: srid): srids
                                                      |> views:room-link(rk, rid: srids, name: rn2): rlink
                                                      |> pages:page-write(text: rlink)
                                              | done d5 |> koru/sqlite3:close.pooled(conn: d5)
                                                      |> pages:page-write(text: "</div>")
                                                      |> views:user-role(): uro
                                                      |> views:acct-restrict(): rst
                                                      |> views:new-room-btn(role: uro, restrict: rst): nrb
                                                      |> pages:page-write(text: nrb)
                                                      |> pages:page-write(text: "</div><button class=\"btn sidebar__toggle\" data-action=\"toggle-class#toggle\"><img aria-hidden=\"true\" src=\"/assets/menu-5462dfd3.svg\" width=\"20\" height=\"20\" /><span class=\"for-screen-reader\">Open menu</span></button></div><div class=\"flex align-end sidebar__tools gap justify-end\">")
                                                      |> views:user-id(): tuid
                                                      |> signing:user-sgid(id: tuid): tsg
                                                      |> views:user-ver(): tv
                                                      |> pages:page-write(text: "<a href=\"/users/me/profile\" class=\"btn avatar flex-item-no-shrink sidebar__tool\"><img aria-hidden=\"true\" src=\"/users/")
                                                      |> pages:page-write(text: tsg)
                                                      |> pages:page-write(text: "/avatar?v=")
                                                      |> pages:page-write(text: tv)
                                                      |> pages:page-write(text: "\" width=\"48\" height=\"48\" style=\"view-transition-name: avatar-")
                                                      |> views:itoa(n: tuid): tuids
                                                      |> pages:page-write(text: tuids)
                                                      |> pages:page-write(text: "\" /></a><a href=\"/account/edit\" class=\"btn align-center gap txt-reversed sidebar__tool\"><img aria-hidden=\"true\" src=\"/assets/settings-aee56972.svg\" width=\"20\" height=\"20\" style=\"view-transition-name: account-settings\" /><span class=\"for-screen-reader\">Account Settings</span></a></div></turbo-frame></body></html>")
                                                      |> pages:page-take(): body -> body
                                              | err e5 |> koru/sqlite3:close.pooled(e5.conn) -> "q4 failed"
                                  | err e4 |> koru/sqlite3:close.pooled(e4.conn) -> "q3 failed"
                      | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> "q2 failed"
        | err eu |> koru/sqlite3:close.pooled(eu.conn) -> "user query failed"
    | err _ -> "db open failed"

// Search (SearchesController): FTS5 phrase match over message_search_index,
// scoped to rooms the user is a member of (reachable_messages), last 100.
// The window and order mirror the contract's own SQL: m.id DESC LIMIT 100,
// rendered ascending. NULL query -> no rows -> 204, matching
// `@messages = Message.none`. Rows render through the same Msg partial as
// the room page — DOM identity and data-message-id ride along.
pub tor search-page { user_email: ?string, q: ?string, host: ?string } -> string
search-page = pages:page-begin()
    |> if(q == null)
    | then -> ""
    | else |> pages:page-write(text: "<!DOCTYPE html><html><body><div id=\"search-results\" class=\"messages searches__results\">")
           |> search-rows(user_email, q, host): body -> body

tor search-rows { user_email: ?string, q: ?string, host: ?string } -> string
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
                                        roomname: rname, body, boosts: "",
                                        host): mt
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
// FIRST RUN — FirstRunsController#show + #create, the installer.
// prevent_repeats gates both arms on Account.any?: once any account row
// exists the route is a permanent redirect to /, so the installer runs
// exactly once. The create mirrors FirstRun.create! — account ("Campfire",
// generated join_code), the administrator user, the "All Talk" open room,
// memberships.grant_to — then signs in with the same sessions insert +
// signed-cookie path SessionsController#create uses. Ids cross statements
// as email-addressed subqueries, not stashed cells.
// Honest approximations: the page omits the avatar file input and
// translation buttons (no multipart upload, no i18n yet); join_code keeps
// the reference's 3x4-grouped shape but over the hex alphabet.
// ============================================================================

pub tor first-run-page {} -> string

first-run-page -> "<!DOCTYPE html><html><head><title>Set up Campfire</title><meta name=\"csrf-token\" content=\"dev-token\"></head><body class=\"signup\"><form action=\"/first_run\" accept-charset=\"UTF-8\" method=\"post\" class=\"center max-width\"><fieldset><legend><strong>Set up Campfire</strong></legend><input class=\"input\" name=\"user[name]\" autocomplete=\"name\" placeholder=\"Name\" required=\"required\"><input class=\"input\" name=\"user[email_address]\" type=\"email\" autocomplete=\"username\" placeholder=\"Email address\" required=\"required\"><input class=\"input\" name=\"user[password]\" type=\"password\" autocomplete=\"new-password\" placeholder=\"Password\" required=\"required\" maxlength=\"72\"><button type=\"submit\">Save</button></fieldset></form></body></html>"

pub tor first-run-create { name: ?string, email: ?string, password: ?string, user_agent: ?string } -> orisha:Response
first-run-create =
    if(name != null and email != null and password != null)
    | then |> session:str-or(s: password): pw |> bcrypt:hash(password: pw, cost: 12): dg
           |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
           | db d |> koru/sqlite3:default(conn: d) {
                   SELECT COUNT(*) FROM accounts
               }
               ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): n |> session:stash-if(ok: true, uid: n)
               | done d2 |> session:take-uid(): accts
                         |> if(accts == 0)
                           | then |> koru/sqlite3:default(conn: d2) {
                                   INSERT INTO accounts
                                       (name, join_code, singleton_guard, created_at, updated_at)
                                   VALUES ('Campfire',
                                       (SELECT substr(j,1,4)||'-'||substr(j,5,4)||'-'||substr(j,9,4)
                                        FROM (SELECT lower(hex(randomblob(6))) AS j)),
                                       0, datetime('now'), datetime('now'))
                               }
                               | done d3 |> koru/sqlite3:default(conn: d3) {
                                       INSERT INTO users
                                           (name, email_address, password_digest, role, status, created_at, updated_at)
                                       VALUES ({{name}}, {{email}}, {{dg}}, 1, 0, datetime('now'), datetime('now'))
                                   }
                                   | done d4 |> koru/sqlite3:default(conn: d4) {
                                           INSERT INTO rooms (name, type, creator_id, created_at, updated_at)
                                           VALUES ('All Talk', 'Rooms::Open',
                                               (SELECT id FROM users WHERE email_address = {{email}}),
                                               datetime('now'), datetime('now'))
                                       }
                                       | done d5 |> koru/sqlite3:default(conn: d5) {
                                               INSERT INTO memberships (room_id, user_id, involvement, created_at, updated_at)
                                               SELECT r.id, u.id, 'mentions', datetime('now'), datetime('now')
                                               FROM rooms r JOIN users u ON u.id = r.creator_id
                                               WHERE u.email_address = {{email}}
                                               ORDER BY r.id DESC LIMIT 1
                                           }
                                           | done d6 |> session:new-token(): tok
                                                     |> signing:cookie-header(token: tok): cv
                                                     |> session:redirect-signed(cookie: cv): hdr
                                                     |> koru/sqlite3:default(conn: d6) {
                                                         INSERT INTO sessions
                                                             (user_id, token, user_agent, ip_address,
                                                              last_active_at, created_at, updated_at)
                                                         VALUES ((SELECT id FROM users WHERE email_address = {{email}}),
                                                             {{tok}}, {{user_agent}}, '',
                                                             datetime('now'), datetime('now'), datetime('now'))
                                                     }
                                                     | done d7 |> koru/sqlite3:close.pooled(conn: d7)
                                                               |> orisha:generation-bump() -> { status: 302, body: "", content_type: "text/plain", extra_headers: hdr }
                                                     | err e7 |> koru/sqlite3:close.pooled(e7.conn) -> { status: 500, body: "session insert failed", content_type: "text/plain", extra_headers: null }
                                           | err e6 |> koru/sqlite3:close.pooled(e6.conn) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /\r\n" }
                                       | err e5 |> koru/sqlite3:close.pooled(e5.conn) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /\r\n" }
                                   | err e4 |> koru/sqlite3:close.pooled(e4.conn) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /\r\n" }
                               | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /\r\n" }
                           | else |> koru/sqlite3:close.pooled(conn: d2) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /\r\n" }
               | err e |> koru/sqlite3:close.pooled(e.conn) -> { status: 500, body: "account check failed", content_type: "text/plain" }
           | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }
    | else -> { status: 400, body: "param is missing or the value is empty: user", content_type: "text/plain" }

pub tor first-run-gate {} -> orisha:Response
first-run-gate =
    config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT COUNT(*) FROM accounts
        }
        ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): n |> session:stash-if(ok: true, uid: n)
        | done d2 |> koru/sqlite3:close.pooled(conn: d2) |> session:take-uid(): accts
                  |> if(accts > 0)
                    | then -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /\r\n" }
                    | else |> first-run-page(): page -> { status: 200, body: page, content_type: "text/html" }
        | err e |> koru/sqlite3:close.pooled(e.conn) -> { status: 500, body: "account check failed", content_type: "text/plain" }
    | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }

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

// ────────────────────────────────────────────────────────────────────────────
// APP PAGES — profile / account / rooms / bots / joins. page-prelude opens
// once, stashes the authenticated user (auth-stash keeps user-id/-name/-ver/
// body-class working) and the singleton account (name, join_code, restrict,
// updated_at) plus custom_styles for the head's style slot. uid > 0 = signed
// in; every page tor answers "" otherwise and the route 302s.

pub tor page-prelude { email: ?string } -> i64
page-prelude =
    config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT u.id, u.name, u.email_address, COALESCE(u.bio,''), u.role, u.updated_at
            FROM users u WHERE u.email_address = {{email}} AND u.status = 0
        }
        ! row ur |> koru/sqlite3:col.int(stmt: ur, index: 0): puid
                 |> koru/sqlite3:col.text(stmt: ur, index: 1): pun
                 |> koru/sqlite3:col.text(stmt: ur, index: 2): pem
                 |> koru/sqlite3:col.text(stmt: ur, index: 3): pbo
                 |> koru/sqlite3:col.int(stmt: ur, index: 4): pro
                 |> koru/sqlite3:col.text(stmt: ur, index: 5): puat
                 |> views:ts-ver(ts: puat): pver
                 |> views:auth-stash(uid: puid, name: pun, email: pem, bio: pbo, role: pro, ver: pver)
        | done d2 |> koru/sqlite3:default(conn: d2) {
                SELECT name, join_code, COALESCE(custom_styles,''), updated_at,
                       COALESCE(json_extract(settings,'$.restrict_room_creation_to_administrators'),0)
                FROM accounts LIMIT 1
            }
            ! row ar |> koru/sqlite3:col.text(stmt: ar, index: 0): anm
                     |> koru/sqlite3:col.text(stmt: ar, index: 1): ajc
                     |> koru/sqlite3:col.text(stmt: ar, index: 2): acs
                     |> koru/sqlite3:col.text(stmt: ar, index: 3): aat
                     |> koru/sqlite3:col.int(stmt: ar, index: 4): arst
                     |> views:ts-ver(ts: aat): aver
                     |> views:acct-stash(name: anm, join: ajc, restrict: arst, ver: aver)
                     |> views:css-stash(css: acs)
            | done d3 |> koru/sqlite3:close.pooled(conn: d3) |> views:user-id(): au -> au
            | err ea |> koru/sqlite3:close.pooled(ea.conn) -> -1
        | err eu |> koru/sqlite3:close.pooled(eu.conn) -> -1
    | err _ -> -1

// <head> + current-user metas + custom styles + account-logo version —
// shared by every app page. Consumes the css stash.
pub tor app-head { title: string } -> string
app-head =
    views:user-id(): huid
    |> views:user-name(): hun
    |> views:user-metas(uid: huid, name: hun): hmet
    |> views:css-take(): hcss
    |> views:style-wrap(css: hcss): hsty
    |> views:acct-ver(): hver
    |> views:head-build(title, metas: hmet, logo: hver, styles: hsty): h -> h

// ── Profile ─────────────────────────────────────────────────────────────────
pub tor profile-page { email: ?string, host: ?string } -> string
profile-page = pages:page-begin()
    |> page-prelude(email): uid
    |> if(uid > 0)
    | then |> views:auth-email(): em
           |> views:auth-bio(): bo
           |> views:user-name(): unm
           |> views:host-or(h: host): hst
           |> signing:transfer-id(id: uid): sid
           |> views:transfer-path(host: hst, sid): turl
           |> qr:path(url: turl): qrp
           |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
           | db m |> koru/sqlite3:default(conn: m) {
                   SELECT r.id, COALESCE(r.name,'') FROM memberships ms
                   JOIN rooms r ON r.id = ms.room_id WHERE ms.user_id = {{uid}}
                   ORDER BY LOWER(r.name)
               }
               ! row mr |> koru/sqlite3:col.int(stmt: mr, index: 0): mrid
                        |> koru/sqlite3:col.text(stmt: mr, index: 1): mrn
                        |> views:itoa(n: mrid): mris
                        |> views:memb-link(rid: mris, name: mrn): ml
                        |> pages:frag-write(text: ml)
               | done m2 |> koru/sqlite3:close.pooled(conn: m2)
                         |> pages:frag-take(): membs
                         |> app-head(title: unm): hd
                         |> pages:page-write(text: hd)
                         |> views:profile-render(uid, name: unm, email: em, bio: bo,
                                                 turl, qrpath: qrp, memberships: membs): pg
                         |> pages:page-write(text: pg)
                         |> pages:page-write(text: "</html>")
                         |> pages:page-take(): pageout -> pageout
               | err emm |> koru/sqlite3:close.pooled(emm.conn) -> ""
           | err _ -> ""
    | else -> ""

// ── Account edit ────────────────────────────────────────────────────────────
pub tor account-page { email: ?string, host: ?string } -> string
account-page = pages:page-begin()
    |> page-prelude(email): uid
    |> if(uid > 0)
    | then |> views:user-role(): ur
           |> views:acct-nav-admin(role: ur): nva
           |> views:acct-name(): anm
           |> views:acct-restrict(): rst
           |> views:acct-admin-block(name: anm, restrict: rst, role: ur): adm
           |> views:acct-member-block(name: anm, role: ur): mem
           |> views:acct-join(): ajc
           |> views:host-or(h: host): hst
           |> views:invite-path(host: hst, code: ajc): ivu
           |> qr:path(url: ivu): qrp
           |> views:acct-regen(role: ur): rgn
           |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
           | db m |> koru/sqlite3:default(conn: m) {
                   SELECT id, name, role, updated_at FROM users WHERE status = 0
                   ORDER BY role, LOWER(name)
               }
               ! row mr |> koru/sqlite3:col.int(stmt: mr, index: 0): muid
                        |> koru/sqlite3:col.text(stmt: mr, index: 1): mun
                        |> koru/sqlite3:col.int(stmt: mr, index: 2): mro
                        |> koru/sqlite3:col.text(stmt: mr, index: 3): muat
                        |> views:ts-ver(ts: muat): mver
                        |> signing:user-sgid(id: muid): msg
                        |> views:acct-user(uid: muid, uname: mun, role: mro, sgid: msg, ver: mver): arow
                        |> pages:frag-write(text: arow)
               | done m2 |> koru/sqlite3:close.pooled(conn: m2)
                         |> pages:frag-take(): usrs
                         |> app-head(title: anm): hd
                         |> pages:page-write(text: hd)
                         |> views:account-render(navadmin: nva, admin: adm, member: mem,
                                                 inviteurl: ivu, qrpath: qrp, regen: rgn, users: usrs): pg
                         |> pages:page-write(text: pg)
                         |> pages:page-write(text: "</html>")
                         |> std/io:free(content: pg)
                         |> pages:page-take(): body -> body
               | err emm |> koru/sqlite3:close.pooled(emm.conn) -> ""
           | err _ -> ""
    | else -> ""

// ── Room form (opens/closeds new+edit shared) ────────────────────────────────
// edit_rid == 0 renders the blank new form; >0 pre-fills the current name.
pub tor room-form { email: ?string, action: string, method: string, edit_rid: i64 } -> string
room-form = pages:page-begin()
    |> page-prelude(email): uid
    |> if(uid > 0)
    | then |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
           | db d |> koru/sqlite3:default(conn: d) {
                   SELECT COALESCE(name,'') FROM rooms WHERE id = {{edit_rid}}
               }
               ! row r |> koru/sqlite3:col.text(stmt: r, index: 0): rn
                        |> views:edit-stash(name: rn, wh: "")
               | done d2 |> koru/sqlite3:default(conn: d2) {
                       SELECT id, name, updated_at FROM users WHERE status = 0 AND role != 2 ORDER BY LOWER(name)
                   }
                   ! row u2 |> koru/sqlite3:col.int(stmt: u2, index: 0): uuid
                            |> koru/sqlite3:col.text(stmt: u2, index: 1): uun
                            |> koru/sqlite3:col.text(stmt: u2, index: 2): uuat
                            |> views:ts-ver(ts: uuat): uuver
                            |> signing:user-sgid(id: uuid): uusg
                            |> views:room-user(uid: uuid, uname: uun, sgid: uusg, ver: uuver): ulab
                            |> pages:frag-write(text: ulab)
                   | done d3 |> koru/sqlite3:close.pooled(conn: d3)
                             |> pages:frag-take(): usrs
                             |> views:edit-name(): rn2
                             |> app-head(title: rn2): hd
                         |> pages:page-write(text: hd)
                             |> views:roomform-render(action, method, name: rn2, users: usrs): pg
                             |> pages:page-write(text: pg)
                             |> pages:page-write(text: "</html>")
                             |> std/io:free(content: pg)
                             |> pages:page-take(): body -> body
                   | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> ""
               | err e2 |> koru/sqlite3:close.pooled(e2.conn) -> ""
           | err _ -> ""
    | else -> ""

// ── Bots ────────────────────────────────────────────────────────────────────
pub tor bots-page { email: ?string, host: ?string } -> string
bots-page = pages:page-begin()
    |> page-prelude(email): uid
    |> if(uid > 0)
    | then |> views:user-role(): ur
           |> if(ur == 1)
           | then |> views:host-or(h: host): hst
                  |> views:bots-begin()
                  |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
                  | db m |> koru/sqlite3:default(conn: m) {
                          SELECT u.id, u.name, u.bot_token, r.id, COALESCE(r.name,'')
                          FROM users u
                          LEFT JOIN memberships ms ON ms.user_id = u.id
                          LEFT JOIN rooms r ON r.id = ms.room_id AND r.type != 'Rooms::Direct'
                          WHERE u.role = 2 AND u.status = 0
                          ORDER BY LOWER(u.name), LOWER(r.name)
                      }
                      ! row mr |> koru/sqlite3:col.int(stmt: mr, index: 0): bid
                               |> koru/sqlite3:col.text(stmt: mr, index: 1): bn
                               |> koru/sqlite3:col.text(stmt: mr, index: 2): bt
                               |> koru/sqlite3:col.int(stmt: mr, index: 3): brid
                               |> koru/sqlite3:col.text(stmt: mr, index: 4): brn
                               |> views:bot-key(id: bid, token: bt): bk
                               |> views:bot-row(uid: bid, name: bn, key: bk, rid: brid, rname: brn, host: hst)
                      | done m2 |> koru/sqlite3:close.pooled(conn: m2)
                                |> views:bots-take(): brows
                                |> app-head(title: "Chat bots"): hd
                         |> pages:page-write(text: hd)
                                |> views:bots-render(bots: brows): pg
                                |> pages:page-write(text: pg)
                                |> pages:page-write(text: "</html>")
                                |> std/io:free(content: pg)
                                |> pages:page-take(): body -> body
                      | err emm |> koru/sqlite3:close.pooled(emm.conn) -> ""
                  | err _ -> ""
           | else -> ""
    | else -> ""

pub tor bot-form { email: ?string, action: string, method: string, edit_bid: i64 } -> string
bot-form = pages:page-begin()
    |> page-prelude(email): uid
    |> if(uid > 0)
    | then |> views:user-role(): ur
           |> if(ur == 1)
           | then |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
                  | db d |> koru/sqlite3:default(conn: d) {
                          SELECT u.name, COALESCE(w.url,'') FROM users u
                          LEFT JOIN webhooks w ON w.user_id = u.id
                          WHERE u.id = {{edit_bid}} AND u.role = 2
                      }
                      ! row r |> koru/sqlite3:col.text(stmt: r, index: 0): bn
                               |> koru/sqlite3:col.text(stmt: r, index: 1): bw
                               |> views:edit-stash(name: bn, wh: bw)
                      | done d2 |> koru/sqlite3:close.pooled(conn: d2)
                                |> views:edit-name(): bn2
                                |> views:edit-wh(): bw2
                                |> app-head(title: bn2): hd
                         |> pages:page-write(text: hd)
                                |> views:botform-render(action, method, name: bn2, webhook: bw2): pg
                                |> pages:page-write(text: pg)
                                |> pages:page-write(text: "</html>")
                                |> std/io:free(content: pg)
                                |> pages:page-take(): body -> body
                      | err e2 |> koru/sqlite3:close.pooled(e2.conn) -> ""
                  | err _ -> ""
           | else -> ""
    | else -> ""

// ── Custom styles ───────────────────────────────────────────────────────────
pub tor styles-page { email: ?string } -> string
styles-page = pages:page-begin()
    |> page-prelude(email): uid
    |> if(uid > 0)
    | then |> views:acct-name(): anm
           |> views:css-take(): css0
           |> session:str-or(s: css0): css
           |> app-head(title: anm): hd
                         |> pages:page-write(text: hd)
           |> views:styles-render(css): pg
           |> pages:page-write(text: pg)
           |> pages:page-write(text: "</html>")
           |> std/io:free(content: pg)
           |> pages:page-take(): body -> body
    | else -> ""

// ── Session transfer (unauthenticated — the QR'd link's landing) ────────────
pub tor transfer-page { code: string } -> string
transfer-page = pages:page-begin()
    |> views:head-build(title: "Campfire", metas: "", logo: "", styles: ""): hd
    |> pages:page-write(text: hd)
    |> views:transfer-action(sid: code): act
    |> views:transfer-render(action: act): pg
    |> pages:page-write(text: pg)
    |> pages:page-write(text: "</html>")
    |> std/io:free(content: pg)
    |> pages:page-take(): body -> body

// ── Join (invite) page — unauthenticated, verified by the join_code ─────────
pub tor join-page { code: string } -> string
join-page = pages:page-begin()
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT name, updated_at, join_code FROM accounts LIMIT 1
        }
        ! row r |> koru/sqlite3:col.text(stmt: r, index: 0): an
                 |> koru/sqlite3:col.text(stmt: r, index: 1): aat
                 |> koru/sqlite3:col.text(stmt: r, index: 2): ajc
                 |> views:ts-ver(ts: aat): aver
                 |> views:edit-stash(name: an, wh: "")
                 |> views:acct-stash(name: an, join: ajc, restrict: 0, ver: aver)
        | done d2 |> koru/sqlite3:close.pooled(conn: d2)
                  |> views:acct-join(): ajc2
                  |> if(ajc2 == code)
                     | then |> views:acct-ver(): av2
                            |> views:edit-name(): an2
                            |> views:head-build(title: "Sign up", metas: "", logo: av2, styles: ""): hd
                            |> pages:page-write(text: hd)
                            |> views:join-render(action: code, acctname: an2): pg
                            |> pages:page-write(text: pg)
                            |> pages:page-write(text: "</html>")
                            |> std/io:free(content: pg)
                            |> pages:page-take(): body -> body
                     | else -> ""
        | err e |> koru/sqlite3:close.pooled(e.conn) -> ""
    | err _ -> ""

// ── New ping (direct room) ──────────────────────────────────────────────────
pub tor directs-page { email: ?string } -> string
directs-page = pages:page-begin()
    |> page-prelude(email): uid
    |> if(uid > 0)
    | then |> views:user-name(): unm
           |> app-head(title: unm): hd
                         |> pages:page-write(text: hd)
           |> views:directs-render(): pg
           |> pages:page-write(text: pg)
           |> pages:page-write(text: "</html>")
           |> std/io:free(content: pg)
           |> pages:page-take(): body -> body
    | else -> ""

// ── Autocomplete JSON ───────────────────────────────────────────────────────
// /autocompletable/users?query= — the suggestion controller's fetch. JSON
// array of {name, value, avatar_url, sgid}, filtered LIKE %query%.
pub tor autocomplete-json { email: ?string, q: ?string } -> string
autocomplete-json =
    page-prelude(email): uid
    |> if(uid > 0)
    | then |> views:ac-begin()
           |> session:str-or(s: q): qq
           |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
           | db m |> koru/sqlite3:default(conn: m) {
                   SELECT id, name, updated_at FROM users WHERE status = 0 AND role != 2
                     AND name LIKE '%' || {{qq}} || '%'
                   ORDER BY LOWER(name) LIMIT 20
               }
               ! row mr |> koru/sqlite3:col.int(stmt: mr, index: 0): auid
                        |> koru/sqlite3:col.text(stmt: mr, index: 1): anm
                        |> koru/sqlite3:col.text(stmt: mr, index: 2): auat
                        |> views:ts-ver(ts: auat): aver
                        |> signing:user-sgid(id: auid): asg
                        |> views:ac-row(uid: auid, name: anm, sgid: asg, ver: aver)
               | done m2 |> koru/sqlite3:close.pooled(conn: m2)
                         |> views:ac-take(): js -> js
               | err emm |> koru/sqlite3:close.pooled(emm.conn) -> "[]"
           | err _ -> "[]"
    | else -> "[]"

// ── QR code ─────────────────────────────────────────────────────────────────
// QrCodeController#show — id is urlsafe-base64 of the target URL; decode and
// render. Empty decode = empty body (a 200 with no pixels, honestly broken).
pub tor qr-page { enc: string } -> orisha:Response
qr-page =
    qr:decode(enc): url
    |> qr:svg(text: url): svg
    |> qr:svg-respond(svg): res -> res

// ── APP WRITES ──────────────────────────────────────────────────────────────

// SessionsController#destroy — POST /session _method=delete. Row delete,
// clearing cookie, back to sign-in.
pub tor session-destroy { token: ?string } -> orisha:Response
session-destroy =
    signing:cookie-verify(raw: token): vtok
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            DELETE FROM sessions WHERE token = {{vtok}}
        }
        | done d2 |> koru/sqlite3:close.pooled(conn: d2) -> { status: 302, body: "", content_type: "text/plain",
                      extra_headers: "Location: /session/new\r\nSet-Cookie: session_token=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; SameSite=Lax\r\n" }
        | err e |> koru/sqlite3:close.pooled(e.conn) -> { status: 500, body: "logout failed", content_type: "text/plain" }
    | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }

// digest-of — bcrypt hash when the password field carries a value, else the
// empty string (the UPDATE treats it as NULL and keeps the old digest).
pub tor digest-of { password: ?string } -> string
digest-of =
    session:str-or(s: password): pw
    |> if(pw != "")
       | then |> bcrypt:hash(password: pw, cost: 12): dg -> dg
       | else -> ""

// ProfilesController#update — name/email/bio always; password_digest only
// when the field carries a non-empty value.
pub tor profile-update { token: ?string, name: ?string, email: ?string,
                         password: ?string, bio: ?string } -> orisha:Response
profile-update =
    signing:cookie-verify(raw: token): vtok
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT u.id FROM users u JOIN sessions s ON s.user_id = u.id
            WHERE s.token = {{vtok}} LIMIT 1
        }
        ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): uid
                 |> session:stash-if(ok: true, uid)
        | done d2 |> session:take-uid(): uid2
                  |> if(uid2 > 0)
                     | then |> digest-of(password): dg2
                            |> koru/sqlite3:default(conn: d2) {
                                UPDATE users SET name = COALESCE({{name}}, name),
                                    email_address = COALESCE({{email}}, email_address),
                                    bio = {{bio}},
                                    password_digest = COALESCE(NULLIF({{dg2}}, ''), password_digest),
                                    updated_at = CURRENT_TIMESTAMP
                                WHERE id = {{uid2}}
                            }
                            | done d3 |> koru/sqlite3:close.pooled(conn: d3)
                                      |> orisha:generation-bump() -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /users/me/profile\r\n" }
                            | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> { status: 500, body: "update failed", content_type: "text/plain" }
                     | else |> koru/sqlite3:close.pooled(conn: d2) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
        | err eu |> koru/sqlite3:close.pooled(eu.conn) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
    | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }

// AccountsController#update — PATCH carries account[name], PUT carries the
// restrict-rooms settings flag. Both are admin-only writes.
pub tor account-update { token: ?string, name: ?string, restrict: ?string } -> orisha:Response
account-update =
    signing:cookie-verify(raw: token): vtok
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT u.id, u.role FROM users u JOIN sessions s ON s.user_id = u.id
            WHERE s.token = {{vtok}} LIMIT 1
        }
        ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): uid
                 |> koru/sqlite3:col.int(stmt: r, index: 1): urole
                 |> session:stash-if(ok: urole == 1, uid)
        | done d2 |> session:take-uid(): uid2
                  |> if(uid2 > 0)
                     | then |> koru/sqlite3:default(conn: d2) {
                             UPDATE accounts SET
                                 name = COALESCE({{name}}, name),
                                 settings = CASE WHEN {{restrict}} IS NOT NULL
                                     THEN json_set(COALESCE(settings,'{}'),'$.restrict_room_creation_to_administrators', json({{restrict}}))
                                     ELSE settings END,
                                 updated_at = CURRENT_TIMESTAMP
                         }
                         | done d3 |> koru/sqlite3:close.pooled(conn: d3)
                                   |> orisha:generation-bump() -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /account/edit\r\n" }
                         | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> { status: 500, body: "update failed", content_type: "text/plain" }
                     | else |> koru/sqlite3:close.pooled(conn: d2) -> { status: 403, body: "", content_type: "text/plain" }
        | err eu |> koru/sqlite3:close.pooled(eu.conn) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
    | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }

// Accounts::JoinCodesController#create — reset_join_code.
pub tor join-reset { token: ?string } -> orisha:Response
join-reset =
    signing:cookie-verify(raw: token): vtok
    |> views:join-code(): jc
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT u.role FROM users u JOIN sessions s ON s.user_id = u.id
            WHERE s.token = {{vtok}} LIMIT 1
        }
        ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): urole
                 |> session:stash-if(ok: urole == 1, uid: 1)
        | done d2 |> session:take-uid(): ok2
                  |> if(ok2 > 0)
                     | then |> koru/sqlite3:default(conn: d2) {
                             UPDATE accounts SET join_code = {{jc}}, updated_at = CURRENT_TIMESTAMP
                         }
                         | done d3 |> koru/sqlite3:close.pooled(conn: d3)
                                   |> orisha:generation-bump() -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /account/edit\r\n" }
                         | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> { status: 500, body: "update failed", content_type: "text/plain" }
                     | else |> koru/sqlite3:close.pooled(conn: d2) -> { status: 403, body: "", content_type: "text/plain" }
        | err eu |> koru/sqlite3:close.pooled(eu.conn) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
    | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }

// Accounts::CustomStylesController#update.
pub tor styles-update { token: ?string, css: ?string } -> orisha:Response
styles-update =
    signing:cookie-verify(raw: token): vtok
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT u.role FROM users u JOIN sessions s ON s.user_id = u.id
            WHERE s.token = {{vtok}} LIMIT 1
        }
        ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): urole
                 |> session:stash-if(ok: urole == 1, uid: 1)
        | done d2 |> session:take-uid(): ok2
                  |> if(ok2 > 0)
                     | then |> koru/sqlite3:default(conn: d2) {
                             UPDATE accounts SET custom_styles = {{css}}, updated_at = CURRENT_TIMESTAMP
                         }
                         | done d3 |> koru/sqlite3:close.pooled(conn: d3)
                                   |> orisha:generation-bump() -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /account/edit\r\n" }
                         | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> { status: 500, body: "update failed", content_type: "text/plain" }
                     | else |> koru/sqlite3:close.pooled(conn: d2) -> { status: 403, body: "", content_type: "text/plain" }
        | err eu |> koru/sqlite3:close.pooled(eu.conn) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
    | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }

// Accounts::BotsController#create — insert the bot user, grant it every
// open room (grant_membership_to_open_rooms), webhook row when the URL is
// present.
pub tor bot-create { token: ?string, name: ?string, webhook: ?string } -> orisha:Response
bot-create =
    signing:cookie-verify(raw: token): vtok
    |> views:bot-token(): btok
    |> session:str-or(s: webhook): whurl
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT u.role FROM users u JOIN sessions s ON s.user_id = u.id
            WHERE s.token = {{vtok}} LIMIT 1
        }
        ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): urole
                 |> session:stash-if(ok: urole == 1, uid: 1)
        | done d2 |> session:take-uid(): ok2
                  |> if(ok2 > 0)
                     | then |> koru/sqlite3:default(conn: d2) {
                             INSERT INTO users (name, role, status, bot_token, created_at, updated_at)
                             VALUES ({{name}}, 2, 0, {{btok}}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                         }
                         | done d3 |> koru/sqlite3:default(conn: d3) {
                                 INSERT INTO memberships (room_id, user_id, involvement, created_at, updated_at)
                                 SELECT r.id, (SELECT MAX(id) FROM users WHERE role = 2), 'mentions', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
                                 FROM rooms r WHERE r.type = 'Rooms::Open'
                             }
                             | done d4 |> koru/sqlite3:default(conn: d4) {
                                     INSERT INTO webhooks (user_id, url, created_at, updated_at)
                                     SELECT (SELECT MAX(id) FROM users WHERE role = 2), {{whurl}}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
                                     WHERE {{whurl}} != ''
                                 }
                                 | done d5 |> koru/sqlite3:close.pooled(conn: d5)
                                           |> orisha:generation-bump() -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /account/bots\r\n" }
                                 | err e5 |> koru/sqlite3:close.pooled(e5.conn) -> { status: 500, body: "webhook failed", content_type: "text/plain" }
                             | err e4 |> koru/sqlite3:close.pooled(e4.conn) -> { status: 500, body: "grant failed", content_type: "text/plain" }
                         | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> { status: 500, body: "create failed", content_type: "text/plain" }
                     | else |> koru/sqlite3:close.pooled(conn: d2) -> { status: 403, body: "", content_type: "text/plain" }
        | err eu |> koru/sqlite3:close.pooled(eu.conn) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
    | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }

// Accounts::BotsController#update — user[name] + user[webhook_url] (webhook
// row upserted; empty URL deletes it, matching update_webhook_url!).
pub tor bot-update { token: ?string, bid: string, name: ?string, webhook: ?string } -> orisha:Response
bot-update =
    signing:cookie-verify(raw: token): vtok
    |> session:str-or(s: webhook): whurl
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT u.role FROM users u JOIN sessions s ON s.user_id = u.id
            WHERE s.token = {{vtok}} LIMIT 1
        }
        ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): urole
                 |> session:stash-if(ok: urole == 1, uid: 1)
        | done d2 |> session:take-uid(): ok2
                  |> if(ok2 > 0)
                     | then |> koru/sqlite3:default(conn: d2) {
                             UPDATE users SET name = COALESCE({{name}}, name), updated_at = CURRENT_TIMESTAMP
                             WHERE id = {{bid}} AND role = 2
                         }
                         | done d3 |> koru/sqlite3:default(conn: d3) {
                                 DELETE FROM webhooks WHERE user_id = {{bid}}
                             }
                             | done d4 |> koru/sqlite3:default(conn: d4) {
                                     INSERT INTO webhooks (user_id, url, created_at, updated_at)
                                     SELECT {{bid}}, {{whurl}}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
                                     WHERE {{whurl}} != ''
                                 }
                                 | done d5 |> koru/sqlite3:close.pooled(conn: d5)
                                           |> orisha:generation-bump() -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /account/bots\r\n" }
                                 | err e5 |> koru/sqlite3:close.pooled(e5.conn) -> { status: 500, body: "webhook failed", content_type: "text/plain" }
                             | err e4 |> koru/sqlite3:close.pooled(e4.conn) -> { status: 500, body: "webhook failed", content_type: "text/plain" }
                         | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> { status: 500, body: "update failed", content_type: "text/plain" }
                     | else |> koru/sqlite3:close.pooled(conn: d2) -> { status: 403, body: "", content_type: "text/plain" }
        | err eu |> koru/sqlite3:close.pooled(eu.conn) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
    | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }

// Accounts::Bots::KeysController#update — reset_bot_key.
pub tor bot-key-reset { token: ?string, bid: string } -> orisha:Response
bot-key-reset =
    signing:cookie-verify(raw: token): vtok
    |> views:bot-token(): btok
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT u.role FROM users u JOIN sessions s ON s.user_id = u.id
            WHERE s.token = {{vtok}} LIMIT 1
        }
        ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): urole
                 |> session:stash-if(ok: urole == 1, uid: 1)
        | done d2 |> session:take-uid(): ok2
                  |> if(ok2 > 0)
                     | then |> koru/sqlite3:default(conn: d2) {
                             UPDATE users SET bot_token = {{btok}}, updated_at = CURRENT_TIMESTAMP
                             WHERE id = {{bid}} AND role = 2
                         }
                         | done d3 |> koru/sqlite3:close.pooled(conn: d3) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /account/bots\r\n" }
                         | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> { status: 500, body: "update failed", content_type: "text/plain" }
                     | else |> koru/sqlite3:close.pooled(conn: d2) -> { status: 403, body: "", content_type: "text/plain" }
        | err eu |> koru/sqlite3:close.pooled(eu.conn) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
    | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }

// Rooms::OpensController#create — insert the open room, grant every active
// user (the model's grant_access_to_all_users), prepend the sidebar link on
// the shared "rooms" turbo stream, then redirect.
pub tor room-create { token: ?string, name: ?string, rtype: string } -> orisha:Response
room-create =
    signing:cookie-verify(raw: token): vtok
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT u.id, u.role, (SELECT COALESCE(json_extract(a.settings,'$.restrict_room_creation_to_administrators'),0) FROM accounts a)
            FROM users u JOIN sessions s ON s.user_id = u.id
            WHERE s.token = {{vtok}} LIMIT 1
        }
        ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): uid
                 |> koru/sqlite3:col.int(stmt: r, index: 1): urole
                 |> koru/sqlite3:col.int(stmt: r, index: 2): urst
                 |> session:stash-if(ok: urole == 1 or urst == 0, uid)
        | done d2 |> session:take-uid(): uid2
                  |> if(uid2 > 0)
                     | then |> koru/sqlite3:default(conn: d2) {
                             INSERT INTO rooms (name, type, creator_id, created_at, updated_at)
                             VALUES ({{name}}, {{rtype}}, {{uid2}}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                         }
                         | done d3 |> koru/sqlite3:default(conn: d3) {
                                 SELECT MAX(id) FROM rooms
                             }
                             ! row r2 |> koru/sqlite3:col.int(stmt: r2, index: 0): nid
                                       |> session:stash-if(ok: true, uid: nid)
                             | done d4 |> session:take-uid(): rid2
                                       |> if(rtype == "Rooms::Open")
                                          | then |> koru/sqlite3:default(conn: d4) {
                                                  INSERT INTO memberships (room_id, user_id, involvement, created_at, updated_at)
                                                  SELECT {{rid2}}, id, 'mentions', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
                                                  FROM users WHERE status = 0
                                              }
                                              | done d5 |> koru/sqlite3:close.pooled(conn: d5)
                                                        |> session:str-or(s: name): nm0
                                                        |> room-broadcast(rid: rid2, name: nm0, rk: "rooms_open")
                                                        |> session:room-path(rid: rid2): rp
                                                        |> session:redirect-to(path: rp): rhdr -> { status: 302, body: "", content_type: "text/plain", extra_headers: rhdr }
                                              | err e5 |> koru/sqlite3:close.pooled(e5.conn) -> { status: 500, body: "grant failed", content_type: "text/plain" }
                                          | else |> koru/sqlite3:default(conn: d4) {
                                                  INSERT INTO memberships (room_id, user_id, involvement, created_at, updated_at)
                                                  VALUES ({{rid2}}, {{uid2}}, 'mentions', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                                              }
                                              | done d5 |> koru/sqlite3:close.pooled(conn: d5)
                                                        |> session:str-or(s: name): nm0
                                                        |> room-broadcast(rid: rid2, name: nm0, rk: "rooms_closed")
                                                        |> session:room-path(rid: rid2): rp
                                                        |> session:redirect-to(path: rp): rhdr -> { status: 302, body: "", content_type: "text/plain", extra_headers: rhdr }
                                              | err e5 |> koru/sqlite3:close.pooled(e5.conn) -> { status: 500, body: "grant failed", content_type: "text/plain" }
                             | err e4 |> koru/sqlite3:close.pooled(e4.conn) -> { status: 500, body: "id read failed", content_type: "text/plain" }
                         | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> { status: 500, body: "create failed", content_type: "text/plain" }
                     | else |> koru/sqlite3:close.pooled(conn: d2) -> { status: 403, body: "", content_type: "text/plain" }
        | err eu |> koru/sqlite3:close.pooled(eu.conn) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
    | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }

// Rooms::*Controller#update — rename + broadcast_replace the sidebar link.
// rk arrives "rooms_open"/"rooms_closed" and selects the list-id prefix.
pub tor room-update { token: ?string, rid: string, name: ?string, rk: string } -> orisha:Response
room-update =
    signing:cookie-verify(raw: token): vtok
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT u.id, u.role FROM users u JOIN sessions s ON s.user_id = u.id
            WHERE s.token = {{vtok}} LIMIT 1
        }
        ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): uid
                 |> koru/sqlite3:col.int(stmt: r, index: 1): urole
                 |> session:stash-if(ok: urole == 1, uid)
        | done d2 |> session:take-uid(): uid2
                  |> if(uid2 > 0)
                     | then |> koru/sqlite3:default(conn: d2) {
                             UPDATE rooms SET name = {{name}}, updated_at = CURRENT_TIMESTAMP
                             WHERE id = {{rid}} AND type != 'Rooms::Direct'
                         }
                         | done d3 |> koru/sqlite3:close.pooled(conn: d3)
                                   |> session:str-or(s: name): nm2
                                   |> messages:msg-int(s: rid): ridn2
                                   |> room-renamed-broadcast(rid: ridn2, name: nm2, rk)
                                   |> session:room-path(rid: ridn2): rp
                                   |> session:redirect-to(path: rp): rhdr -> { status: 302, body: "", content_type: "text/plain", extra_headers: rhdr }
                         | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> { status: 500, body: "update failed", content_type: "text/plain" }
                     | else |> koru/sqlite3:close.pooled(conn: d2) -> { status: 403, body: "", content_type: "text/plain" }
        | err eu |> koru/sqlite3:close.pooled(eu.conn) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
    | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }

// Rooms::DirectsController#create — find-for exact member set or create,
// grant the full set (direct involvement = 'everything'), prepend the
// direct link on each member's user_<gid>:rooms stream.
pub tor direct-create { token: ?string, ids: string } -> orisha:Response
direct-create =
    signing:cookie-verify(raw: token): vtok
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT u.id FROM users u JOIN sessions s ON s.user_id = u.id
            WHERE s.token = {{vtok}} LIMIT 1
        }
        ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): uid
                 |> session:stash-if(ok: true, uid)
        | done d2 |> session:take-uid(): uid2
                  |> if(uid2 > 0)
                     | then |> views:uids-join(ids, uid: uid2): allids
                            |> views:uids-count(ids: allids): nmem
                            |> koru/sqlite3:default(conn: d2) {
                                SELECT r.id FROM rooms r
                                WHERE r.type = 'Rooms::Direct'
                                  AND (SELECT COUNT(*) FROM memberships m0 WHERE m0.room_id = r.id) = {{nmem}}
                                  AND (SELECT COUNT(*) FROM memberships m1 WHERE m1.room_id = r.id AND m1.user_id IN (SELECT CAST(value AS INTEGER) FROM json_each({{allids}}))) = {{nmem}}
                                LIMIT 1
                            }
                            ! row fr |> koru/sqlite3:col.int(stmt: fr, index: 0): fid
                                       |> session:stash-if(ok: true, uid: fid)
                            | done d3 |> session:take-uid(): found
                                      |> if(found > 0)
                                         | then |> koru/sqlite3:close.pooled(conn: d3)
                                                |> session:room-path(rid: found): rp
                                                |> session:redirect-to(path: rp): rhdr -> { status: 302, body: "", content_type: "text/plain", extra_headers: rhdr }
                                         | else |> koru/sqlite3:default(conn: d3) {
                                                 INSERT INTO rooms (name, type, creator_id, created_at, updated_at)
                                                 VALUES (NULL, 'Rooms::Direct', {{uid2}}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                                             }
                                             | done d4 |> koru/sqlite3:default(conn: d4) { SELECT MAX(id) FROM rooms }
                                                       ! row r2 |> koru/sqlite3:col.int(stmt: r2, index: 0): nid
                                                                |> session:stash-if(ok: true, uid: nid)
                                                       | done d5 |> session:take-uid(): rid2
                                                                 |> koru/sqlite3:default(conn: d5) {
                                                                     INSERT INTO memberships (room_id, user_id, involvement, created_at, updated_at)
                                                                     SELECT {{rid2}}, u.id, 'everything', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
                                                                     FROM users u WHERE u.id IN (SELECT CAST(value AS INTEGER) FROM json_each({{allids}}))
                                                                 }
                                                                 | done d6 |> koru/sqlite3:close.pooled(conn: d6)
                                                                           |> direct-broadcast(rid: rid2)
                                                                           |> session:room-path(rid: rid2): rp
                                                                           |> session:redirect-to(path: rp): rhdr -> { status: 302, body: "", content_type: "text/plain", extra_headers: rhdr }
                                                                 | err e6 |> koru/sqlite3:close.pooled(e6.conn) -> { status: 500, body: "grant failed", content_type: "text/plain" }
                                                       | err e5 |> koru/sqlite3:close.pooled(e5.conn) -> { status: 500, body: "id read failed", content_type: "text/plain" }
                                             | err e4 |> koru/sqlite3:close.pooled(e4.conn) -> { status: 500, body: "create failed", content_type: "text/plain" }
                            | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> { status: 500, body: "find failed", content_type: "text/plain" }
                     | else |> koru/sqlite3:close.pooled(conn: d2) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
        | err eu |> koru/sqlite3:close.pooled(eu.conn) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
    | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }

// ── Room refresh ────────────────────────────────────────────────────────────
// Rooms::RefreshesController#show — refresh_room_controller's catch-up GET
// (/rooms/:id/refresh?since=<ms>&reason=…): a turbo-stream appending the
// messages created since `since` into dom_id(room, :messages) and replacing
// the ones updated since. since is epoch milliseconds; absent reads as 0
// (the reference's params.to_i). Non-members get the sign-in redirect that
// RoomScoped's before_action produces.
pub tor refresh-msg { mid: i64, cmid: string, cat: string, uat: string,
                      anm: string, uid: i64, auat: string, body: string,
                      abio: string, rid: string, action: string, tgt: string,
                      host: ?string }
refresh-msg =
    views:user-title(name: anm, bio: abio): atitle
    |> views:ts-ver(ts: auat): uver
    |> views:ts-iso(ts: cat): iso
    |> views:ts-ms(ts: cat): ms
    |> views:ts-ms(ts: uat): ums
    |> views:room-name(): rname
    |> views:boost-rows(mid): brow
    |> signing:user-sgid(id: uid): usg
    |> views:message-render(cmid, mid, uid, rid, ms, ums, iso, author: anm, atitle, uver, usgid: usg, roomname: rname, body, boosts: brow, host): mhtml
    |> views:stream-wrap(action, target: tgt): shtml
    |> pages:frag-write()
    |> std/io:free(content: mhtml)

pub tor room-refresh { rid: string, email: ?string, since: ?string, host: ?string } -> orisha:Response
room-refresh = pages:page-begin()
    |> views:page-reset()
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT COALESCE(r.name, ''), r.type FROM rooms r
            JOIN memberships m ON m.room_id = r.id
            JOIN users u ON u.id = m.user_id
            WHERE r.id = {{rid}}
              AND u.email_address = {{email}}
              AND m.involvement != 'invisible'
        }
        ! row rr |> koru/sqlite3:col.text(stmt: rr, index: 0): rn
                 |> koru/sqlite3:col.text(stmt: rr, index: 1): rt
                 |> views:stash-room(name: rn, rtype: rt)
        | done d2 |> views:room-present(): has
                  |> if(has)
                     | then |> koru/sqlite3:default(conn: d2) {
                             SELECT b.id, b.message_id, b.content, u.id, u.name, u.updated_at
                             FROM boosts b
                             JOIN users u ON u.id = b.booster_id
                             JOIN messages m2 ON m2.id = b.message_id
                             WHERE m2.room_id = {{rid}}
                         }
                         ! row br |> koru/sqlite3:col.int(stmt: br, index: 0): bid
                                  |> koru/sqlite3:col.int(stmt: br, index: 1): bmid
                                  |> koru/sqlite3:col.text(stmt: br, index: 2): bct
                                  |> koru/sqlite3:col.int(stmt: br, index: 3): buid
                                  |> koru/sqlite3:col.text(stmt: br, index: 4): bnm
                                  |> koru/sqlite3:col.text(stmt: br, index: 5): buat
                                  |> views:ts-ver(ts: buat): bver
                                  |> signing:user-sgid(id: buid): bsg
                                  |> views:Boost-render(bid, mid: bmid, buid, bsgid: bsg, bname: bnm, bcontent: bct, bver): bf
                                  |> views:boost-stash(mid: bmid, html: bf)
                                  |> std/io:free(content: bf)
                         | done d3 |> koru/sqlite3:default(conn: d3) {
                                 SELECT m.id, m.client_message_id, m.created_at, m.updated_at,
                                        u.name, u.id, u.updated_at, rt.body, u.bio
                                 FROM messages m
                                 JOIN action_text_rich_texts rt
                                   ON rt.record_type='Message' AND rt.record_id = m.id
                                 JOIN users u ON u.id = m.creator_id
                                 WHERE m.room_id = {{rid}}
                                   AND CAST(strftime('%s', m.created_at) AS INTEGER) * 1000 >
                                       COALESCE(CAST({{since}} AS INTEGER), 0)
                                 ORDER BY m.created_at
                             }
                             ! row mr |> koru/sqlite3:col.int(stmt: mr, index: 0): mid
                                      |> koru/sqlite3:col.text(stmt: mr, index: 1): mcmid
                                      |> koru/sqlite3:col.text(stmt: mr, index: 2): mcat
                                      |> koru/sqlite3:col.text(stmt: mr, index: 3): muat
                                      |> koru/sqlite3:col.text(stmt: mr, index: 4): manm
                                      |> koru/sqlite3:col.int(stmt: mr, index: 5): muid
                                      |> koru/sqlite3:col.text(stmt: mr, index: 6): muuat
                                      |> koru/sqlite3:col.text(stmt: mr, index: 7): mbody
                                      |> koru/sqlite3:col.text(stmt: mr, index: 8): mbio
                                      |> views:room-key(): rk
                                      |> messages:msg-target(key: rk, rid): tgt
                                      |> refresh-msg(mid, cmid: mcmid, cat: mcat, uat: muat, anm: manm, uid: muid, auat: muuat, body: mbody, abio: mbio, rid, action: "append", tgt, host)
                             | done d4 |> koru/sqlite3:default(conn: d4) {
                                     SELECT m.id, m.client_message_id, m.created_at, m.updated_at,
                                            u.name, u.id, u.updated_at, rt.body, u.bio
                                     FROM messages m
                                     JOIN action_text_rich_texts rt
                                       ON rt.record_type='Message' AND rt.record_id = m.id
                                     JOIN users u ON u.id = m.creator_id
                                     WHERE m.room_id = {{rid}}
                                       AND CAST(strftime('%s', m.updated_at) AS INTEGER) * 1000 >
                                           COALESCE(CAST({{since}} AS INTEGER), 0)
                                       AND CAST(strftime('%s', m.created_at) AS INTEGER) * 1000 <=
                                           COALESCE(CAST({{since}} AS INTEGER), 0)
                                     ORDER BY m.updated_at
                                 }
                                 ! row ur |> koru/sqlite3:col.int(stmt: ur, index: 0): mid
                                          |> koru/sqlite3:col.text(stmt: ur, index: 1): mcmid
                                          |> koru/sqlite3:col.text(stmt: ur, index: 2): mcat
                                          |> koru/sqlite3:col.text(stmt: ur, index: 3): muat
                                          |> koru/sqlite3:col.text(stmt: ur, index: 4): manm
                                          |> koru/sqlite3:col.int(stmt: ur, index: 5): muid
                                          |> koru/sqlite3:col.text(stmt: ur, index: 6): muuat
                                          |> koru/sqlite3:col.text(stmt: ur, index: 7): mbody
                                          |> koru/sqlite3:col.text(stmt: ur, index: 8): mbio
                                          |> views:mdom(cmid: mcmid): tgt
                                          |> refresh-msg(mid, cmid: mcmid, cat: mcat, uat: muat, anm: manm, uid: muid, auat: muuat, body: mbody, abio: mbio, rid, action: "replace", tgt, host)
                                 | done d5 |> koru/sqlite3:close.pooled(conn: d5)
                                           |> pages:frag-take(): sbody -> { status: 200, body: sbody, content_type: "text/vnd.turbo-stream.html" }
                                 | err e5 |> koru/sqlite3:close.pooled(e5.conn) -> { status: 500, body: "refresh failed", content_type: "text/plain" }
                             | err e4 |> koru/sqlite3:close.pooled(e4.conn) -> { status: 500, body: "refresh failed", content_type: "text/plain" }
                         | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> { status: 500, body: "refresh failed", content_type: "text/plain" }
                     | else |> koru/sqlite3:close.pooled(conn: d2) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
        | err eu |> koru/sqlite3:close.pooled(eu.conn) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
    | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }

// Sessions::TransfersController#update — the auto-submitted PUT: verify the
// signed transfer id, open a session for that user, land on /.
pub tor transfer-consume { token: ?string, code: string, ua: ?string } -> orisha:Response
transfer-consume =
    signing:transfer-verify(raw: code): uid
    |> if(uid > 0)
    | then |> session:new-token(): tok
           |> signing:cookie-header(token: tok): cv
           |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
           | db d |> koru/sqlite3:default(conn: d) {
                   INSERT INTO sessions (user_id, token, user_agent, ip_address, last_active_at, created_at, updated_at)
                   VALUES ({{uid}}, {{tok}}, {{ua}}, '', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
               }
               | done d2 |> koru/sqlite3:close.pooled(conn: d2)
                         |> session:redirect-signed(cookie: cv): hdr -> { status: 302, body: "", content_type: "text/plain", extra_headers: hdr }
               | err e2 |> koru/sqlite3:close.pooled(e2.conn) -> { status: 500, body: "session failed", content_type: "text/plain" }
           | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }
    | else -> { status: 400, body: "", content_type: "text/plain" }

// UsersController#create — verified join_code, create user + open-room
// memberships + session, land on /.
pub tor join-create { code: string, name: ?string, email: ?string,
                      password: ?string, ua: ?string } -> orisha:Response
join-create =
    session:str-or(s: password): pw
    |> if(name != null and email != null and pw != "")
    | then |> bcrypt:hash(password: pw, cost: 12): dg
           |> session:new-token(): tok
           |> signing:cookie-header(token: tok): cv
           |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
           | db d |> koru/sqlite3:default(conn: d) {
                   SELECT join_code FROM accounts LIMIT 1
               }
               ! row r |> koru/sqlite3:col.text(stmt: r, index: 0): jc
                        |> session:stash-if(ok: jc == code, uid: 1)
               | done d2 |> session:take-uid(): ok2
                         |> if(ok2 > 0)
                            | then |> koru/sqlite3:default(conn: d2) {
                                    INSERT INTO users (name, email_address, password_digest, role, status, created_at, updated_at)
                                    VALUES ({{name}}, {{email}}, {{dg}}, 0, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                                }
                                | done d3 |> koru/sqlite3:default(conn: d3) { SELECT MAX(id) FROM users }
                                          ! row r2 |> koru/sqlite3:col.int(stmt: r2, index: 0): nid
                                                   |> session:stash-if(ok: true, uid: nid)
                                          | done d4 |> session:take-uid(): uid2
                                                    |> koru/sqlite3:default(conn: d4) {
                                                        INSERT INTO memberships (room_id, user_id, involvement, created_at, updated_at)
                                                        SELECT r.id, {{uid2}}, 'mentions', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
                                                        FROM rooms r WHERE r.type = 'Rooms::Open'
                                                    }
                                                    | done d5 |> koru/sqlite3:default(conn: d5) {
                                                            INSERT INTO sessions (user_id, token, user_agent, ip_address, last_active_at, created_at, updated_at)
                                                            VALUES ({{uid2}}, {{tok}}, {{ua}}, '', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                                                        }
                                                        | done d6 |> koru/sqlite3:close.pooled(conn: d6)
                                                                  |> session:redirect-signed(cookie: cv): hdr
                                                                  |> orisha:generation-bump() -> { status: 302, body: "", content_type: "text/plain", extra_headers: hdr }
                                                        | err e6 |> koru/sqlite3:close.pooled(e6.conn) -> { status: 500, body: "session failed", content_type: "text/plain" }
                                                    | err e5 |> koru/sqlite3:close.pooled(e5.conn) -> { status: 500, body: "grant failed", content_type: "text/plain" }
                                          | err e4 |> koru/sqlite3:close.pooled(e4.conn) -> { status: 500, body: "id read failed", content_type: "text/plain" }
                                | err e3 |> koru/sqlite3:close.pooled(e3.conn)
                                         |> session:redirect-to(path: "/session/new"): hdr2 -> { status: 302, body: "", content_type: "text/plain", extra_headers: hdr2 }
                            | else |> koru/sqlite3:close.pooled(conn: d2) -> { status: 404, body: "", content_type: "text/plain" }
               | err e2 |> koru/sqlite3:close.pooled(e2.conn) -> { status: 500, body: "account read failed", content_type: "text/plain" }
           | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }
    | else -> { status: 400, body: "param is missing or the value is empty: user", content_type: "text/plain" }

// ── Sidebar broadcasts ──────────────────────────────────────────────────────
// opens/closeds create → prepend the shared link on the "rooms" stream
// (broadcast_prepend_to :rooms, target: :shared_rooms). The decoded stream
// name is bare "rooms".
pub tor room-broadcast { rid: i64, name: string, rk: string }
room-broadcast =
    views:itoa(n: rid): rids
    |> views:room-link(rk, rid: rids, name): rl
    |> views:stream-wrap(action: "prepend", target: "shared_rooms", html: rl): st
    |> cable:json-quote(s: st): qt
    |> cable:fanout(stream: "rooms", payload: qt)
    |> orisha:generation-bump()

// Rename → broadcast_replace_to :rooms, target: [room, :list].
pub tor room-renamed-broadcast { rid: i64, name: string, rk: string }
room-renamed-broadcast =
    views:itoa(n: rid): rids
    |> views:list-id(rk, rid: rids): lid
    |> views:room-link(rk, rid: rids, name): rl
    |> views:stream-wrap(action: "replace", target: lid, html: rl): st
    |> cable:json-quote(s: st): qt
    |> cable:fanout(stream: "rooms", payload: qt)
    |> orisha:generation-bump()

// Direct create → one prepend per member on their user_<gid>:rooms stream,
// the link rendered with the first other member's name/avatar (the
// reference renders all others comma-joined — multi-member pings get the
// first other here, a known fidelity gap).
pub tor direct-broadcast { rid: i64 }
direct-broadcast =
    views:itoa(n: rid): rids
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT m.user_id, ou.id, ou.name, ou.updated_at
            FROM memberships m
            JOIN users ou ON ou.id = (
                SELECT om.user_id FROM memberships om
                WHERE om.room_id = m.room_id AND om.user_id != m.user_id
                ORDER BY om.user_id LIMIT 1)
            WHERE m.room_id = {{rid}}
        }
        ! row mr |> koru/sqlite3:col.int(stmt: mr, index: 0): muid
                 |> koru/sqlite3:col.int(stmt: mr, index: 1): ouid
                 |> koru/sqlite3:col.text(stmt: mr, index: 2): onm
                 |> koru/sqlite3:col.text(stmt: mr, index: 3): ouat
                 |> views:ts-ver(ts: ouat): v
                 |> signing:user-sgid(id: ouid): sg
                 |> views:first-name(name: onm): fnm
                 |> views:direct-link(rid: rids, name: fnm, sgid: sg, ver: v): dl
                 |> views:stream-wrap(action: "prepend", target: "direct_rooms", html: dl): st
                 |> cable:json-quote(s: st): qt
                 |> signing:urooms-raw(id: muid): us
                 |> cable:fanout(stream: us, payload: qt)
        | done d2 |> koru/sqlite3:close.pooled(conn: d2)
                  |> orisha:generation-bump()
        | err e2 |> koru/sqlite3:close.pooled(e2.conn) |> orisha:generation-bump()
    | err _ |> orisha:generation-bump()

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
! [GET /first_run]   |> first-run-gate(): res -> res
! [POST /first_run]  |> orisha:form(req, name: "user[name]"): fname
                     |> orisha:form(req, name: "user[email_address]"): femail
                     |> orisha:form(req, name: "user[password]"): fpw
                     |> orisha:header(req, name: "User-Agent"): fua
                     |> first-run-create(name: fname, email: femail, password: fpw, user_agent: fua): res -> res
! [GET /session/new] |> sign-in-page(): page -> { status: 200, body: page, content_type: "text/html" }
! [POST /session] |> orisha:form(req, name: "_method"): meth
                  |> session:str-or(s: meth): m2
                  |> if(m2 == "delete")
                     | then |> orisha:cookie(req, name: "session_token"): dtok
                            |> session-destroy(token: dtok): res -> res
                     | else |> orisha:form(req, name: "email_address"): email
                            |> orisha:form(req, name: "password"): password
                            |> orisha:header(req, name: "User-Agent"): ua
                            |> session-login(email, password, user_agent: ua): res -> res
! [GET /rooms/:id] p |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> orisha:header(req, name: "Host"): hst |> views:room-page(rid: p.id, email: ue, host: hst): page |> pages:page-status-or(status: 404): code -> { status: code, body: page, content_type: "text/html", cacheable: true }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [GET /rooms/:id/refresh] p |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> orisha:query-param(req, name: "since"): sn
    |> orisha:header(req, name: "Host"): rhst
    |> room-refresh(rid: p.id, email: ue, since: sn, host: rhst): res -> res
! [GET /rooms/:id/messages] p |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> orisha:query-param(req, name: "before"): before
    |> if(ue != null)
    | then |> orisha:header(req, name: "Host"): mhst |> messages-page(p.id, before, email: ue, host: mhst): page |> pages:page-status(): code -> { status: code, body: page, content_type: "text/html", cacheable: true }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [POST /rooms/:id/messages] p |> orisha:cookie(req, name: "session_token"): tok
    |> signing:cookie-verify(raw: tok): vtok
    |> orisha:form(req, name: "message[body]"): mbody
    |> orisha:form(req, name: "message[client_message_id]"): mcmid
    |> orisha:header(req, name: "Host"): phst
    |> messages:create(rid: p.id, token: vtok, body: mbody, cmid: mcmid, host: phst): res -> res
! [GET /rooms/:id/messages/:mid/edit] p |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> orisha:header(req, name: "Host"): ehst |> messages:edit(rid: p.id, p.mid, email: ue, host: ehst): page |> pages:page-status-or(status: 404): code -> { status: code, body: page, content_type: "text/html" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [GET /rooms/:id/messages/:mid] p |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> orisha:header(req, name: "Host"): ehst |> messages:show(rid: p.id, p.mid, email: ue, host: ehst): page |> pages:page-status-or(status: 404): code -> { status: code, body: page, content_type: "text/html" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [POST /rooms/:id/messages/:mid] p |> orisha:cookie(req, name: "session_token"): tok
    |> signing:cookie-verify(raw: tok): vtok
    |> orisha:form(req, name: "message[body]"): mbody
    |> messages:update(rid: p.id, p.mid, token: vtok, body: mbody): res -> res
! [GET /users/me/sidebar] |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> sidebar-page(user_email: ue): page |> pages:page-status(): code -> { status: code, body: page, content_type: "text/html", cacheable: true }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [GET /searches] |> orisha:cookie(req, name: "session_token"): tok |> orisha:query-param(req, name: "q"): q |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> orisha:header(req, name: "Host"): shst |> search-page(user_email: ue, q, host: shst): page |> pages:page-status(): code -> { status: code, body: page, content_type: "text/html", cacheable: true }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [GET /cable]       |> cable:route(req): res -> res
! [GET /users/:token/avatar] p |> signing:sgid-verify(raw: p.token): uid
    |> if(uid > 0)
    | then |> avatar-lookup(uid): res -> res
    | else -> { status: 404, body: "", content_type: "text/plain" }
! [GET /users/me/profile] |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> orisha:header(req, name: "Host"): hst |> profile-page(email: ue, host: hst): page -> { status: 200, body: page, content_type: "text/html" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [POST /users/me/profile] |> orisha:cookie(req, name: "session_token"): tok
    |> orisha:form(req, name: "user[name]"): un
    |> orisha:form(req, name: "user[email_address]"): uem
    |> orisha:form(req, name: "user[password]"): upw
    |> orisha:form(req, name: "user[bio]"): ubo
    |> profile-update(token: tok, name: un, email: uem, password: upw, bio: ubo): res -> res
! [GET /account/edit] |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> orisha:header(req, name: "Host"): hst |> account-page(email: ue, host: hst): page -> { status: 200, body: page, content_type: "text/html" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [POST /account] |> orisha:cookie(req, name: "session_token"): tok
    |> orisha:form(req, name: "account[name]"): an
    |> orisha:form(req, name: "account[settings_attributes][restrict_room_creation_to_administrators]"): rst
    |> account-update(token: tok, name: an, restrict: rst): res -> res
! [POST /account/join_code] |> orisha:cookie(req, name: "session_token"): tok
    |> join-reset(token: tok): res -> res
! [GET /account/custom_styles/edit] |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> styles-page(email: ue): page -> { status: 200, body: page, content_type: "text/html" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [POST /account/custom_styles] |> orisha:cookie(req, name: "session_token"): tok
    |> orisha:form(req, name: "account[custom_styles]"): acs
    |> styles-update(token: tok, css: acs): res -> res
! [GET /account/bots] |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> orisha:header(req, name: "Host"): hst |> bots-page(email: ue, host: hst): page -> { status: 200, body: page, content_type: "text/html" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [GET /account/bots/new] |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> bot-form(email: ue, action: "/account/bots", method: "", edit_bid: 0): page -> { status: 200, body: page, content_type: "text/html" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [GET /account/bots/:id/edit] p |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> messages:msg-int(s: p.id): bidn
           |> views:bot-action(bid: bidn): bact
           |> bot-form(email: ue, action: bact, method: "patch", edit_bid: bidn): page -> { status: 200, body: page, content_type: "text/html" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [POST /account/bots] |> orisha:cookie(req, name: "session_token"): tok
    |> orisha:form(req, name: "user[name]"): bn
    |> orisha:form(req, name: "user[webhook_url]"): bw
    |> bot-create(token: tok, name: bn, webhook: bw): res -> res
! [POST /account/bots/:id] p |> orisha:cookie(req, name: "session_token"): tok
    |> orisha:form(req, name: "user[name]"): bn
    |> orisha:form(req, name: "user[webhook_url]"): bw
    |> bot-update(token: tok, bid: p.id, name: bn, webhook: bw): res -> res
! [POST /account/bots/:id/key] p |> orisha:cookie(req, name: "session_token"): tok
    |> bot-key-reset(token: tok, bid: p.id): res -> res
! [GET /rooms/opens/new] |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> room-form(email: ue, action: "/rooms/opens", method: "", edit_rid: 0): page -> { status: 200, body: page, content_type: "text/html" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [GET /rooms/opens/:id/edit] p |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> messages:msg-int(s: p.id): erid
           |> views:room-form-action(plural: "opens", rid: erid): ract
           |> room-form(email: ue, action: ract, method: "patch", edit_rid: erid): page -> { status: 200, body: page, content_type: "text/html" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [GET /rooms/closeds/new] |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> room-form(email: ue, action: "/rooms/closeds", method: "", edit_rid: 0): page -> { status: 200, body: page, content_type: "text/html" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [GET /rooms/closeds/:id/edit] p |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> messages:msg-int(s: p.id): erid
           |> views:room-form-action(plural: "closeds", rid: erid): ract
           |> room-form(email: ue, action: ract, method: "patch", edit_rid: erid): page -> { status: 200, body: page, content_type: "text/html" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [POST /rooms/opens] |> orisha:cookie(req, name: "session_token"): tok
    |> orisha:form(req, name: "room[name]"): rn
    |> room-create(token: tok, name: rn, rtype: "Rooms::Open"): res -> res
! [POST /rooms/opens/:id] p |> orisha:cookie(req, name: "session_token"): tok
    |> orisha:form(req, name: "room[name]"): rn
    |> room-update(token: tok, rid: p.id, name: rn, rk: "rooms_open"): res -> res
! [POST /rooms/closeds] |> orisha:cookie(req, name: "session_token"): tok
    |> orisha:form(req, name: "room[name]"): rn
    |> room-create(token: tok, name: rn, rtype: "Rooms::Closed"): res -> res
! [POST /rooms/closeds/:id] p |> orisha:cookie(req, name: "session_token"): tok
    |> orisha:form(req, name: "room[name]"): rn
    |> room-update(token: tok, rid: p.id, name: rn, rk: "rooms_closed"): res -> res
! [GET /rooms/directs/new] |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> if(ue != null)
    | then |> directs-page(email: ue): page -> { status: 200, body: page, content_type: "text/html" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [POST /rooms/directs] |> orisha:cookie(req, name: "session_token"): tok
    |> orisha:form-ids(req, name: "user_ids[]"): fids
    |> orisha:query-param(req, name: "user_ids[]"): qid
    |> session:str-or(s: qid): qids
    |> messages:ids-or(form: fids, query: qids): ids
    |> direct-create(token: tok, ids): res -> res
! [GET /session/transfers/:id] p |> transfer-page(code: p.id): page -> { status: 200, body: page, content_type: "text/html" }
! [POST /session/transfers/:id] p |> orisha:header(req, name: "User-Agent"): tua
    |> transfer-consume(token: null, code: p.id, ua: tua): res -> res
! [PUT /session/transfers/:id] p |> orisha:header(req, name: "User-Agent"): tua
    |> transfer-consume(token: null, code: p.id, ua: tua): res -> res
! [GET /join/:code] p |> join-page(p.code): page
    |> if(page == "")
    | then -> { status: 404, body: "", content_type: "text/plain" }
    | else -> { status: 200, body: page, content_type: "text/html" }
! [POST /join/:code] p |> orisha:form(req, name: "user[name]"): jn
    |> orisha:form(req, name: "user[email_address]"): je
    |> orisha:form(req, name: "user[password]"): jp
    |> orisha:header(req, name: "User-Agent"): jua
    |> join-create(p.code, name: jn, email: je, password: jp, ua: jua): res -> res
! [GET /qr_code/:id] p -> qr-page(enc: p.id)
! [GET /autocompletable/users] |> orisha:cookie(req, name: "session_token"): tok |> current-email(token: tok): ue
    |> orisha:query-param(req, name: "query"): aq
    |> orisha:query-param(req, name: "filter"): af
    |> if(ue != null)
    | then |> session:str-or(s: aq): aq2 |> if(aq2 == "")
        | then |> autocomplete-json(email: ue, q: af): js -> { status: 200, body: js, content_type: "application/json" }
        | else |> autocomplete-json(email: ue, q: aq): js -> { status: 200, body: js, content_type: "application/json" }
    | else -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
! [POST /rooms/:id/:key/messages] p |> orisha:raw-body(req): bbody
    |> orisha:header(req, name: "Host"): bhst
    |> messages:bot-create(rid: p.id, p.key, body: bbody, host: bhst): res -> res
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
