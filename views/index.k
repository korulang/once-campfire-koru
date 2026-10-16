// views — koru/dom components for the Campfire page surface, ported from
// reference/app/views/{layouts/application,rooms/show,messages/_*}.html.erb
// via the Rust port's golden-verified templates (crates/views/templates/).
//
// Composition is slot-shaped: markup is a balanced tree and `{{ x:h }}`
// writes a string prop verbatim, so the page is one RoomPage shell with the
// caller's rendered rows injected — the `<%= render @messages %>` shape.
// Action Text bodies and rendered boost rows go through the same code.
//
// Rails semantics ported, not just markup:
//   - PAGE_SIZE 40: the messages container renders the LAST page (most
//     recent 40, ascending), not the whole room.
//   - the day-separator h2 is INSIDE each message div, unconditional — the
//     client decides display from it; it is not a day-boundary element.
//   - body class carries user role (`sidebar admin`), not a literal.
//
// Honest approximations (flagged, not hidden): no CSRF meta (no CSRF yet),
// `message--emoji` all-emoji class unimplemented, attachment boost-menu
// branch unimplemented (no seeded attachments), invitation block omitted
// (paged rooms never render it). Asset hrefs carry the observed digest —
// stable strings, not secrets.

import koru/dom

// One boost chip — messages/boosts/_boost.html.erb.
koru/dom:component(Boost) {
    <div id="boost_{{ bid:d }}" class="boost boost-item flex-inline postion--relative max-width align-center fill-white gap" data-controller="boost-delete" data-boost-delete-perform-class="boost--deleting" data-boost-delete-reveal-class="expanded" data-boost-delete-booster-id-value="{{ buid:d }}">
    <figure class="avatar boost__avatar flex-item-no-shrink">
    <a title="{{ bname:s }}" class="btn avatar" data-turbo-frame="_top" href="/users/{{ buid:d }}"><img aria-label="{{ bname:s }} boosted {{ bcontent:s }}" src="/users/{{ bsgid:s }}/avatar?v={{ bver:s }}" width="48" height="48" /></a>
    </figure>
    <span role="button" class="txt-small txt-medium" data-action="click-&gt;boost-delete#reveal keydown.enter-&gt;boost-delete#reveal:prevent" data-boost-delete-target="content">{{ bcontent:s }}</span>
    <form class="button_to" method="post" action="/messages/{{ mid:d }}/boosts/{{ bid:d }}"><input type="hidden" name="_method" value="delete" /><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" /><button data-action="boost-delete#perform" data-boost-delete-target="button" class="btn btn--negative flex-item-justify-end boost__delete" type="submit">
    <img aria-hidden="true" src="/assets/minus-b31a1093.svg" width="20" height="20" />
    <span class="for-screen-reader">Delete this boost</span>
    </button></form>
    </div>
    <span id="delete_boost_accessible_label" class="for-screen-reader">Press enter to delete this boost</span>
}

// One message row — messages/_message.html.erb flattened (_actions,
// _presentation, boosts/_boosts inlined; boosts arrive as a rendered string
// slot). The day-separator h2 is unconditional inside the message div.
koru/dom:component(Msg) {
    <div id="message_{{ cmid:s }}" class="message " data-controller="reply" data-user-id="{{ uid:d }}" data-message-id="{{ mid:d }}" data-message-timestamp="{{ ms:d }}" data-message-updated-at="{{ ums:d }}" data-sort-value="{{ ms:d }}" data-messages-target="message" data-search-results-target="message" data-refresh-room-target="message" data-reply-composer-outlet="#composer">
    <h2 class="message__day-separator"><time datetime="{{ iso:s }}" data-local-time-target="date"></time></h2>
    <figure class="avatar message__avatar">
    <a title="{{ atitle:s }}" class="btn avatar" data-turbo-frame="_top" href="/users/{{ uid:d }}"><img aria-hidden="true" src="/users/{{ usgid:s }}/avatar?v={{ uver:s }}" width="48" height="48" /></a>
    </figure>
    <turbo-frame id="edit_message_{{ cmid:s }}">
    <div class="message__body">
    <div class="message__body-content">
    <div class="message__meta">
    <h3 class="message__heading">
    <span class="message__author" title="{{ atitle:s }}"><strong data-reply-target="author">{{ author:s }}</strong></span>
    <a target="_top" class="message__permalink" href="/rooms/{{ rid:s }}/@{{ mid:d }}"><time class="message__timestamp" datetime="{{ iso:s }}" data-local-time-target="time"></time></a>
    <span class="message__room"><a target="_top" data-reply-target="link" href="/rooms/{{ rid:s }}/@{{ mid:d }}">{{ roomname:s }}</a></span>
    </h3>
    <div class="message__actions" data-controller="soft-keyboard">
    <details class="position-relative" data-controller="popup" data-action="keydown.esc-&gt;popup#close toggle-&gt;popup#toggle click@document-&gt;popup#closeOnClickOutside" data-popup-orientation-top-class="popup-orientation-top">
    <summary class="btn message__action-btn message__options-btn">
    <img class="colorize--black" aria-hidden="true" src="/assets/menu-dots-horizontal-f6a5d793.svg" width="20" height="20" />
    <span class="for-screen-reader">Message options</span>
    </summary>
    <div class="message__actions-menu border shadow" data-popup-target="menu">
    <div class="quick-boosts">
    <form data-turbo-frame="boosting_message_{{ cmid:s }}" data-action="popup#close" action="/messages/{{ mid:d }}/boosts" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <input type="hidden" name="boost[content]" id="boost_content" value="👍" />
    <button name="button" type="submit" title="Thumbs up" class="btn message__action-btn" data-emoji="👍"><figure class="margin-none boost-character">👍</figure><span class="for-screen-reader">Thumbs up</span></button>
    </form>
    <form data-turbo-frame="boosting_message_{{ cmid:s }}" data-action="popup#close" action="/messages/{{ mid:d }}/boosts" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <input type="hidden" name="boost[content]" id="boost_content" value="👏" />
    <button name="button" type="submit" title="Clapping" class="btn message__action-btn" data-emoji="👏"><figure class="margin-none boost-character">👏</figure><span class="for-screen-reader">Clapping</span></button>
    </form>
    <form data-turbo-frame="boosting_message_{{ cmid:s }}" data-action="popup#close" action="/messages/{{ mid:d }}/boosts" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <input type="hidden" name="boost[content]" id="boost_content" value="👋" />
    <button name="button" type="submit" title="Waving hand" class="btn message__action-btn" data-emoji="👋"><figure class="margin-none boost-character">👋</figure><span class="for-screen-reader">Waving hand</span></button>
    </form>
    <form data-turbo-frame="boosting_message_{{ cmid:s }}" data-action="popup#close" action="/messages/{{ mid:d }}/boosts" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <input type="hidden" name="boost[content]" id="boost_content" value="💪" />
    <button name="button" type="submit" title="Muscle" class="btn message__action-btn" data-emoji="💪"><figure class="margin-none boost-character">💪</figure><span class="for-screen-reader">Muscle</span></button>
    </form>
    <form data-turbo-frame="boosting_message_{{ cmid:s }}" data-action="popup#close" action="/messages/{{ mid:d }}/boosts" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <input type="hidden" name="boost[content]" id="boost_content" value="❤️" />
    <button name="button" type="submit" title="Red heart" class="btn message__action-btn" data-emoji="❤️"><figure class="margin-none boost-character">❤️</figure><span class="for-screen-reader">Red heart</span></button>
    </form>
    <form data-turbo-frame="boosting_message_{{ cmid:s }}" data-action="popup#close" action="/messages/{{ mid:d }}/boosts" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <input type="hidden" name="boost[content]" id="boost_content" value="😂" />
    <button name="button" type="submit" title="Face with tears of joy" class="btn message__action-btn" data-emoji="😂"><figure class="margin-none boost-character">😂</figure><span class="for-screen-reader">Face with tears of joy</span></button>
    </form>
    <form data-turbo-frame="boosting_message_{{ cmid:s }}" data-action="popup#close" action="/messages/{{ mid:d }}/boosts" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <input type="hidden" name="boost[content]" id="boost_content" value="🎉" />
    <button name="button" type="submit" title="Party popper" class="btn message__action-btn" data-emoji="🎉"><figure class="margin-none boost-character">🎉</figure><span class="for-screen-reader">Party popper</span></button>
    </form>
    <form data-turbo-frame="boosting_message_{{ cmid:s }}" data-action="popup#close" action="/messages/{{ mid:d }}/boosts" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <input type="hidden" name="boost[content]" id="boost_content" value="🔥" />
    <button name="button" type="submit" title="Fire" class="btn message__action-btn" data-emoji="🔥"><figure class="margin-none boost-character">🔥</figure><span class="for-screen-reader">Fire</span></button>
    </form>
    <a class="btn message__action-btn message__boost-btn" data-turbo-frame="new_boost_message_{{ cmid:s }}" data-action="soft-keyboard#open popup#close" href="/messages/{{ mid:d }}/boosts/new">
    <img class="colorize--black" aria-hidden="true" src="/assets/boost-4a7bab66.svg" width="20" height="20" />
    <span class="for-screen-reader">New boost</span>
    </a>
    </div>
    <div class="flex flex-wrap border-top margin-block-start-half pad-block-start-half message__actions-grid">
    <button class="btn message__action-btn center full-width" data-action="reply#reply" title="Reply" aria-label="Reply">
    <img class="colorize--black" aria-hidden="true" src="/assets/reply-edb77e33.svg" width="20" height="20" />
    </button>
    <button class="btn message__action-btn center full-width" title="Copy link" aria-label="Copy link" data-controller="copy-to-clipboard" data-action="copy-to-clipboard#copy" data-copy-to-clipboard-success-class="btn--success" data-copy-to-clipboard-content-value="{{ host:s }}/rooms/{{ rid:s }}/@{{ mid:d }}">
    <img class="colorize--black" aria-hidden="true" src="/assets/link-e546a5df.svg" width="20" height="20" />
    </button>
    <a class="btn message__action-btn center full-width message__edit-btn" data-turbo-frame="edit_message_{{ cmid:s }}" title="Edit" aria-label="Edit" href="/rooms/{{ rid:s }}/messages/{{ mid:d }}/edit">
    <img class="colorize--black" aria-hidden="true" src="/assets/pencil-cf9d28aa.svg" width="20" height="20" />
    </a>
    </div>
    </div>
    </details>
    </div>
    </div>
    <div id="presentation_message_{{ cmid:s }}" dir="auto" data-reply-target="body" data-messages-target="body"><div class="lexxy-content">{{ body:h }}</div></div>
    <turbo-frame id="boosting_message_{{ cmid:s }}">
    <div class="boosts flex flex-wrap align-center gap full-width" style="--column-gap: 0.4ch; --row-gap: 0" data-controller="turbo-streaming" data-action="turbo:submit-start->turbo-streaming#unsubscribe">
    <div class="flex-inline flex-wrap gap" id="boosts_message_{{ cmid:s }}" data-turbo-streaming-target="container">{{ boosts:h }}</div>
    <turbo-frame id="new_boost_message_{{ cmid:s }}">
    <div class="flex-inline message__boost-inline" data-controller="soft-keyboard">
    <a class="boost__action txt-small btn" action="soft-keyboard#open" href="/messages/{{ mid:d }}/boosts/new">
    <img aria-hidden="true" src="/assets/boost-4a7bab66.svg" width="20" height="20" />
    <span class="for-screen-reader">Add a boost</span>
    </a>
    </div>
    </turbo-frame>
    </div>
    </turbo-frame>
    </div>
    </div>
    </turbo-frame>
    </div>
}

// messages/edit.html — the editing frame loaded into edit_message_<cmid>.
// The lexxy editor carries the current body in its `value` attribute
// (attr-escaped :s); the delete form posts the same path with
// _method=delete.
koru/dom:component(EditMsg) {
    <turbo-frame id="edit_message_{{ cmid:s }}">
    <div class="message__body position-relative" data-controller="scroll-into-view">
    <div class="message__body-content message__body-content--editing gap">
    <div class="composer--edit composer--rich-text">
    <form id="form_message_{{ cmid:s }}" data-controller="form" data-action="lexxy:file-accept->form#preventAttachment keydown.esc->form#cancel keydown.ctrl+enter->form#submit:prevent keydown.meta+enter->form#submit:prevent" action="/rooms/{{ rid:s }}/messages/{{ mid:d }}" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <input type="hidden" name="_method" value="patch" />
    <div class="full-width input input--actor min-width fill-white">
    <lexxy-editor rows="1" class="input lexxy-content" aria-multiline="true" aria-label="Edit message" autofocus="autofocus" permitted-attachment-types="application/vnd.campfire.mention application/vnd.actiontext.opengraph-embed" data-action="lexxy:change->typing-notifications#start keydown->composer#submitByKeyboard:capture" data-direct-upload-url="{{ host:s }}/rails/active_storage/direct_uploads" data-blob-url-template="{{ host:s }}/rails/active_storage/blobs/redirect/:signed_id/:filename" id="message_body" input="message_body_trix_input_message_{{ cmid:s }}" name="message[body]" value="{{ body:s }}">
    <lexxy-prompt trigger="@" name="mention" src="/autocompletable/users?room_id={{ rid:s }}" remote-filtering="true" empty-results="No matches">
    </lexxy-prompt>
    </lexxy-editor>
    </div>
    <a data-form-target="cancel" hidden="hidden" href="/rooms/{{ rid:s }}/messages/{{ mid:d }}">Close editor and discard changes</a>
    <div class="message__edit-btns flex align-center justify-space-between gap full-width pad-block-start-half">
    <button name="button" type="submit" class="btn btn--reversed">
    <img aria-hidden="true" src="/assets/check-7897ff7e.svg" />
    <span class="for-screen-reader">Save changes</span>
    </button>
    <button name="button" type="submit" class="btn btn--negative" form="delete_form_message_{{ cmid:s }}" data-turbo-confirm="Are you sure you want to delete this message?">
    <img aria-hidden="true" src="/assets/trash-708c7eb2.svg" />
    <span class="for-screen-reader">Delete message</span>
    </button>
    </div>
    </form>
    </div>
    </div>
    <div class="message__actions flex flex-wrap">
    <a class="message__action-btn message__edit-close-btn txt-small btn btn--borderless" href="/rooms/{{ rid:s }}/messages/{{ mid:d }}">
    <img class="colorize--black" aria-hidden="true" src="/assets/remove-0e7a045d.svg" />
    <span class="for-screen-reader">Close editor and discard changes</span>
    </a>
    </div>
    <form id="delete_form_message_{{ cmid:s }}" data-turbo-frame="edit_message_{{ cmid:s }}" action="/rooms/{{ rid:s }}/messages/{{ mid:d }}" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <input type="hidden" name="_method" value="delete" />
    </form>
    </div>
    </turbo-frame>
}

// The whole page — layouts/application.html + rooms/show.html flattened.
// The body holds the rendered rows verbatim ({{ rows:h }}); <!DOCTYPE is
// outside the dialect, the caller writes it. The messages/_template script
// block lives inside message-area, first child, as on the wire.
// ── Application pages ────────────────────────────────────────────────────────
// Head + the page components every non-room route renders. Head carries the
// whole <head> (stylesheets, custom_styles slot, importmap, modulepreloads)
// once so each page component only supplies its <body>. `metas` is the
// current-user-id/name pair (empty for the unauthenticated transfer and join
// pages); `styles` is the account custom_styles <style> tag or "".


// Users::ProfilesController#show — the identity form plus the session-
// transfer fieldset (#session_transfer_url is the browser contract's
// anchor). Avatar upload/delete and the push-subscriptions dev section are
// omitted: no Active Storage write path exists yet.
koru/dom:component(ProfilePage) {
    <body class="admin" data-controller="local-time lightbox">
    <a href="#main-content" class="skip-navigation btn">Skip to main content</a>
    <nav id="nav">
    <div class="flex-item-justify-start">
    <a class="btn" href="/">
    <img aria-hidden="true" src="/assets/arrow-left-abe40556.svg" width="20" height="20" />
    <span class="for-screen-reader">Go Back</span>
    </a>
    </div>
    <div class="flex-item-justify-end">
    <form method="post" action="/session" data-controller="sessions"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <input type="hidden" name="_method" value="delete" />
    <button class="btn" data-action="sessions#logout:prevent">
    <img aria-hidden="true" src="/assets/logout-a6131db1.svg" width="20" height="20" />
    <span class="for-screen-reader">Log out</span>
    </button>
    </form>
    </div>
    </nav>
    <main id="main-content">
    <section class="panel flex flex-column gap center-block" style="view-transition-name: avatar-{{ uid:d }}">
    <form class="txt-medium" data-controller="form" action="/users/me/profile" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <input type="hidden" name="_method" value="patch" />
    <div class="flex flex-column gap">
    <div class="flex align-center gap">
    <label class="flex align-center gap flex-item-grow input input--actor">
    <input class="input txt-large" autocomplete="name" placeholder="Enter your name" autofocus="autofocus" required="required" data-1p-ignore="true" type="text" value="{{ name:s }}" name="user[name]" id="user_name" />
    <img aria-hidden="true" class="colorize--black" src="/assets/person-da193438.svg" width="24" height="24" />
    </label>
    </div>
    <div class="flex align-center gap">
    <label class="flex align-center gap flex-item-grow input input--actor">
    <input class="input txt-large" value="{{ email:s }}" autocomplete="username" placeholder="Enter your email address" type="email" name="user[email_address]" id="user_email_address" />
    <img aria-hidden="true" class="colorize--black" src="/assets/email-6c595bc5.svg" width="24" height="24" />
    </label>
    </div>
    <div class="flex align-center gap">
    <label class="flex align-center gap flex-item-grow input input--actor">
    <input class="input txt-large" autocomplete="new-password" placeholder="Change password" type="password" maxlength="72" name="user[password]" id="user_password" />
    <img aria-hidden="true" class="colorize--black" src="/assets/password-0896da4e.svg" width="24" height="24" />
    </label>
    </div>
    <div class="flex align-start gap">
    <label class="flex align-center gap flex-item-grow input input--actor">
    <textarea class="input txt-large" placeholder="A few words about yourself…" maxlength="200" rows="3" name="user[bio]" id="user_bio">{{ bio:s }}</textarea>
    <img aria-hidden="true" class="colorize--black" src="/assets/bio-567a6005.svg" width="24" height="24" />
    </label>
    </div>
    <button class="btn btn--reversed center txt-large" type="submit">
    <img aria-hidden="true" src="/assets/check-7897ff7e.svg" width="20" height="20" />
    <span class="for-screen-reader">Save changes</span>
    </button>
    </div>
    </form>
    <div class="margin-block pad-inline pad-block fill-shade border-radius">
    <menu class="flex flex-column gap margin-none pad">
    {{ memberships:h }}
    </menu>
    </div>
    <fieldset>
    <legend class="gap">
    <img aria-hidden="true" class="colorize--black" src="/assets/laptop-cf35e6d4.svg" width="36" height="36" />
    <img aria-hidden="true" class="colorize--black" src="/assets/transfer-3ec4f61b.svg" width="36" height="36" />
    <img aria-hidden="true" class="colorize--black" src="/assets/mobile-phone-d0d2301d.svg" width="36" height="36" />
    </legend>
    <div class="flex flex-column gap">
    <label for="session_transfer_url" class="for-screen-reader">Use this link to login automatically on another device</label>
    <input type="text" class="input" value="{{ turl:s }}" id="session_transfer_url" readonly>
    <div class="flex align-center center gap">
    <a class="btn" data-lightbox-target="image" data-action="lightbox#open" data-lightbox-url-value="{{ qrpath:s }}" href="{{ qrpath:s }}">
    <span class="for-screen-reader">Show auto-login QR code</span>
    <img aria-hidden="true" class="colorize--black" src="/assets/qr-code-dac3b273.svg" width="20" height="20" />
    </a>
    <button class="btn" data-controller="copy-to-clipboard" data-action="copy-to-clipboard#copy" data-copy-to-clipboard-success-class="btn--success" data-copy-to-clipboard-content-value="{{ turl:s }}">
    <span class="for-screen-reader">Copy auto-login link</span>
    <img aria-hidden="true" class="flex-item-no-shrink colorize--black" src="/assets/copy-paste-4c379063.svg" width="20" height="20" />
    </button>
    </div>
    </div>
    </fieldset>
    </section>
    </main>
    <aside id="sidebar" data-controller="toggle-class" data-toggle-class-toggle-class="open">
    </aside>
    </body>
}

// AccountsController#edit — administrators get the bots/custom-styles nav
// links, the account-name form, and the creation-restriction switch; members
// see the account name plus the shared invite block. `admin`/`member` are
// the exclusive slot pair the flow fills from users.role.
koru/dom:component(AccountPage) {
    <body class="admin" data-controller="local-time lightbox">
    <a href="#main-content" class="skip-navigation btn">Skip to main content</a>
    <nav id="nav">
    <div class="flex-item-justify-start">
    <a class="btn" href="/">
    <img aria-hidden="true" src="/assets/arrow-left-abe40556.svg" width="20" height="20" />
    <span class="for-screen-reader">Go Back</span>
    </a>
    </div>
    <div>{{ navadmin:h }}</div>
    </nav>
    <main id="main-content">
    <section class="panel txt-align-center flex flex-column gap" style="view-transition-name: account-settings">
    <div>{{ admin:h }}</div>
    <div>{{ member:h }}</div>
    <div class="margin-block pad-inline pad-block-start fill-shade border-radius">
    <div class="flex flex-column align-center gap">
    <label class="flex flex-column gap full-width" style="--row-gap: 0.5em">
    <strong id="invite_label" class="invite-label">Share to invite more people</strong>
    <span class="flex align-center gap input input--actor fill-white">
    <img aria-hidden="true" class="colorize--black" src="/assets/person-add-1432b76b.svg" width="20" height="20" />
    <input type="text" class="input" id="invite_url" value="{{ inviteurl:s }}" aria-labelledby="invite_label" readonly>
    </span>
    </label>
    <div class="flex align-center gap">
    <a class="btn" data-lightbox-target="image" data-action="lightbox#open" data-lightbox-url-value="{{ qrpath:s }}" href="{{ qrpath:s }}">
    <span class="for-screen-reader">Show join link QR code</span>
    <img aria-hidden="true" class="colorize--black" src="/assets/qr-code-dac3b273.svg" width="20" height="20" />
    </a>
    <button class="btn" data-controller="copy-to-clipboard" data-action="copy-to-clipboard#copy" data-copy-to-clipboard-success-class="btn--success" data-copy-to-clipboard-content-value="{{ inviteurl:s }}">
    <span class="for-screen-reader">Copy join link</span>
    <img aria-hidden="true" class="colorize--black" src="/assets/copy-paste-4c379063.svg" width="20" height="20" />
    </button>
    <div>{{ regen:h }}</div>
    </div>
    </div>
    <hr class="margin-block separator full-width" style="--border-style: solid">
    <menu class="flex flex-column gap margin-none pad">
    <turbo-frame id="account_users">
    {{ users:h }}
    </turbo-frame>
    </menu>
    </div>
    </section>
    </main>
    <aside id="sidebar" data-controller="toggle-class" data-toggle-class-toggle-class="open">
    </aside>
    </body>
}

// Rooms::OpensController#new + #edit — one form component parameterized by
// action + method override. The access menu renders the "Everyone" toggle
// row and the active-user list the reference shows for context; only
// room[name] is a permitted parameter.
koru/dom:component(RoomFormPage) {
    <body class="admin" data-controller="local-time lightbox">
    <a href="#main-content" class="skip-navigation btn">Skip to main content</a>
    <nav id="nav">
    <div class="flex-item-justify-start">
    <a class="btn" href="/">
    <img aria-hidden="true" src="/assets/arrow-left-abe40556.svg" width="20" height="20" />
    <span class="for-screen-reader">Go Back</span>
    </a>
    </div>
    </nav>
    <main id="main-content">
    <section class="panel flex flex-column gap center-block">
    <form action="{{ action:s }}" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <input type="hidden" name="_method" value="{{ method:s }}" />
    <div class="flex align-center gap">
    <label class="flex-item-grow txt-large">
    <input name="room[name]" id="room_name" class="input full-width" required="required" autofocus="autofocus" placeholder="Name the room" data-turbo-permanent="true" data-action="keydown.enter-&gt;form#submit:prevent" type="text" value="{{ name:s }}">
    <span class="for-screen-reader">Name this room</span>
    </label>
    </div>
    <hr class="margin-block borderless">
    <section class="room-access margin-block pad-inline fill-shade border-radius">
    <menu class="flex flex-column gap margin-none pad overflow-y constrain-height" data-controller="filter" data-filter-active-class="filter--active" data-filter-selected-class="selected">
    <li class="flex align-center gap margin-none">
    <figure class="avatar flex-item-no-shrink" style="--avatar-border-radius: 0; --avatar-size: 4ch;">
    <img aria-hidden="true" class="colorize--black" style="background-color: transparent" src="/assets/everyone-4ca1d460.svg" width="20" height="20">
    <span class="for-screen-reader">Everyone</span>
    </figure>
    <div class="min-width">
    <div class="overflow-ellipsis fill-shade"><strong>Everyone</strong></div>
    </div>
    <hr class="separator" aria-hidden="true">
    <label for="room_type" class="switch">
    <input type="checkbox" id="room_type" class="switch__input" checked="checked" disabled="disabled">
    <span class="switch__btn round"></span>
    <span class="for-screen-reader">Give only some access to this room</span>
    </label>
    </li>
    <hr class="separator full-width" style="--border-style: solid">
    <div data-filter-target="list" contents="">
    {{ users:h }}
    </div>
    </menu>
    </section>
    <button name="button" type="submit" class="btn btn--reversed txt-large center">
    <img aria-hidden="true" src="/assets/check-7897ff7e.svg" width="20" height="20">
    <span class="for-screen-reader">Save</span>
    </button>
    </form>
    </section>
    </main>
    <aside id="sidebar" data-controller="toggle-class" data-toggle-class-toggle-class="open">
    </aside>
    </body>
}

// Accounts::BotsController#index — one <li> per bot (built by bot-row in
// views/index.kz, one access fieldset per non-direct membership).
koru/dom:component(BotsPage) {
    <body class="admin" data-controller="local-time lightbox">
    <a href="#main-content" class="skip-navigation btn">Skip to main content</a>
    <nav id="nav">
    <div class="flex-item-justify-start">
    <a class="btn" href="/account/edit">
    <img aria-hidden="true" src="/assets/arrow-left-abe40556.svg" width="20" height="20" />
    <span class="for-screen-reader">Go Back</span>
    </a>
    </div>
    </nav>
    <main id="main-content">
    <section class="panel panel--wide txt-align-center flex flex-column position-relative" style="view-transition-name: chat-bots">
    <div class="pad-inline-double center">
    <h1 class="margin-none">Chat bots</h1>
    <p class="margin-none-block-start">With Chat bots, other sites and services can post updates directly to Campfire.</p>
    <a href="/account/bots/new" class="btn btn--reversed txt-large" aria-label="Add a chat bot">
    <img aria-hidden="true" src="/assets/bot-8a69692e.svg" width="20" height="20" />
    <img aria-hidden="true" src="/assets/add-f232d8a6.svg" width="20" height="20" />
    </a>
    </div>
    <div class="pad-inline pad-block-start">
    <menu class="flex flex-column gap margin-none pad">
    {{ bots:h }}
    </menu>
    </div>
    </section>
    </main>
    </body>
}

// Accounts::BotsController#new + #edit — user[name] + user[webhook_url].
koru/dom:component(BotFormPage) {
    <body class="admin" data-controller="local-time lightbox">
    <a href="#main-content" class="skip-navigation btn">Skip to main content</a>
    <nav id="nav">
    <div class="flex-item-justify-start">
    <a class="btn" href="/account/bots">
    <img aria-hidden="true" src="/assets/arrow-left-abe40556.svg" width="20" height="20" />
    <span class="for-screen-reader">Go Back</span>
    </a>
    </div>
    </nav>
    <main id="main-content">
    <section class="panel panel--wide txt-align-center flex flex-column position-relative">
    <h1 class="for-screen-reader">Chat Bot Setup</h1>
    <form class="flex flex-column gap" action="{{ action:s }}" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <input type="hidden" name="_method" value="{{ method:s }}" />
    <div class="flex align-center gap">
    <label class="flex align-center gap flex-item-grow txt-large input input--actor">
    <input class="input" autocomplete="name" placeholder="Name the bot" autofocus="autofocus" required="required" data-1p-ignore="true" type="text" name="user[name]" id="user_name" value="{{ name:s }}" />
    <img aria-hidden="true" class="colorize--black" src="/assets/bot-8a69692e.svg" width="24" height="24" />
    </label>
    </div>
    <div class="flex align-center gap">
    <label class="flex align-center gap flex-item-grow txt-large input input--actor">
    <input class="input" placeholder="Webhook URL" type="url" name="user[webhook_url]" id="user_webhook_url" value="{{ webhook:s }}" />
    <img aria-hidden="true" class="colorize--black" src="/assets/external/web-24ffe636.svg" width="24" height="24" />
    </label>
    </div>
    <button class="btn btn--reversed center txt-large" type="submit">
    <img aria-hidden="true" src="/assets/check-7897ff7e.svg" width="20" height="20" />
    <span class="for-screen-reader">Save changes</span>
    </button>
    </form>
    </section>
    </main>
    </body>
}

// Accounts::CustomStylesController#edit — account[custom_styles] textarea.
koru/dom:component(StylesPage) {
    <body class="admin" data-controller="local-time lightbox">
    <a href="#main-content" class="skip-navigation btn">Skip to main content</a>
    <nav id="nav">
    <div class="flex-item-justify-start">
    <a class="btn" href="/account/edit">
    <img aria-hidden="true" src="/assets/arrow-left-abe40556.svg" width="20" height="20" />
    <span class="for-screen-reader">Go Back</span>
    </a>
    </div>
    </nav>
    <main id="main-content">
    <section class="panel panel--wide txt-align-center flex flex-column position-relative" style="view-transition-name: custom-styles">
    <form class="flex flex-column gap" action="/account/custom_styles" accept-charset="UTF-8" method="post" data-controller="form" data-action="keydown.ctrl+enter-&gt;form#submit keydown.meta+enter-&gt;form#submit"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <div class="pad-inline-double margin-inline">
    <h1 class="margin-none">Custom CSS</h1>
    <p class="flex flex-wrap align-center justify-center gap margin-none-block-start" style="--column-gap: 0.5ch; --row-gap: 0">
    <span>Add custom CSS styles.</span>
    <img aria-hidden="true" class="flex-inline colorize--black" src="/assets/alert-b937985b.svg" width="16" height="16" />
    <span>Use Caution: you could break things.</span>
    </p>
    </div>
    <label class="flex align-start gap flex-item-grow">
    <textarea class="input input--code txt--small" placeholder="Add CSS styles…" autocomplete="off" spellcheck="false" autocorrect="off" autocapitalize="off" rows="16" name="account[custom_styles]" id="account_custom_styles">{{ css:s }}</textarea>
    </label>
    <button class="btn btn--reversed center txt-large" type="submit">
    <img aria-hidden="true" src="/assets/check-7897ff7e.svg" width="20" height="20" />
    <span class="for-screen-reader">Save changes</span>
    </button>
    </form>
    </section>
    </main>
    </body>
}

// Sessions::TransfersController#show — auto_submit_form_with method: :put.
// The auto-submit controller requestSubmits on connect; without JS the form
// is still a complete, honest post to the same URL.
koru/dom:component(TransferPage) {
    <body class="admin" data-controller="local-time lightbox">
    <main id="main-content">
    <form data-controller="auto-submit" action="{{ action:s }}" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <input type="hidden" name="_method" value="put" />
    </form>
    </main>
    </body>
}

// UsersController#new — the join form. Posts to /join/:join_code; the
// code is verified server-side (mismatch is a 404).
koru/dom:component(JoinPage) {
    <body class="signup" data-controller="local-time lightbox">
    <a href="#main-content" class="skip-navigation btn">Skip to main content</a>
    <nav id="nav">
    <div class="flex-item-justify-end">
    <a href="/session/new" class="btn flex-item-justify-end">
    <img aria-hidden="true" src="/assets/login-keys-df926967.svg" width="20" height="20" />
    <span class="for-screen-reader">Sign in</span>
    </a>
    </div>
    </nav>
    <main id="main-content">
    <form class="center" action="{{ action:s }}" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <section class="nametag u-relative">
    <div class="nametag__inner flex flex-column gap">
    <fieldset class="flex flex-column center-block">
    <legend class="txt-align-center flex gap">
    <strong class="txt-large">{{ acctname:s }}</strong>
    </legend>
    </fieldset>
    <div class="flex align-center gap">
    <label class="flex align-center gap flex-item-grow txt-large input input--actor">
    <input class="input" autocomplete="name" placeholder="Name" autofocus="autofocus" required="required" data-1p-ignore="true" type="text" name="user[name]" id="user_name" />
    <img aria-hidden="true" class="colorize--black" src="/assets/person-da193438.svg" width="24" height="24" />
    </label>
    </div>
    <div class="flex align-center gap">
    <label class="flex align-center gap flex-item-grow txt-large input input--actor">
    <input class="input" autocomplete="username" placeholder="Email address" required="required" type="email" name="user[email_address]" id="user_email_address" />
    <img aria-hidden="true" class="colorize--black" src="/assets/email-6c595bc5.svg" width="24" height="24" />
    </label>
    </div>
    <div class="flex align-center gap">
    <label class="flex align-center gap flex-item-grow txt-large input input--actor">
    <input class="input" autocomplete="new-password" placeholder="Password" required="required" maxlength="72" type="password" name="user[password]" id="user_password" />
    <img aria-hidden="true" class="colorize--black" src="/assets/password-0896da4e.svg" width="24" height="24" />
    </label>
    </div>
    <button class="btn btn--reversed center txt-large" type="submit">
    <img aria-hidden="true" src="/assets/check-7897ff7e.svg" width="20" height="20" />
    <span class="for-screen-reader">Save</span>
    </button>
    </div>
    </section>
    </form>
    </main>
    </body>
}

// Rooms::DirectsController#new — the ping composer. Rendered as a full page
// whose <turbo-frame id="direct_rooms_control"> replaces the sidebar's
// control frame when the "New Ping" link navigates it (_self).
koru/dom:component(DirectsPage) {
    <body class="admin" data-controller="local-time lightbox">
    <a href="#main-content" class="skip-navigation btn">Skip to main content</a>
    <nav id="nav">
    </nav>
    <main id="main-content">
    <turbo-frame id="direct_rooms_control" target="_top">
    <div class="directs directs--new flex flex-column gap">
    <form class="flex gap flex-item-grow" data-controller="form" data-action="keydown.esc-&gt;form#cancel" action="/rooms/directs" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <a class="btn flex-item-no-shrink" data-turbo-frame="user_sidebar" data-form-target="cancel" href="/users/me/sidebar">
    <img aria-hidden="true" src="/assets/arrow-left-abe40556.svg" width="20" height="20" />
    <span class="for-screen-reader">Cancel changes</span>
    </a>
    <section class="autocomplete__container unpad input input--actor">
    <div class="autocomplete__input input flex flex-wrap position-relative flex-item-grow" data-controller="autocomplete" data-autocomplete-url-value="/autocompletable/users">
    <select name="user_ids[]" data-autocomplete-target="select" data-template-id="autocompletable-user" multiple="true" hidden="" required="">
    </select>
    <template id="autocompletable-user">
    <div class="autocomplete__pill max-width" data-value="" tabindex="0">
    <img class="avatar flex-item-no-shrink" data-content="avatar" src="">
    <span class="autocomplete-field__selected-value-text overflow-ellipsis flex-item-grow" data-content="label">
    </span>
    <button type="button" data-action="autocomplete#remove:prevent" data-value="" tabindex="-1" class="btn btn--plain txt-small translucent flex-item-no-shrink">
    <img aria-hidden="true" class="colorize--black" src="/assets/remove-circle-384c618c.svg" width="20" height="20" />
    <span class="for-screen-reader">Remove <span data-content="screenReaderLabel"></span></span>
    </button>
    </div>
    </template>
    <input autocomplete="off" autocorrect="off" data-1p-ignore="true" class="autocomplete__input input flex flex-wrap position-relative" data-autocomplete-target="input" data-action="input-&gt;autocomplete#search keydown-&gt;autocomplete#didPressKey" type="text" name="rooms_direct[user_ids_input]" id="rooms_direct_user_ids_input">
    </div>
    </section>
    <button name="button" type="submit" class="btn btn--reversed flex-item-no-shrink">
    <img aria-hidden="true" src="/assets/check-7897ff7e.svg" width="20" height="20" />
    <span class="for-screen-reader">Start Ping</span>
    </button>
    </form>
    <span class="txt-small translucent pad-inline-half center">Type names to ping someone…</span>
    </div>
    </turbo-frame>
    </main>
    <aside id="sidebar" data-controller="toggle-class" data-toggle-class-toggle-class="open">
    </aside>
    </body>
}

koru/dom:component(RoomPage) {
    <body class="{{ bodyclass:s }}" data-controller="local-time lightbox">
    <a href="#main-content" class="skip-navigation btn">Skip to main content</a>
    <nav id="nav">
    <span class="btn btn--reversed btn--faux room--current"><h1 class="room__contents txt-medium overflow-ellipsis">{{ navtitle:h }}</h1></span>
    <a class="btn" style="view-transition-name: edit-room-{{ rid:s }}" data-room-id="{{ rid:s }}" href="{{ editpath:s }}">
    <img aria-hidden="true" src="/assets/menu-dots-horizontal-f6a5d793.svg" width="20" height="20" />
    <span class="for-screen-reader">{{ settingslabel:s }}</span>
    </a>
    <span>
    <span class="button_to_change_notifying" data-controller="notifications" data-notifications-subscriptions-url-value="/users/me/push_subscriptions" data-notifications-attention-class="btn--pulsing">
    <turbo-frame data-controller="turbo-frame" data-action="notifications:ready@window-&gt;turbo-frame#load" data-turbo-frame-url-param="/rooms/{{ rid:s }}/involvement" id="involvement_{{ msgdom:s }}">
    <button class="btn" data-action="click->notifications#attemptToSubscribe" data-notifications-target="bell">
    <img aria-hidden="true" src="/assets/notification-bell-loading-7533ce55.svg" width="20" height="20" />
    <img aria-hidden="true" hidden="hidden" src="/assets/notification-bell-alert-b467cde7.svg" width="20" height="20" />
    <span class="for-screen-reader">Notification settings for this room</span>
    </button>
    </turbo-frame>
    <dialog data-notifications-target="notAllowedNotice" class="dialog pad center center-block border-radius border shadow" style="--inline-space: var(--block-space)">
    <div class="flex flex-column txt-align-center">
    <span class="btn btn--faux center txt-x-large">
    <img aria-hidden="true" src="/assets/notification-bell-alert-b467cde7.svg" width="48" height="48" />
    <span class="for-screen-reader">Notifications alert</span>
    </span>
    <section>
    <h1 class="txt-large margin-none">Notifications aren’t allowed</h1>
    <div class="txt-align-start margin-block-start">
    <details class="notifications-help" data-notifications-target="details">
    <summary class="btn">
    <img aria-hidden="true" src="/assets/external/web-24ffe636.svg" width="20" height="20" />
    <strong>Check your Curl settings</strong>
    <img aria-hidden="true" class="disclosure" src="/assets/disclosure-26d63471.svg" width="10" height="10" />
    </summary>
    <p>Ensure notifications are enabled for <em>{{ host:s }}/</em> in your web browser settings.</p>
    </details>
    <details class="notifications-help hide-in-browser" data-notifications-target="details">
    <summary class="btn">
    <img aria-hidden="true" src="/assets/external/gear-50e77d2b.svg" width="20" height="20" />
    <strong>Check your  settings</strong>
    <img aria-hidden="true" class="disclosure" src="/assets/disclosure-26d63471.svg" width="10" height="10" />
    </summary>
    <p>Ensure notifications are allowed for Curl in your system settings.</p>
    </details>
    <details class="notifications-help pwa__instructions hide-in-pwa" data-controller="pwa-install" data-pwa-install-prompting-class="pwa--can-install" data-notifications-target="details">
    <summary class="btn">
    <img aria-hidden="true" src="/assets/external/install-f762b3be.svg" width="20" height="20" />
    <strong>Install Campfire as a web app.</strong>
    <img aria-hidden="true" class="disclosure" src="/assets/disclosure-26d63471.svg" width="10" height="10" />
    </summary>
    <p>Some platforms require you to install Campfire as a web app to receive push notifications.</p>
    <div class="margin-block-start txt-align-center pwa__installer">
    <hr class="separator margin-block">
    <button class="btn btn--reversed center" data-action="pwa-install#promptInstall">
    <img aria-hidden="true" src="/assets/external/install-f762b3be.svg" />
    Install now
    </button>
    </div>
    </details>
    </div>
    </section>
    <form method="dialog" class="flex align-center gap center">
    <button class="btn dialog__close" autofocus="true">
    <span class="for-screen-reader">Close</span>
    <img aria-hidden="true" src="/assets/remove-0e7a045d.svg" width="20" height="20" />
    </button>
    </form>
    </div>
    </dialog>
    </span>
    </span>
    </nav>
    <main id="main-content">
    <div id="message-area" class="message-area" contents="true" data-controller="messages presence drop-target" data-action="turbo:before-stream-render@document-&gt;messages#beforeStreamRender keydown.up@document-&gt;messages#editMyLastMessage dragenter-&gt;drop-target#dragenter dragover-&gt;drop-target#dragover drop-&gt;drop-target#drop visibilitychange@document-&gt;presence#visibilityChanged" data-messages-first-of-day-class="message--first-of-day" data-messages-formatted-class="message--formatted" data-messages-me-class="message--me" data-messages-mentioned-class="message--mentioned" data-messages-threaded-class="message--threaded" data-messages-page-url-value="{{ host:s }}/rooms/{{ rid:s }}/messages">
    <script type="text/template" data-messages-target="template">
    <div class="message message--me $messageClasses$" id="message_$clientMessageId$" data-format-message-target="message" data-user-id="{{ uid:d }}" data-message-timestamp="$messageTimestamp$" data-messages-target="message">
    <div class="message__day-separator"><time class="message__timestamp" datetime="$messageDatetime$" data-local-time-target="date"></time></div>
    <figure class="avatar message__avatar">
    <a title="{{ uname:s }}" class="btn avatar" data-turbo-frame="_top" href="/users/{{ uid:d }}"><img aria-hidden="true" src="/users/{{ usgid:s }}/avatar?v={{ uver:s }}" width="48" height="48" /></a>
    </figure>
    <div class="message__body">
    <div class="message__body-content">
    <div class="message__meta">
    <h3 class="message__heading">
    <span class="message__author"><strong>{{ uname:s }}</strong></span>
    <span class="message__permalink"><time class="message__timestamp" datetime="$messageDatetime$" data-local-time-target="time"></time></span>
    </h3>
    <div class="message__actions">
    <div class="position-relative">
    <span class="btn message__action-btn message__options-btn">
    <img class="colorize--black" aria-hidden="true" src="/assets/menu-dots-horizontal-f6a5d793.svg" />
    <span class="for-screen-reader">Message options</span>
    </span>
    </div>
    </div>
    </div>
    $body$
    </div>
    </div>
    </div>
    </script>
    <div id="messages_{{ msgdom:s }}" class="messages" data-controller="maintain-scroll refresh-room" data-action="turbo:before-stream-render@document-&gt;maintain-scroll#beforeStreamRender visibilitychange@document-&gt;refresh-room#visibilityChanged online@window-&gt;refresh-room#online" data-messages-target="messages" data-refresh-room-loaded-at-value="{{ loaded:d }}" data-refresh-room-url-value="{{ host:s }}/rooms/{{ rid:s }}/refresh">{{ rows:h }}</div>
    <turbo-cable-stream-source channel="RoomMessagesChannel" signed-stream-name="{{ stream:s }}"></turbo-cable-stream-source>
    <button class="message-area__return-to-latest btn" data-action="messages#returnToLatest" data-messages-target="latest" hidden="hidden"><img aria-hidden="true" src="/assets/arrow-down-3f174d76.svg" width="20" height="20" /><span class="for-screen-reader">Jump to newest message</span></button>
    </div>
    <footer id="footer">
    <div class="composer flex align-end gap position-relative" data-controller="typing-notifications" data-typing-notifications-active-class="typing-indicator--active">
    <a class="btn flex-item-no-shrink margin-block-end composer__context-btn" style="view-transition-name: input-switcher" href="/searches">
    <img aria-hidden="true" src="/assets/search-5f29565f.svg" width="20" height="20" />
    <span class="for-screen-reader">Search</span>
    </a>
    <turbo-frame id="composer-frame">
    <form id="composer" class="margin-block flex-item-grow contain" data-controller="composer drop-target" data-action="dragenter-&gt;drop-target#dragenter dragover-&gt;drop-target#dragover drop-&gt;drop-target#drop drop-target:drop@window-&gt;composer#dropFiles lexxy:file-accept-&gt;composer#preventAttachment refresh-room:online@window-&gt;composer#online typing-notifications#stop paste-&gt;composer#pasteFiles turbo:submit-end-&gt;composer#submitEnd refresh-room:offline@window-&gt;composer#offline" data-composer-messages-outlet="#message-area" data-composer-toolbar-class="composer--rich-text" data-composer-room-id-value="{{ rid:s }}" action="/rooms/{{ rid:s }}/messages" accept-charset="UTF-8" method="post"><input type="hidden" name="authenticity_token" value="{{ csrf:s }}" />
    <fieldset data-composer-target="fields" contents>
    <div class="flex flex-column">
    <div class="composer__filelist flex flex--align-center gap flex-wrap" data-composer-target="fileList"></div>
    <div class="flex composer__input input input--actor fill-white min-width" style="--input-border-radius: 1.3rem">
    <div class="flex align-end gap full-width">
    <img aria-hidden="true" class="composer__input-hint colorize--black" style="view-transition-name: input-btn;" src="/assets/messages-outlined-87ff0331.svg" width="22" height="22" />
    <div class="flex flex-column flex-item-grow min-width gap">
    <lexxy-editor rows="1" class="input lexxy-content" style="order: -1" aria-multiline="true" aria-label="Write a message" permitted-attachment-types="application/vnd.campfire.mention application/vnd.actiontext.opengraph-embed" data-controller="unfurl" data-action="lexxy:change-&gt;typing-notifications#start keydown-&gt;composer#submitByKeyboard:capture lexxy:change-&gt;composer#saveDraft lexxy:insert-link-&gt;unfurl#unfurl" data-composer-target="text" data-direct-upload-url="{{ host:s }}/rails/active_storage/direct_uploads" data-blob-url-template="{{ host:s }}/rails/active_storage/blobs/redirect/:signed_id/:filename" id="message_body" input="message_body_trix_input_message" name="message[body]">
    <lexxy-prompt trigger="@" name="mention" src="/autocompletable/users?room_id={{ rid:s }}" remote-filtering="true" empty-results="No matches"></lexxy-prompt>
    </lexxy-editor>
    </div>
    <label class="btn btn--borderless txt-small flex-item-no-shrink composer__attachment-btn input--file">
    <img class="colorize--black" aria-hidden="true" src="/assets/attachment-8bcccab0.svg" width="22" height="22" />
    <input type="file" data-action="composer#filePicked" multiple />
    <span class="for-screen-reader">Attach a file</span>
    </label>
    <button class="btn btn--borderless txt-small flex-item-no-shrink composer__rich-text-btn" type="button" data-action="composer#toggleToolbar">
    <img class="colorize--black" aria-hidden="true" src="/assets/text-options-055e0d16.svg" width="20" height="20" />
    <span class="for-screen-reader">Rich text</span>
    </button>
    <button name="send" type="submit" data-action="composer#submit" class="btn btn--reversed flex-item-no-shrink txt-small">
    <img aria-hidden="true" src="/assets/arrow-up-f96b3895.svg" width="20" height="20" />
    <span class="for-screen-reader">Send Message</span>
    </button>
    </div>
    </div>
    </div>
    </fieldset>
    <div class="typing-indicator gap txt-small align-center flex-inline" data-typing-notifications-target="indicator">
    <div class="typing-indicator__author spinner" data-typing-notifications-target="author"></div>
    </div>
    <input data-composer-target="clientid" type="hidden" name="message[client_message_id]" id="message_client_message_id" />
    </form>
    </turbo-frame>
    </div>
    </footer>
    </main>
    <aside id="sidebar" data-controller="toggle-class" data-toggle-class-toggle-class="open">
    <turbo-frame data-turbo-permanent="true" data-controller="rooms-list read-rooms turbo-frame" data-rooms-list-unread-class="unread" data-action="presence:present@window->rooms-list#read read-rooms:read->rooms-list#read turbo:frame-load->rooms-list#loaded refresh-room:visible@window->turbo-frame#reload" id="user_sidebar" src="/users/me/sidebar" target="_top"></turbo-frame>
    </aside>
    <dialog class="lightbox" aria-label="Image Viewer (Press escape to close)" data-lightbox-target="dialog" data-action="close->lightbox#reset">
    <img src="" class="lightbox__image" data-lightbox-target="zoomedImage" />
    <form method="dialog" class="lightbox__btn">
    <button class="btn"><img aria-hidden="true" src="/assets/remove-0e7a045d.svg" /><span class="for-screen-reader">Close image viewer</span></button>
    </form>
    <a href="" class="lightbox__btn--download btn hide-in-ios-pwa" data-lightbox-target="download"><img aria-hidden="true" src="/assets/download-04029899.svg" /><span class="for-screen-reader">Download file</span></a>
    <button class="lightbox__btn--share btn" data-controller="web-share" data-action="web-share#share" data-web-share-files-value="" data-lightbox-target="share"><img aria-hidden="true" src="/assets/share-bf28da4f.svg" /><span class="for-screen-reader">Share file</span></button>
    </dialog>
    <a href="https://once.com" id="app-logo" target="_blank" aria-label="Once software from 37signals home page">
    <img alt="Campfire logo" width="256" height="216" src="/assets/campfire-icon-3d9986c5.png" />
    </a>
    </body>
}

// ── Page flows ──────────────────────────────────────────────────────────────
import koru/sqlite3
import config
import pages
import signing
import std/io

// Helper tors (impls in index.kz — the .k companion is the contract file).
// Request-scoped stashes for room and current user, timestamp shaping,
// dom-id keys, the boost arena, and static page regions.
pub tor stash-room { name: string, rtype: string }
pub tor stash-user { uid: i64, name: string, role: i64, ver: string }
pub tor room-present {} -> bool
pub tor room-name {} -> string
pub tor room-key {} -> string
pub tor room-type {} -> string
pub tor ts-ms { ts: string } -> i64
pub tor ts-iso { ts: string } -> string
pub tor ts-ver { ts: string } -> string
pub tor msgdom { rid: string } -> string
pub tor mdom { cmid: string } -> string
pub tor html-esc { text: string } -> string
pub tor nav-title { rtype: string, name: string } -> string
pub tor settings-label { rtype: string } -> string
pub tor user-metas { uid: i64, name: string } -> string
pub tor style-wrap { css: ?string } -> string
pub tor css-stash { css: string<*> }
pub tor css-take {} -> ?string
pub tor stream-wrap { action: string, target: string, html: string<*> } -> string
pub tor room-link { rk: string, rid: string, name: string } -> string
pub tor direct-link { rid: string, name: string, sgid: string, ver: string } -> string
pub tor memb-link { rid: string, name: string } -> string
pub tor bot-key { id: i64, token: string } -> string
pub tor curl-line { host: string, rid: string, key: string } -> string
pub tor bots-begin {}
pub tor bot-row { uid: i64, name: string, key: string, rid: i64, rname: string, host: string } -> string
pub tor bots-take {} -> string
pub tor acct-user { uid: i64, uname: string, role: i64, sgid: string, ver: string } -> string
pub tor room-user { uid: i64, uname: string, sgid: string, ver: string } -> string
pub tor ac-begin {}
pub tor ac-row { uid: i64, name: string, sgid: string, ver: string } -> string
pub tor ac-take {} -> string
pub tor room-edit-path { rid: string } -> string
pub tor page-reset {}
pub tor body-class {} -> string
pub tor user-id {} -> i64
pub tor user-name {} -> string
pub tor user-ver {} -> string
pub tor user-title { name: string, bio: string } -> string
pub tor now-ms {} -> i64
pub tor host-or { h: ?string } -> string
pub tor boost-stash { mid: i64, html: string<*> }
pub tor auth-stash { uid: i64, name: string<*>, email: string<*>, bio: string<*>, role: i64, ver: string<*> }
pub tor user-role {} -> i64
pub tor new-room-btn { role: i64, restrict: i64 } -> string
pub tor auth-email {} -> string
pub tor auth-bio {} -> string
pub tor acct-stash { name: string<*>, join: string<*>, restrict: i64, ver: string<*> }
pub tor acct-restrict {} -> i64
pub tor acct-ver {} -> string
pub tor acct-name {} -> string
pub tor acct-join {} -> string
pub tor ping-btn { uid: i64, name: string, sgid: string, ver: string } -> string
pub tor itoa { n: i64 } -> string
pub tor nav-flag { role: i64 } -> string
pub tor edit-stash { name: string<*>, wh: string<*> }
pub tor edit-name {} -> string
pub tor edit-wh {} -> string
pub tor join-code {} -> string
pub tor bot-token {} -> string
pub tor acct-nav-admin { role: i64 } -> string
pub tor acct-admin-block { name: string, restrict: i64, role: i64 } -> string
pub tor acct-member-block { name: string, role: i64 } -> string
pub tor acct-regen { role: i64 } -> string
pub tor uids-join { ids: string, uid: i64 } -> string
pub tor uids-count { ids: string } -> i64
pub tor list-id { rk: string, rid: string } -> string
pub tor bot-action { bid: i64 } -> string
pub tor room-form-action { plural: string, rid: i64 } -> string
pub tor first-name { name: string } -> string
pub tor transfer-path { host: string, sid: string } -> string
pub tor invite-path { host: string, code: string } -> string
pub tor head-build { title: string, metas: string, logo: string, styles: string } -> string
pub tor csrf-stash { masked: ?string }
pub tor csrf-get {} -> string
pub tor csrf-metas { pre: string } -> string
pub tor meta-cat { a: string, b: string } -> string
pub tor room-meta { pre: string, rid: string } -> string
pub tor csrf-input {} -> string
pub tor admin-cls { base: string, role: i64 } -> string
pub tor unprocessable-body {} -> string
pub tor respond-unprocessable { body: string } -> orisha:Response
pub tor signin-body { logo: string, host: string, acct: string, mailname: string, mailemail: string } -> string
pub tor profile-render { uid: i64, name: string, email: string, bio: string,
                         turl: string, qrpath: string, memberships: string } -> string<std/io:allocated!>
pub tor account-render { navadmin: string, admin: string, member: string,
                         inviteurl: string, qrpath: string, regen: string, users: string } -> string<std/io:allocated!>
pub tor roomform-render { action: string, method: string, name: string, users: string } -> string<std/io:allocated!>
pub tor bots-render { bots: string } -> string<std/io:allocated!>
pub tor botform-render { action: string, method: string, name: string, webhook: string } -> string<std/io:allocated!>
pub tor styles-render { css: string } -> string<std/io:allocated!>
pub tor transfer-action { sid: string } -> string
pub tor transfer-render { action: string } -> string<std/io:allocated!>
pub tor join-render { action: string, acctname: string } -> string<std/io:allocated!>
pub tor directs-render {} -> string<std/io:allocated!>

pub tor boost-rows { mid: i64 } -> string

// The room page. Membership is an EXISTS-shaped join that also yields the
// current user's id/name/role/updated_at for the shell's metas — a
// non-member or missing room yields no row -> empty buffer -> 404 via
// page-status-or.
//
// Order of the done-arm chain: room row -> boost rows stashed (last-40
// window, one query) -> message rows render Msg with boost-rows(mid)
// lookup -> RoomPage with the accumulated buffer injected raw.
pub tor room-page { rid: string, email: ?string, host: ?string } -> string
room-page = pages:page-begin()
    |> page-reset()
    |> config:db-path(): dbp |> koru/sqlite3:open.pooled(path: dbp)
    | db d |> koru/sqlite3(conn: d) {
            SELECT COALESCE(r.name,
                       (SELECT GROUP_CONCAT(u2.name, ', ')
                        FROM memberships m2 JOIN users u2 ON u2.id = m2.user_id
                        WHERE m2.room_id = r.id AND m2.user_id != u.id)),
                   r.type, u.id, u.name, u.role, u.updated_at
            FROM rooms r
            JOIN memberships m ON m.room_id = r.id
            JOIN users u ON u.id = m.user_id
            WHERE r.id = {{rid}}
              AND u.email_address = {{email}}
              AND m.involvement != 'invisible'
        }
        ! row rr |> koru/sqlite3:col.text(stmt: rr, index: 0): rn
                 |> koru/sqlite3:col.text(stmt: rr, index: 1): rt
                 |> koru/sqlite3:col.int(stmt: rr, index: 2): uuid
                 |> koru/sqlite3:col.text(stmt: rr, index: 3): unm
                 |> koru/sqlite3:col.int(stmt: rr, index: 4): urole
                 |> koru/sqlite3:col.text(stmt: rr, index: 5): uver0
                 |> ts-ver(ts: uver0): uver1
                 |> stash-room(name: rn, rtype: rt)
                 |> stash-user(uid: uuid, name: unm, role: urole, ver: uver1)
        | done d2 |> koru/sqlite3(conn: d2) {
                SELECT b.id, b.message_id, b.content, u.id, u.name, u.updated_at
                FROM boosts b
                JOIN users u ON u.id = b.booster_id
                JOIN (SELECT m.id AS mid FROM messages m
                      WHERE m.room_id = {{rid}}
                        AND EXISTS(SELECT 1 FROM memberships mm
                                   JOIN users uu ON uu.id = mm.user_id
                                   WHERE mm.room_id = m.room_id
                                     AND uu.email_address = {{email}}
                                     AND mm.involvement != 'invisible')
                      ORDER BY m.created_at DESC LIMIT 40) w ON w.mid = b.message_id
            }
            ! row br |> koru/sqlite3:col.int(stmt: br, index: 0): bid
                     |> koru/sqlite3:col.int(stmt: br, index: 1): bmid
                     |> koru/sqlite3:col.text(stmt: br, index: 2): bct
                     |> koru/sqlite3:col.int(stmt: br, index: 3): buid
                     |> koru/sqlite3:col.text(stmt: br, index: 4): bnm
                     |> koru/sqlite3:col.text(stmt: br, index: 5): buat
                     |> ts-ver(ts: buat): bver
                     |> signing:user-sgid(id: buid): bsg
                     |> csrf-get(): bcsrf
                     |> Boost-render(bid, mid: bmid, buid, bsgid: bsg, bname: bnm, bcontent: bct, bver, csrf: bcsrf): bf
                     |> boost-stash(mid: bmid, html: bf)
                     |> std/io:free(content: bf)
            | done d3 |> koru/sqlite3(conn: d3) {
                    SELECT m.id, m.client_message_id, m.created_at, m.updated_at,
                           u.name, u.id, u.updated_at, rt.body, u.bio
                    FROM (
                        SELECT m2.id, m2.client_message_id, m2.created_at,
                               m2.updated_at, m2.creator_id
                        FROM messages m2
                        WHERE m2.room_id = {{rid}}
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
                        |> user-title(name: anm, bio: abio): atitle
                        |> ts-iso(ts: cat): iso
                        |> ts-ms(ts: cat): ms
                        |> ts-ms(ts: uat): ums
                        |> ts-ver(ts: auat): uver
                        |> room-name(): rn3
                        |> boost-rows(mid): brow
                        |> signing:user-sgid(id: uid): usg
                        |> host-or(h: host): rh
                        |> csrf-get(): mcsrf
                        |> Msg-render(cmid: cid, mid, uid, rid, ms, ums, iso,
                                      author: anm, atitle, uver, usgid: usg,
                                      roomname: rn3, body, boosts: brow,
                                      host: rh, csrf: mcsrf): mt
                        |> pages:page-write(text: mt)
                        |> std/io:free(content: mt)
                | done d4 |> room-present(): has
                          |> if(has)
                          | then |> koru/sqlite3:close.pooled(conn: d4)
                                 |> page-shell(rid, host): page -> page
                          | else |> koru/sqlite3:close.pooled(conn: d4) -> ""
                | err e3 |> koru/sqlite3:close.pooled(e3.conn)
                         |> pages:page-take(): partial -> partial
            | err e2 |> koru/sqlite3:close.pooled(e2.conn)
                     |> pages:page-take(): partial -> partial
        | err e1 |> koru/sqlite3:close.pooled(e1.conn)
                 |> pages:page-take(): partial -> partial
    | err _ -> "db open failed"

// Assemble the shell: take the accumulated message rows, render RoomPage
// around them, and rewrite the buffer as doctype + page. Runs only on the
// member path (the caller's `if` arms it); a non-member reaches this never.
pub tor page-shell { rid: string, host: ?string } -> string
page-shell = pages:page-take(): rows
    |> room-name(): rn
    |> msgdom(rid): md
    |> room-edit-path(rid): ep
    |> host-or(h: host): hst
    |> user-id(): uid
    |> user-name(): unm
    |> user-ver(): uver
    |> signing:user-sgid(id: uid): usg
    |> room-type(): rt
    |> nav-title(rtype: rt, name: rn): nt
    |> settings-label(rtype: rt): sl
    |> signing:messages-stream(rtype: rt, rid): stm
    |> body-class(): bc
    |> now-ms(): lat
    |> user-metas(uid, name: unm): hmet
    |> room-meta(pre: hmet, rid): hmet2
    |> csrf-metas(pre: hmet2): hmet3
    |> csrf-get(): hcsrf
    |> css-take(): hcss
    |> style-wrap(css: hcss): hsty
    |> acct-ver(): hver
    |> head-build(title: rn, metas: hmet3, logo: hver, styles: hsty): hd
    |> RoomPage-render(navtitle: nt, settingslabel: sl, rid, msgdom: md,
                       uid, uname: unm, uver, usgid: usg,
                       bodyclass: bc, loaded: lat,
                       host: hst, editpath: ep,
                       stream: stm, rows, csrf: hcsrf): page
    |> pages:page-begin()
    |> pages:page-write(text: hd)
    |> pages:page-write(text: page)
    |> pages:page-write(text: "</html>")
    |> std/io:free(content: page)
    |> pages:page-take(): body -> body

// Detached render of one message row — the partial `messages/create`
// broadcasts and re-renders (`render @message` outside a request). The Msg
// component is private to this module; this is its public face, with the
// same slots the room-page row arm fills and `boosts` empty for a fresh
// message.
pub tor message-render { cmid: string, mid: i64, uid: i64, rid: string,
                         ms: i64, ums: i64, iso: string, author: string,
                         atitle: string, uver: string, usgid: string,
                         roomname: string, body: string, boosts: string,
                         host: ?string } -> string<std/io:allocated!>

// The pub face of EditMsg — same allocated! boundary discipline as
// message-render: the component call happens host-side in index.kz.
pub tor edit-render { cmid: string, rid: string, mid: i64,
                      body: string, host: ?string } -> string<std/io:allocated!>

// The impl is a zig proc (index.kz): an `allocated!` value auto-discharges
// at a chain's end before it can satisfy the flow's return, so the call to
// the component's render event happens host-side where the return hands
// the buffer straight to the caller.
