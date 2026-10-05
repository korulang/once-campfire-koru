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
| 7 | orisha pump | 85% throughput regression on Linux epoll/io-uring path since Aug (reported by adjacent session) | board run | — | **open** — unverified by this session |
| 8 | orisha pump | `conn_states` claimed "no index is ever touched twice" — false at the accept boundary: accept thread + worker race on fd reissue could return a dirty state; `releaseConn` on fd≥4096 also leaked the fd | race window, not observed directly — surfaced by the same audit | orisha `e8a8881` (mutex + detach-before-close) | **fixed** — mechanism closed; did not move the -c16 metric on its own (arena was the live desync) |

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
