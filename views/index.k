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
    <form class="button_to" method="post" action="/messages/{{ mid:d }}/boosts/{{ bid:d }}"><input type="hidden" name="_method" value="delete" /><button data-action="boost-delete#perform" data-boost-delete-target="button" class="btn btn--negative flex-item-justify-end boost__delete" type="submit">
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
    <form data-turbo-frame="boosting_message_{{ cmid:s }}" data-action="popup#close" action="/messages/{{ mid:d }}/boosts" accept-charset="UTF-8" method="post">
    <input type="hidden" name="boost[content]" id="boost_content" value="👍" />
    <button name="button" type="submit" title="Thumbs up" class="btn message__action-btn" data-emoji="👍"><figure class="margin-none boost-character">👍</figure><span class="for-screen-reader">Thumbs up</span></button>
    </form>
    <form data-turbo-frame="boosting_message_{{ cmid:s }}" data-action="popup#close" action="/messages/{{ mid:d }}/boosts" accept-charset="UTF-8" method="post">
    <input type="hidden" name="boost[content]" id="boost_content" value="👏" />
    <button name="button" type="submit" title="Clapping" class="btn message__action-btn" data-emoji="👏"><figure class="margin-none boost-character">👏</figure><span class="for-screen-reader">Clapping</span></button>
    </form>
    <form data-turbo-frame="boosting_message_{{ cmid:s }}" data-action="popup#close" action="/messages/{{ mid:d }}/boosts" accept-charset="UTF-8" method="post">
    <input type="hidden" name="boost[content]" id="boost_content" value="👋" />
    <button name="button" type="submit" title="Waving hand" class="btn message__action-btn" data-emoji="👋"><figure class="margin-none boost-character">👋</figure><span class="for-screen-reader">Waving hand</span></button>
    </form>
    <form data-turbo-frame="boosting_message_{{ cmid:s }}" data-action="popup#close" action="/messages/{{ mid:d }}/boosts" accept-charset="UTF-8" method="post">
    <input type="hidden" name="boost[content]" id="boost_content" value="💪" />
    <button name="button" type="submit" title="Muscle" class="btn message__action-btn" data-emoji="💪"><figure class="margin-none boost-character">💪</figure><span class="for-screen-reader">Muscle</span></button>
    </form>
    <form data-turbo-frame="boosting_message_{{ cmid:s }}" data-action="popup#close" action="/messages/{{ mid:d }}/boosts" accept-charset="UTF-8" method="post">
    <input type="hidden" name="boost[content]" id="boost_content" value="❤️" />
    <button name="button" type="submit" title="Red heart" class="btn message__action-btn" data-emoji="❤️"><figure class="margin-none boost-character">❤️</figure><span class="for-screen-reader">Red heart</span></button>
    </form>
    <form data-turbo-frame="boosting_message_{{ cmid:s }}" data-action="popup#close" action="/messages/{{ mid:d }}/boosts" accept-charset="UTF-8" method="post">
    <input type="hidden" name="boost[content]" id="boost_content" value="😂" />
    <button name="button" type="submit" title="Face with tears of joy" class="btn message__action-btn" data-emoji="😂"><figure class="margin-none boost-character">😂</figure><span class="for-screen-reader">Face with tears of joy</span></button>
    </form>
    <form data-turbo-frame="boosting_message_{{ cmid:s }}" data-action="popup#close" action="/messages/{{ mid:d }}/boosts" accept-charset="UTF-8" method="post">
    <input type="hidden" name="boost[content]" id="boost_content" value="🎉" />
    <button name="button" type="submit" title="Party popper" class="btn message__action-btn" data-emoji="🎉"><figure class="margin-none boost-character">🎉</figure><span class="for-screen-reader">Party popper</span></button>
    </form>
    <form data-turbo-frame="boosting_message_{{ cmid:s }}" data-action="popup#close" action="/messages/{{ mid:d }}/boosts" accept-charset="UTF-8" method="post">
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
    <button class="btn message__action-btn center full-width" title="Copy link" aria-label="Copy link" data-controller="copy-to-clipboard" data-action="copy-to-clipboard#copy" data-copy-to-clipboard-success-class="btn--success" data-copy-to-clipboard-url-value="/rooms/{{ rid:s }}/@{{ mid:d }}">
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

// The whole page — layouts/application.html + rooms/show.html flattened.
// The body holds the rendered rows verbatim ({{ rows:h }}); <!DOCTYPE is
// outside the dialect, the caller writes it. The messages/_template script
// block lives inside message-area, first child, as on the wire.
koru/dom:component(RoomPage) {
    <html><head><title>{{ title:s }}</title>
    <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no, interactive-widget=resizes-content">
    <meta name="view-transition" content="same-origin">
    <meta name="color-scheme" content="light dark">
    <meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)">
    <meta name="theme-color" content="#000000" media="(prefers-color-scheme: dark)">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="current-user-id" content="{{ uid:d }}" />
    <meta name="current-user-name" content="{{ uname:s }}" />
    <meta name="action-cable-url" content="/cable">
    <meta name="vapid-public-key">
    <meta name="turbo-prefetch" content="true">
    <link rel="manifest" href="/webmanifest.json">
    <link rel="icon" href="/account/logo?v={{ logo:s }}" type="image/png">
    <link rel="apple-touch-icon" href="/account/logo?v={{ logo:s }}">
    <link rel="stylesheet" href="/assets/_reset-9c3efd7b.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/actiontext-7b8d51ea.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/animation-bcdb4bab.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/autocomplete-9de8c93f.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/avatars-279376ab.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/base-637a0ec8.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/boosts-da4032a8.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/buttons-c7d39fd4.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/code-333ae548.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/colorize-eb391ca0.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/colors-aee62523.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/composer-e490638a.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/embeds-c20d0a3a.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/filters-8a4d63ed.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/flash-a561c1e5.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/inputs-9e58a07c.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/layout-ff6ddfc6.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/lexxy-content-0ff2f961.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/lexxy-editor-2d5c7ebe.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/lexxy-variables-3fef4323.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/lexxy-2876c58e.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/lightbox-af496d39.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/messages-c5485fef.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/nav-05e7183a.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/panels-af44ec6d.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/separators-172b3ab8.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/sidebar-0be58db9.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/signup-6e02d591.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/spinner-5a118f25.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/trix-65afdb1d.css" data-turbo-track="reload" />
    <link rel="stylesheet" href="/assets/utilities-e2f32466.css" data-turbo-track="reload" />
    <script type="importmap" data-turbo-track="reload">{
  "imports": {
    "application": "/assets/application-a54c74a7.js",
    "@hotwired/stimulus": "/assets/stimulus.min-4b1e420e.js",
    "@hotwired/stimulus-loading": "/assets/stimulus-loading-1fc53fe7.js",
    "@hotwired/turbo-rails": "/assets/turbo-a1e3a50a.js",
    "@rails/actioncable": "/assets/actioncable.esm-e0ec9819.js",
    "@rails/request.js": "/assets/@rails--request-3fc8489d.js",
    "lexxy": "/assets/lexxy-a21f41d4.js",
    "highlight.js": "/assets/highlight.js/core-4e141f64.js",
    "initializers/autocomplete": "/assets/initializers/autocomplete-ba9abe45.js",
    "initializers/current": "/assets/initializers/current-3a3b90da.js",
    "initializers/highlight": "/assets/initializers/highlight-5bd558f1.js",
    "initializers": "/assets/initializers/index-d2bbfae4.js",
    "initializers/rich_text": "/assets/initializers/rich_text-f451a05e.js",
    "lib/autocomplete/autocomplete_handler": "/assets/lib/autocomplete/autocomplete_handler-becd1e1a.js",
    "lib/autocomplete/base_autocomplete_handler": "/assets/lib/autocomplete/base_autocomplete_handler-96e7e419.js",
    "lib/autocomplete/collection": "/assets/lib/autocomplete/collection-3e251a0e.js",
    "lib/autocomplete/constants": "/assets/lib/autocomplete/constants-17c2858b.js",
    "lib/autocomplete/custom_elements/suggestion_option": "/assets/lib/autocomplete/custom_elements/suggestion_option-ac7846b3.js",
    "lib/autocomplete/custom_elements/suggestion_select": "/assets/lib/autocomplete/custom_elements/suggestion_select-f0045305.js",
    "lib/autocomplete/helpers": "/assets/lib/autocomplete/helpers-651308b9.js",
    "lib/autocomplete/renderer": "/assets/lib/autocomplete/renderer-5caf6120.js",
    "lib/autocomplete/selection": "/assets/lib/autocomplete/selection-862705bf.js",
    "lib/autocomplete/suggestion_context": "/assets/lib/autocomplete/suggestion_context-b265ffb4.js",
    "lib/autocomplete/suggestion_controller": "/assets/lib/autocomplete/suggestion_controller-10624c40.js",
    "lib/autocomplete/suggestion_results_controller": "/assets/lib/autocomplete/suggestion_results_controller-91405749.js",
    "lib/autocomplete/utils": "/assets/lib/autocomplete/utils-296fb278.js",
    "lib/cookie": "/assets/lib/cookie-76006835.js",
    "lib/rich_text/campfire_extension": "/assets/lib/rich_text/campfire_extension-f62f017b.js",
    "lib/rich_text/cite_node": "/assets/lib/rich_text/cite_node-b4d2b89a.js",
    "controllers/application": "/assets/controllers/application-f004202c.js",
    "controllers/auto_submit_controller": "/assets/controllers/auto_submit_controller-ee52d396.js",
    "controllers/autocomplete_controller": "/assets/controllers/autocomplete_controller-eaf5b07d.js",
    "controllers/badge_dot_controller": "/assets/controllers/badge_dot_controller-e0d733c8.js",
    "controllers/boost_delete_controller": "/assets/controllers/boost_delete_controller-29fd1686.js",
    "controllers/composer_controller": "/assets/controllers/composer_controller-73c33f9f.js",
    "controllers/copy_to_clipboard_controller": "/assets/controllers/copy_to_clipboard_controller-a4928c72.js",
    "controllers/drop_target_controller": "/assets/controllers/drop_target_controller-3a205782.js",
    "controllers/element_removal_controller": "/assets/controllers/element_removal_controller-4526910a.js",
    "controllers/filter_controller": "/assets/controllers/filter_controller-ca9769d5.js",
    "controllers/form_controller": "/assets/controllers/form_controller-6f3d64db.js",
    "controllers": "/assets/controllers/index-594ba2fb.js",
    "controllers/lightbox_controller": "/assets/controllers/lightbox_controller-98fc07ca.js",
    "controllers/local_time_controller": "/assets/controllers/local_time_controller-7daf3d0c.js",
    "controllers/maintain_scroll_controller": "/assets/controllers/maintain_scroll_controller-1debbbfb.js",
    "controllers/messages_controller": "/assets/controllers/messages_controller-3d90944a.js",
    "controllers/notifications_controller": "/assets/controllers/notifications_controller-746d0662.js",
    "controllers/popup_controller": "/assets/controllers/popup_controller-9f8ea824.js",
    "controllers/presence_controller": "/assets/controllers/presence_controller-28f14aad.js",
    "controllers/pwa_install_controller": "/assets/controllers/pwa_install_controller-3fe3fc5e.js",
    "controllers/read_rooms_controller": "/assets/controllers/read_rooms_controller-8245522a.js",
    "controllers/refresh_room_controller": "/assets/controllers/refresh_room_controller-4e4b6014.js",
    "controllers/reply_controller": "/assets/controllers/reply_controller-278bb9cc.js",
    "controllers/rooms_list_controller": "/assets/controllers/rooms_list_controller-64840fcd.js",
    "controllers/scroll_into_view_controller": "/assets/controllers/scroll_into_view_controller-8a0bc733.js",
    "controllers/search_results_controller": "/assets/controllers/search_results_controller-aab46974.js",
    "controllers/sessions_controller": "/assets/controllers/sessions_controller-a9fdfe3d.js",
    "controllers/soft_keyboard_controller": "/assets/controllers/soft_keyboard_controller-be1da837.js",
    "controllers/sorted_list_controller": "/assets/controllers/sorted_list_controller-9f9ae485.js",
    "controllers/sound_controller": "/assets/controllers/sound_controller-d3e5656e.js",
    "controllers/toggle_class_controller": "/assets/controllers/toggle_class_controller-b67fa681.js",
    "controllers/turbo_frame_controller": "/assets/controllers/turbo_frame_controller-9f4f722f.js",
    "controllers/turbo_streaming_controller": "/assets/controllers/turbo_streaming_controller-04b85a80.js",
    "controllers/typing_notifications_controller": "/assets/controllers/typing_notifications_controller-86906ab9.js",
    "controllers/unfurl_controller": "/assets/controllers/unfurl_controller-4a868f9a.js",
    "controllers/upload_preview_controller": "/assets/controllers/upload_preview_controller-9b8b26bb.js",
    "controllers/web_share_controller": "/assets/controllers/web_share_controller-f7236b6f.js",
    "helpers/dom_helpers": "/assets/helpers/dom_helpers-0f234176.js",
    "helpers/navigator_helpers": "/assets/helpers/navigator_helpers-3c9f4c31.js",
    "helpers/string_helpers": "/assets/helpers/string_helpers-40941ba8.js",
    "helpers/timing_helpers": "/assets/helpers/timing_helpers-94d95529.js",
    "helpers/turbo_helpers": "/assets/helpers/turbo_helpers-a3c01462.js",
    "models/client_message": "/assets/models/client_message-de3c07cf.js",
    "models/file_uploader": "/assets/models/file_uploader-09a18428.js",
    "models/message_formatter": "/assets/models/message_formatter-f39a0c5d.js",
    "models/message_paginator": "/assets/models/message_paginator-b79013e3.js",
    "models/scroll_manager": "/assets/models/scroll_manager-ed559629.js",
    "models/typing_tracker": "/assets/models/typing_tracker-42a444a5.js",
    "languages/bash": "/assets/languages/bash-13136668.js",
    "languages/css": "/assets/languages/css-a7f2e40b.js",
    "languages/diff": "/assets/languages/diff-94a335fe.js",
    "languages/go": "/assets/languages/go-10465864.js",
    "languages/java": "/assets/languages/java-95f3a30f.js",
    "languages/javascript": "/assets/languages/javascript-18eb0dd8.js",
    "languages/json": "/assets/languages/json-60184e1b.js",
    "languages/python": "/assets/languages/python-8f48fd1a.js",
    "languages/ruby": "/assets/languages/ruby-287ccd0f.js",
    "languages/rust": "/assets/languages/rust-d48f93d8.js",
    "languages/sql": "/assets/languages/sql-642be05a.js",
    "languages/xml": "/assets/languages/xml-fa7f1eda.js"
    }
    }</script>
    <link rel="modulepreload" href="/assets/application-a54c74a7.js">
    <link rel="modulepreload" href="/assets/stimulus.min-4b1e420e.js">
    <link rel="modulepreload" href="/assets/stimulus-loading-1fc53fe7.js">
    <link rel="modulepreload" href="/assets/turbo-a1e3a50a.js">
    <link rel="modulepreload" href="/assets/actioncable.esm-e0ec9819.js">
    <link rel="modulepreload" href="/assets/@rails--request-3fc8489d.js">
    <link rel="modulepreload" href="/assets/lexxy-a21f41d4.js">
    <link rel="modulepreload" href="/assets/highlight.js/core-4e141f64.js">
    <link rel="modulepreload" href="/assets/initializers/autocomplete-ba9abe45.js">
    <link rel="modulepreload" href="/assets/initializers/current-3a3b90da.js">
    <link rel="modulepreload" href="/assets/initializers/highlight-5bd558f1.js">
    <link rel="modulepreload" href="/assets/initializers/index-d2bbfae4.js">
    <link rel="modulepreload" href="/assets/initializers/rich_text-f451a05e.js">
    <link rel="modulepreload" href="/assets/lib/autocomplete/autocomplete_handler-becd1e1a.js">
    <link rel="modulepreload" href="/assets/lib/autocomplete/base_autocomplete_handler-96e7e419.js">
    <link rel="modulepreload" href="/assets/lib/autocomplete/collection-3e251a0e.js">
    <link rel="modulepreload" href="/assets/lib/autocomplete/constants-17c2858b.js">
    <link rel="modulepreload" href="/assets/lib/autocomplete/custom_elements/suggestion_option-ac7846b3.js">
    <link rel="modulepreload" href="/assets/lib/autocomplete/custom_elements/suggestion_select-f0045305.js">
    <link rel="modulepreload" href="/assets/lib/autocomplete/helpers-651308b9.js">
    <link rel="modulepreload" href="/assets/lib/autocomplete/renderer-5caf6120.js">
    <link rel="modulepreload" href="/assets/lib/autocomplete/selection-862705bf.js">
    <link rel="modulepreload" href="/assets/lib/autocomplete/suggestion_context-b265ffb4.js">
    <link rel="modulepreload" href="/assets/lib/autocomplete/suggestion_controller-10624c40.js">
    <link rel="modulepreload" href="/assets/lib/autocomplete/suggestion_results_controller-91405749.js">
    <link rel="modulepreload" href="/assets/lib/autocomplete/utils-296fb278.js">
    <link rel="modulepreload" href="/assets/lib/cookie-76006835.js">
    <link rel="modulepreload" href="/assets/lib/rich_text/campfire_extension-f62f017b.js">
    <link rel="modulepreload" href="/assets/lib/rich_text/cite_node-b4d2b89a.js">
    <link rel="modulepreload" href="/assets/controllers/application-f004202c.js">
    <link rel="modulepreload" href="/assets/controllers/auto_submit_controller-ee52d396.js">
    <link rel="modulepreload" href="/assets/controllers/autocomplete_controller-eaf5b07d.js">
    <link rel="modulepreload" href="/assets/controllers/badge_dot_controller-e0d733c8.js">
    <link rel="modulepreload" href="/assets/controllers/boost_delete_controller-29fd1686.js">
    <link rel="modulepreload" href="/assets/controllers/composer_controller-73c33f9f.js">
    <link rel="modulepreload" href="/assets/controllers/copy_to_clipboard_controller-a4928c72.js">
    <link rel="modulepreload" href="/assets/controllers/drop_target_controller-3a205782.js">
    <link rel="modulepreload" href="/assets/controllers/element_removal_controller-4526910a.js">
    <link rel="modulepreload" href="/assets/controllers/filter_controller-ca9769d5.js">
    <link rel="modulepreload" href="/assets/controllers/form_controller-6f3d64db.js">
    <link rel="modulepreload" href="/assets/controllers/index-594ba2fb.js">
    <link rel="modulepreload" href="/assets/controllers/lightbox_controller-98fc07ca.js">
    <link rel="modulepreload" href="/assets/controllers/local_time_controller-7daf3d0c.js">
    <link rel="modulepreload" href="/assets/controllers/maintain_scroll_controller-1debbbfb.js">
    <link rel="modulepreload" href="/assets/controllers/messages_controller-3d90944a.js">
    <link rel="modulepreload" href="/assets/controllers/notifications_controller-746d0662.js">
    <link rel="modulepreload" href="/assets/controllers/popup_controller-9f8ea824.js">
    <link rel="modulepreload" href="/assets/controllers/presence_controller-28f14aad.js">
    <link rel="modulepreload" href="/assets/controllers/pwa_install_controller-3fe3fc5e.js">
    <link rel="modulepreload" href="/assets/controllers/read_rooms_controller-8245522a.js">
    <link rel="modulepreload" href="/assets/controllers/refresh_room_controller-4e4b6014.js">
    <link rel="modulepreload" href="/assets/controllers/reply_controller-278bb9cc.js">
    <link rel="modulepreload" href="/assets/controllers/rooms_list_controller-64840fcd.js">
    <link rel="modulepreload" href="/assets/controllers/scroll_into_view_controller-8a0bc733.js">
    <link rel="modulepreload" href="/assets/controllers/search_results_controller-aab46974.js">
    <link rel="modulepreload" href="/assets/controllers/sessions_controller-a9fdfe3d.js">
    <link rel="modulepreload" href="/assets/controllers/soft_keyboard_controller-be1da837.js">
    <link rel="modulepreload" href="/assets/controllers/sorted_list_controller-9f9ae485.js">
    <link rel="modulepreload" href="/assets/controllers/sound_controller-d3e5656e.js">
    <link rel="modulepreload" href="/assets/controllers/toggle_class_controller-b67fa681.js">
    <link rel="modulepreload" href="/assets/controllers/turbo_frame_controller-9f4f722f.js">
    <link rel="modulepreload" href="/assets/controllers/turbo_streaming_controller-04b85a80.js">
    <link rel="modulepreload" href="/assets/controllers/typing_notifications_controller-86906ab9.js">
    <link rel="modulepreload" href="/assets/controllers/unfurl_controller-4a868f9a.js">
    <link rel="modulepreload" href="/assets/controllers/upload_preview_controller-9b8b26bb.js">
    <link rel="modulepreload" href="/assets/controllers/web_share_controller-f7236b6f.js">
    <link rel="modulepreload" href="/assets/helpers/dom_helpers-0f234176.js">
    <link rel="modulepreload" href="/assets/helpers/navigator_helpers-3c9f4c31.js">
    <link rel="modulepreload" href="/assets/helpers/string_helpers-40941ba8.js">
    <link rel="modulepreload" href="/assets/helpers/timing_helpers-94d95529.js">
    <link rel="modulepreload" href="/assets/helpers/turbo_helpers-a3c01462.js">
    <link rel="modulepreload" href="/assets/models/client_message-de3c07cf.js">
    <link rel="modulepreload" href="/assets/models/file_uploader-09a18428.js">
    <link rel="modulepreload" href="/assets/models/message_formatter-f39a0c5d.js">
    <link rel="modulepreload" href="/assets/models/message_paginator-b79013e3.js">
    <link rel="modulepreload" href="/assets/models/scroll_manager-ed559629.js">
    <link rel="modulepreload" href="/assets/models/typing_tracker-42a444a5.js">
    <link rel="modulepreload" href="/assets/languages/bash-13136668.js">
    <link rel="modulepreload" href="/assets/languages/css-a7f2e40b.js">
    <link rel="modulepreload" href="/assets/languages/diff-94a335fe.js">
    <link rel="modulepreload" href="/assets/languages/go-10465864.js">
    <link rel="modulepreload" href="/assets/languages/java-95f3a30f.js">
    <link rel="modulepreload" href="/assets/languages/javascript-18eb0dd8.js">
    <link rel="modulepreload" href="/assets/languages/json-60184e1b.js">
    <link rel="modulepreload" href="/assets/languages/python-8f48fd1a.js">
    <link rel="modulepreload" href="/assets/languages/ruby-287ccd0f.js">
    <link rel="modulepreload" href="/assets/languages/rust-d48f93d8.js">
    <link rel="modulepreload" href="/assets/languages/sql-642be05a.js">
    <link rel="modulepreload" href="/assets/languages/xml-fa7f1eda.js">
    <script type="module">import "application"</script>
    <meta name="turbo-cache-control" content="no-preview">
    <meta name="current-room-id" content="{{ rid:s }}">
    </head>
    <body class="{{ bodyclass:s }}" data-controller="local-time lightbox">
    <a href="#main-content" class="skip-navigation btn">Skip to main content</a>
    <nav id="nav">
    <span class="btn btn--reversed btn--faux room--current"><h1 class="room__contents txt-medium overflow-ellipsis">{{ title:s }}</h1></span>
    <a class="btn" style="view-transition-name: edit-room-{{ rid:s }}" data-room-id="{{ rid:s }}" href="{{ editpath:s }}">
    <img aria-hidden="true" src="/assets/menu-dots-horizontal-f6a5d793.svg" width="20" height="20" />
    <span class="for-screen-reader">Settings for this room</span>
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
    <p>Ensure notifications are enabled for <em>https://{{ host:s }}/</em> in your web browser settings.</p>
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
    <div id="message-area" class="message-area" contents="true" data-controller="messages presence drop-target" data-action="turbo:before-stream-render@document-&gt;messages#beforeStreamRender keydown.up@document-&gt;messages#editMyLastMessage dragenter-&gt;drop-target#dragenter dragover-&gt;drop-target#dragover drop-&gt;drop-target#drop visibilitychange@document-&gt;presence#visibilityChanged" data-messages-first-of-day-class="message--first-of-day" data-messages-formatted-class="message--formatted" data-messages-me-class="message--me" data-messages-mentioned-class="message--mentioned" data-messages-threaded-class="message--threaded" data-messages-page-url-value="https://{{ host:s }}/rooms/{{ rid:s }}/messages">
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
    <div id="messages_{{ msgdom:s }}" class="messages" data-controller="maintain-scroll refresh-room" data-action="turbo:before-stream-render@document-&gt;maintain-scroll#beforeStreamRender visibilitychange@document-&gt;refresh-room#visibilityChanged online@window-&gt;refresh-room#online" data-messages-target="messages" data-refresh-room-loaded-at-value="{{ loaded:d }}" data-refresh-room-url-value="https://{{ host:s }}/rooms/{{ rid:s }}/refresh">{{ rows:h }}</div>
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
    <form id="composer" class="margin-block flex-item-grow contain" data-controller="composer drop-target" data-action="dragenter-&gt;drop-target#dragenter dragover-&gt;drop-target#dragover drop-&gt;drop-target#drop drop-target:drop@window-&gt;composer#dropFiles lexxy:file-accept-&gt;composer#preventAttachment refresh-room:online@window-&gt;composer#online typing-notifications#stop paste-&gt;composer#pasteFiles turbo:submit-end-&gt;composer#submitEnd refresh-room:offline@window-&gt;composer#offline" data-composer-messages-outlet="#message-area" data-composer-toolbar-class="composer--rich-text" data-composer-room-id-value="{{ rid:s }}" action="/rooms/{{ rid:s }}/messages" accept-charset="UTF-8" method="post">
    <fieldset data-composer-target="fields" contents>
    <div class="flex flex-column">
    <div class="composer__filelist flex flex--align-center gap flex-wrap" data-composer-target="fileList"></div>
    <div class="flex composer__input input input--actor fill-white min-width" style="--input-border-radius: 1.3rem">
    <div class="flex align-end gap full-width">
    <img aria-hidden="true" class="composer__input-hint colorize--black" style="view-transition-name: input-btn;" src="/assets/messages-outlined-87ff0331.svg" width="22" height="22" />
    <div class="flex flex-column flex-item-grow min-width gap">
    <lexxy-editor rows="1" class="input lexxy-content" style="order: -1" aria-multiline="true" aria-label="Write a message" permitted-attachment-types="application/vnd.campfire.mention application/vnd.actiontext.opengraph-embed" data-controller="unfurl" data-action="lexxy:change-&gt;typing-notifications#start keydown-&gt;composer#submitByKeyboard:capture lexxy:change-&gt;composer#saveDraft lexxy:insert-link-&gt;unfurl#unfurl" data-composer-target="text" data-direct-upload-url="https://{{ host:s }}/rails/active_storage/direct_uploads" data-blob-url-template="https://{{ host:s }}/rails/active_storage/blobs/redirect/:signed_id/:filename" id="message_body" input="message_body_trix_input_message" name="message[body]">
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
    </body></html>
}

// ── Page flows ──────────────────────────────────────────────────────────────
import koru/sqlite3
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
    |> koru/sqlite3:open.pooled(path: "seed/production.sqlite3")
    | db d |> koru/sqlite3:default(conn: d) {
            SELECT r.name, r.type, u.id, u.name, u.role, u.updated_at
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
        | done d2 |> koru/sqlite3:default(conn: d2) {
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
                     |> Boost-render(bid, mid: bmid, buid, bsgid: bsg, bname: bnm, bcontent: bct, bver): bf
                     |> boost-stash(mid: bmid, html: bf)
                     |> std/io:free(content: bf)
            | done d3 |> koru/sqlite3:default(conn: d3) {
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
                        |> Msg-render(cmid: cid, mid, uid, rid, ms, ums, iso,
                                      author: anm, atitle, uver, usgid: usg,
                                      roomname: rn3, body, boosts: brow): mt
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
    |> signing:messages-stream(rtype: rt, rid): stm
    |> body-class(): bc
    |> now-ms(): lat
    |> RoomPage-render(title: rn, rid, msgdom: md,
                       uid, uname: unm, uver, usgid: usg,
                       bodyclass: bc, loaded: lat,
                       host: hst, editpath: ep,
                       logo: "20260101160000",
                       stream: stm, rows): page
    |> pages:page-begin()
    |> pages:page-write(text: "<!DOCTYPE html>")
    |> pages:page-write(text: page)
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
                         roomname: string, body: string, boosts: string } -> string<std/io:allocated!>

// The impl is a zig proc (index.kz): an `allocated!` value auto-discharges
// at a chain's end before it can satisfy the flow's return, so the call to
// the component's render event happens host-side where the return hands
// the buffer straight to the caller.
