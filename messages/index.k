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
import cable
import signing
import views
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

pub tor create { rid: string, token: ?string, body: ?string, cmid: ?string } -> orisha:Response
pub tor broadcast-render { rid: string, ridn: i64, midn: i64, uidn: i64,
                           cmidx: string, ts: string, mbody: string } -> string
pub tor broadcast-send { rid: i64, body: string } -> orisha:Response

create =
    msg-reset()
    |> cable:members-reset()
    |> if(token == null)
    | then -> { status: 302, body: "", content_type: "text/plain", extra_headers: "Location: /session/new\r\n" }
    | else |> if(body == null)
        | then -> { status: 400, body: "param is missing or the value is empty: message", content_type: "text/plain" }
        | else |> msg-int(s: rid): ridn
               |> koru/sqlite3:open.pooled(path: "seed/production.sqlite3")
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
                                                                |> broadcast-render(rid, ridn, midn, uidn, cmidx, ts, mbody): shtml
                                                                |> msg-wait-done(): wok
                                                                |> if(wok)
                                                                   | then |> broadcast-send(rid: ridn, body: shtml): res -> res
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
    |> views:message-render(cmid: cmidx, mid: midn, uid: uidn, rid, ms, ums: ms, iso, author: anm, atitle, uver, usgid: usg, roomname: rname, body: mbody, boosts: ""): mhtml
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
