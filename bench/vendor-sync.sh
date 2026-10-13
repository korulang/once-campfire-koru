#!/usr/bin/env bash
# Refresh vendor/ — the pinned source snapshots this repo builds from.
#
# The app's compile needs the koru toolchain and three library trees that
# live in sibling checkouts during development (see koru.json paths).
# vendor/ is the self-contained copy: anyone with just this repository can
# `docker build -t once-campfire-koru:app .` and get a working image.
#
# Re-run after changing any of the four sources; commit the result.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/.." && pwd)"
VENDOR="$APP_DIR/vendor"

path_of() { python3 -c "import json; print(json.load(open('$APP_DIR/koru.json'))['paths']['$1'])"; }

ORISHA_DIR="$(cd "$APP_DIR/$(path_of orisha)/.." && pwd)"   # worktree root containing lib/
CF_DEPS_DIR="$(cd "$APP_DIR/$(path_of koru)" && pwd)"       # koru-libs worktree root
BCRYPT_DIR="$(cd "$APP_DIR/$(path_of bcrypt)" && pwd)"      # bcrypt package dir
KORU_DIR="$(cd "$APP_DIR/$(path_of std)/.." && pwd)"        # koru repo root

for d in "$ORISHA_DIR" "$CF_DEPS_DIR" "$BCRYPT_DIR" "$KORU_DIR"; do
  [ -d "$d" ] || { echo "missing dependency dir: $d" >&2; exit 1; }
done

echo "vendor: refreshing from live checkouts"
rm -rf "$VENDOR"
mkdir -p "$VENDOR/koru" "$VENDOR/orisha" "$VENDOR/koru-libs" "$VENDOR/bcrypt"

# Toolchain: zig sources, standard library, build definition.
cp "$KORU_DIR/build.zig" "$VENDOR/koru/"
[ -f "$KORU_DIR/build.zig.zon" ] && cp "$KORU_DIR/build.zig.zon" "$VENDOR/koru/" || true
rsync -a --exclude .zig-cache --exclude zig-out "$KORU_DIR/src/" "$VENDOR/koru/src/"
rsync -a "$KORU_DIR/koru_std/" "$VENDOR/koru/koru_std/"

# Orisha: only the library tree (koru.json resolves <root>/lib).
rsync -a "$ORISHA_DIR/lib/" "$VENDOR/orisha/lib/"

# koru-libs: only the packages this app imports (orisha pulls openssl).
for pkg in sqlite3 dom yyjson openssl; do
  rsync -a "$CF_DEPS_DIR/$pkg/" "$VENDOR/koru-libs/$pkg/" --exclude tests
done
rsync -a "$BCRYPT_DIR/" "$VENDOR/bcrypt/" --exclude tests

# Record provenance.
{
  echo "# Vendored source snapshots"
  echo "# refreshed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  for name in "koru:$KORU_DIR" "orisha:$ORISHA_DIR" "koru-libs:$CF_DEPS_DIR" "bcrypt:$BCRYPT_DIR"; do
    n=${name%%:*}; d=${name#*:}
    head=$(git -C "$d" rev-parse HEAD 2>/dev/null || echo "?")
    branch=$(git -C "$d" branch --show-current 2>/dev/null || echo "?")
    echo "- $n @ $head ($branch) — $d"
  done
} > "$VENDOR/VENDOR.md"
cat "$VENDOR/VENDOR.md"
