# once-campfire-koru

[Campfire](https://github.com/basecamp/once-campfire) implemented in
[Koru](https://korulang.org), compiled by `koruc` into a single native binary
served by the [Orisha](https://github.com/korulang) async pump. It targets the
same contract as every other port in the family: the SQLite schema, storage
layout, signed/encrypted sessions, Turbo frontend, Action Cable channels, and
the shared verification suite.

- ~8,100 lines of application source (`.k`/`.kz`), 49 routes — ~6.3 KLOC
  by the suite's counting method (nonblank, noncomment backend lines; the
  templates are Koru code, so there is no separate template count).
- Passes the shared browser gate (Playwright, two tabs, zero console errors).
- Passes all eight route contracts in
  [once-campfire-verification](https://github.com/basecamp/once-campfire-verification),
  including persisted-write audits (message row, Action Text body, FTS entry,
  unique ids and request tokens).
- Single process, in-process jobs, native WebSocket cable. No Redis, no Puma,
  no job workers — the analog of the C and C++ entries.

## Build the image

Everything needed to compile lives in `vendor/` — the Koru toolchain
(zig sources + `koru_std`), the Orisha library, and the koru-libs packages
this app imports — snapshotted at the revisions recorded in
[`vendor/VENDOR.md`](vendor/VENDOR.md).

```sh
docker build -t once-campfire-koru:app .
```

The build compiles `koruc` from source, then runs
`koruc build main.k --build=linux --release=fast`, which emits the Linux
epoll backend and links the app. The `--release=fast` flag is required —
bcrypt verification is unreasonably slow in a Debug build.

## Run it

The image follows the reference contract (uid 1000, `/rails` workdir,
`bin/boot`, `HTTP_PORT`):

```sh
docker run --network host \
  -e HTTP_PORT=3000 \
  -v /path/to/db:/rails/storage/db \
  -v /path/to/files:/rails/storage/files \
  -v /path/to/logs:/rails/storage/logs \
  once-campfire-koru:app
```

`CAMPFIRE_DATABASE_PATH`, `CAMPFIRE_FILES_PATH` and `CAMPFIRE_STORAGE_PATH`
default to the mounted `/rails/storage` layout. `SECRET_KEY_BASE` and the
rest of the shared fixture's `reference.env` are honored.

## Benchmark it

Keep this checkout next to
[once-campfire-verification](https://github.com/basecamp/once-campfire-verification)
so `<workspace>/once-campfire-koru` resolves, then:

```sh
bin/benchmark --apps koru,rust
```

`KORU_IMAGE` overrides the image name. Host networking is required (Linux).
The `koru` app kind requires a one-line registration in `bench/compare.rb`
(`allowed` list plus topology metadata); see `bench/submission.patch` in this
repository.

## What our numbers look like

*A measurement, not a spec — the numbers below describe the build at
`91bae1a` (2026-10-16). Later commits may move them; `bench/` is where the
latest verified run lives, and `bench/RUNBOOK.md` is the full recipe to
produce a new one.*

Dedicated `s-8vcpu-16gb-amd` droplet (since destroyed), server pinned to
cores 0–3, shared loadgen pinned to 4–7, three reps for Koru plus one Rust
canary rep confirming box equivalence with the October 13 run, 8-second
cells, contracts generated per app per rep from the seed SQL, every
acknowledged write audited against the database. This build carries the
full security layer — CSRF verification on every write, real login page,
complete heads — and measures flat-to-faster versus the earlier run that
skipped it. Median requests/sec at concurrency 64:

| route | Koru | Rust | ratio |
|-------|-----:|-----:|------:|
| room_show | 89,908 | 16,304 | 5.5x |
| messages_page | 97,901 | 15,045 | 6.5x |
| sidebar | 104,751 | 19,755 | 5.3x |
| search | 106,175 | 17,947 | 5.9x |
| avatar | 75,138 | 76,482 | 0.98x |
| static_css | 106,114 | 85,827 | 1.24x |
| up | 102,837 | 32,758 | 3.1x |
| post_message | 3,415 | 1,915 | 1.8x |

96 cells, zero invalid responses, zero transport errors, 266k audited
writes verified. Full cells, manifests and audits are committed under
`bench/droplet-run-2026-10-16/`; the earlier pre-CSRF run is at
`bench/droplet-run-2026-10-13/`.

**What the read-route rows measure.** Both implementations cache whole
authenticated responses. The difference is hit cost: Orisha's cache key is a
SHA256 over method + path + query + Cookie + Host + negotiated encoding, and
a hit returns stored pre-gzipped bytes without dispatch or database access —
the session cookie is already inside the key, and every write path bumps a
generation counter that retires the map. The Rust cache deliberately re-runs
cookie verification, session, user and membership checks plus
`PRAGMA data_version` before a hit can serve, so a mid-hit revocation cannot
leak a page. The GET rows therefore measure hit-cost plus request path — an
architecture gap, not a renderer gap. The rows that cannot be hit-shaped —
`post_message` (real write path), `/up` (raw request path), cold start
(50ms vs 180ms) and peak RSS (37MB vs 127MB) — are the like-for-like core.

Absolute throughput is machine-bound: the published suite measures on an
AMD Ryzen AI MAX+ 395; this droplet is a shared-vCPU box roughly an order of
magnitude slower per core on this workload. Same-box ratios are the claim.

## Layout

```
main.k            routes, flow chains, page assembly
views/            renderers (message, room, sidebar, search, profile)
messages/         message persistence, Action Text, FTS, broadcast
cable/            websocket channels
session/          session + authentication
signing/          Rails-compatible signed digests (sgid, avatar tokens)
pages/            page/fragment buffers
qr/               QR endpoints
avatar/           avatar lookup (storage/files)
config/           env wiring (ports, database, storage)
generated/        checked-in generated sources (flows-block.k)
vendor/           toolchain + library snapshots (see VENDOR.md)
bench/            comparison driver, run artifacts, submission patch
```

## Development

`koru.json` resolves the toolchain and libraries from sibling checkouts:
`../koru` (compiler + `koru_std`), `../orisha` worktree `ws-fanout`,
`../koru-libs` worktrees `cf-deps` and `bcrypt-pkg`. With those in place:

```sh
koruc build main.k                 # dev binary (a.out)
koruc build main.k --build=linux --release=fast   # linux release
CAMPFIRE_DATABASE_PATH=seed/production.sqlite3 ./a.out
```

`bench/vendor-sync.sh` re-snapshots `vendor/` from those checkouts.
