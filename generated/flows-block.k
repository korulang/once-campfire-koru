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
pub tor app-head { title: string } -> string<std/io:allocated!>
app-head =
    views:user-id(): huid
    |> views:user-name(): hun
    |> views:user-metas(uid: huid, name: hun): hmet
    |> views:css-take(): hcss
    |> views:style-wrap(css: hcss): hsty
    |> views:acct-ver(): hver
    |> views:head-render(title, metas: hmet, logo: hver, styles: hsty): h -> h

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
                        |> pages:page-write(text: ml)
               | done m2 |> koru/sqlite3:close.pooled(conn: m2)
                         |> pages:page-take(): membs
                         |> app-head(title: unm): hd
                         |> views:profile-render(head: hd, uid, name: unm, email: em, bio: bo,
                                                 turl, qrpath: qrp, memberships: membs): pg
                         |> std/io:free(content: hd)
                         -> pg
               | err emm |> koru/sqlite3:close.pooled(emm.conn) -> ""
           | err _ -> ""
    | else -> ""

// ── Account edit ────────────────────────────────────────────────────────────
pub tor account-page { email: ?string, host: ?string } -> string
account-page = pages:page-begin()
    |> page-prelude(email): uid
    |> if(uid > 0)
    | then |> views:user-name(): unm
           |> views:user-role(): ur
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
                        |> pages:page-write(text: arow)
               | done m2 |> koru/sqlite3:close.pooled(conn: m2)
                         |> pages:page-take(): usrs
                         |> app-head(title: anm): hd
                         |> views:account-render(head: hd, navadmin: nva, admin: adm, member: mem,
                                                 inviteurl: ivu, qrpath: qrp, regen: rgn, users: usrs): pg
                         |> std/io:free(content: hd)
                         -> pg
               | err emm |> koru/sqlite3:close.pooled(emm.conn) -> ""
           | err _ -> ""
    | else -> ""

// ── Room form (opens/closeds new+edit shared) ────────────────────────────────
// edit_rid == 0 renders the blank new form; >0 pre-fills the current name.
pub tor room-form { email: ?string, action: string, edit_rid: i64 } -> string
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
                            |> pages:page-write(text: ulab)
                   | done d3 |> koru/sqlite3:close.pooled(conn: d3)
                             |> pages:page-take(): usrs
                             |> views:edit-name(): rn2
                             |> app-head(title: rn2): hd
                             |> views:roomform-render(head: hd, action, method: "", name: rn2, users: usrs): pg
                             |> std/io:free(content: hd)
                             -> pg
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
                                |> views:bots-render(head: hd, bots: brows): pg
                                |> std/io:free(content: hd)
                                -> pg
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
                                |> views:botform-render(head: hd, action, method, name: bn2, webhook: bw2): pg
                                |> std/io:free(content: hd)
                                -> pg
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
           |> views:styles-render(head: hd, css): pg
           |> std/io:free(content: hd)
           -> pg
    | else -> ""

// ── Session transfer (unauthenticated — the QR'd link's landing) ────────────
pub tor transfer-page { code: string } -> string
transfer-page =
    views:head-render(title: "Campfire", metas: "", logo: "", styles: ""): hd
    |> views:transfer-render(head: hd, action: code): pg
    |> std/io:free(content: hd)
    -> pg

// ── Join (invite) page — unauthenticated, verified by the join_code ─────────
pub tor join-page { code: string } -> string
join-page =
    config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
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
                            |> views:head-render(title: "Sign up", metas: "", logo: av2, styles: ""): hd
                            |> views:join-render(head: hd, action: code, acctname: an2): pg
                            |> std/io:free(content: hd)
                            -> pg
                     | else -> ""
        | err e |> koru/sqlite3:close.pooled(e.conn) -> ""
    | err _ -> ""

// ── New ping (direct room) ──────────────────────────────────────────────────
pub tor directs-page { email: ?string } -> string
directs-page =
    page-prelude(email): uid
    |> if(uid > 0)
    | then |> views:user-name(): unm
           |> app-head(title: unm): hd
           |> views:directs-render(head: hd): pg
           |> std/io:free(content: hd)
           -> pg
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
                     AND name LIKE '%' || {{qq}} || '%' ESCAPE '\'
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
pub tor qr-page { enc: string } -> string
qr-page =
    qr:decode(enc): url
    |> qr:svg(text: url): svg -> svg

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
        | done d2 |> koru/sqlite3:close.pooled(conn: d2)
                  -> { status: 302, body: "", content_type: "text/plain",
                      extra_headers: "Location: /session/new\r\nSet-Cookie: session_token=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; SameSite=Lax\r\n" }
        | err e |> koru/sqlite3:close.pooled(e.conn) -> { status: 500, body: "logout failed", content_type: "text/plain" }
    | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }

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
                     | then |> session:str-or(s: password): pw
                            |> if(pw != "")
                               | then |> bcrypt:hash(password: pw, cost: 12): dg
                                      |> session:stash-text(text: dg)
                               | else |> session:stash-text(text: "")
                            |> session:take-text(): dg2
                            |> koru/sqlite3:default(conn: d2) {
                                UPDATE users SET name = COALESCE({{name}}, name),
                                    email_address = COALESCE({{email}}, email_address),
                                    bio = {{bio}},
                                    password_digest = COALESCE({{dg2}}, password_digest),
                                    updated_at = CURRENT_TIMESTAMP
                                WHERE id = {{uid2}}
                            }
                            | done d3 |> koru/sqlite3:close.pooled(conn: d3)
                                      |> orisha:generation-bump()
                                      -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /users/me/profile\r\n" }
                            | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> { status: 500, body: "update failed", content_type: "text/plain" }
                     | else |> koru/sqlite3:close.pooled(conn: d2)
                            -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
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
                                   |> orisha:generation-bump()
                                   -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /account/edit\r\n" }
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
                                   |> orisha:generation-bump()
                                   -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /account/edit\r\n" }
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
                                   |> orisha:generation-bump()
                                   -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /account/edit\r\n" }
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
                                           |> orisha:generation-bump()
                                           -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /account/bots\r\n" }
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
                                           |> orisha:generation-bump()
                                           -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /account/bots\r\n" }
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
                         | done d3 |> koru/sqlite3:close.pooled(conn: d3)
                                   -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /account/bots\r\n" }
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
                                                        |> session:redirect-to(path: rp): rhdr
                                                        -> { status: 302, body: "", content_type: "text/plain", extra_headers: rhdr }
                                              | err e5 |> koru/sqlite3:close.pooled(e5.conn) -> { status: 500, body: "grant failed", content_type: "text/plain" }
                                          | else |> koru/sqlite3:default(conn: d4) {
                                                  INSERT INTO memberships (room_id, user_id, involvement, created_at, updated_at)
                                                  VALUES ({{rid2}}, {{uid2}}, 'mentions', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                                              }
                                              | done d5 |> koru/sqlite3:close.pooled(conn: d5)
                                                        |> session:str-or(s: name): nm0
                                                        |> room-broadcast(rid: rid2, name: nm0, rk: "rooms_closed")
                                                        |> session:room-path(rid: rid2): rp
                                                        |> session:redirect-to(path: rp): rhdr
                                                        -> { status: 302, body: "", content_type: "text/plain", extra_headers: rhdr }
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
                                   |> views:msg-int(s: rid): ridn2
                                   |> room-renamed-broadcast(rid: ridn2, name: nm2, rk)
                                   |> session:room-path(rid: ridn2): rp
                                   |> session:redirect-to(path: rp): rhdr
                                   -> { status: 302, body: "", content_type: "text/plain", extra_headers: rhdr }
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
                                  AND (SELECT COUNT(*) FROM memberships m1 WHERE m1.room_id = r.id AND m1.user_id IN ({{allids}})) = {{nmem}}
                                LIMIT 1
                            }
                            ! row fr |> koru/sqlite3:col.int(stmt: fr, index: 0): fid
                                       |> session:stash-if(ok: true, uid: fid)
                            | done d3 |> session:take-uid(): found
                                      |> if(found > 0)
                                         | then |> koru/sqlite3:close.pooled(conn: d3)
                                                |> session:room-path(rid: found): rp
                                                |> session:redirect-to(path: rp): rhdr
                                                -> { status: 302, body: "", content_type: "text/plain", extra_headers: rhdr }
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
                                                                     FROM users u WHERE u.id IN ({{allids}})
                                                                 }
                                                                 | done d6 |> koru/sqlite3:close.pooled(conn: d6)
                                                                           |> direct-broadcast(rid: rid2)
                                                                           |> session:room-path(rid: rid2): rp
                                                                           |> session:redirect-to(path: rp): rhdr
                                                                           -> { status: 302, body: "", content_type: "text/plain", extra_headers: rhdr }
                                                                 | err e6 |> koru/sqlite3:close.pooled(e6.conn) -> { status: 500, body: "grant failed", content_type: "text/plain" }
                                                       | err e5 |> koru/sqlite3:close.pooled(e5.conn) -> { status: 500, body: "id read failed", content_type: "text/plain" }
                                             | err e4 |> koru/sqlite3:close.pooled(e4.conn) -> { status: 500, body: "create failed", content_type: "text/plain" }
                            | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> { status: 500, body: "find failed", content_type: "text/plain" }
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
                   INSERT INTO sessions (user_id, token, user_agent, ip_address, created_at, updated_at)
                   VALUES ({{uid}}, {{tok}}, {{ua}}, '', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
               }
               | done d2 |> koru/sqlite3:close.pooled(conn: d2)
                         |> session:redirect-signed(cookie: cv): hdr
                         -> { status: 302, body: "", content_type: "text/plain", extra_headers: hdr }
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
                                                            INSERT INTO sessions (user_id, token, user_agent, ip_address, created_at, updated_at)
                                                            VALUES ({{uid2}}, {{tok}}, {{ua}}, '', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
                                                        }
                                                        | done d6 |> koru/sqlite3:close.pooled(conn: d6)
                                                                  |> session:redirect-signed(cookie: cv): hdr
                                                                  |> orisha:generation-bump()
                                                                  -> { status: 302, body: "", content_type: "text/plain", extra_headers: hdr }
                                                        | err e6 |> koru/sqlite3:close.pooled(e6.conn) -> { status: 500, body: "session failed", content_type: "text/plain" }
                                                    | err e5 |> koru/sqlite3:close.pooled(e5.conn) -> { status: 500, body: "grant failed", content_type: "text/plain" }
                                          | err e4 |> koru/sqlite3:close.pooled(e4.conn) -> { status: 500, body: "id read failed", content_type: "text/plain" }
                                | err e3 |> koru/sqlite3:close.pooled(e3.conn)
                                         |> session:redirect-to(path: "/session/new"): hdr2
                                         -> { status: 302, body: "", content_type: "text/plain", extra_headers: hdr2 }
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

// views:msg-int lives in messages; main.k binds it here for the string rid
// room-update carries.
