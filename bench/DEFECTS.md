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
| 5 | orisha pump | global fd-indexed `conn_states` vs per-worker ownership: fd reuse + stale events cross connections → mangled request paths | `GET /up` @ -c16 returns 404/302 (~0.10%); single-conn clean | — | **open** — next: per-worker conn tables |
| 6 | koru codegen | produce-type annotation must sit on the `->` decl line; bare-pun record produce emits positional `.{a,b}` | session tor produced `void` Output | worked around in `session-login` | **open** — compiler ergonomics, unpinned |
| 7 | orisha pump | 85% throughput regression on Linux epoll/io-uring path since Aug (reported by adjacent session) | board run | — | **open** — unverified by this session |

## Measured baselines (laptop, smoke tier)

| Date | Cell | Result |
|------|------|--------|
| 2026-10-05 | /up @ -c16, 15s | 1.93M reqs, ~128k rps, 2123 non-2xx (pre-SIGPIPE) |
| 2026-10-05 | /up @ -c16, 15s | 1.96M reqs, ~130k rps, 1953 non-2xx (post-SIGPIPE) |
| 2026-10-05 | /up @ -c1, 15s | 464k reqs, ~31k rps, **0** errors |
| 2026-10-05 | storm 1500 | pre-fix: silent death; post-fix: alive, 1496×200 |
| 2026-10-05 | app routes @ -c16 | ~11.2k rps, 190 non-2xx (pre-busy_timeout) |

Falsifier for #5: `/up` @ -c16 histogram returns non-200 only when request
bytes cross connections. After per-worker conn tables: expect non-2xx → 0.
