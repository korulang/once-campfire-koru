#!/usr/bin/env python3
"""Parity probe — the part of Campfire correctness the bench contract can't see.

The official harness (route-contract-v1) validates the data plane: message ids,
seeded content, write persistence. It never sends an invalid request, so an app
that skips CSRF verification or stubs pages passes cleanly. This probe measures
the negative paths and structural contract that the Rails reference actually
enforces — the oracle column below was measured against the reference image
(once-campfire-verification:reference-90b3300), not assumed.

Usage: parity_probe.py <base-url> <labels.json>
Exit 0 = every probe matches the reference. Exit 1 = divergence, table printed.
"""
import sys, json, re, urllib.request, urllib.parse, http.cookiejar, uuid

base, labels_path = sys.argv[1], sys.argv[2]
labels = json.load(open(labels_path))
email, pw = labels["emails.david"], labels["passwords.all"]
room, hq = labels["rooms.watercooler"], labels["rooms.hq"]

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a): return None

def mk():
    cj = http.cookiejar.CookieJar()
    return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj), NoRedirect)

def req(op, method, path, fields=None, headers=None):
    data = urllib.parse.urlencode(fields).encode() if fields is not None else None
    r = urllib.request.Request(base + path, data=data, method=method,
        headers={"Content-Type": "application/x-www-form-urlencoded",
                 "Accept": "text/vnd.turbo-stream.html, text/html", **(headers or {})})
    try:
        resp = op.open(r); return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()

results = []  # (name, expected, actual)
def expect(name, expected, fn):
    st, body = fn()
    results.append((name, expected, str(st), st == expected, body))

# --- legitimate session: one jar across GET form -> POST ---
op = mk()
expect("GET /session/new", 200, lambda: req(op, "GET", "/session/new"))
_, login_page = req(op, "GET", "/session/new")
m = re.search(rb'name="authenticity_token"[^>]*value="([^"]+)"', login_page) or \
    re.search(rb'value="([^"]+)"[^>]*name="authenticity_token"', login_page)
csrf = m.group(1).decode() if m else ""
login_stub = len(login_page) < 5000

expect("POST /session (valid)", 302, lambda: req(op, "POST", "/session",
    {"email_address": email, "password": pw, "authenticity_token": csrf}))

# session rotates on login; re-read csrf from an authenticated page
_, authed = req(op, "GET", f"/rooms/{room}")
m = re.search(rb'name="csrf-token" content="([^"]+)"', authed)
if m: csrf = m.group(1).decode()

for name, fields in [
    ("POST /session no-token", {"email_address": email, "password": pw}),
    ("POST /session bad-token", {"email_address": email, "password": pw, "authenticity_token": "bogus"}),
    ("POST /session wrong-password", {"email_address": email, "password": "wrong", "authenticity_token": csrf}),
]:
    expect(name, 422, lambda f=fields: req(mk(), "POST", "/session", f))

mid = "oracle-" + uuid.uuid4().hex[:12]
expect("POST msg valid csrf", 200, lambda: req(op, "POST", f"/rooms/{hq}/messages",
    {"message[body]": "oracle", "message[client_message_id]": mid, "authenticity_token": csrf},
    {"x-csrf-token": csrf}))
expect("POST msg NO csrf", 422, lambda: req(op, "POST", f"/rooms/{hq}/messages",
    {"message[body]": "oracle-notoken", "message[client_message_id]": "oracle-no"}))
expect("POST msg bad csrf", 422, lambda: req(op, "POST", f"/rooms/{hq}/messages",
    {"message[body]": "oracle-bad", "message[client_message_id]": "oracle-bad", "authenticity_token": "bogus"}))
anon = mk()
expect("POST msg no session", 302, lambda: req(anon, "POST", f"/rooms/{hq}/messages",
    {"message[body]": "oracle-anon", "message[client_message_id]": "oracle-anon"}))
expect("GET room unauthenticated", 302, lambda: req(anon, "GET", f"/rooms/{room}"))

_, room_body = req(op, "GET", f"/rooms/{hq}")
results.append(("read-after-write visible", "yes",
                "yes" if mid.encode() in room_body else "NO", mid.encode() in room_body, b""))
results.append(("session/new is a real page", "no", "yes" if login_stub else "no", not login_stub, b""))

_, room_html = req(op, "GET", f"/rooms/{room}")
_, sidebar = req(op, "GET", "/users/me/sidebar")
head_end = room_html.find(b"</head>")
head_only = room_html[:head_end] if head_end != -1 else b""
for marker, where, label in [
    (b'name="csrf-param"', head_only, "room head has csrf-param"),
    (b'name="csrf-token"', head_only, "room head has csrf-token"),
    (b'name="current-room-id"', head_only, "current-room-id inside <head>"),
]:
    ok = marker in where
    results.append((label, "yes", "yes" if ok else "NO", ok, b""))
ok = b'name="authenticity_token"' in room_html
results.append(("room forms carry authenticity_token", "yes", "yes" if ok else "NO", ok, b""))
ok = b"<head" in sidebar
results.append(("sidebar has <head>", "yes", "yes" if ok else "NO", ok, b""))

fails = 0
print(f"\n{'probe':44} {'expected':>8} {'actual':>8}")
for name, exp, act, ok, _ in results:
    mark = "" if ok else "  <-- DIVERGES"
    if not ok: fails += 1
    print(f"{name:44} {exp:>8} {act:>8}{mark}")
print(f"\n{fails} divergence(s) vs the Rails reference oracle")
sys.exit(1 if fails else 0)
