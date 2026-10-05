#!/usr/bin/env bash
# Campfire-Koru steering battery — pinned cells, append-only results.
#
# One row per cell in bench/results.tsv, stamped with the SHAs that produced
# the binary. The compiler stamp comes from bench/compiler-stamp.txt — write
# it when you build (the compiler is a binary; its sha cannot be recovered
# from the tree). Module SHAs resolve through koru.json's paths, so a
# worktree-built library stamps its worktree HEAD, not the main checkout's.
#
# Cells:
#   up_c1     single connection to /up — keep-alive framing control
#   up_c16    16-way /up — cross-connection desync detector (bench shape)
#   storm     1500 concurrent curls at /up — process-survival check
#
# Smoke tier only: laptop numbers steer direction, never publishable proof.
# Ground truth runs on the twobox droplet pair (orisha/benchmarks/twobox).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/.." && pwd)"
RESULTS="$HERE/results.tsv"
STAMP="$HERE/compiler-stamp.txt"
PORT="${PORT:-3109}"
BASE="http://127.0.0.1:$PORT"
DUR="${DUR:-15s}"
STORM_N="${STORM_N:-1500}"

sha_of() {
	local sha
	sha=$(git -C "$1" rev-parse --short HEAD 2>/dev/null) || { echo "?"; return; }
	[ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ] && sha="$sha-dirty"
	echo "$sha"
}

# Resolve module dirs through koru.json — the paths that actually built a.out.
path_of() {
	python3 -c "import json,sys; print(json.load(open('$APP_DIR/koru.json'))['paths'].get('$1',''))"
}
APP_SHA=$(sha_of "$APP_DIR")
ORISHA_SHA=$(sha_of "$APP_DIR/$(path_of orisha)")
SQLITE_SHA=$(sha_of "$APP_DIR/$(path_of koru)")
BCRYPT_SHA=$(sha_of "$APP_DIR/$(path_of bcrypt)")
COMPILER_SHA=$([ -f "$STAMP" ] && cat "$STAMP" || echo "unstamped")

[ -f "$RESULTS" ] || printf 'date\tapp\tcompiler\torisha\tsqlite\tbcrypt\tcell\trequests\tduration_s\trps\tnon2xx\tdetail\n' > "$RESULTS"

alive() { lsof -tiTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; }
row() {
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$APP_SHA" "$COMPILER_SHA" \
		"$ORISHA_SHA" "$SQLITE_SHA" "$BCRYPT_SHA" \
		"$1" "$2" "$3" "$4" "$5" "$6" >> "$RESULTS"
}

if ! alive; then
	echo "server not listening on :$PORT — start ./a.out first" >&2
	exit 1
fi

# --- up_c16 -----------------------------------------------------------------
out=$(wrk -t4 -c16 -d"$DUR" "$BASE/up" 2>&1)
reqs=$(echo "$out" | awk '/requests in/ {print $1}')
dur=$(echo "$out" | awk '/requests in/ {gsub("s","",$4); print $4}')
rps=$(echo "$out" | awk -F': ' '/Requests\/sec/ {gsub(/[^0-9.]/,"",$2); print $2}')
n2=$(echo "$out" | awk '/Non-2xx/ {print $NF+0}')
row up_c16 "${reqs:-0}" "${dur:-0}" "${rps:-0}" "${n2:-0}" "alive=$(alive && echo yes || echo NO)"
echo "up_c16   ${reqs} reqs, ${rps} rps, non2xx=${n2:-0} $(alive || echo '— SERVER DOWN')"

# --- up_c1 ------------------------------------------------------------------
out=$(wrk -t1 -c1 -d"$DUR" "$BASE/up" 2>&1)
reqs=$(echo "$out" | awk '/requests in/ {print $1}')
dur=$(echo "$out" | awk '/requests in/ {gsub("s","",$4); print $4}')
rps=$(echo "$out" | awk -F': ' '/Requests\/sec/ {gsub(/[^0-9.]/,"",$2); print $2}')
n2=$(echo "$out" | awk '/Non-2xx/ {print $NF+0}')
row up_c1 "${reqs:-0}" "${dur:-0}" "${rps:-0}" "${n2:-0}" "alive=$(alive || echo '— SERVER DOWN')"
echo "up_c1    ${reqs} reqs, ${rps} rps, non2xx=${n2:-0} $(alive || echo '— SERVER DOWN')"

# --- storm ------------------------------------------------------------------
if alive; then
	tmp=$(mktemp)
	for i in $(seq 1 "$STORM_N"); do
		curl -s -o /dev/null -w "%{http_code}\n" "$BASE/up" >> "$tmp" &
	done
	wait
	hist=$(sort "$tmp" | uniq -c | awk '{printf "%sx%s ", $1, $2}')
	ok=$(awk '$1==200' "$tmp" | wc -l | tr -d ' ')
	row storm "$STORM_N" "-" "-" "$((STORM_N - ok))" "$hist alive=$(alive && echo yes || echo NO)"
	rm -f "$tmp"
	echo "storm    $hist $(alive && echo '— alive' || echo '— SERVER DOWN')"
else
	row storm 0 "-" "-" "$STORM_N" "skipped — server already down"
	echo "storm    skipped — server already down"
fi
