# Defect ledger — what Campfire surfaced in the toolchain

The app is the instrument; these are what it found. Each entry: layer,
reproducer, fix commit, status. "Fixed" means the mechanism is gone and the
falsifier re-ran clean — not merely that a load test looked quieter.

| # | Layer | Defect | Reproducer | Fix | Status |
|---|-------|--------|-----------|-----|--------|
| 1 | koru codegen | `if`/`for`/`cond` template arms inside `orisha:router` emitted raw `__koru_continue_*`/`__koru_inline_scoped_*` markers → invalid Zig | `tests/regression/350_SUBFLOWS/350_026..028`; `repro/` here | koru `f784ace2b` + pins `8950bb8`, merged `082171caf` → k-sharp | **fixed** — markers resolved on string-codegen path; 3 pins |
| 2 | orisha router | `[GET /rooms/:id/messages]` shadowed by `[GET /rooms/:id]` — greedy suffix capture ate the longer route | route matrix: `/rooms/1/messages` misrouted; `/rooms/1/extra/deep` → 200 | orisha `5788075` (segment-wise matcher for non-trailing-param patterns) | **fixed** |
| 3 | koru-libs sqlite3 | short-lived per-request connections hit `SQLITE_BUSY` under concurrency; app conflated open/query failure with "no user" → 302 flake | `bench/run.sh app_hammer` → `current-email` err logs | koru-libs `8cfdc3d` (`busy_timeout=5000` on open) | **fixed** — lock errors 775 → 0 |
| 4 | orisha pump | `send()` on peer-closed socket → SIGPIPE → silent process death under connection storms | 1500-way curl storm killed server every run, empty log | orisha `254d3af` (`ignoreSigpipe` in all `drive` bodies) | **fixed** — storm survived, storm cell stays as regression probe |
| 5 | orisha pump | `raw_arena` (x.raw copy) + `request_arena` (Request.allocator) were global FixedBufferAllocators shared by all workers — one worker's `reset()` overwrote a slice another worker's router was mid-parse on → mangled paths → 404, or landed on authed routes → 302 | `GET /up` @ -c16: ~0.10% non-2xx; single-conn clean | orisha `24d62c4` (threadlocal arenas) | **fixed** — 2× -c16 runs, ~3.8M reqs, **0** non-2xx |
| 6 | koru codegen | produce-type annotation must sit on the `->` decl line; bare-pun record produce emits positional `.{a,b}` | session tor produced `void` Output | worked around in `session-login` | **open** — compiler ergonomics, unpinned |
| 7 | orisha pump | 85% throughput regression on Linux epoll/io-uring path since Aug (reported by adjacent session) | board run | — | **not reproduced** — 2026-10-13 droplet run: epoll pump, 4 pinned cores, contract-validated app routes sustained 73–115k rps (room_show c64 86k, up c64 114k), consistent with macOS/kqueue laptop numbers |
| 8 | orisha pump | `conn_states` claimed "no index is ever touched twice" — false at the accept boundary: accept thread + worker race on fd reissue could return a dirty state; `releaseConn` on fd≥4096 also leaked the fd | race window, not observed directly — surfaced by the same audit | orisha `e8a8881` (mutex + detach-before-close) | **fixed** — mechanism closed; did not move the -c16 metric on its own (arena was the live desync) |
| 9 | koru import | dir-scanned companion submodule kept the readdir-first dirent as `canonical_path` while `import dir/sub` resolved probe-order (`.kz` before `.k`) — one module, two canonicals → transform decl collected twice → `duplicate struct member name 'call_handler_orisha_pump_run'` in emitted backend. Deterministic on ext4, invisible on APFS | minimal orisha app on Linux: 2 handlers vs 1 on macOS | koru `7bbfc3a` (dir scan routes stem through `resolveKoruFile`) + pin `140_030` | **fixed** — Linux emits 1 handler + 1 registration; Campfire builds and serves on the droplet |
| 10 | app auth | **No CSRF verification anywhere.** `POST /session` accepts missing and bogus `authenticity_token` (302, logs in); `POST /rooms/:id/messages` accepts both (200, writes). Reference: 422. Surfaced only because the parity probe sends invalid requests — route-contract-v1 never does | `bench/parity_probe.py`: rows no-token/bad-token on both endpoints | — | **open** |
| 11 | app views | `/session/new` is a 250B stub (`csrf-token: dev-token`, bare form) vs the reference's 25KB page | parity_probe `session/new is a real page` | — | **open** |
| 12 | app views | authed pages omit `csrf-param`/`csrf-token` metas; `current-room-id` emitted *after* `</head>`; sidebar/search emit no `<head>` at all (body-only docs that still pass the contract's doctype+`</html>` check) | parity_probe head rows | — | **open** |
| 13 | app views | all forms lack hidden `authenticity_token` inputs (reference: 323 on room_show) — consistent with #10 but the forms are wrong even for a CSRF-aware future | parity_probe forms row | — | **open** |
| 14 | app auth | wrong-password login returns 401, reference re-renders 422 — correct rejection, divergent surface | parity_probe wrong-password row | — | **open** (cosmetic; decide whether to match) |
| 15 | oracle | **route-contract-v1 is data-plane-only**: it cannot see security or page-structure gaps, so benchmark wins can ride on missing machinery. The probe is now the gate: Rails passes 0 divergences, this app fails 11. No benchmark number ships on a gate-red app | this whole finding | `bench/parity_probe.py` added | **gate installed** |

## Measured baselines (droplet, c-4 lon1, epoll pump, Debug build)

| Date | Cell | Result |
|------|------|--------|
| 2026-10-05 | /up @ -c16, 15s | 774,549 reqs, 51,296 rps, **0 non-2xx** |
| 2026-10-05 | /up @ -c1, 15s | 97,244 reqs, 6,440 rps, **0** |
| 2026-10-05 | storm 1500 | 1500×200, alive |
| 2026-10-05 | routes | `/up` 200; anon `/` → 302 `/session/new` |

## Measured baselines (laptop, smoke tier)

| Date | Cell | Result |
|------|------|--------|
| 2026-10-05 | /up @ -c16, 15s | 1.93M reqs, ~128k rps, 2123 non-2xx (pre-SIGPIPE) |
| 2026-10-05 | /up @ -c16, 15s | 1.96M reqs, ~130k rps, 1953 non-2xx (post-SIGPIPE) |
| 2026-10-05 | /up @ -c16, 15s | 1.77M reqs, ~117k rps, 3166 non-2xx (post-conn_states mutex — arena still armed) |
| 2026-10-05 | /up @ -c16, 15s ×2 | 1.97M + 1.83M reqs, ~130k rps, **0 non-2xx** (post-arena fix) |
| 2026-10-05 | /up @ -c1, 15s | 464k reqs, ~31k rps, **0** errors |
| 2026-10-05 | storm 1500 | pre-SIGPIPE: silent death; post-fix: alive, 1500×200 |
| 2026-10-05 | app routes @ -c16 | ~11.2k rps, 190 non-2xx (pre-busy_timeout) |

## Measured baselines (droplet, s-8vcpu-16gb-amd, contract-validated full-app HTTP)

2026-10-13, `bench/droplet-run-2026-10-13/`. Koru (`--build=linux --release=fast`,
epoll pump) vs Rust (`cargo build --release`, HEAD with `reference/` submodule),
same shared fixture, alternating reps ×3, server pinned 0-3 / loadgen 4-7,
8s cells, every response contract-validated (0 invalid in all 144 cells),
write audits verified (koru 230k, rust 111k acknowledged+persisted).
Rust note: a stale local binary failed `search: differs from seed SQL`
(`created_at` order); the droplet build from current HEAD passes on first
attempt every rep — the ordering defect was the artifact, not the code.
Koru emits no `csrf-token` meta (no CSRF verify); loadgen omits the field
when empty — POST cell symmetric.

| Route | conc | Koru med rps | Rust med rps | K/R |
|-------|-----:|-------------:|-------------:|----:|
| room_show | 64 | 86,021 | 13,587 | 6.3x |
| messages_page | 64 | 87,570 | 14,055 | 6.2x |
| sidebar | 64 | 105,484 | 17,752 | 5.9x |
| search | 64 | 98,731 | 17,075 | 5.8x |
| avatar | 64 | 75,371 | 70,215 | 1.07x |
| static_css | 64 | 108,831 | 81,030 | 1.34x |
| up | 64 | 114,126 | 30,216 | 3.8x |
| post_message | 64 | 3,203 | 1,812 | 1.8x |

Cold start: koru ~50ms / rust ~180ms. Idle RSS: 17MB / 55MB.
Peak RSS: 37MB / 127MB. Droplet destroyed post-run; no droplets remain.
