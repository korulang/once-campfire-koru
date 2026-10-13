// messages — MessagesController#create as a flow: authenticate the signed
// session, gate on room membership, write message + Action Text row, run
// the reference's bookkeeping (room touch, unread sweep, FTS index), then
// broadcast_create — the detached partial append to the room's message
// stream, then {roomId} to every member's unreads — and answer with the
// same turbo-stream the broadcast carried.
//
// The oracle is crates/campfire/src/controllers/messages.rs (create,
// create_message, canonical_body) + channels/broadcasts.rs
// (message_create). Named gaps vs the reference, recorded here rather
// than hidden in the flow:
//   - canonicalize_body (ActionText::Content::load — sanitizer, SGID and
//     attachment resolution) is not ported; the submitted body stores
//     verbatim. Bodies arrive as the Trix editor emits them.
//   - process_attachment and deliver_webhooks_to_bots have no surface —
//     no Active Storage, no bots.
//   - RoomNotFound renders a 200 view inside the app layout upstream;
//     this path answers a bare 404 status instead.
//   - Writes run under one transaction (BEGIN IMMEDIATE … COMMIT, with
//     ROLLBACK on any failure) instead of the reference's db.transaction —
//     same all-or-nothing guarantee. The transaction runs on ONE dedicated
//     writer thread rather than the request workers' pooled connections,
//     removing the WAL write-lock contention and the inline checkpoint
//     from the POST path. The writer signals the inserted id EARLY (right
//     after the INSERT), so the request thread renders the broadcast
//     markup in parallel with the remaining statements, then fans out only
//     after the commit signal.

import orisha
import koru/sqlite3
import config
import cable
import signing
import views
import session
import pages
import std/io

pub tor msg-reset {}
pub tor stash-creator { uid: i64, name: string, bio: string, ver: string }
pub tor cr-authed {} -> bool
pub tor cr-uid {} -> i64
pub tor cr-name {} -> string
pub tor cr-bio {} -> string
pub tor cr-ver {} -> string
pub tor msg-now {} -> string
pub tor msg-cutoff {} -> string
pub tor msg-uuid {} -> string
pub tor cmid-or { supplied: ?string } -> string
pub tor msg-int { s: string } -> i64
pub tor str-or { s: ?string } -> string
pub tor plain-text { html: string<*> } -> string
pub tor msg-target { key: string, rid: string } -> string
pub tor turbo-wrap { target: string, html: string<*> } -> string
pub tor respond-created { body: string } -> orisha:Response

// The write pipeline, split into three request-thread steps around the
// dedicated writer's FIFO:
//   msg-enqueue   — enqueue the job (blocks while the ring is full).
//   msg-wait-mid  — wait for the post-INSERT mid signal, hand back the id.
//   msg-wait-done — wait for COMMIT/ROLLBACK; true only on commit.
// The request thread renders between wait-mid and wait-done, overlapping
// the writer's remaining statements, then broadcasts after wait-done.
pub tor msg-enqueue { uid: i64, rid: i64, cmid: string, ts: string,
                      body: string, cut: string, ptext: string }
pub tor msg-wait-mid {} -> i64
pub tor msg-wait-done {} -> bool

// The render + broadcast halves of broadcast_create, so the render can run
// before the commit while fanout/unreads/response wait for it.
pub tor stash-render { stream: string, payload: string, body: string } -> string
pub tor render-stream {} -> string
pub tor render-payload {} -> string

pub tor create { rid: string, token: ?string, body: ?string, cmid: ?string,
                 host: ?string } -> orisha:Response
pub tor broadcast-render { rid: string, ridn: i64, midn: i64, uidn: i64,
                           cmidx: string, ts: string, mbody: string,
                           host: ?string } -> string
pub tor broadcast-send { rid: i64, body: string } -> orisha:Response
pub tor bot-send { rid: i64, mid: i64 } -> orisha:Response
pub tor bot-create { rid: string, key: string, body: string,
                     host: ?string } -> orisha:Response
pub tor bot-location { mid: i64 } -> string
pub tor respond-located { loc: string } -> orisha:Response
pub tor ids-or { form: string, query: string } -> string

create =
    msg-reset()
    |> cable:members-reset()
    |> if(token == null)
    | then -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
    | else |> if(body == null)
        | then -> { status: 400, body: "param is missing or the value is empty: message", content_type: "text/plain" }
        | else |> msg-int(s: rid): ridn
               |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
               | db d |> koru/sqlite3:default(conn: d) {
                       SELECT u.id, u.name, u.bio, u.updated_at FROM sessions s
                       JOIN users u ON u.id = s.user_id
                       WHERE s.token = {{token}} LIMIT 1
                   }
                   ! row ar |> koru/sqlite3:col.int(stmt: ar, index: 0): cuid
                            |> koru/sqlite3:col.text(stmt: ar, index: 1): cnm
                            |> koru/sqlite3:col.text(stmt: ar, index: 2): cbio
                            |> koru/sqlite3:col.text(stmt: ar, index: 3): cver
                            |> stash-creator(uid: cuid, name: cnm, bio: cbio, ver: cver)
                   | done d2 |> cr-authed(): authed
                             |> cr-uid(): uidn
                             |> if(authed)
                             | then |> koru/sqlite3:default(conn: d2) {
                                     SELECT r.name, r.type FROM rooms r
                                     JOIN memberships m ON m.room_id = r.id
                                     WHERE m.user_id = {{uidn}} AND r.id = {{ridn}} LIMIT 1
                                 }
                                 ! row rr |> koru/sqlite3:col.text(stmt: rr, index: 0): rnm
                                          |> koru/sqlite3:col.text(stmt: rr, index: 1): rtp
                                          |> views:stash-room(name: rnm, rtype: rtp)
                                 | done d3 |> views:room-present(): rf
                                           |> if(rf)
                                           | then |> str-or(s: body): mbody
                                                  |> msg-now(): ts
                                                  |> cmid-or(supplied: cmid): cmidx
                                                  |> msg-cutoff(): cut
                                                  |> plain-text(html: mbody): ptxt
                                                  |> koru/sqlite3:default(conn: d3) {
                                                          SELECT m.user_id FROM memberships m WHERE m.room_id = {{ridn}}
                                                      }
                                                      ! row mr |> koru/sqlite3:col.int(stmt: mr, index: 0): muid
                                                               |> cable:member-stash(uid: muid)
                                                      | done d4 |> koru/sqlite3:close.pooled(conn: d4)
                                                                |> msg-enqueue(uid: uidn, rid: ridn, cmid: cmidx, ts, body: mbody, cut, ptext: ptxt)
                                                                |> msg-wait-mid(): midn
                                                                |> broadcast-render(rid, ridn, midn, uidn, cmidx, ts, mbody, host): shtml
                                                                |> msg-wait-done(): wok
                                                                |> if(wok)
                                                                   | then |> orisha:generation-bump()
                                                                          |> broadcast-send(rid: ridn, body: shtml): res -> res
                                                                   | else -> { status: 500, body: "write failed", content_type: "text/plain" }
                                                      | err e4 |> koru/sqlite3:close.pooled(e4.conn) -> { status: 500, body: "member read failed", content_type: "text/plain" }
                                           | else |> koru/sqlite3:close.pooled(conn: d3) -> { status: 404, body: "Room not found", content_type: "text/plain" }
                                 | err e2 |> koru/sqlite3:close.pooled(e2.conn) -> { status: 500, body: "room lookup failed", content_type: "text/plain" }
                             | else |> koru/sqlite3:close.pooled(conn: d2) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
                   | err e |> koru/sqlite3:close.pooled(e.conn) -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
               | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }

// Render half of broadcast_create: build the detached partial, wrap it in
// the append turbo-stream, and JSON-quote it for the fanout. Runs between
// msg-wait-mid and msg-wait-done — the CPU work overlaps the writer's
// remaining statements. Stashes the fanout stream + quoted payload so
// broadcast-send can fire them after the commit.
broadcast-render =
    cr-name(): anm
    |> cr-bio(): abio
    |> cr-ver(): aver
    |> views:user-title(name: anm, bio: abio): atitle
    |> views:ts-ver(ts: aver): uver
    |> signing:user-sgid(id: uidn): usg
    |> views:room-name(): rname
    |> views:room-key(): rkey
    |> views:room-type(): rt
    |> views:ts-ms(ts): ms
    |> views:ts-iso(ts): iso
    |> views:message-render(cmid: cmidx, mid: midn, uid: uidn, rid, ms, ums: ms, iso, author: anm, atitle, uver, usgid: usg, roomname: rname, body: mbody, boosts: "", host): mhtml
    |> msg-target(key: rkey, rid): tgt
    |> turbo-wrap(target: tgt, html: mhtml): shtml
    |> std/io:free(content: mhtml)
    |> cable:gid-param(rtype: rt, rid: ridn): gp
    |> cable:chan-stream(prefix: gp, gp: "messages"): mstream
    |> cable:json-quote(s: shtml): qhtml
    |> stash-render(stream: mstream, payload: qhtml, body: shtml): body -> body

// Send half of broadcast_create: the append fanout, {roomId} to each
// member's unreads, then the same turbo-stream markup as the response.
// Runs only after msg-wait-done reports a committed write.
broadcast-send =
    render-stream(): mstream
    |> render-payload(): qhtml
    |> cable:fanout(stream: mstream, payload: qhtml)
    |> cable:unreads-cast(rid)
    |> respond-created(body): res -> res

// ── Edit / update / show ────────────────────────────────────────────────────
// MessagesController#edit renders the message inside a turbo-frame carrying
// a lexxy editor; #update writes the new body and broadcast_replace_to's
// the presentation target; #show is the redirect + close-link target.
pub tor stash-cmid { s: string }
pub tor msg-cmid {} -> string
pub tor msg-path { rid: string, mid: string } -> string
pub tor present-wrap { cmid: string, body: string } -> string

pub tor edit { rid: string, mid: string, email: ?string,
               host: ?string } -> string
pub tor show { rid: string, mid: string, email: ?string,
               host: ?string } -> string
pub tor update { rid: string, mid: string, token: ?string,
                 body: ?string } -> orisha:Response

// edit — ensure_can_administer lives in the query: creator or account
// administrator. The frame renders the reference's messages/edit.html —
// lexxy-editor carrying the current body in its value attribute.
edit =
    msg-reset()
    |> if(email == null)
    | then -> ""
    | else |> msg-int(s: rid): ridn
           |> msg-int(s: mid): midn
           |> pages:page-begin()
           |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
           | db d |> koru/sqlite3:default(conn: d) {
                   SELECT m.client_message_id, rt.body
                   FROM messages m
                   JOIN action_text_rich_texts rt
                     ON rt.record_type = 'Message' AND rt.record_id = m.id
                   WHERE m.id = {{midn}} AND m.room_id = {{ridn}}
                     AND (m.creator_id = (SELECT u.id FROM users u
                                          WHERE u.email_address = {{email}})
                          OR (SELECT u.role FROM users u
                              WHERE u.email_address = {{email}}) > 0)
                   LIMIT 1
               }
               ! row mr |> koru/sqlite3:col.text(stmt: mr, index: 0): ecmid
                        |> koru/sqlite3:col.text(stmt: mr, index: 1): ebody
                        |> views:edit-render(cmid: ecmid, rid, mid: midn,
                                             body: ebody, host): mt
                        |> pages:page-write(text: mt)
                        |> std/io:free(content: mt)
               | done d2 |> koru/sqlite3:close.pooled(conn: d2)
                         |> pages:page-take(): page -> page
               | err e |> koru/sqlite3:close.pooled(e.conn)
                         |> pages:page-take(): partial -> partial
           | err _ |> pages:page-take(): partial -> partial

// show — render @message. The turbo-frame navigation after update (and the
// edit close link) extracts edit_message_<cmid> out of this response.
show =
    msg-reset()
    |> if(email == null)
    | then -> ""
    | else |> msg-int(s: rid): ridn
           |> msg-int(s: mid): midn
           |> pages:page-begin()
           |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
           | db d |> koru/sqlite3:default(conn: d) {
                   SELECT m.id, m.client_message_id, m.created_at, m.updated_at,
                          u.name, u.id, u.updated_at, rt.body, u.bio, r.name
                   FROM messages m
                   JOIN action_text_rich_texts rt
                     ON rt.record_type = 'Message' AND rt.record_id = m.id
                   JOIN users u ON u.id = m.creator_id
                   JOIN rooms r ON r.id = m.room_id
                   WHERE m.id = {{midn}} AND m.room_id = {{ridn}}
                     AND EXISTS (SELECT 1 FROM memberships mb
                                 JOIN users uu ON uu.id = mb.user_id
                                 WHERE mb.room_id = m.room_id
                                   AND uu.email_address = {{email}})
                   LIMIT 1
               }
               ! row mr |> koru/sqlite3:col.int(stmt: mr, index: 0): mid2
                        |> koru/sqlite3:col.text(stmt: mr, index: 1): cid
                        |> koru/sqlite3:col.text(stmt: mr, index: 2): cat
                        |> koru/sqlite3:col.text(stmt: mr, index: 3): uat
                        |> koru/sqlite3:col.text(stmt: mr, index: 4): anm
                        |> koru/sqlite3:col.int(stmt: mr, index: 5): uid
                        |> koru/sqlite3:col.text(stmt: mr, index: 6): auat
                        |> koru/sqlite3:col.text(stmt: mr, index: 7): body
                        |> koru/sqlite3:col.text(stmt: mr, index: 8): abio
                        |> koru/sqlite3:col.text(stmt: mr, index: 9): rname
                        |> views:user-title(name: anm, bio: abio): atitle
                        |> views:ts-iso(ts: cat): iso
                        |> views:ts-ms(ts: cat): ms
                        |> views:ts-ms(ts: uat): ums
                        |> views:ts-ver(ts: auat): uver
                        |> signing:user-sgid(id: uid): usg
                        |> views:message-render(cmid: cid, mid: mid2, uid,
                                                rid, ms, ums, iso,
                                                author: anm, atitle, uver,
                                                usgid: usg, roomname: rname,
                                                body, boosts: "", host): mt
                        |> pages:page-write(text: mt)
                        |> std/io:free(content: mt)
               | done d2 |> koru/sqlite3:close.pooled(conn: d2)
                         |> pages:page-take(): page -> page
               | err e |> koru/sqlite3:close.pooled(e.conn)
                         |> pages:page-take(): partial -> partial
           | err _ |> pages:page-take(): partial -> partial

// update — permissioned row (creator or administrator) carries the cmid;
// a missing row means not found or forbidden, both a bare 403 here. Writes
// the Action Text body + message.updated_at, broadcast_replace_to's the
// presentation target, then the html-format redirect to the message.
update =
    msg-reset()
    |> cable:members-reset()
    |> if(token == null)
    | then -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
    | else |> if(body == null)
        | then -> { status: 400, body: "param is missing or the value is empty: message", content_type: "text/plain" }
        | else |> msg-int(s: rid): ridn
               |> msg-int(s: mid): midn
               |> str-or(s: body): nbody
               |> msg-now(): nts
               |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
               | db d |> koru/sqlite3:default(conn: d) {
                       SELECT m.client_message_id, r.type, r.name
                       FROM sessions s
                       JOIN users u ON u.id = s.user_id
                       JOIN messages m ON m.id = {{midn}} AND m.room_id = {{ridn}}
                       JOIN rooms r ON r.id = m.room_id
                       WHERE s.token = {{token}}
                         AND (m.creator_id = u.id OR u.role > 0)
                       LIMIT 1
                   }
                   ! row ar |> koru/sqlite3:col.text(stmt: ar, index: 0): mcmid
                            |> koru/sqlite3:col.text(stmt: ar, index: 1): rtp
                            |> koru/sqlite3:col.text(stmt: ar, index: 2): rnm
                            |> stash-cmid(s: mcmid)
                            |> views:stash-room(name: rnm, rtype: rtp)
                   | done d2 |> msg-cmid(): mcmid2
                             |> if(mcmid2 != "")
                             | then |> koru/sqlite3:default(conn: d2) {
                                         UPDATE action_text_rich_texts
                                         SET body = {{nbody}}, updated_at = {{nts}}
                                         WHERE record_type = 'Message' AND record_id = {{midn}}
                                     }
                                     | done d3 |> koru/sqlite3:default(conn: d3) {
                                                     INSERT OR REPLACE INTO message_search_index (rowid, body)
                                                     VALUES ({{midn}}, {{nbody}})
                                                 }
                                                 | done d3f |> koru/sqlite3:default(conn: d3f) {
                                                                 UPDATE messages SET updated_at = {{nts}}
                                                                 WHERE id = {{midn}}
                                                             }
                                                             | done d4 |> koru/sqlite3:close.pooled(conn: d4)
                                                                       |> present-wrap(cmid: mcmid2, body: nbody): shtml
                                                                       |> views:room-type(): rt2
                                                                       |> cable:gid-param(rtype: rt2, rid: ridn): gp
                                                                       |> cable:chan-stream(prefix: gp, gp: "messages"): mstream
                                                                       |> cable:json-quote(s: shtml): qhtml
                                                                       |> cable:fanout(stream: mstream, payload: qhtml)
                                                                       |> orisha:generation-bump()
                                                                       |> msg-path(rid, mid): mp
                                                                       |> session:redirect-to(path: mp): hdr -> { status: 302, body: "", content_type: "text/plain", extra_headers: hdr }
                                                             | err e4 |> koru/sqlite3:close.pooled(e4.conn) -> { status: 500, body: "message update failed", content_type: "text/plain" }
                                                 | err e3f |> koru/sqlite3:close.pooled(e3f.conn) -> { status: 500, body: "index update failed", content_type: "text/plain" }
                                     | err e3 |> koru/sqlite3:close.pooled(e3.conn) -> { status: 500, body: "body update failed", content_type: "text/plain" }
                             | else |> koru/sqlite3:close.pooled(conn: d2) -> { status: 403, body: "Forbidden", content_type: "text/plain" }
                   | err e |> koru/sqlite3:close.pooled(e.conn) -> { status: 500, body: "message lookup failed", content_type: "text/plain" }
               | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }

// ── Bot create ──────────────────────────────────────────────────────────────
// Messages::ByBotsController#create — the bot_key is "id-token" in the path
// (matched by concatenation in SQL), the body is the raw request body, and
// the response is 201 + Location, not the HTML form's turbo-stream. The
// write/broadcast pipeline is create's unchanged: enqueue, render between
// mid and done, fan out after COMMIT.
bot-create =
    msg-reset()
    |> cable:members-reset()
    |> if(body == "")
    | then -> { status: 400, body: "param is missing or the value is empty: message", content_type: "text/plain" }
    | else |> msg-int(s: rid): ridn
           |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
           | db d |> koru/sqlite3:default(conn: d) {
                   SELECT u.id, u.name, u.bio, u.updated_at FROM users u
                   WHERE u.role = 2 AND u.status = 0
                     AND (u.id || '-' || u.bot_token) = {{key}} LIMIT 1
               }
               ! row ar |> koru/sqlite3:col.int(stmt: ar, index: 0): cuid
                        |> koru/sqlite3:col.text(stmt: ar, index: 1): cnm
                        |> koru/sqlite3:col.text(stmt: ar, index: 2): cbio
                        |> koru/sqlite3:col.text(stmt: ar, index: 3): cver
                        |> stash-creator(uid: cuid, name: cnm, bio: cbio, ver: cver)
               | done d2 |> cr-authed(): authed
                         |> cr-uid(): uidn
                         |> if(authed)
                         | then |> koru/sqlite3:default(conn: d2) {
                                 SELECT r.name, r.type FROM rooms r
                                 JOIN memberships m ON m.room_id = r.id
                                 WHERE m.user_id = {{uidn}} AND r.id = {{ridn}} LIMIT 1
                             }
                             ! row rr |> koru/sqlite3:col.text(stmt: rr, index: 0): rnm
                                      |> koru/sqlite3:col.text(stmt: rr, index: 1): rtp
                                      |> views:stash-room(name: rnm, rtype: rtp)
                             | done d3 |> views:room-present(): rf
                                       |> if(rf)
                                       | then |> msg-now(): ts
                                              |> cmid-or(supplied: null): cmidx
                                              |> msg-cutoff(): cut
                                              |> plain-text(html: body): ptxt
                                              |> koru/sqlite3:default(conn: d3) {
                                                      SELECT m.user_id FROM memberships m WHERE m.room_id = {{ridn}}
                                                  }
                                                  ! row mr |> koru/sqlite3:col.int(stmt: mr, index: 0): muid
                                                           |> cable:member-stash(uid: muid)
                                                  | done d4 |> koru/sqlite3:close.pooled(conn: d4)
                                                            |> msg-enqueue(uid: uidn, rid: ridn, cmid: cmidx, ts, body, cut, ptext: ptxt)
                                                            |> msg-wait-mid(): midn
                                                            |> broadcast-render(rid, ridn, midn, uidn, cmidx, ts, mbody: body, host): _
                                                            |> msg-wait-done(): wok
                                                            |> if(wok)
                                                               | then |> orisha:generation-bump()
                                                                      |> bot-send(rid: ridn, mid: midn): res -> res
                                                               | else -> { status: 500, body: "write failed", content_type: "text/plain" }
                                                  | err e4 |> koru/sqlite3:close.pooled(e4.conn) -> { status: 500, body: "member read failed", content_type: "text/plain" }
                                       | else |> koru/sqlite3:close.pooled(conn: d3) -> { status: 404, body: "Room not found", content_type: "text/plain" }
                             | err e2 |> koru/sqlite3:close.pooled(e2.conn) -> { status: 500, body: "room lookup failed", content_type: "text/plain" }
                         | else |> koru/sqlite3:close.pooled(conn: d2) -> { status: 401, body: "", content_type: "text/plain" }
               | err e |> koru/sqlite3:close.pooled(e.conn) -> { status: 401, body: "", content_type: "text/plain" }
           | err _ -> { status: 500, body: "db open failed", content_type: "text/plain" }

// 201 + Location — the fanout half is broadcast-send's verbatim, the
// response is a bare head where the HTML path answers the stream markup.
bot-send =
    render-stream(): mstream
    |> render-payload(): qhtml
    |> cable:fanout(stream: mstream, payload: qhtml)
    |> cable:unreads-cast(rid)
    |> bot-location(mid): loc
    |> orisha:generation-bump()
    |> respond-located(loc): res -> res
