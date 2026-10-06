// views — koru/dom components for the Campfire page surface.
//
// Composition is slot-shaped: markup is a balanced tree and `{{ x:h }}`
// writes a string prop verbatim, so a page is one RoomPage shell with the
// caller's rendered rows injected — the `<%= render @messages %>` shape.
// Per-message Action Text bodies go through the same code ({{ body:h }}).
// Day separators carry request state, so they render zig-side and append
// into the row buffer between message components.
//
// Honest approximations (flagged, not hidden): avatar paths are unsigned
// (/users/<id>/avatar — Rails ships an HMAC-signed blob URL), asset hrefs are
// undigested, no CSRF/CSP/asset meta, no signed turbo-stream name, boost menus
// carry the 👍 set only. The wire structure is faithful; the secrets-and-
// digests layer is not.

import koru/dom

// One message row, balanced: avatar + meta + actions + raw Action Text body
// + the boost turbo-frame. `{{ body:h }}` is the trusted-markup slot.
koru/dom:component(Msg) {
    <div id="message_{{ cmid:s }}" class="message " data-controller="reply" data-user-id="{{ uid:d }}" data-message-id="{{ mid:d }}" data-message-timestamp="{{ ms:d }}" data-message-updated-at="{{ ums:d }}" data-sort-value="{{ ms:d }}" data-messages-target="message" data-search-results-target="message" data-refresh-room-target="message" data-reply-composer-outlet="#composer">
    <figure class="avatar message__avatar">
    <a title="{{ author:s }}" class="btn avatar" data-turbo-frame="_top" href="/users/{{ uid:d }}"><img aria-hidden="true" src="/users/{{ uid:d }}/avatar?v={{ ums:d }}" width="48" height="48"></a>
    </figure>
    <turbo-frame id="edit_message_{{ cmid:s }}">
    <div class="message__body">
    <div class="message__body-content">
    <div class="message__meta">
    <h3 class="message__heading">
    <span class="message__author" title="{{ author:s }}"><strong data-reply-target="author">{{ author:s }}</strong></span>
    <a target="_top" class="message__permalink" href="/rooms/{{ rid:s }}/@{{ mid:d }}"><time class="message__timestamp" datetime="{{ iso:s }}" data-local-time-target="time"></time></a>
    <span class="message__room"><a target="_top" data-reply-target="link" href="/rooms/{{ rid:s }}/@{{ mid:d }}">{{ roomname:s }}</a></span>
    </h3>
    <div class="message__actions" data-controller="soft-keyboard">
    <details class="position-relative" data-controller="popup" data-action="keydown.esc-&gt;popup#close toggle-&gt;popup#toggle click@document-&gt;popup#closeOnClickOutside" data-popup-orientation-top-class="popup-orientation-top">
    <summary class="btn message__action-btn message__options-btn"><span class="for-screen-reader">Message options</span></summary>
    <div class="message__actions-menu border shadow" data-popup-target="menu">
    <div class="quick-boosts">
    <form data-turbo-frame="boosting_message_{{ cmid:s }}" data-action="popup#close" action="/messages/{{ mid:d }}/boosts" accept-charset="UTF-8" method="post">
    <input type="hidden" name="boost[content]" value="&#x1F44D;">
    <button name="button" type="submit" title="Thumbs up" class="btn message__action-btn" data-emoji="&#x1F44D;"><figure class="margin-none boost-character">&#x1F44D;</figure><span class="for-screen-reader">Thumbs up</span></button>
    </form>
    </div>
    </div>
    </details>
    </div>
    </div>
    <div id="presentation_message_{{ cmid:s }}" dir="auto" data-reply-target="body" data-messages-target="body">
    <div class="lexxy-content">{{ body:h }}</div>
    </div>
    <turbo-frame id="boosting_message_{{ cmid:s }}">
    <div class="boosts flex flex-wrap align-center gap full-width" data-controller="turbo-streaming" data-action="turbo:submit-start-&gt;turbo-streaming#unsubscribe">
    <div class="flex-inline flex-wrap gap" id="boosts_message_{{ cmid:s }}" data-turbo-streaming-target="container">
    </div>
    <turbo-frame id="new_boost_message_{{ cmid:s }}">
    <div class="flex-inline message__boost-inline" data-controller="soft-keyboard">
    <a class="boost__action txt-small btn" action="soft-keyboard#open" href="/messages/{{ mid:d }}/boosts/new"><span class="for-screen-reader">Add a boost</span></a>
    </div>
    </turbo-frame>
    </div>
    </turbo-frame>
    </div>
    </div>
    </turbo-frame>
    </div>
}

// The whole page, balanced: head + chrome, the messages container holds the
// caller's rendered rows verbatim ({{ rows:h }}), then composer, footer,
// sidebar frame, lightbox, app logo, tail. <!DOCTYPE lives outside the
// dialect — the caller writes it before this render lands in the buffer.
koru/dom:component(RoomPage) {
    <html><head><title>{{ title:s }}</title>
    <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no, interactive-widget=resizes-content">
    <meta name="view-transition" content="same-origin">
    <meta name="color-scheme" content="light dark">
    <meta name="turbo-prefetch" content="true">
    <meta name="current-room-id" content="{{ rid:s }}">
    </head>
    <body class="sidebar" data-controller="local-time lightbox">
    <a href="#main-content" class="skip-navigation btn">Skip to main content</a>
    <nav id="nav">
      <span class="btn btn--reversed btn--faux room--current"><h1 class="room__contents txt-medium overflow-ellipsis">{{ title:s }}</h1></span>
      <a class="btn" href="/rooms/{{ rid:s }}/edit"><span class="for-screen-reader">Room settings</span></a>
    </nav>
    <main id="main-content">
    <div id="message_area" class="message-area" data-controller="messages typing-notifications">
    <div id="messages_{{ msgdom:s }}" class="messages" data-controller="maintain-scroll refresh-room" data-messages-target="messages" data-refresh-room-url-value="/rooms/{{ rid:s }}/refresh">{{ rows:h }}</div>
    </div>
    <turbo-frame id="composer-frame">
    <form id="composer" class="margin-block flex-item-grow contain" data-controller="composer" data-composer-room-id-value="{{ rid:s }}" action="/rooms/{{ rid:s }}/messages" accept-charset="UTF-8" method="post">
    <fieldset data-composer-target="fields" contents>
    <div class="flex flex-column">
    <div class="flex composer__input input input--actor fill-white min-width">
    <div class="flex align-end gap full-width">
    <div class="flex flex-column flex-item-grow min-width gap">
    <textarea id="message_body" name="message[body]" rows="1" class="input" aria-label="Write a message"></textarea>
    </div>
    <button class="btn btn--borderless txt-small flex-item-no-shrink" type="submit"><span class="for-screen-reader">Send Message</span></button>
    </div>
    </div>
    </div>
    </fieldset>
    <input data-composer-target="clientid" type="hidden" name="message[client_message_id]" id="message_client_message_id">
    </form>
    </turbo-frame>
    <footer id="footer"></footer>
    </main>
    <aside id="sidebar" data-controller="toggle-class" data-toggle-class-toggle-class="open">
    <turbo-frame data-turbo-permanent="true" id="user_sidebar" src="/users/me/sidebar" target="_top"></turbo-frame>
    </aside>
    </body></html>
}

// ── Page flows ──────────────────────────────────────────────────────────────
import koru/sqlite3
import pages
import std/io

// Helper tors (impls in index.kz — the .k companion is the contract file):
// request-scoped room stash, timestamp shaping, dom-id key, day-separator fold.
pub tor stash-room { name: string, rtype: string }
pub tor room-present {} -> bool
pub tor room-name {} -> string
pub tor room-key {} -> string
pub tor ts-ms { ts: string } -> i64
pub tor ts-iso { ts: string } -> string
pub tor msgdom { rid: string } -> string
pub tor page-reset {}
pub tor day-sep { ts: string } -> string

// The room page — room row stashes shell values, message rows render into the
// buffer as one Msg component each (Action Text verbatim through :h), and the
// done arm injects the accumulated rows into RoomPage's {{ rows:h }} slot.
//
// Membership is an EXISTS clause, not a gate: a non-member (or missing room)
// yields no room row -> room-present stays false -> empty buffer -> 404 via
// page-status-or. The `if` lives in a `| done` continuation, the sanctioned
// place.
pub tor room-page { rid: string, email: ?string } -> string
room-page = pages:page-begin()
    |> page-reset()
    |> koru/sqlite3:open.pooled(path: "seed/production.sqlite3")
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT r.name, r.type FROM rooms r
            WHERE r.id = {{rid}}
              AND EXISTS(SELECT 1 FROM memberships m
                         JOIN users u ON u.id = m.user_id
                         WHERE m.room_id = r.id
                           AND u.email_address = {{email}}
                           AND m.involvement != 'invisible')
        }
        ! row rr |> koru/sqlite3:col.text(stmt: rr, index: 0): rn
                 |> koru/sqlite3:col.text(stmt: rr, index: 1): rt
                 |> stash-room(name: rn, rtype: rt)
        | done d2 |> koru/sqlite3:default(conn: d2) {
                SELECT m.id, m.client_message_id, m.created_at, m.updated_at,
                       u.name, u.id, rt.body
                FROM messages m
                JOIN action_text_rich_texts rt
                  ON rt.record_type='Message' AND rt.record_id = m.id
                JOIN users u ON u.id = m.creator_id
                WHERE m.room_id = {{rid}}
                  AND EXISTS(SELECT 1 FROM memberships mm
                             JOIN users uu ON uu.id = mm.user_id
                             WHERE mm.room_id = m.room_id
                               AND uu.email_address = {{email}}
                               AND mm.involvement != 'invisible')
                ORDER BY m.created_at
            }
            ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): mid
                    |> koru/sqlite3:col.text(stmt: r, index: 1): cid
                    |> koru/sqlite3:col.text(stmt: r, index: 2): cat
                    |> koru/sqlite3:col.text(stmt: r, index: 3): uat
                    |> koru/sqlite3:col.text(stmt: r, index: 4): anm
                    |> koru/sqlite3:col.int(stmt: r, index: 5): uid
                    |> koru/sqlite3:col.text(stmt: r, index: 6): body
                    |> day-sep(ts: cat): sep
                    |> pages:page-write(text: sep)
                    |> ts-iso(ts: cat): iso
                    |> ts-ms(ts: cat): ms
                    |> ts-ms(ts: uat): ums
                    |> room-name(): rn3
                    |> Msg-render(cmid: cid, mid, uid, rid, ms, ums, iso, author: anm, roomname: rn3, body): mt
                    |> pages:page-write(text: mt)
                    |> std/io:free(content: mt)
            | done d3 |> room-present(): has
                      |> if(has)
                      | then |> pages:page-take(): rows
                             |> room-name(): rn4
                             |> msgdom(rid): md
                             |> RoomPage-render(title: rn4, rid, msgdom: md, rows): page
                             |> pages:page-begin()
                             |> pages:page-write(text: "<!DOCTYPE html>")
                             |> pages:page-write(text: page)
                             |> std/io:free(content: page)
                             |> koru/sqlite3:close.pooled(conn: d3)
                             |> pages:page-take(): body -> body
                      | else |> koru/sqlite3:close.pooled(conn: d3)
                             |> pages:page-take(): body -> body
            | err e3 |> koru/sqlite3:close.pooled(e3.conn)
                     |> pages:page-take(): partial -> partial
        | err e2 |> koru/sqlite3:close.pooled(e2.conn)
                 |> pages:page-take(): partial -> partial
    | err _ -> "db open failed"
