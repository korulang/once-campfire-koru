# once-campfire-koru

[Campfire](https://github.com/basecamp/once-campfire) implemented in
[Koru](https://korulang.org), compiled by `koruc` into a single native binary
served by the [Orisha](https://github.com/korulang) async pump. It targets the
same contract as every other port in the family: the SQLite schema, storage
layout, signed/encrypted sessions, Turbo frontend, Action Cable channels, and
the shared verification suite.

- ~8,900 lines of application source (`.k`/`.kz`), 49 routes — ~6.8 KLOC
  by the suite's counting method (nonblank, noncomment backend lines; the
  templates are Koru code, so there is no separate template count). For
  context, the published backend counts: Rails 5.5, Laravel 4.1, Express 6.8,
  Elixir 11.6, Go 23.2, Rust 30.7, C 94.8 — Rails-sized source carrying
  Rust-class throughput.
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

## Response cache

Whole GET 200 responses are cached in-process. The key is a SHA256 over
method + path + query + Cookie + Host + negotiated content encoding, so the
session cookie is already inside the key; a hit returns stored pre-gzipped
bytes without dispatch or database access. Every write path bumps a
generation counter that retires the map, so staleness is bounded by the
next write, not a TTL.

## Measured numbers

*A measurement, not a spec — this table describes the build at `663f0e4`
(2026-10-20). Later commits may move it; `bench/droplet-run-*/` is where
verified runs live with their own dates and SHAs.*

Dedicated `s-8vcpu-16gb-amd` droplet (DO-Premium-AMD, since destroyed),
app pinned to cores 0–3, shared loadgen pinned to 4–7, 8-second cells,
route contracts generated per app from the seed SQL, every acknowledged
write audited against the database (85,745 verified). One rep; the
same-suite Rust canary lives in `bench/droplet-run-2026-10-16/`.
Requests/sec, whole validated responses:

| route | c16 | c64 |
|-------|----:|----:|
| room_show | 103,729 | 104,191 |
| messages_page | 104,546 | 100,487 |
| sidebar | 110,929 | 119,002 |
| search | 111,291 | 114,216 |
| avatar | 117,257 | 117,492 |
| static_css | 118,094 | 119,139 |
| up | 110,422 | 116,152 |
| post_message | 4,512 | 3,326 |

Cold start 39ms; peak RSS 36MB (idle 16MB). Zero invalid responses, zero
transport errors across all cells.

The instrument ceiling matters here: `bench/sol` — a replay server that
only re-emits captured response bytes — tops out at ~120–127k rps on
this box under this harness rev, so sidebar, static_css, up and avatar
are pressing the loadgen, not the app. `bench/allocs` counts per request:
5 mallocs / 7KB per avatar cache hit; 66 mallocs / ~577KB per posted
message (zlib deflate dominates).

Full cells, manifests and audits: `bench/droplet-run-2026-10-20/`.
Recipe to produce a new run: `bench/RUNBOOK.md`.

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
