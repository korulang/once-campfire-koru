// cable — Action Cable's channel policy in flows. index.kz holds the
// mechanism (fd registry, wire envelopes, the ping beat); this file spells
// the DECISIONS: who may upgrade, what each command does, which channel
// confirms, rejects, streams, or stays silent.
//
// The oracle is the Rust port's recorded Rails transcript —
// crates/campfire/src/channels/tests/golden/reference.json — plus the
// channel sources themselves. Where a frame exists in the golden, the
// branch below answers it; divergences too cornered for the wire are
// flagged in comments, never hidden.

import orisha
import koru/yyjson
import koru/sqlite3
import signing

// ============================================================================
// /cable — the upgrade route
// ============================================================================
//
// Server::call: not a websocket request OR a disallowed origin is a 404
// "Page not found" (Rails' respond_to_invalid_request), before auth. The
// 101's body is the connection's first frame: `welcome` once identified,
// or the unauthorized `disconnect` with `close` — the pump frames the body
// and hangs up behind it, which is reject_unauthorized_connection's shape.

pub tor route { req: *orisha:Request } -> orisha:Response

route =
    orisha:header(req, name: "Connection"): connh
    |> orisha:header(req, name: "Upgrade"): uph
    |> upgrade-request(conn_hdr: connh, up_hdr: uph): isws
    |> orisha:header(req, name: "Origin"): orgn
    |> orisha:header(req, name: "Host"): hosth
    |> orisha:header(req, name: "X-Forwarded-Proto"): fwdp
    |> orisha:header(req, name: "X-Forwarded-Ssl"): fwds
    |> origin-ok(origin: orgn, host: hosth, fwd_proto: fwdp, fwd_ssl: fwds): okg
    |> orisha:ws-accept(req): acc
    |> if(isws == 0 or okg == 0 or acc == null)
       | then -> { status: 404, body: "Page not found", content_type: "text/plain; charset=utf-8" }
       | else |> orisha:cookie(req, name: "session_token"): tokr
              |> signing:cookie-verify(raw: tokr): tok
              |> cable-auth(token: tok): uid
              |> orisha:fd(req): fd
              |> orisha:header(req, name: "Sec-WebSocket-Protocol"): off
              |> protocol(offered: off): proto
              |> upgrade-head(acc: acc.?, proto): head
              |> if(uid > 0)
                 | then |> auth-name(): un |> connected(fd, uid, uname: un) -> { status: 101, body: "{\"type\":\"welcome\"}", content_type: "text/plain", extra_headers: head }
                 | else -> { status: 101, body: "{\"type\":\"disconnect\",\"reason\":\"unauthorized\",\"reconnect\":false}", content_type: "text/plain", extra_headers: head, close: true }

// `cookies.signed[:session_token]` → sessions.token → user. A deactivated
// user's sessions are deleted by the deactivate path, so the plain join is
// the whole gate — no status column read needed.
pub tor cable-auth { token: ?string } -> i64
cable-auth =
    if(token == null)
    | then -> 0
    | else |> koru/sqlite3:open.pooled(path: "seed/production.sqlite3")
           | db d |> koru/sqlite3:default(conn: d) {
                   SELECT u.id, u.name FROM sessions s
                   JOIN users u ON u.id = s.user_id
                   WHERE s.token = {{token}} LIMIT 1
               }
               ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): uid
                       |> koru/sqlite3:col.text(stmt: r, index: 1): un
                       |> stash-auth(uid, name: un)
               | done d2 |> koru/sqlite3:close.pooled(conn: d2) |> auth-uid(): auid -> auid
               | err e |> koru/sqlite3:close.pooled(e.conn) -> 0
           | err _ -> 0

// ============================================================================
// dispatch — `! frame` lands here; `command` picks the table
// ============================================================================
//
// A frame that isn't parseable JSON or carries no known command is dropped
// silently — that is the reference's `rescue`-and-log path; nothing ever
// reaches the wire for it.

pub tor dispatch { fd: usize, payload: string }

dispatch =
    koru/yyjson:parse(text: payload)
    | ok doc |> koru/yyjson:root(doc): rv
             |> param-borrow(doc, v: rv, key: "command"): cmd
             |> command-kind(name: cmd)
             | subscribe   |> sub-command(doc, rv, fd)   |> koru/yyjson:close(doc)
             | unsubscribe |> unsub-command(doc, rv, fd) |> koru/yyjson:close(doc)
             | message     |> msg-command(doc, rv, fd)   |> koru/yyjson:close(doc)
             | unknown     |> koru/yyjson:close(doc)
    | err _ |> _

// `subscribe`: parse the identifier (it is itself a JSON document — the
// channel name and params live inside), classify the channel, run its
// subscribed(). A resubscribe (`dupe`) re-runs subscribed but the confirm
// is NOT resent — and the stream registers twice, which the golden's
// double unread fanout proves.
pub tor sub-command { doc: *koru/yyjson:Doc<open>, rv: *koru/yyjson:Value, fd: usize }

sub-command =
    param-borrow(doc, v: rv, key: "identifier"): ident
    |> if(ident == null)
       | then |> _
       | else |> sub-ident(fd, ident: ident.?)

pub tor sub-ident { fd: usize, ident: string }

sub-ident =
    has-sub(fd, ident): dupe
    |> koru/yyjson:parse(text: ident)
    | ok doc2 |> koru/yyjson:root(doc: doc2): rv2
             |> param-borrow(doc: doc2, v: rv2, key: "channel"): cn
             |> channel-kind(name: cn)
             | base      |> add-sub(fd, ident, stream: "", kind: 1, rid: 0)
                          |> confirm-unless(fd, ident, dupe) |> koru/yyjson:close(doc: doc2)
             | heartbeat |> add-sub(fd, ident, stream: "", kind: 2, rid: 0)
                          |> confirm-unless(fd, ident, dupe) |> koru/yyjson:close(doc: doc2)
             | reads     |> sub-user-stream(fd, ident, dupe, suffix: "reads", kind: 4)
                          |> koru/yyjson:close(doc: doc2)
             | unreads   |> sub-user-stream(fd, ident, dupe, suffix: "unreads", kind: 8)
                          |> koru/yyjson:close(doc: doc2)
             | room      |> sub-room(doc: doc2, rv2, fd, ident, dupe, prefix: "room", kind: 5)
                          |> koru/yyjson:close(doc: doc2)
             | presence  |> sub-presence(doc: doc2, rv2, fd, ident, dupe)
                          |> koru/yyjson:close(doc: doc2)
             | typing    |> sub-room(doc: doc2, rv2, fd, ident, dupe, prefix: "typing_notifications", kind: 7)
                          |> koru/yyjson:close(doc: doc2)
             | messages  |> sub-messages(doc: doc2, rv2, fd, ident, dupe)
                          |> koru/yyjson:close(doc: doc2)
             | turbo     |> sub-turbo(doc: doc2, rv2, fd, ident, dupe)
                          |> koru/yyjson:close(doc: doc2)
             | unknown   |> koru/yyjson:close(doc: doc2)
    | err _ |> _

// EmptyChannel channels confirm with no streams; user streams
// (ReadRoomsChannel, UnreadRoomsChannel) confirm and register
// `user_<id>_reads` / `user_<id>_unreads` — stream_from, no prefix.
pub tor sub-user-stream { fd: usize, ident: string, dupe: i64, suffix: string, kind: i64 }

sub-user-stream =
    uid-of(fd): uid
    |> user-stream(uid, suffix): sm
    |> add-sub(fd, ident, stream: sm, kind, rid: 0)
    |> confirm-unless(fd, ident, dupe)

// RoomChannel-family subscribe: `current_user.rooms.find_by(room_id)` —
// the cast (`to_i`, truncation) already happened in param-id; a nil id and
// a non-member both reject. On member, stream `<channel_name>:<room gid>`
// built from the row's stored STI type, then confirm (first time only).
pub tor sub-room { doc: *koru/yyjson:Doc<open>, rv2: *koru/yyjson:Value,
                   fd: usize, ident: string, dupe: i64, prefix: string, kind: i64 }

sub-room =
    param-id(doc, v: rv2, key: "room_id"): rid
    |> if(rid == null)
       | then |> reject(fd, ident)
       | else |> uid-of(fd): uid
              |> member-check(uid, rid: rid.?): okm
              |> if(okm == 1)
                 | then |> take-rtype(): rt |> gid-param(rtype: rt, rid: rid.?): gp
                        |> chan-stream(prefix, gp): sm
                        |> add-sub(fd, ident, stream: sm, kind, rid: rid.?)
                        |> confirm-unless(fd, ident, dupe)
                 | else |> if(okm == 0)
                    | then |> reject(fd, ident)

// PresenceChannel#subscribed = room::subscribe + on_subscribe :present —
// after the confirm, `Membership#present` runs and `broadcast_read_room`
// lands on the subscriber's own reads stream (the golden's step-7 second
// frame). A `subscribed` perform re-runs only room::subscribe (quiet).
pub tor sub-presence { doc: *koru/yyjson:Doc<open>, rv2: *koru/yyjson:Value,
                       fd: usize, ident: string, dupe: i64 }

sub-presence =
    param-id(doc, v: rv2, key: "room_id"): rid
    |> if(rid == null)
       | then |> reject(fd, ident)
       | else |> uid-of(fd): uid
              |> member-check(uid, rid: rid.?): okm
              |> if(okm == 1)
                 | then |> take-rtype(): rt |> gid-param(rtype: rt, rid: rid.?): gp
                        |> chan-stream(prefix: "presence", gp): sm
                        |> add-sub(fd, ident, stream: sm, kind: 3, rid: rid.?)
                        |> confirm-unless(fd, ident, dupe)
                        |> if(dupe == 0)
                           | then |> present(uid, rid: rid.?)
                 | else |> if(okm == 0)
                    | then |> reject(fd, ident)

// `on_subscribe :present` — Membership#connect then broadcast_read_room.
// The two statements fold the reference's conditional arithmetic into CASE
// arms over the 60s CONNECTION_TTL cutoff.
pub tor present { uid: i64, rid: i64 }

present =
    koru/sqlite3:open.pooled(path: "seed/production.sqlite3")
    | db d |> koru/sqlite3:default(conn: d) {
            UPDATE memberships SET
              connections = CASE WHEN connected_at IS NOT NULL
                                  AND connected_at >= datetime('now','-60 seconds')
                                 THEN COALESCE(connections,0) + 1 ELSE 1 END,
              connected_at = datetime('now'),
              unread_at = NULL
            WHERE user_id = {{uid}} AND room_id = {{rid}}
        }
        | done d2 |> koru/sqlite3:close.pooled(conn: d2)
                  |> read-room-fanout(uid, rid)
        | err e |> koru/sqlite3:close.pooled(e.conn)
    | err _ |> _

pub tor read-room-fanout { uid: i64, rid: i64 }

read-room-fanout =
    room-payload(rid, key: "room_id"): rp
    |> user-stream(uid, suffix: "reads"): rs
    |> fanout(stream: rs, payload: rp)

// `Membership#disconnected` — decrement while connected, clear
// connected_at once the count empties. The second statement's updated_at
// touch is the reference's `disconnected` tail exactly.
pub tor membership-disconnect { uid: i64, rid: i64 }

membership-disconnect =
    koru/sqlite3:open.pooled(path: "seed/production.sqlite3")
    | db d |> koru/sqlite3:default(conn: d) {
            UPDATE memberships SET
              connections = CASE WHEN connected_at IS NOT NULL
                                  AND connected_at >= datetime('now','-60 seconds')
                                 THEN COALESCE(connections,0) - 1 ELSE 0 END,
              updated_at = datetime('now')
            WHERE user_id = {{uid}} AND room_id = {{rid}}
        }
        | done d2 |> koru/sqlite3:default(conn: d2) {
                    UPDATE memberships SET connected_at = NULL, updated_at = datetime('now')
                    WHERE user_id = {{uid}} AND room_id = {{rid}}
                      AND connections < 1 AND connected_at IS NOT NULL
                }
                | done d3 |> koru/sqlite3:close.pooled(conn: d3)
                | err e2 |> koru/sqlite3:close.pooled(e2.conn)
        | err e |> koru/sqlite3:close.pooled(e.conn)
    | err _ |> _

// `Membership#refresh_connection`: bump the count only when the connection
// went stale, always touch connected_at.
pub tor membership-refresh { uid: i64, rid: i64 }

membership-refresh =
    koru/sqlite3:open.pooled(path: "seed/production.sqlite3")
    | db d |> koru/sqlite3:default(conn: d) {
            UPDATE memberships SET
              connections = CASE WHEN NOT (connected_at IS NOT NULL
                                  AND connected_at >= datetime('now','-60 seconds'))
                                  AND connections != 1 THEN 1 ELSE connections END,
              connected_at = datetime('now'),
              updated_at = datetime('now')
            WHERE user_id = {{uid}} AND room_id = {{rid}}
        }
        | done d2 |> koru/sqlite3:close.pooled(conn: d2)
        | err e |> koru/sqlite3:close.pooled(e.conn)
    | err _ |> _

// `current_user.rooms.find_by` — membership join returning the room's
// stored type; rtype rides the threadlocal cell out of `! row`. 1 member /
// 0 none / -1 db error (the reference's ChannelError → silent).
pub tor member-check { uid: i64, rid: i64 } -> i64

member-check =
    koru/sqlite3:open.pooled(path: "seed/production.sqlite3")
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT r.type FROM rooms r
            JOIN memberships m ON m.room_id = r.id
            WHERE m.user_id = {{uid}} AND r.id = {{rid}} LIMIT 1
        }
        ! row rr |> koru/sqlite3:col.text(stmt: rr, index: 0): rt |> stash-rtype(s: rt)
        | done d2 |> koru/sqlite3:close.pooled(conn: d2) |> rtype-seen(): seen -> seen
        | err e |> koru/sqlite3:close.pooled(e.conn) -> -1
    | err _ -> -1

// RoomMessagesChannel: signed_stream_name must verify, parse to a room
// gid (only: Room), and the user must belong. An unrecognised model is a
// NameError in the reference — silent, no reject frame.
pub tor sub-messages { doc: *koru/yyjson:Doc<open>, rv2: *koru/yyjson:Value,
                       fd: usize, ident: string, dupe: i64 }

sub-messages =
    param-borrow(doc, v: rv2, key: "signed_stream_name"): ssn
    |> if(ssn == null)
       | then |> reject(fd, ident)
       | else |> signing:stream-verify(signed: ssn.?): vname
              |> if(vname == null)
                 | then |> reject(fd, ident)
                 | else |> room-gid(stream: vname.?): rid
                        |> if(rid == -2)
                           | then |> _
                           | else |> if(rid <= 0)
                                   | then |> reject(fd, ident)
                                   | else |> gid-type(): gt |> uid-of(fd): uid
                                          |> member-gid-check(uid, rid, gtype: gt): okm
                                          |> if(okm == 1)
                                             | then |> add-sub(fd, ident, stream: vname.?, kind: 6, rid)
                                                    |> confirm-unless(fd, ident, dupe)
                                             | else |> if(okm == 0)
                                                    | then |> reject(fd, ident)

// Turbo::StreamsChannel: same verify, but `guarded_stream?` rejects every
// `*:messages` stream — those belong to RoomMessagesChannel. Any other
// verified name streams. No membership check — the stream name itself is
// the capability.
pub tor sub-turbo { doc: *koru/yyjson:Doc<open>, rv2: *koru/yyjson:Value,
                    fd: usize, ident: string, dupe: i64 }

sub-turbo =
    param-borrow(doc, v: rv2, key: "signed_stream_name"): ssn
    |> if(ssn == null)
       | then |> reject(fd, ident)
       | else |> signing:stream-verify(signed: ssn.?): vname
              |> if(vname == null)
                 | then |> reject(fd, ident)
                 | else |> room-guard(stream: vname.?): gd
                        |> if(gd == 1)
                           | then |> reject(fd, ident)
                           | else |> add-sub(fd, ident, stream: vname.?, kind: 9, rid: 0)
                                    |> confirm-unless(fd, ident, dupe)

// The membership join for a gid-scoped subscribe: `Room` in the gid means
// the base class (any STI row); a `Rooms::*` name pins the type.
pub tor member-gid-check { uid: i64, rid: i64, gtype: string } -> i64

member-gid-check =
    koru/sqlite3:open.pooled(path: "seed/production.sqlite3")
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT 1 FROM rooms r
            JOIN memberships m ON m.room_id = r.id
            WHERE m.user_id = {{uid}} AND r.id = {{rid}}
              AND ({{gtype}} = 'Room' OR r.type = {{gtype}}) LIMIT 1
        }
        ! row rr |> stash-rtype(s: "x")
        | done d2 |> koru/sqlite3:close.pooled(conn: d2) |> rtype-seen(): seen -> seen
        | err e |> koru/sqlite3:close.pooled(e.conn) -> -1
    | err _ -> -1

// `unsubscribe`: drop the identifier's entries; a presence sub owes
// absent() — Membership#disconnected only, no broadcast. `! gone-room`
// rides out of the registry to where sqlite is reachable.
pub tor unsub-command { doc: *koru/yyjson:Doc<open>, rv: *koru/yyjson:Value, fd: usize }

unsub-command =
    param-borrow(doc, v: rv, key: "identifier"): ident
    |> if(ident == null)
       | then |> _
       | else |> drop-sub(fd, ident: ident.?)
              ! gone-room g |> membership-disconnect(g.uid, g.rid)
              | ok |> _
              | missing |> _

// `message`: `data` is a JSON-encoded string (Rails parses it); `action`
// inside picks the perform. Only presence and typing have performs that
// reach the wire — everything else returns "unhandled" in the reference
// and produces nothing.
pub tor msg-command { doc: *koru/yyjson:Doc<open>, rv: *koru/yyjson:Value, fd: usize }

msg-command =
    param-borrow(doc, v: rv, key: "identifier"): ident
    |> if(ident == null)
       | then |> _
       | else |> sub-kind(fd, ident: ident.?): k
              |> param-borrow(doc, v: rv, key: "data"): dstr
              |> if(dstr == null)
                 | then |> _
                 | else |> msg-dispatch(fd, ident: ident.?, k, dstr: dstr.?)

pub tor msg-dispatch { fd: usize, ident: string, k: i64, dstr: string }

msg-dispatch =
    koru/yyjson:parse(text: dstr)
    | ok doc2 |> koru/yyjson:root(doc: doc2): rv2
             |> param-borrow(doc: doc2, v: rv2, key: "action"): act
             |> if(k == 3)
                | then |> presence-action(name: act)
                       | present    |> presence-present(fd, ident) |> koru/yyjson:close(doc: doc2)
                       | absent     |> presence-absent(fd, ident)  |> koru/yyjson:close(doc: doc2)
                       | refresh    |> presence-refresh(fd, ident) |> koru/yyjson:close(doc: doc2)
                       | subscribed |> resub-silent(fd, ident)     |> koru/yyjson:close(doc: doc2)
                       | other      |> koru/yyjson:close(doc: doc2)
                | else |> if(k == 7)
                        | then |> typing-action(name: act)
                               | start      |> typing-cast(fd, ident, action: "start"): _ |> koru/yyjson:close(doc: doc2)
                               | stop       |> typing-cast(fd, ident, action: "stop"): _ |> koru/yyjson:close(doc: doc2)
                               | subscribed |> resub-silent(fd, ident) |> koru/yyjson:close(doc: doc2)
                               | other      |> koru/yyjson:close(doc: doc2)
                        | else |> if(act != null and act == "subscribed")
                                | then |> resub-silent(fd, ident) |> koru/yyjson:close(doc: doc2)
                                | else |> koru/yyjson:close(doc: doc2)
    | err _ |> _

// `perform("subscribed")` re-runs the channel's subscribed() with the
// ORIGINAL params — the identifier is reparsed and re-registered, still no
// confirm. For reads/unreads/base/heartbeat the sub is re-registered or
// re-checked; `sub-ident` with dupe forced quiet spells it.
pub tor resub-silent { fd: usize, ident: string }

resub-silent =
    koru/yyjson:parse(text: ident)
    | ok doc3 |> koru/yyjson:root(doc: doc3): rv3
             |> param-borrow(doc: doc3, v: rv3, key: "channel"): cn
             |> channel-kind(name: cn)
             | base      |> add-sub(fd, ident, stream: "", kind: 1, rid: 0) |> koru/yyjson:close(doc: doc3)
             | heartbeat |> add-sub(fd, ident, stream: "", kind: 2, rid: 0) |> koru/yyjson:close(doc: doc3)
             | reads     |> sub-user-stream(fd, ident, dupe: 1, suffix: "reads", kind: 4) |> koru/yyjson:close(doc: doc3)
             | unreads   |> sub-user-stream(fd, ident, dupe: 1, suffix: "unreads", kind: 8) |> koru/yyjson:close(doc: doc3)
             | room      |> sub-room(doc: doc3, rv2: rv3, fd, ident, dupe: 1, prefix: "room", kind: 5) |> koru/yyjson:close(doc: doc3)
             | presence  |> sub-presence-quiet(doc: doc3, rv2: rv3, fd, ident) |> koru/yyjson:close(doc: doc3)
             | typing    |> sub-room(doc: doc3, rv2: rv3, fd, ident, dupe: 1, prefix: "typing_notifications", kind: 7) |> koru/yyjson:close(doc: doc3)
             | messages  |> sub-messages(doc: doc3, rv2: rv3, fd, ident, dupe: 1) |> koru/yyjson:close(doc: doc3)
             | turbo     |> koru/yyjson:close(doc: doc3)
             | unknown   |> koru/yyjson:close(doc: doc3)
    | err _ |> _

// The quiet shape of sub-presence — room::subscribe WITHOUT on_subscribe
// (perform("subscribed") calls room::subscribe directly, not subscribed()).
pub tor sub-presence-quiet { doc: *koru/yyjson:Doc<open>, rv2: *koru/yyjson:Value,
                             fd: usize, ident: string }

sub-presence-quiet =
    param-id(doc, v: rv2, key: "room_id"): rid
    |> if(rid == null)
       | then |> _
       | else |> uid-of(fd): uid
              |> member-check(uid, rid: rid.?): okm
              |> if(okm == 1)
                 | then |> take-rtype(): rt |> gid-param(rtype: rt, rid: rid.?): gp
                        |> chan-stream(prefix: "presence", gp): sm
                        |> add-sub(fd, ident, stream: sm, kind: 3, rid: rid.?)

// `present` from a perform — membership + read_room, riding the sub's
// bound rid.
pub tor presence-present { fd: usize, ident: string }

presence-present =
    sub-rid(fd, ident): rid
    |> uid-of(fd): uid
    |> if(uid > 0 and rid > 0)
       | then |> present(uid, rid)

// `absent` — Membership#disconnected, no broadcast.
pub tor presence-absent { fd: usize, ident: string }

presence-absent =
    sub-rid(fd, ident): rid
    |> uid-of(fd): uid
    |> if(uid > 0 and rid > 0)
       | then |> membership-disconnect(uid, rid)

// `refresh` — Membership#refresh_connection, silent on the wire.
pub tor presence-refresh { fd: usize, ident: string }

presence-refresh =
    sub-rid(fd, ident): rid
    |> uid-of(fd): uid
    |> if(uid > 0 and rid > 0)
       | then |> membership-refresh(uid, rid)

// ============================================================================
// ! closed — the pump is reaping a socket
// ============================================================================
//
// Every presence registration owes Membership#disconnected; `dropped`
// fires `! gone-room` per such sub, which lands here where sqlite lives.

pub tor gone { g: *GoneRoom }

gone =
    membership-disconnect(g.uid, g.rid)

// ============================================================================
// helpers
// ============================================================================

pub tor confirm-unless { fd: usize, ident: string, dupe: i64 }

confirm-unless =
    if(dupe == 0)
    | then |> confirm(fd, ident)

// ============================================================================
// mechanism decls — implemented in index.kz
// ============================================================================

pub tor connected { fd: usize, uid: i64, uname: string }

pub tor dropped { fd: usize }
! gone-room *GoneRoom
| ok
| stale

pub tor has-sub { fd: usize, ident: string } -> i64

pub tor uid-of { fd: usize } -> i64

pub tor add-sub { fd: usize, ident: string, stream: string, kind: i64, rid: i64 }

pub tor drop-sub { fd: usize, ident: string }
! gone-room *GoneRoom
| ok
| missing

pub tor sub-kind { fd: usize, ident: string } -> i64

pub tor sub-stream { fd: usize, ident: string } -> string

pub tor confirm { fd: usize, ident: string }

pub tor reject { fd: usize, ident: string }

pub tor fanout { stream: string, payload: string }

// `broadcast_unread_room` — member uids are read on the request thread's
// pooled conn before the write is enqueued (member-stash, one per row),
// then unreads-cast delivers `{roomId}` to each `user_<id>_unreads` stream
// after the append, matching broadcast order.
pub tor members-reset {}
pub tor member-stash { uid: i64 }
pub tor unreads-cast { rid: i64 }

pub tor json-quote { s: string } -> string

pub tor kick { uid: i64, reconnect: bool }

pub tor upgrade-head { acc: string, proto: ?string } -> string

pub tor protocol { offered: ?string } -> ?string

pub tor upgrade-request { conn_hdr: ?string, up_hdr: ?string } -> i64

pub tor origin-ok { origin: ?string, host: ?string, fwd_proto: ?string, fwd_ssl: ?string } -> i64

pub tor param-borrow { doc: *koru/yyjson:Doc<open>, v: *koru/yyjson:Value, key: string } -> ?string

pub tor param-id { doc: *koru/yyjson:Doc<open>, v: *koru/yyjson:Value, key: string } -> ?i64

pub tor gid-type {} -> string

pub tor room-gid { stream: string } -> i64

pub tor gid-param { rtype: string, rid: i64 } -> string

pub tor user-stream { uid: i64, suffix: string } -> string

pub tor typing-cast { fd: usize, ident: string, action: string } -> i64

pub tor room-payload { rid: i64, key: string } -> string

pub tor chan-stream { prefix: string, gp: string } -> string

pub tor stash-rtype { s: string }

pub tor take-rtype {} -> string

pub tor sub-rid { fd: usize, ident: string } -> i64

pub tor command-kind { name: ?string }
| subscribe
| unsubscribe
| message
| unknown

pub tor channel-kind { name: ?string }
| base
| heartbeat
| presence
| reads
| room
| messages
| typing
| unreads
| turbo
| unknown

pub tor presence-action { name: ?string }
| present
| absent
| refresh
| subscribed
| other

pub tor typing-action { name: ?string }
| start
| stop
| subscribed
| other

pub tor room-guard { stream: string } -> i64

pub tor stash-auth { uid: i64, name: string }

pub tor auth-uid {} -> i64

pub tor auth-name {} -> string

pub tor rtype-seen {} -> i64
