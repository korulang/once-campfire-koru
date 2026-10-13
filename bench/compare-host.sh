#!/usr/bin/env bash
# Koru-vs-Rust Campfire comparison — host-binary adaptation of
# once-campfire-rust/bench/run. Same seed, same contracts, same loadgen,
# same rep discipline; the app is a process pinned to SERVER_CPUS instead
# of a container.
#
#   bench/compare-host.sh [--apps koru,rust] [--reps 3] [--out DIR]
#
# Each rep, for each app in turn (never two at once; the order alternates
# between reps): a fresh copy of the shared fixture, then cold start, idle
# RSS, the contract-validated HTTP suite and the write audit, with process
# RSS sampled throughout. On Linux the app runs under taskset on
# SERVER_CPUS and the load generator on LOADGEN_CPUS; elsewhere the pins
# are skipped and the numbers are smoke-tier only.
#
# Knobs (env): SERVER_CPUS=8-11 LOADGEN_CPUS=12-15 HTTP_SECS=8
#   HTTP_CONCS="1 16 64" LOAD_MAX=1.5 LOAD_WAIT_SECS=900 PORT=4390
#   KORU_BIN=../a.out RUST_BIN=../../once-campfire-rust/target/release/campfire
#   FIXTURE=/private/tmp/ocv/fixtures/default  VERIFICATION_ROOT=/private/tmp/ocv
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$HERE/.." && pwd)"
VERIFICATION_ROOT=${VERIFICATION_ROOT:-/private/tmp/ocv}
BENCH=$VERIFICATION_ROOT/bench
LOADGEN=${LOADGEN:-$VERIFICATION_ROOT/loadgen/target/release/loadgen}
FIXTURE=${FIXTURE:-$VERIFICATION_ROOT/fixtures/default}
LABELS=$FIXTURE/labels.json
ENV_FILE=$FIXTURE/reference.env

KORU_BIN=${KORU_BIN:-$APP_DIR/a.out}
RUST_BIN=${RUST_BIN:-$(dirname "$APP_DIR")/once-campfire-rust/target/release/campfire}
SERVER_CPUS=${SERVER_CPUS:-8-11}
LOADGEN_CPUS=${LOADGEN_CPUS:-12-15}
HTTP_SECS=${HTTP_SECS:-8}
HTTP_CONCS=${HTTP_CONCS:-1 16 64}
LOAD_MAX=${LOAD_MAX:-1.5}
LOAD_WAIT_SECS=${LOAD_WAIT_SECS:-900}
PORT=${PORT:-4390}
BASE=http://127.0.0.1:$PORT
PINNED=0
command -v taskset >/dev/null 2>&1 && PINNED=1

APP_PID="" COLD_MS=""
APPS=koru,rust REPS=3 OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apps) APPS=$2; shift 2 ;;
    --reps) REPS=$2; shift 2 ;;
    --out)  OUT=$2; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
OUT=${OUT:-$APP_DIR/tmp/compare/$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
WORK=$OUT/.work

log() { echo "[$(date +%T)] $*" >&2; }
label() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$LABELS" "$1"; }

ROOM=$(label rooms.watercooler)
WRITE_ROOM=$(label rooms.hq)
BEFORE=$(label messages.busy_060)
AVATAR=$(label avatar_tokens.jason)
EMAIL=$(label emails.david)
PASSWORD=$(label passwords.all)

runner() { if [ "$PINNED" = 1 ]; then taskset -c "$1" "${@:2}"; else "${@:2}"; fi; }
lg() { runner "$LOADGEN_CPUS" "$LOADGEN" "$@"; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

rss_kb() { # linux /proc first, macOS ps as the dry-run fallback
  if [ -r "/proc/$1/status" ]; then
    awk '/^VmRSS:/{print $2}' "/proc/$1/status"
  else
    ps -o rss= -p "$1" | tr -d ' '
  fi
}

# Samples the app process's RSS every 200ms, keeping the peak in $2.
start_sampler() {
  ( peak=0
    while kill -0 "$1" 2>/dev/null; do
      cur=$(rss_kb "$1"); cur=${cur:-0}
      [ "$cur" -gt "$peak" ] && peak=$cur
      echo "{\"peak_rss_mb\": $((peak / 1024))}" > "$2.tmp" && mv "$2.tmp" "$2"
      sleep 0.2
    done ) &
  SAMPLER=$!
}

neuter_deliveries() {
  python3 - "$1" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("UPDATE push_subscriptions SET endpoint = 'https://127.0.0.1:9/push/' || id")
db.execute("UPDATE webhooks SET url = 'http://127.0.0.1:9/hook/' || id")
db.commit()
PY
}

wait_for_quiet() {
  local waited=0
  while awk '{exit !($1 >= '"$LOAD_MAX"')}' /proc/loadavg 2>/dev/null && [ "$waited" -lt "$LOAD_WAIT_SECS" ]; do
    sleep 10; waited=$((waited + 10))
  done
  log "load before run: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg) (waited ${waited}s)"
}

app_bin() { case "$1" in koru) echo "$KORU_BIN" ;; rust) echo "$RUST_BIN" ;; esac; }

teardown() {
  [ -n "${SAMPLER:-}" ] && kill "$SAMPLER" 2>/dev/null || true
  [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null || true
}
trap teardown EXIT INT TERM

start_app() {
  local app=$1 dir=$WORK/$app
  # A leftover process on the port would make /up answer while the real
  # binary exits on bind — the rep would then measure the wrong server.
  if curl -fsS -o /dev/null "$BASE/up" 2>/dev/null; then
    log "$app: port $PORT already answers /up — refusing to start over a stale server"
    return 1
  fi
  rm -rf "$dir"; mkdir -p "$dir/db" "$dir/files"
  cp -a "$FIXTURE/db/production.sqlite3" "$dir/db/"
  cp -a "$FIXTURE/storage/." "$dir/files/"
  neuter_deliveries "$dir/db/production.sqlite3"
  local t0; t0=$(python3 -c 'import time; print(time.time())')
  # `env` execs taskset which execs the binary — APP_PID is the app's pid.
  local runner=()
  [ "$PINNED" = 1 ] && runner=(taskset -c "$SERVER_CPUS")
  env $(grep -Ev '^(#|$)' "$ENV_FILE" | tr '\n' ' ') \
    HTTP_PORT=$PORT TARGET_PORT=$((PORT + 1)) \
    CAMPFIRE_DATABASE_PATH="$dir/db/production.sqlite3" \
    CAMPFIRE_STORAGE_PATH="$dir" CAMPFIRE_FILES_PATH="$dir/files" \
    ${runner[@]+"${runner[@]}"} "$(app_bin "$app")" > "$dir/server.log" 2>&1 &
  APP_PID=$!
  for _ in $(seq 1 3000); do
    if curl -fsS -o /dev/null "$BASE/up" 2>/dev/null; then break; fi
    kill -0 "$APP_PID" 2>/dev/null || { log "$app exited early:"; tail -20 "$dir/server.log" >&2; return 1; }
    sleep 0.02
  done
  curl -fsS -o /dev/null "$BASE/up" || { tail -30 "$dir/server.log" >&2; return 1; }
  # /up answering is not proof this child bound it — the pid must be alive.
  kill -0 "$APP_PID" 2>/dev/null || { log "$app exited after /up answered — a stale server owns $PORT"; tail -10 "$dir/server.log" >&2; return 1; }
  COLD_MS=$(python3 -c "import sys,time; print(round((time.time() - float(sys.argv[1])) * 1000))" "$t0")
}

stop_app() {
  kill "$APP_PID" 2>/dev/null || true
  wait "$APP_PID" 2>/dev/null || true
  APP_PID=""
}

run_rep() {
  local app=$1 rep=$2 f=$OUT/$app-$rep.json
  wait_for_quiet
  local load_start; load_start=$(cat /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg)
  log "$app rep $rep: starting (load: $(echo "$load_start" | cut -d' ' -f1-3))"
  local cold_ms; COLD_MS=""
  start_app "$app" || return 1
  cold_ms=$COLD_MS

  local cookie scrape csrf css contract_dir=$WORK/$app/contracts attempt=0 contract_err=""
  while true; do
    attempt=$((attempt + 1))
    cookie=$(lg login --base "$BASE" --email "$EMAIL" --password "$PASSWORD" | python3 -c 'import json,sys; print(json.load(sys.stdin)["cookie"])')
    scrape=$(lg scrape --base "$BASE" --cookie "$cookie" --room "$ROOM")
    csrf=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["csrf"] or "")' "$scrape")
    css=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["css"])' "$scrape")
    if contract_err=$(ruby "$BENCH/contracts.rb" "$BASE" "$cookie" "$WORK/$app/db/production.sqlite3" "$LABELS" "$css" "$contract_dir" 2>&1 >/dev/null); then
      contract_err=""; break
    fi
    # An app whose per-process response ordering doesn't match the seed's
    # canonical order (rust's search has been observed to emit created_at
    # order on some boots) fails the contract's exact-id check before any
    # timed cell runs. Restarting reseeds it; the app measured below is the
    # restarted process. Attempts are recorded in the rep JSON.
    [ "$attempt" -ge 5 ] && { log "$app rep $rep: contract generation failed after $attempt attempts: $contract_err"; return 1; }
    log "$app rep $rep: contract generation failed (attempt $attempt) — restarting app: $(echo "$contract_err" | tail -1)"
    stop_app
    start_app "$app" || return 1
    cold_ms=$COLD_MS
  done

  sleep 10
  local idle_rss; idle_rss=$(( $(rss_kb "$APP_PID") / 1024 ))
  start_sampler "$APP_PID" "$OUT/.$app-$rep.mem"
  log "$app rep $rep: cold start ${cold_ms}ms, idle ${idle_rss}MB RSS (contract attempts: $attempt)"

  local routes=(
    "room_show|/rooms/$ROOM"
    "messages_page|/rooms/$ROOM/messages?before=$BEFORE"
    "sidebar|/users/me/sidebar"
    "search|/searches?q=coffee"
    "avatar|/users/$AVATAR/avatar"
    "static_css|$css"
    "up|/up"
    "post_message|POST"
  )
  local http_json="[]" r name path args acknowledged=0 audits=()
  for r in "${routes[@]}"; do
    name=${r%%|*}; path=${r#*|}
    if [ "$path" = POST ]; then args=(--post-room "$WRITE_ROOM" --csrf "$csrf"); else args=(--path "$path"); fi
    args+=(--validate "$contract_dir/$name.json")
    local warm_audit=()
    if [ "$path" = POST ]; then
      audits+=("$contract_dir/post-warmup.jsonl")
      warm_audit=(--audit-writes "$contract_dir/post-warmup.jsonl")
    fi
    local warmup; warmup=$(lg http --base "$BASE" --cookie "$cookie" "${args[@]}" "${warm_audit[@]}" --conc 4 --duration 2 | ruby "$BENCH/check_sample.rb")
    if [ "$path" = POST ]; then acknowledged=$((acknowledged + $(ruby -rjson -e 'puts JSON.parse(ARGV[0]).fetch("ok")' "$warmup"))); fi
    for c in $HTTP_CONCS; do
      local timed_audit=()
      if [ "$path" = POST ]; then
        audits+=("$contract_dir/post-$c.jsonl")
        timed_audit=(--audit-writes "$contract_dir/post-$c.jsonl")
      fi
      local res; res=$(lg http --base "$BASE" --cookie "$cookie" "${args[@]}" "${timed_audit[@]}" --conc "$c" --duration "$HTTP_SECS" | ruby "$BENCH/check_sample.rb")
      if [ "$path" = POST ]; then acknowledged=$((acknowledged + $(ruby -rjson -e 'puts JSON.parse(ARGV[0]).fetch("ok")' "$res"))); fi
      http_json=$(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); r=json.loads(sys.argv[2]); r["route"]=sys.argv[3]; a.append(r); print(json.dumps(a))' "$http_json" "$res" "$name")
      log "$app rep $rep: $name c=$c $(python3 -c 'import json,sys; r=json.loads(sys.argv[1]); print(r["rps"], "rps p50", r["latency"].get("p50_ms"), "p99", r["latency"].get("p99_ms"), r["statuses"], "err", r["errors"], "invalid", r.get("invalid_responses"))' "$res")"
    done
  done

  ruby "$BENCH/validate_acks.rb" "$WORK/$app/db/production.sqlite3" "$WRITE_ROOM" "$acknowledged" "${audits[@]}" > "$OUT/$app-$rep-write-audit.json"

  sleep 0.5
  local peak; peak=$(cat "$OUT/.$app-$rep.mem")
  kill "$SAMPLER" 2>/dev/null || true; SAMPLER=""
  python3 - "$f" "$app" "$rep" "$cold_ms" "$idle_rss" "$peak" "$http_json" "$load_start" "$(cat /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg)" "$attempt" <<'PY'
import json, sys
f, app, rep, cold, idle, peak, http, load0, load, attempts = sys.argv[1:]
json.dump({
  "app": app, "rep": int(rep), "cold_start_ms": int(cold), "contract_attempts": int(attempts),
  "memory": {"idle_rss_mb": int(idle), **json.loads(peak)},
  "http": json.loads(http), "loadavg_start": load0, "loadavg_end": load,
}, open(f, "w"), indent=1)
PY
  stop_app
  rm -rf "$WORK/$app"
  log "$app rep $rep: done -> $f"
}

{
  echo "date: $(date -Is)"
  echo "shared verification source: $(git -C "$VERIFICATION_ROOT" rev-parse HEAD) (dirty: $(git -C "$VERIFICATION_ROOT" status --porcelain -- bench loadgen | wc -l) files)"
  echo "shared response gates sha256: $(sha256 "$BENCH/contracts.rb" "$BENCH/check_sample.rb" "$BENCH/validate_acks.rb" | sha256 | cut -d' ' -f1)"
  if [ -r /proc/cpuinfo ]; then
    echo "host: $(uname -r), $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs), $(nproc) threads, $(free -g | awk '/Mem:/{print $2}')GB"
  else
    echo "host: $(uname -sm), $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) threads — UNPINNED DRY RUN, smoke tier only"
  fi
  echo "server cpus: $SERVER_CPUS; loadgen cpus: $LOADGEN_CPUS; pinned: $PINNED"
  echo "koru bin: $KORU_BIN"; echo "rust bin: $RUST_BIN"
} > "$OUT/manifest.txt"

IFS=, read -ra app_list <<< "$APPS"
for rep in $(seq 1 "$REPS"); do
  if [ $((rep % 2)) -eq 1 ]; then order=("${app_list[@]}"); else
    order=(); for ((i=${#app_list[@]}-1; i>=0; i--)); do order+=("${app_list[$i]}"); done
  fi
  for app in "${order[@]}"; do
    run_rep "$app" "$rep" || log "$app rep $rep: FAILED"
  done
done

echo "results: $OUT" >&2
