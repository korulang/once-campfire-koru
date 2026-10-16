# Benchmark runbook — dedicated droplet

How the committed `droplet-run-*` artifacts were produced. Total wall time
~45 min including builds; droplet cost ~$0.17/hr, destroyed at the end.

## 0. Pre-flight

Gate first (`bench-gate`): parity probe at 0 divergences against the Rails
reference before spending money — see `bench/parity_probe.py`.

Need locally: `doctl` (authenticated), ssh key registered in DO account
(`koru-bench`, id 57437287 — `ssh-add ~/.ssh/koru_bench`), sibling checkouts
`once-campfire-rust` (with `reference/` submodule) and the verification repo
(`/private/tmp/ocv` — git archive of HEAD + the untracked `fixtures/default`).

## 1. Provision

```sh
doctl compute droplet create campfire-bench-$(date +%m%d) \
  --size s-8vcpu-16gb-amd --image debian-13-x64 --region fra1 \
  --ssh-keys 57437287 --tag-names campfire-bench --wait
# then immediately, on the box: shutdown -h +240   (tripwire; real teardown is doctl delete)
```

## 2. Ship

Git-archive each HEAD (git is absent-history on the box; SHAs recorded
post-hoc into the manifest):

```sh
cd once-campfire-koru && git archive -o /tmp/ship-koru.tar.gz HEAD
cd once-campfire-rust && git archive -o /tmp/ship-rust.tar.gz HEAD
cd once-campfire-rust/reference && git archive -o /tmp/ship-reference.tar.gz HEAD
cd /private/tmp/ocv && git archive -o /tmp/ship-ocv.tar.gz HEAD
tar czf /tmp/ship-fixture.tar.gz fixtures/default
scp /tmp/ship-*.tar.gz root@$IP:/root/
```

## 3. Droplet deps + layout

```sh
apt-get install -y build-essential curl ruby python3 sqlite3 \
  libsqlite3-dev libssl-dev libyyjson-dev zlib1g-dev pkg-config \
  libvips-dev ffmpeg xz-utils ca-certificates util-linux git
# zig 0.15.2 tarball -> /opt, symlink to /usr/local/bin/zig
# rustup stable minimal
```

Module layout koru.json expects (vendor tree provides the content):

```
ship/app/                       <- koru tarball
ship/koru/                      <- app/vendor/koru  (compiler; zig build -Doptimize=ReleaseSafe)
ship/orisha/.claude/worktrees/ws-fanout/        <- app/vendor/orisha
ship/koru-libs/.claude/worktrees/cf-deps/       <- app/vendor/koru-libs
ship/koru-libs/.claude/worktrees/bcrypt-pkg/bcrypt/ <- app/vendor/bcrypt
ship/rust-src/                  <- rust tarball; reference/ <- reference tarball
ship/ocv/                       <- ocv tarball + fixture extracted inside
```

## 4. Build on the box

```sh
cd ship/koru && zig build -Doptimize=ReleaseSafe          # -> zig-out/bin/koruc
cd ship/app  && PATH=../koru/zig-out/bin:$PATH \
  koruc build main.k --build=linux --release=fast         # -> a.out
cd ship/rust-src && cargo build --release                 # -> target/release/campfire
cd ship/ocv/loadgen && cargo build --release              # -> target/release/loadgen
```

Smoke: start `a.out` against a fixture copy, `curl :PORT/up` -> 200, then
kill it — the harness refuses to start over a stale server, and a second
listener on the port will poison the run (see DEFECTS #17).

## 5. Race

```sh
cd ship/app && env \
  VERIFICATION_ROOT=/root/ship/ocv \
  KORU_BIN=/root/ship/app/a.out \
  RUST_BIN=/root/ship/rust-src/target/release/campfire \
  LOADGEN=/root/ship/ocv/loadgen/target/release/loadgen \
  FIXTURE=/root/ship/ocv/fixtures/default \
  SERVER_CPUS=0-3 LOADGEN_CPUS=4-7 HTTP_SECS=8 PORT=4390 \
  bench/compare-host.sh --apps koru --reps 3 --out /root/ship/out
# then the rust canary:
  bench/compare-host.sh --apps rust --reps 1 --out /root/ship/out
```

8 routes x {1,16,64} per rep, contracts generated per rep from the seed,
post cells audited for persisted writes. Expect ~10 min/rep.

## 6. Pull + destroy

```sh
ssh root@$IP 'cd /root/ship/out && tar czf /root/ship-results.tar.gz .'
scp root@$IP:/root/ship-results.tar.gz /tmp/
mkdir -p bench/droplet-run-$(date +%F)
tar xzf /tmp/ship-results.tar.gz -C bench/droplet-run-$(date +%F)
doctl compute droplet delete campfire-bench-* --force
doctl compute droplet list        # must be empty — this line is the receipt
```

Amend `manifest.txt` with the source SHAs (`git rev-parse HEAD` in each
local checkout) and the gate line — the on-box `git rev-parse` prints
nothing since sources ship as archives.
