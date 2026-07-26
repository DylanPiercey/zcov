#!/usr/bin/env bash
# Runs each cross-compiled binary under podman and checks its lcov is
# byte-identical to the host build. The darwin targets are CI-only.
#
#   zig build release && tools/test-platforms.sh
set -uo pipefail
cd "$(dirname "$0")/.."

FIX=${FIX:-/tmp/zcov-platform-fixture}
OUT=${OUT:-/tmp/zcov-platform-out}
pass=0 fail=0

command -v podman >/dev/null || { echo "podman is required"; exit 1; }
[ -x zig-out/bin/zcov ] || { echo "run: zig build -Doptimize=ReleaseFast"; exit 1; }

echo "building fixture"
node tools/platform-fixture.mjs "$FIX" >/dev/null
rm -rf "$FIX/ref" "$OUT"; mkdir -p "$FIX/ref" "$OUT"
./zig-out/bin/zcov report -d "$FIX/cov" --cwd "$FIX" --threads 1 -r lcov -o "$FIX/ref" >/dev/null 2>&1
REF="$FIX/ref/lcov.info"
[ -s "$REF" ] || { echo "host reference is empty"; exit 1; }

report() {
  local label="$1" file="$2"
  if [ -f "$file" ] && cmp -s "$file" "$REF"; then
    printf "  %-20s identical\n" "$label"; pass=$((pass+1))
  else
    printf "  %-20s DIFFERS\n" "$label"; diff "$REF" "$file" 2>/dev/null | head -6 | sed 's/^/      /'
    fail=$((fail+1))
  fi
}

# The dump holds absolute paths, so the fixture is mounted where it was made.
linux_case() {
  local img="$1" plat="$2" bin="$3" label="$4"
  local o="$OUT/$label"; rm -rf "$o"; mkdir -p "$o"
  timeout 300 podman run --rm --platform "$plat" \
    -v "$PWD/npm/$bin:/zcov:ro,z" -v "$FIX:$FIX:ro,z" -v "$o:/out:z" \
    "$img" /zcov/zcov report -d "$FIX/cov" --cwd "$FIX" --threads 1 -r lcov -o /out >/dev/null 2>&1
  report "$label" "$o/lcov.info"
}

echo "linux targets"
linux_case docker.io/library/alpine:3.21    linux/amd64 zcov-linux-x64-musl   linux-x64-musl
linux_case docker.io/library/debian:12-slim linux/amd64 zcov-linux-x64-gnu    linux-x64-gnu
linux_case docker.io/library/alpine:3.21    linux/arm64 zcov-linux-arm64-musl linux-arm64-musl
linux_case docker.io/library/debian:12-slim linux/arm64 zcov-linux-arm64-gnu  linux-arm64-gnu

# Windows needs both a wine host and a dump that looks like it came from
# Windows: V8 there reports `file:///C:/...`, and paths arrive with backslashes.
if podman image exists zcov-wine 2>/dev/null; then
  echo "windows target (wine)"
  WIN="$FIX-win"; rm -rf "$WIN"; cp -r "$FIX" "$WIN"; rm -rf "$WIN/ref"
  node -e '
    const fs=require("fs"); const [dir,from]=process.argv.slice(1);
    for (const f of fs.readdirSync(dir+"/cov")) {
      const p=dir+"/cov/"+f;
      fs.writeFileSync(p, fs.readFileSync(p,"utf8").replaceAll("file://"+from+"/","file:///Z:"+from+"-win/"));
    }' "$WIN" "$FIX"
  o="$OUT/win32-x64"; rm -rf "$o"; mkdir -p "$o"
  timeout 900 podman run --rm --platform linux/amd64 \
    -v "$PWD/npm/zcov-win32-x64:/zcov:ro,z" -v "$WIN:$WIN:z" -v "$o:/out:z" \
    zcov-wine wine /zcov/zcov.exe report \
      -d "Z:${WIN//\//\\}\\cov" --cwd "Z:${WIN//\//\\}" --threads 1 -r lcov -o 'Z:\out' >/dev/null 2>&1
  report win32-x64 "$o/lcov.info"
else
  echo "windows target: skipped (build it with tools/wine.Containerfile)"
fi

echo
echo "  $((pass+fail)) targets checked: $pass identical, $fail differing"
echo "  not covered here: darwin-x64, darwin-arm64, freebsd-x64, win32-arm64"
[ "$fail" -eq 0 ]
