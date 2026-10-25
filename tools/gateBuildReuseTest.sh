#!/usr/bin/env bash
set -euo pipefail
subject=${1:-$(dirname "$0")/gate.sh}
group=${2:-all}
case "$group" in all|unit|core|inputs|roots|failures|cli) ;; *) printf 'unknown build reuse test group: %s\n' "$group" >&2; exit 2 ;; esac
subject=$(cd "$(dirname "$subject")" && pwd)/$(basename "$subject")
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
w="$d/wt"
mkdir -p "$w/tools" "$w/src/test" "$w/std/core/system" "$w/runtime" "$w/vendor" "$d/home" "$w/out/gate"
cp "$subject" "$w/tools/gate.sh"
printf 'out/\nmsc*\n' >"$w/.gitignore"
for path in src/index.ms src/test/a.ms std/a.ms runtime/a.h vendor/a.h; do printf 'fixture\n' >"$w/$path"; done
printf '{}\n' >"$w/src/test/known-red.json"
printf 'standard root\n' >"$w/std/core/system/index.ms"
cat >"$w/msc" <<'FAKE'
#!/usr/bin/env bash
set -eu
stage=0
case "$1" in
  build)
    printf 'build\n' >>"$HOME/calls"
    [ ! -f "$HOME/build-fail" ] || exit 1
    for arg in "$@"; do case "$arg" in --output=*) out=${arg#*=} ;; esac; done
    if [ -f "$HOME/cache-hit" ] && [[ "$out" != */boot*/* ]]; then rm "$HOME/cache-hit"; exit 0; fi
    mkdir -p "$(dirname "$out")"
    if [ -f "$HOME/evolving" ]; then
      next=$((stage < 2 ? stage + 1 : 2))
      sed "s/^stage=[0-9]$/stage=$next/" "$0" >"$out"
    else
      cp "$0" "$out"
    fi
    chmod +x "$out"
    if [ -f "$HOME/change-result" ] && [[ "$out" != */boot*/* ]]; then printf '\n:\n' >>"$out"; fi
    [ ! -f "$HOME/change-producer" ] || printf '\n:\n' >>"$PWD/msc"
    object=object.o
    if [ -f "$HOME/evolving" ]; then
      if [ "$stage" -eq 0 ]; then object=objectA.o; else object=objectB.o; fi
    fi
    printf '%s\n-o\n%s\n' "$object" "$out" >"${out}_link.rsp"
    ;;
  run)
    printf 'scan\n' >>"$HOME/calls"
    [ ! -f "$HOME/scan-fail" ] || exit 1
    [ ! -f "$HOME/change-candidate" ] || printf '\n:\n' >>"$0"
    ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$w/msc"
cp "$w/msc" "$d/verified.msc"
git -C "$w" init -q -b main
git -C "$w" -c user.name=t -c user.email=t@t add -A
git -C "$w" -c user.name=t -c user.email=t@t commit -qm base
base=$(git -C "$w" rev-parse HEAD)
printf 'changed test\n' >>"$w/src/test/a.ms"
git -C "$w" -c user.name=t -c user.email=t@t commit -qam test
export HOME="$d/home" USERPROFILE="$d/home"
export GATE_WAIT_MAX=-1 GATE_PAR=1 GATE_KNOWN_LOCAL="$d/local.json"
export GATE_LEDGER="$d/gate.tsv" GATE_SELECT_LEDGER="$d/select.tsv"
cd "$w"
source <(awk '/^base=main release=/{exit} {print}' tools/gate.sh)
for name in lane_cmd build_lane; do
  source <(awk -v name="$name" '$0 == name "() {" { on = 1 } on { print } on && /^\}/ { exit }' tools/gate.sh)
  declare -F "$name" >/dev/null
done
BUILDER="$TOP/msc" CC_FLAG="" release=0 record=0 rcscan_on=1
if [ "$(uname -s)" = Darwin ]; then CC_FLAG=--cc=clang; fi
bad=0
checks=0
self_host_boot() { printf 'bootstrap\n' >>"$d/home/calls"; }
run() {
  : >"$d/home/calls"
  paths=$({ git diff --name-only "$base...HEAD"; git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u)
  build_lane >"$d/log" 2>&1
}
expect() {
  local name=$1 builds=$2 scans=$3 boots=${4:-0} got_builds got_scans got_boots
  checks=$((checks + 1))
  got_builds=$(grep -c '^build$' "$d/home/calls" || true)
  got_scans=$(grep -c '^scan$' "$d/home/calls" || true)
  got_boots=$(grep -c '^bootstrap$' "$d/home/calls" || true)
  if [ "$got_builds" != "$builds" ] || [ "$got_scans" != "$scans" ] || [ "$got_boots" != "$boots" ]; then
    printf 'FAIL build reuse: %s: want builds/scans/boots=%s/%s/%s, got %s/%s/%s\n' "$name" "$builds" "$scans" "$boots" "$got_builds" "$got_scans" "$got_boots"
    bad=1
  else
    printf 'PASS build reuse: %s\n' "$name"
  fi
}
selected() { [[ "$group" = all || "$group" = unit || "$group" = "$1" ]]; }
if selected core; then
run
expect 'a byte-identical self-build proves the fixed point in gen1' 1 1
if ! grep -q 'byte-identical fixed point' "$d/log"; then
  printf 'FAIL build reuse: the byte-identity proof was not reported\n'; bad=1
fi
touch "$d/home/change-result"
run
expect 'different candidate bytes use the full bootstrap' 1 1 1
rm "$d/home/change-result"
cp "$d/verified.msc" "$w/msc"; cp "$d/verified.msc" "$CAND"
fi
if selected inputs; then
for path in src/index.ms std/a.ms runtime/a.h vendor/a.h; do
  printf 'dirty\n' >>"$w/$path"
  run
  expect "changed $path keeps the full bootstrap" 1 1 1
  git -C "$w" checkout -q -- "$path"
done
for path in build.ms src/build.ms; do
  printf 'config\n' >"$w/$path"
  run
  expect "$path changes keep the full bootstrap" 1 1 1
  rm "$w/$path"
done
fi
if selected roots; then
mkdir -p "$d/install/std/core/system"
printf 'different standard root\n' >"$d/install/std/core/system/index.ms"
cp "$d/verified.msc" "$d/install/msc"
BUILDER="$d/install/msc"
run
expect 'an installed producer cannot borrow the candidate support root' 1 1 1
BUILDER="$TOP/msc"
for root in "$OUT/std" "$TOP/out/std"; do
  mkdir -p "$root/core/system"
  printf 'shadow standard root\n' >"$root/core/system/index.ms"
  run
  expect "a shadow support root at $root disables byte identity" 1 1 1
  rm "$root/core/system/index.ms"
  rmdir "$root/core/system" "$root/core" "$root"
done
if ln -s "$d/install/msc" "$d/link-probe" 2>/dev/null && [ -L "$d/link-probe" ]; then
  rm "$w/msc"; ln -s "$d/install/msc" "$w/msc"
  run
  expect 'a symlinked producer uses the full bootstrap' 1 1 1
  rm "$w/msc"; cp "$d/verified.msc" "$w/msc"
  rm -f "$CAND"; ln -s "$d/install/msc" "$CAND"
  run
  expect 'a symlinked candidate uses the full bootstrap' 1 1 1
  rm "$CAND"; cp "$d/verified.msc" "$CAND"
  mv "$OUT" "$d/saved-gate"; ln -s "$d/saved-gate" "$OUT"
  run
  expect 'a symlinked candidate directory uses the full bootstrap' 1 1 1
  rm "$OUT"; mv "$d/saved-gate" "$OUT"
else
  printf 'SKIP build reuse: this host cannot create real symlinks\n'
fi
fi
if selected failures; then
touch "$d/home/scan-fail"
if run; then printf 'FAIL build reuse: a failing current scan was accepted\n'; bad=1; fi
expect 'the identity proof cannot hide a failing current scan' 1 1
rm "$d/home/scan-fail"
touch "$d/home/change-candidate"
if run; then printf 'FAIL build reuse: candidate mutation during the scan was accepted\n'; bad=1; fi
expect 'candidate mutation during the current scan cannot stay green' 1 1
rm "$d/home/change-candidate"
cp "$d/verified.msc" "$CAND"
touch "$d/home/change-producer"
if run; then printf 'FAIL build reuse: producer mutation during gen1 was accepted\n'; bad=1; fi
expect 'producer mutation invalidates the self-build proof' 1 0
rm "$d/home/change-producer"
cp "$d/verified.msc" "$w/msc"
touch "$d/home/build-fail"
if run; then printf 'FAIL build reuse: a failing native build was accepted\n'; bad=1; fi
expect 'the native build is never skipped' 1 0
rm "$d/home/build-fail"
fi
if selected core; then
release=1
run
expect 'release still runs the full bootstrap' 1 1 1
release=0
record=1
run
expect 'recording known reds still runs the full bootstrap' 1 1 1
record=0
saved_digest=$(declare -f file_digest)
file_digest() { printf 'matching-output-with-failed-status\n'; return 1; }
if run; then printf 'FAIL build reuse: failed digest validation was accepted\n'; bad=1; fi
expect 'digest errors cannot certify a fixed point' 1 0 1
eval "$saved_digest"
printf 'test "inline test" {}\n' >>"$w/src/index.ms"
git -C "$w" -c user.name=t -c user.email=t@t commit -qam inline-test
run
expect 'a committed inline test in production source keeps the full bootstrap' 1 1 1
git -C "$w" restore --source="$base" -- src/index.ms
git -C "$w" -c user.name=t -c user.email=t@t commit -qam restore-production
fi
if [ "$group" = all ] || [ "$group" = cli ]; then
cp "$d/verified.msc" "$w/msc"
sed 's/^stage=0$/stage=1/' "$d/verified.msc" >"$CAND"; chmod +x "$CAND"
printf 'objectB.o\n-o\n%s\n' "$CAND" >"${CAND}_link.rsp"
touch "$d/home/cache-hit" "$d/home/evolving"
: >"$d/home/calls"
if ! bash tools/gate.sh --base "$base" --lanes build >"$d/cli.log" 2>&1; then
  printf 'FAIL build reuse: the real gate rejected a native cache hit\n'; bad=1
  grep -E '^gate:|^  new:' "$d/cli.log" | tail -10 || true
fi
expect 'a stale response from an interrupted link cannot fake the fixed point' 4 1
if ! grep -q '^stage=2$' "$CAND"; then
  printf 'FAIL build reuse: stale response evidence retained the wrong compiler generation\n'; bad=1
fi
fi
printf 'build reuse: %s checks, status %s\n' "$checks" "$bad"
exit "$bad"
