#!/usr/bin/env bash
set -uo pipefail

INERT='\.md$|^docs/|^\.claude/|^\.github/|^\.gitignore$|^LICENSE|^src/test/known-red\.json$'
FLOOR_EXEMPT='^tools/'
EMITS='^src/(analyzer|ast|binder|checker|codegen|diagnostics|lexer|module|monomorphize|parser|raiser|transform|utils)/|^src/compiler/(meta/|[^/]+\.ms$)|^src/index\.ms$|^(std|runtime|vendor)/'
RULES=(
  'tools|^tools/'
  'hcr|^src/test/hcr/|^src/compiler/(cache|compile|hcrAbi)\.ms$|^src/transform/native/hcr|^runtime/hcr|^examples/hcrProbe/'
  'tests|^src/test/(c|js|fixedbugs|handoff|fmt|checker3pass|lang)/|^src/test/helpers\.ms$'
  "tests,corpus|$EMITS"
  'guard|^src/test/guard/'
  'corpus|^src/test/corpus/'
  'san,guard|^src/analyzer/|^runtime/(drc\.|arena\.h|manual\.h)|^src/transform/lowering/(destructorLifting|deferLower|ctorLower)\.ms$'
  'fmt|^src/(compiler/fmt|parser|lexer)/|^src/test/fmt/|^std/meta/'
  'boundary|^src/compiler/(buildConfig|cache|cc|commands|compile|defines|options|toolchain)\.ms$|^src/compiler/(meta/hostTable\.ms$|package/)|^src/index\.ms$|^src/test/nativeBuildBoundary\.ms$|^(runtime|vendor)/|^std/(fs|process)/'
)
DEFAULT_LANES="build suite"
ORDER="tools build boundary suite hcr tests suite-orc fmt corpus san guard"
LADDER="build boundary suite hcr tests suite-orc fmt corpus san guard"
KNOWN_LANES="boundary suite hcr suite-orc tests fmt corpus san guard"
RAISER_PATHS='^src/(raiser|codegen/raiser)/|^src/transform/raiserLowering\.ms$|\.rms$|^src/test/corpus/run\.ms$'
SELECT_BLIND='^(runtime|std|vendor)/|^src/test/corpus/[^/]*$|^src/(raiser|codegen/raiser)/|^src/transform/raiserLowering\.ms$|^src/compiler/meta/hostTable\.ms$|^src/compiler/(buildConfig|cache|cc|compile|defines|options|toolchain)\.ms$'

usage() {
  cat <<'USAGE'
usage: tools/gate.sh [--base <rev>] [--release] [--lanes a,b] [--dry-run] [--record]

Pick the verification lanes from the paths a change touches, run them one
after another, and compare every red against src/test/known-red.json.

  --base <rev>   diff against <rev> (default: main); uncommitted paths count too
  --release      the full ladder, whatever the diff says
  --lanes a,b    run exactly these lanes: tools build boundary suite hcr tests suite-orc fmt corpus san guard
  --dry-run      print the chosen lanes and the paths that pulled each one in
  --record       run the ladder on a clean main and rewrite known-red.json
  --reuse        read a lane log that already ended instead of running that lane again
  --reds <lane> <log>  print the failure names the gate reads out of a lane log
  --inert <from> <to>  exit 0 when every path changed from..to picks no lane
  --select       print the corpus programs whose emitted C or JS differs from the merge base
  --route        read paths on stdin, print "lane<TAB>path" for each lane a path picks
  --self-test    check the routing table and the red parsers against fixed cases

Every path that is not inert and not under tools/ gets build and suite; a rule
only adds lanes to that floor. The tests lane compiles its tiers with the
candidate, so a pin there tests the change rather than the previous compiler.

corpus and san run on the programs whose emitted C or JS the change alters
(control = the compiler at the merge base, kept in out/gate/ctl); they run whole
under --lanes and --release, and when a changed path cannot show in emitted code.

A known red that has turned green fails too: the set is then claiming a failure
that no longer happens, so drop the entry in the commit that fixed it. Unlike a
new red it does not stop the later lanes — one run should show every stale entry.

Every entry needs a non-empty "note" saying why it is still red or naming the
card that owns it; an empty one stops the run before any lane. --record writes
new entries with an empty note, so the run that records is the run that fills them.

The "flaky" section names programs that fail at random (a hang, a timeout), by
program rather than by lane. Their reds are counted and printed but are never new,
never known, and never known-now-green — a program that fails half the time cannot
answer either question. Putting one there needs a run that shows both outcomes.

exit: 0 no new red · 1 new red or a stale known red · 2 usage · 75 machine busy past GATE_WAIT_MAX
env:  GATE_WAIT_MAX seconds to wait for load <= cores (default 1800, 0 = do not wait)
USAGE
}

say() { printf '%s\n' "$*"; }
die() { printf 'gate: %s\n' "$*" >&2; exit 2; }

inert_range() {
  local paths
  paths=$(git diff --name-only --no-renames "$1" "$2") || return 2
  ! printf '%s\n' "$paths" | grep -Ev "$INERT" | grep -q .
}

digest() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1; }
hash_files() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }

emit_one() {
  local bin=$1 name=$2 entry=$3 d="$GATE_EMIT_DIR/$2" c_rc js_rc c js cs
  rm -rf "$d"; mkdir -p "$d" && cd "$d" || exit 1
  "$bin" build "$entry" --emit=c --gc=drc >c.log 2>&1; c_rc=$?
  "$bin" build "$entry" --emit=c --gc=drc --danger >>c.log 2>&1 || c_rc=1
  mapfile -t cs < <(find out -name '*.c' 2>/dev/null | LC_ALL=C sort)
  c=$({ echo "rc=$c_rc"; [ "$c_rc" -eq 0 ] || cat c.log; [ "${#cs[@]}" -eq 0 ] || hash_files "${cs[@]}"; } | digest)
  "$bin" build "$entry" --target=js --output=out.js >js.log 2>&1; js_rc=$?
  js=$({ echo "rc=$js_rc"; if [ "$js_rc" -eq 0 ]; then cat out.js; else cat js.log; fi; } 2>/dev/null | digest)
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$c" "$js" "$c_rc" "${#cs[@]}"
}

if [ "${1:-}" = --emit-one ]; then emit_one "${2:?}" "${3:?}" "${4:?}"; exit 0; fi

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git checkout"
cd "$TOP" || die "cannot enter $TOP"
KNOWN="$TOP/src/test/known-red.json"
OUT="$TOP/out/gate"
CAND="$OUT/msc"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) CAND="$CAND.exe" ;;
esac
EMIT="$OUT/emit"

reds_of() {
  local lane=$1 log=$2 rc=$3
  case "$lane" in
    build) [ "$rc" -eq 0 ] || echo "build" ;;
    boundary) sed -n 's/^FAIL  \(.*\)  expected=.*$/\1/p; s/^boundary: setup step failed: \(.*\) (root .*$/setup: \1/p' "$log" ;;
    tools) sed -n 's/^FAIL \(.*\): \(bash -n\|self-test\|check\)$/\1/p' "$log" ;;
    suite|suite-orc|tests)
      sed $'s/\x1b\\[[0-9;]*m//g' "$log" | awk -v top="$TOP/" '
        /^NORESULT / { sub(/^NORESULT /,""); print; next }
        /^ FAIL  / { f=$0; sub(/^ FAIL  /,"",f); if (index(f,top)==1) f=substr(f,length(top)+1); next }
        /^  × / { t=$0; sub(/^  × /,"",t); print f " > " t }
      '
      ;;
    corpus|san) sed -n 's/^ *✗ FAIL \([^]]*\]\).*$/\1/p' "$log" ;;
    guard|hcr) sed -n 's/^FAIL \([^:]*\):.*$/\1/p' "$log" ;;
    fmt) sed -n 's/^\(LOSSY\|UNSTABLE\|NO-FMT\|UNREADABLE\) \(.*\.ms\).*$/\2/p' "$log" ;;
  esac | sort -u
}

route_paths() {
  RULES_TXT=$(printf '%s\n' "${RULES[@]}") INERT_RE=$INERT EXEMPT_RE=$FLOOR_EXEMPT DEFAULT_TXT=$DEFAULT_LANES awk '
    BEGIN {
      n = split(ENVIRON["RULES_TXT"], rule, "\n")
      for (i = 1; i <= n; i++) { k = index(rule[i], "|"); lanes[i] = substr(rule[i], 1, k - 1); re[i] = substr(rule[i], k + 1) }
      nd = split(ENVIRON["DEFAULT_TXT"], floor, " ")
    }
    $0 == "" || $0 ~ ENVIRON["INERT_RE"] { next }
    {
      if ($0 !~ ENVIRON["EXEMPT_RE"]) for (j = 1; j <= nd; j++) print floor[j] "\t" $0
      for (i = 1; i <= n; i++) if ($0 ~ re[i]) { m = split(lanes[i], l, ","); for (j = 1; j <= m; j++) print l[j] "\t" $0 }
    }'
}

program_keys() {
  awk -F'\t' -v dir="src/test/corpus/programs/" '
    function prog(p,   n, a) { sub("^" dir, "", p); n = split(p, a, "/"); if (n == 1) sub(/\.ms$/, "", a[1]); return a[1] }
    $1 == "key" { key[prog($3)] = $2; next }
    $1 == "dirty" { n = split($3, r, " -> "); for (i = 1; i <= n; i++) outside[prog(r[i])] = 1; next }
    $1 == "ref" {
      c = index($3, ":\""); p = substr($3, 1, c - 1); m = substr($3, c + 2)
      rel = p; sub("^" dir, "", rel); depth = split(rel, a, "/") - 2
      if (depth < 0 || gsub(/\.\.\//, "", m) > depth) outside[prog(p)] = 1
      next }
    END { for (p in key) if (!(p in outside)) print p " " key[p] }'
}

self_test() {
  local bad=0 cases got want log
  cases=$(cat <<'CASES'
src/checker/checkPass.ms|build corpus suite tests
src/parser/parser.ms|build corpus fmt suite tests
src/lexer/lexer.ms|build corpus fmt suite tests
std/meta/node.ms|build corpus fmt suite tests
std/fs/index.ms|boundary build corpus suite tests
vendor/miniz/miniz.c|boundary build corpus suite tests
src/module/loader.ms|build corpus suite tests
src/monomorphize/index.ms|build corpus suite tests
src/utils/path.ms|build corpus suite tests
src/index.ms|boundary build corpus suite tests
src/analyzer/inject.ms|build corpus guard san suite tests
runtime/drc.h|boundary build corpus guard san suite tests
runtime/hcr.c|boundary build corpus hcr suite tests
src/codegen/c/expressions.ms|build corpus suite tests
src/transform/lowering/deferLower.ms|build corpus guard san suite tests
src/compiler/cc.ms|boundary build corpus suite tests
src/compiler/compile.ms|boundary build corpus hcr suite tests
src/compiler/meta/comptime.ms|build corpus suite tests
src/compiler/lsp/server.ms|build suite
src/compiler/transam/query.ms|build suite
src/compiler/package/install.ms|boundary build suite
src/compiler/meta/hostTable.ms|boundary build corpus suite tests
src/test/nativeBuildBoundary.ms|boundary build suite
src/compiler/fmt/printer.ms|build fmt suite
src/test/c/json.ms|build suite tests
src/test/helpers.ms|build suite tests
src/test/fmt/run.ms|build fmt suite tests
src/test/corpus/programs/804-enumNegativeValue.ms|build corpus suite
src/test/guard/run.ms|build guard suite
src/test/hcr/run.ms|build hcr suite
src/test/native/programs/x.ms|build suite
examples/hcrProbe/main.ms|build hcr suite
tools/gate.sh|tools
tools/syncLocalBinary.ms|tools
docs/TESTING.md|
src/test/known-red.json|
CASES
)
  got=$(printf '%s\n' "$cases" | cut -d'|' -f1 | route_paths | sort -u \
    | awk -F'\t' '{ a[$2] = ($2 in a) ? a[$2] " " $1 : $1 } END { for (p in a) print p "|" a[p] }')
  GOT=$got awk -F'|' '
    BEGIN { n = split(ENVIRON["GOT"], g, "\n"); for (i = 1; i <= n; i++) { k = index(g[i], "|"); m[substr(g[i], 1, k - 1)] = substr(g[i], k + 1) } }
    m[$1] != $2 { printf "FAIL route %s: want \"%s\", got \"%s\"\n", $1, $2, m[$1]; bad = 1 }
    END { exit bad }' <<<"$cases" || bad=1
  INERT_RE=$INERT BLIND_RE=$SELECT_BLIND awk -F'|' '
    { got = ($1 !~ ENVIRON["INERT_RE"] && $1 ~ ENVIRON["BLIND_RE"]) ? "blind" : "" }
    got != $2 { printf "FAIL narrowing %s: want \"%s\", got \"%s\"\n", $1, $2, got; bad = 1 }
    END { exit bad }' <<'CASES' || bad=1
src/checker/checkPass.ms|
src/codegen/c/expressions.ms|
src/compiler/cc.ms|blind
src/compiler/compile.ms|blind
src/compiler/toolchain.ms|blind
std/fs/index.ms|blind
runtime/drc.h|blind
src/test/corpus/run.ms|blind
src/test/corpus/programs/804-enumNegativeValue.ms|
CASES
  INERT_RE=$INERT RAISER_RE=$RAISER_PATHS awk -F'|' '
    { got = ($1 !~ ENVIRON["INERT_RE"] && $1 ~ ENVIRON["RAISER_RE"]) ? "raiser" : "" }
    got != $2 { printf "FAIL raiser lane %s: want \"%s\", got \"%s\"\n", $1, $2, got; bad = 1 }
    END { exit bad }' <<'CASES' || bad=1
src/raiser/vm.ms|raiser
src/codegen/raiser/emit.ms|raiser
src/transform/raiserLowering.ms|raiser
std/core/date/index.rms|raiser
src/test/corpus/run.ms|raiser
src/checker/checkPass.ms|
src/codegen/c/expressions.ms|
std/core/date/index.cms|
CASES
  log=$(mktemp) || return 1
  printf '%s\n' " FAIL  $TOP/src/test/c/json.ms" "  × parses numbers" \
    "NORESULT src/test/fixedbugs/index.ms > no result" "error: 3 type error(s) found" >"$log"
  got=$(reds_of tests "$log" 1 | paste -sd'|' -)
  want="src/test/c/json.ms > parses numbers|src/test/fixedbugs/index.ms > no result"
  [ "$got" = "$want" ] || { printf 'FAIL reds tests: want "%s", got "%s"\n' "$want" "$got"; bad=1; }
  printf '%s\n' "FAIL  when branch after a -d: value change  expected=two actual=other" \
    "boundary: setup step failed: source baseline (root C:/tmp/msc-native-boundary-1)" "pass  argv  expected=1 actual=1" >"$log"
  got=$(reds_of boundary "$log" 1 | paste -sd'|' -)
  want="setup: source baseline|when branch after a -d: value change"
  [ "$got" = "$want" ] || { printf 'FAIL reds boundary: want "%s", got "%s"\n' "$want" "$got"; bad=1; }
  rm -f "$log"
  got=$(printf 'key\t%s\tsrc/test/corpus/programs/%s\n' o1 100-file.ms o2 200-dir o3 630-escapes.ms o4 802-nested o5 803-up o6 804-dirty \
    | cat - <(printf 'ref\t\tsrc/test/corpus/programs/%s\n' '630-escapes.ms:"../../../' '802-nested/app/direct.ms:"../' '802-nested/main.ms:"./' '803-up/main.ms:"../') \
      <(printf 'dirty\t\tsrc/test/corpus/programs/%s\n' 804-dirty/main.ms 900-new/main.ms) \
    | program_keys | sort | paste -sd'|' -)
  want="100-file o1|200-dir o2|802-nested o4"
  [ "$got" = "$want" ] || { printf 'FAIL control reuse: want "%s", got "%s"\n' "$want" "$got"; bad=1; }
  [ "$bad" -ne 0 ] || say "gate: self-test ok"
  return $bad
}

base=main release=0 dry=0 record=0 reuse=0 lanes_arg="" select_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base=${2:?--base needs a rev}; shift ;;
    --release) release=1 ;;
    --lanes) lanes_arg=${2:?--lanes needs a list}; shift ;;
    --dry-run) dry=1 ;;
    --select) select_only=1 ;;
    --record) record=1 ;;
    --reuse) reuse=1 ;;
    --reds) reds_of "${2:?--reds needs a lane}" "${3:?--reds needs a log}" 1; exit 0 ;;
    --inert) inert_range "${2:?--inert needs <from> <to>}" "${3:?--inert needs <from> <to>}"; exit $? ;;
    --route) route_paths; exit 0 ;;
    --self-test) self_test; exit $? ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

changed_paths() {
  {
    git diff --name-only --no-renames "$base...HEAD" 2>/dev/null
    git diff --name-only --no-renames HEAD
    git ls-files --others --exclude-standard
  } | sort -u
}

mkdir -p "$OUT" || die "cannot create $OUT"
: >"$OUT/why"
paths=$(changed_paths)

if [ -n "$lanes_arg" ]; then
  chosen=$(printf '%s\n' "$lanes_arg" | tr ',' '\n')
  for l in $chosen; do
    case " $ORDER " in *" $l "*) ;; *) die "unknown lane '$l'" ;; esac
    printf '%s\t%s\n' "$l" "--lanes" >>"$OUT/why"
  done
elif [ "$release" -eq 1 ] || [ "$record" -eq 1 ]; then
  chosen=$LADDER
  for l in $chosen; do printf '%s\t%s\n' "$l" "the full ladder" >>"$OUT/why"; done
else
  printf '%s\n' "$paths" | route_paths | sort -u >"$OUT/why"
  chosen=$(cut -f1 "$OUT/why" | sort -u)
fi

lanes=""
for l in $ORDER; do
  if printf '%s\n' $chosen | grep -qx "$l"; then lanes="$lanes $l"; fi
done
lanes=${lanes# }

select=0 select_why="" select_label=""
for l in corpus san; do
  case " $lanes " in *" $l "*) select_label="${select_label:+$select_label and }$l" ;; esac
done
case " $lanes " in *" corpus "*|*" san "*)
  if [ -n "$lanes_arg" ]; then select_why="--lanes runs a lane whole"
  elif [ "$release" -eq 1 ] || [ "$record" -eq 1 ]; then select_why="the full ladder"
  else
    blind=$(printf '%s\n' "$paths" | grep -Ev "$INERT" | grep -E "$SELECT_BLIND" | head -1)
    if [ -n "$blind" ]; then select_why="$blind cannot show in emitted code"; else select=1; fi
  fi ;;
esac

raiser_on=0 raiser_why=""
if [ "$release" -eq 1 ] || [ "$record" -eq 1 ]; then raiser_on=1 raiser_why="the full ladder"
else
  raiser_why=$(printf '%s\n' "$paths" | grep -Ev "$INERT" | grep -E "$RAISER_PATHS" | head -1)
  [ -z "$raiser_why" ] || raiser_on=1
fi

explain() {
  local l n
  for l in $lanes; do
    n=$(awk -F'\t' -v l="$l" '$1==l' "$OUT/why" | wc -l | tr -d ' ')
    say "gate: $l <- $(awk -F'\t' -v l="$l" '$1==l{print $2}' "$OUT/why" | head -3 | paste -sd, - | sed 's/,/, /g')$([ "$n" -gt 3 ] && printf ' (+%d more)' $((n - 3)))"
  done
  if [ "$select" -eq 1 ]; then
    say "gate: $select_label narrowed to the programs whose emitted C or JS differs from $(git merge-base "$base" HEAD | cut -c1-8)"
  elif [ -n "$select_why" ] && [ -z "$lanes_arg" ] && [ "$release" -eq 0 ] && [ "$record" -eq 0 ]; then
    say "gate: no narrowing for $select_label ($select_why)"
  fi
  case " $lanes " in *" corpus "*)
    if [ "$raiser_on" -eq 1 ]; then say "gate: corpus runs the raiser lane <- $raiser_why"; else say "gate: corpus without the raiser lane (no change reaches the Raiser VM)"; fi ;;
  esac
}

if [ -z "$lanes" ]; then
  say "gate: GREEN (no lane: $(printf '%s\n' "$paths" | grep -c . | tr -d ' ') changed path(s), none reach the compiler or a tool)"
  exit 0
fi
explain
[ "$dry" -eq 0 ] || exit 0

if [ "$record" -eq 1 ]; then
  base=main
  off_main=$(changed_paths | route_paths | awk -F'\t' '$1 != "tools" { print $2 }' | sort -u)
  [ -z "$off_main" ] || die "--record: this checkout differs from main on paths the lanes test:
$(printf '%s\n' "$off_main" | head -5 | sed 's/^/  /')"
fi

if [ -x "$TOP/msc" ]; then BUILDER="$TOP/msc"; else BUILDER=$(command -v msc) || die "no ./msc and no msc on PATH"; fi
CC_FLAG=""
[ "$(uname -s)" = Darwin ] && command -v clang >/dev/null 2>&1 && CC_FLAG="--cc=clang"

cores() { sysctl -n hw.ncpu 2>/dev/null || nproc; }
load1() {
  if [ -r /proc/loadavg ]; then cut -d' ' -f1 /proc/loadavg; else sysctl -n vm.loadavg | awk '{print $2}'; fi
}
admit() {
  local max=${GATE_WAIT_MAX:-1800} waited=0 n l
  n=$(cores)
  while :; do
    l=$(load1)
    awk -v l="$l" -v n="$n" 'BEGIN{exit !(l<=n)}' && return 0
    [ "$waited" -lt "$max" ] || { say "gate: BUSY load $l > $n cores after ${waited}s"; exit 75; }
    say "gate: waiting, load $l > $n cores (${waited}s/${max}s)"
    sleep 60; waited=$((waited + 60))
  done
}

lane_cmd() {
  case "$1" in
    build) printf '%s build src/index.ms --gc=drc --danger %s --output=%s' "$BUILDER" "$CC_FLAG" "$CAND" ;;
    boundary) printf '%s run src/test/nativeBuildBoundary.ms --target=raiser %s' "$CAND" "$CAND" ;;
    hcr) printf 'MSC=%s %s run src/test/hcr/run.ms --target=raiser' "$CAND" "$CAND" ;;
    corpus) printf '%s%sMSC=%s %s run src/test/corpus/run.ms' "$narrow" "$([ "$raiser_on" -eq 1 ] && printf 'MSCORPUS_RAISER=1 ')" "$CAND" "$BUILDER" ;;
    san) printf '%sMSCORPUS_SAN=1 MSC=%s %s run src/test/corpus/run.ms' "$narrow" "$CAND" "$BUILDER" ;;
    fmt) printf '%s run src/test/fmt/run.ms' "$BUILDER" ;;
  esac
}

run_tools_lane() {
  local p rc=0
  while IFS=$'\t' read -r _ p; do
    [ -f "$p" ] || continue
    case "$p" in
      *.sh)
        if ! bash -n "$p"; then printf 'FAIL %s: bash -n\n' "$p"; rc=1
        elif [ "$p" = tools/gate.sh ] && ! bash "$p" --self-test; then printf 'FAIL %s: self-test\n' "$p"; rc=1
        fi ;;
      *.ms) "$BUILDER" check "$p" || { printf 'FAIL %s: check\n' "$p"; rc=1; } ;;
    esac
  done < <(awk -F'\t' '$1=="tools"' "$OUT/why")
  return $rc
}

TIERS="src/test/js/index.ms src/test/c/index.ms src/test/fixedbugs/index.ms src/test/handoff/index.ms src/test/fmt/index.ms src/test/checker3pass/index.ms src/test/lang/index.ms src/test/helpers.ms"

part_of() { printf '%s/%s.%s.part' "$OUT" "$1" "$(printf '%s' "$2" | tr '/.' '__')"; }

test_one() {
  local bin=$1 f=$2 part=$3; shift 3
  env -u NO_COLOR -u FORCE_COLOR "$bin" test "$f" "$@" >"$part" 2>&1
  echo $? >"$part.rc"
}

run_test_lane() {
  local rc=0 f part files=src/index.ms
  case "$1" in
    suite) with_test_binary with_slot test_one "$BUILDER" src/index.ms "$(part_of suite src/index.ms)" ;;
    suite-orc) with_test_binary with_slot test_one "$BUILDER" src/index.ms "$(part_of suite-orc src/index.ms)" --gc=orc ;;
    tests)
      files=$TIERS
      for f in $files; do with_slot test_one "$CAND" "$f" "$(part_of tests "$f")" --tests-in-dir & done
      wait ;;
  esac
  for f in $files; do
    part=$(part_of "$1" "$f")
    cat "$part"
    [ "$(cat "$part.rc" 2>/dev/null)" = 0 ] || rc=1
    if ! sed $'s/\x1b\\[[0-9;]*m//g' "$part" | grep -Eq '^ *Test Files +[0-9]'; then
      printf 'NORESULT %s > no result\n' "$f"
      sed $'s/\x1b\\[[0-9;]*m//g' "$part" | grep -E '^(error|internal|fatal)' | head -3
      rc=1
    fi
    rm -f "$part" "$part.rc"
  done
  return $rc
}

known_of() {
  [ -f "$KNOWN" ] || return 0
  jq -r --arg l "$1" '.[$l] // {} | keys[]' "$KNOWN" | tr -d '\r' | sort -u
}

flaky_ids() {
  [ -f "$KNOWN" ] || return 0
  jq -r '.flaky // {} | keys[]' "$KNOWN" | sort -u
}

split_flaky() {
  awk -v want="$1" '
    NR == FNR { f[$0] = 1; next }
    { id = $0; sub(/ \[[^]]*\]$/, "", id)
      hit = (id in f) || ($0 in f)
      if ((want == "keep") == (hit != 0)) print }' "$OUT/flaky.ids" -
}

totals_of() {
  local lane=$1 log=$2
  [ -f "$log" ] || return 0
  case "$lane" in
    corpus|san)
      sed $'s/\x1b\\[[0-9;]*m//g' "$log" | awk '
        /^[0-9]+ pass · [0-9]+ fail/ { p = $1; f = $4 }
        END { if (p != "") printf "%d/%d", p, p + f }' ;;
    suite|suite-orc|tests)
      sed $'s/\x1b\\[[0-9;]*m//g' "$log" | awk '
        /^ *Tests +[0-9]/ {
          for (i = 2; i <= NF; i++) if ($i == "passed") p += $(i - 1)
          if (match($0, /\([0-9]+\)$/)) t += substr($0, RSTART + 1, RLENGTH - 2)
        }
        END { if (t) printf "%d/%d", p, t }' ;;
  esac
}

list_programs() {
  local e n
  for e in "$TOP"/src/test/corpus/programs/*; do
    n=${e##*/}
    case "$n" in [0-9]*-*) ;; *) continue ;; esac
    if [ -d "$e" ]; then
      [ -f "$e/main.ms" ] && printf '%s %s\n' "$n" "$e/main.ms"
    else
      case "$n" in *.ms) printf '%s %s\n' "${n%.ms}" "$e" ;; esac
    fi
  done
}

emit_side() {
  local jobs
  jobs=$(share_of_cores 2)
  mkdir -p "$2"
  bounded env -u FORCE_COLOR GATE_EMIT_DIR="$2" NO_COLOR=1 xargs -r -P "$jobs" -L1 "$TOP/tools/gate.sh" --emit-one "$1"
}

reusable_programs() {
  local dir=src/test/corpus/programs
  {
    git ls-tree HEAD "$dir/" | awk -F'\t' '{ split($1, m, " "); print "key\t" m[3] "\t" $2 }'
    git status --porcelain --untracked-files=all -- "$dir" | awk '{ print "dirty\t\t" substr($0, 4) }'
    grep -rEo '"\.{1,2}/(\.\./)*' "$dir" | awk '{ print "ref\t\t" $0 }'
  } | program_keys
}

emit_control() {
  local dir="$OUT/ctl/emit"
  mkdir -p "$dir"
  reusable_programs >"$EMIT/ctl.keys"
  awk -v dir="$dir" -v keys="$EMIT/ctl.keys" '
    BEGIN { while ((getline l < keys) > 0) { split(l, a, " "); key[a[1]] = a[2] } }
    { f = dir "/" $1; have = ""
      if (($1 in key) && (getline have < (f ".key")) > 0 && have == key[$1] && (getline sig < (f ".sig")) > 0) { close(f ".key"); close(f ".sig"); next }
      close(f ".key"); close(f ".sig"); print }' "$EMIT/programs" >"$EMIT/ctl.todo"
  emit_side "$1" "$dir" <"$EMIT/ctl.todo" | awk -v dir="$dir" -v keys="$EMIT/ctl.keys" '
    BEGIN { while ((getline l < keys) > 0) { split(l, a, " "); key[a[1]] = a[2] } }
    { f = dir "/" $1; print > (f ".sig"); close(f ".sig"); printf "%s", (($1 in key) ? key[$1] "\n" : "") > (f ".key"); close(f ".key") }'
  awk -v dir="$dir" '{ f = dir "/" $1 ".sig"; if ((getline l < f) > 0) print l; close(f) }' "$EMIT/programs" | sort >"$EMIT/ctl.sig"
}

select_whole() { select=0; say "gate: select gave up, no narrowing for $select_label ($1)"; }

select_programs() {
  local sha ctl="$OUT/ctl/msc" t0=$SECONDS n_all line
  sha=$(git merge-base "$base" HEAD) || { select_whole "no merge base with $base"; return; }
  if [ ! -x "$ctl" ] || [ "$(cat "$OUT/ctl/sha" 2>/dev/null)" != "$sha" ]; then
    rm -rf "$OUT/ctl" "$OUT/ctl-src"
    mkdir -p "$OUT/ctl" "$OUT/ctl-src"
    git archive "$sha" src | tar -x -C "$OUT/ctl-src" || { select_whole "cannot unpack src at $sha"; return; }
    (cd "$OUT/ctl-src" && bounded env -u NO_COLOR -u FORCE_COLOR $BUILDER build src/index.ms --gc=drc --danger $CC_FLAG --output="$ctl") >"$OUT/ctl.log" 2>&1
    [ -x "$ctl" ] || { select_whole "the control compiler at $(printf '%s' "$sha" | cut -c1-8) did not build, log: $OUT/ctl.log"; return; }
    printf '%s\n' "$sha" >"$OUT/ctl/sha"
  fi
  rm -rf "$EMIT"
  mkdir -p "$EMIT"
  list_programs >"$EMIT/programs"
  emit_control "$ctl"
  emit_side "$CAND" "$EMIT/cand" <"$EMIT/programs" | sort >"$EMIT/cand.sig"
  n_all=$(grep -c . "$EMIT/programs")
  if [ "$(grep -c . "$EMIT/ctl.sig")" -ne "$n_all" ] || [ "$(grep -c . "$EMIT/cand.sig")" -ne "$n_all" ]; then
    select_whole "an emit pass lost programs"; return
  fi
  if awk -F'\t' '$4 == 0 && $5 == 0 { bad = 1 } END { exit !bad }' "$EMIT/ctl.sig" "$EMIT/cand.sig"; then
    select_whole "a clean --emit=c left no C file to compare"; return
  fi
  join -t "$(printf '\t')" "$EMIT/ctl.sig" "$EMIT/cand.sig" >"$EMIT/both"
  awk -F'\t' '$2 != $6 { print $1 }' "$EMIT/both" >"$EMIT/differ.c"
  awk -F'\t' '$3 != $7 { print $1 }' "$EMIT/both" >"$EMIT/differ.js"
  printf '%s\n' "$paths" | sed -n 's|^src/test/corpus/programs/\([^/]*\).*$|\1|p' | sed 's/\.ms$//' | sort -u >"$EMIT/touched.all"
  cut -d' ' -f1 "$EMIT/programs" | sort | comm -12 - "$EMIT/touched.all" >"$EMIT/touched"
  sort -u "$EMIT/differ.c" "$EMIT/differ.js" "$EMIT/touched" >"$EMIT/only.corpus"
  sort -u "$EMIT/differ.c" "$EMIT/touched" >"$EMIT/only.san"
  line="gate: select $(fmt_secs $((SECONDS - t0))) · $n_all programs · $(grep -c . "$EMIT/differ.c" | tr -d ' ') differ in C · $(grep -c . "$EMIT/differ.js" | tr -d ' ') in JS · $(grep -c . "$EMIT/touched" | tr -d ' ') touched"
  [ -s "$EMIT/only.corpus" ] || line="$line — byte-neutral for the corpus; if this is a fix, its repro belongs in corpus/programs"
  say "$line"
  selected=1
}

narrow_for() {
  narrow="" only_csv="" lanes_csv=""
  [ "$select" -eq 1 ] || return 0
  only_csv=$(paste -sd, "$EMIT/only.$1")
  [ -n "$only_csv" ] || return 0
  narrow="MSCORPUS_ONLY=$only_csv "
  if [ "$1" = corpus ] && [ ! -s "$EMIT/only.san" ]; then
    lanes_csv="c,drc,js,esm,raiser"
    narrow="${narrow}MSCORPUS_LANES=$lanes_csv "
  fi
}

scope_known() {
  awk -v only="$only_csv" -v lanes="$lanes_csv" -v drop_raiser="$([ "$1" = corpus ] && [ "$raiser_on" -eq 0 ] && echo 1)" '
    BEGIN { n = split(only, a, ","); for (i = 1; i <= n; i++) keep[a[i]] = 1
            m = split(lanes, b, ","); for (i = 1; i <= m; i++) lane_kept[b[i]] = 1 }
    { prog = $0; sub(/ \[.*$/, "", prog); lane = $0; sub(/^.*\[/, "", lane); sub(/\].*$/, "", lane)
      if (drop_raiser == 1 && lane == "raiser") next
      if (n > 0 && !(prog in keep)) next
      if (m > 0 && lane != "parity" && !(lane in lane_kept)) next
      print }'
}

LANE_LIMIT=${GATE_LANE_LIMIT:-5400}

kill_group() {
  local w
  if [ -r "/proc/$1/winpid" ]; then
    for w in $(ps | awk -v g="$1" '$1 !~ /^[0-9]+$/ { $1 = ""; $0 = $0 } $3 == g { print $4 }'); do
      taskkill //T //F //PID "$w" >/dev/null 2>&1
    done
  fi
  kill -KILL -- "-$1" 2>/dev/null
}

bounded() {
  local pid waited=0
  set -m; "$@" & pid=$!; set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$LANE_LIMIT" ]; then
      kill_group "$pid"; wait "$pid" 2>/dev/null
      printf '\nTIMEOUT after %ss, process tree killed: %s\n' "$LANE_LIMIT" "$*" >&2
      return 124
    fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid"
}

need_cand() {
  [ -x "$CAND" ] || die "lane '$1' tests the candidate compiler; include the build lane"
}

fmt_secs() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }

GATES_DIR="${HOME:-$USERPROFILE}/.metascript/gates"

live_gates() {
  local f n=0
  for f in "$GATES_DIR"/*; do
    [ -e "$f" ] || continue
    if kill -0 "${f##*/}" 2>/dev/null; then n=$((n + 1)); else rm -f "$f"; fi
  done
  [ "$n" -ge 1 ] || n=1
  echo "$n"
}

share_of_cores() {
  local w=$(( $(cores) / $(live_gates) / $1 ))
  [ "$w" -ge 1 ] || w=1
  echo "$w"
}

if [ "$select_only" -eq 1 ]; then
  need_cand select
  select=1 selected=0 select_label=corpus
  select_programs
  [ "$selected" -eq 0 ] || cat "$EMIT/only.corpus"
  exit 0
fi

if [ "$record" -eq 0 ] && [ -f "$KNOWN" ]; then
  unnoted=$(jq -r 'to_entries[] | .key as $l | .value | to_entries[]
                   | select((.value.note // "") == "") | "  no reason: \($l) · \(.key)"' "$KNOWN")
  if [ -n "$unnoted" ]; then
    printf '%s\n' "$unnoted" >&2
    die "known red(s) without a note: each one names why it is still red, or the card that owns it"
  fi
fi

mkdir -p "$OUT"
flaky_ids >"$OUT/flaky.ids"

SLOTS_DIR="$OUT/slots"

take_slot() {
  local i
  while :; do
    for ((i = 0; i < PAR; i++)); do mkdir "$SLOTS_DIR/$i" 2>/dev/null && { echo "$i"; return; }; done
    sleep 1
  done
}

with_slot() {
  local s rc
  s=$(take_slot)
  "$@"; rc=$?
  rmdir "$SLOTS_DIR/$s" 2>/dev/null
  return $rc
}

with_test_binary() {
  until mkdir "$SLOTS_DIR/test-binary" 2>/dev/null; do sleep 1; done
  "$@"; local rc=$?
  rmdir "$SLOTS_DIR/test-binary" 2>/dev/null
  return $rc
}

run_guard_lane() {
  local i n=${GATE_GUARD_SHARDS:-$PAR} rc=0 part
  for ((i = 0; i < n; i++)); do
    part="$OUT/guard.$i.part"
    (with_slot env -u FORCE_COLOR NO_COLOR=1 GUARD_SHARD="$i/$n" MSC="$CAND" "$CAND" run src/test/guard/run.ms --target=raiser >"$part" 2>&1; echo $? >"$part.rc") &
  done
  wait
  for ((i = 0; i < n; i++)); do
    part="$OUT/guard.$i.part"
    cat "$part"
    [ "$(cat "$part.rc" 2>/dev/null)" = 0 ] || rc=1
    rm -f "$part" "$part.rc"
  done
  return $rc
}

lane_body() {
  local lane=$1 log="$OUT/$1.log" rc t0=$SECONDS
  case "$lane" in
    tools) bounded run_tools_lane >"$log" 2>&1; rc=$? ;;
    tests|suite|suite-orc) bounded run_test_lane "$lane" >"$log" 2>&1; rc=$? ;;
    guard) bounded run_guard_lane >"$log" 2>&1; rc=$? ;;
    boundary|corpus|san|hcr) with_slot bounded env -u FORCE_COLOR NO_COLOR=1 bash -c "$(lane_cmd "$lane")" >"$log" 2>&1; rc=$? ;;
    *) with_slot bounded env -u NO_COLOR -u FORCE_COLOR bash -c "$(lane_cmd "$lane")" >"$log" 2>&1; rc=$? ;;
  esac
  printf '\nSECS=%d\nRC=%d\nEND\n' "$((SECONDS - t0))" "$rc" >>"$log"
}

PHASES=("tools build" "boundary suite suite-orc hcr tests fmt" "corpus guard" "san")

start=$SECONDS
ran="" verdict=GREEN stopped="" selected=0 narrow="" only_csv="" lanes_csv=""
mkdir -p "$GATES_DIR" && : >"$GATES_DIR/$$"
trap 'rm -f "$GATES_DIR/$$"' EXIT
PAR=${GATE_PAR:-$(share_of_cores 10)}
rm -rf "$SLOTS_DIR" && mkdir -p "$SLOTS_DIR"
[ "$lanes" = tools ] || admit

for phase in "${PHASES[@]}"; do
  todo=""
  for lane in $phase; do case " $lanes " in *" $lane "*) todo="$todo $lane" ;; esac; done
  [ -n "$todo" ] || continue
  if [ -n "$stopped" ]; then
    for lane in $todo; do say "gate: $lane skipped, $stopped has a new red"; done
    continue
  fi
  [ "$todo" = " tools" ] || [ "$phase" = "${PHASES[0]}" ] || admit
  heavy=0
  for lane in $todo; do case "$lane" in corpus|san) heavy=$((heavy + 1)) ;; esac; done
  [ "$heavy" -ge 1 ] || heavy=1
  export MSCORPUS_BUILD_JOBS
  MSCORPUS_BUILD_JOBS=$(share_of_cores "$heavy")
  select_pid=""
  case " $todo " in *" suite "*|*" tests "*)
    if [ "$select" -eq 1 ] && [ "$selected" -eq 0 ] && [ -x "$CAND" ]; then
      (with_slot select_programs; printf '%s %s\n' "$select" "$selected" >"$OUT/select.state") & select_pid=$!
    fi ;;
  esac
  pids="" launched=""
  for lane in $todo; do
    log="$OUT/$lane.log"
    : >"$OUT/$lane.scope"
    case "$lane" in build|tools) ;; *) need_cand "$lane" ;; esac
    case "$lane" in corpus|san)
      if [ -n "$select_pid" ]; then wait "$select_pid"; select_pid=""; read -r select selected <"$OUT/select.state"; fi
      [ "$select" -eq 0 ] || [ "$selected" -eq 1 ] || select_programs
      narrow="" only_csv="" lanes_csv=""
      narrow_for "$lane"
      if [ "$select" -eq 1 ] && [ -z "$only_csv" ]; then say "gate: $lane skipped, no program's emitted $([ "$lane" = san ] && printf 'C' || printf 'C or JS') differs"; continue; fi
      printf '%s\n%s\n' "$only_csv" "$lanes_csv" >"$OUT/$lane.scope" ;;
    esac
    launched="$launched $lane"
    if [ "$reuse" -eq 1 ] && [ "$(tail -1 "$log" 2>/dev/null)" = END ]; then continue; fi
    lane_body "$lane" & pids="$pids $!"
  done
  [ -z "$pids" ] || wait $pids
  if [ -n "$select_pid" ]; then wait "$select_pid"; read -r select selected <"$OUT/select.state"; fi
  for lane in $launched; do
  log="$OUT/$lane.log"
  rc=$(sed -n 's/^RC=\([0-9][0-9]*\)$/\1/p' "$log" | tail -1); rc=${rc:-1}
  secs=$(sed -n 's/^SECS=\([0-9][0-9]*\)$/\1/p' "$log" | tail -1)
  { read -r only_csv; read -r lanes_csv; } <"$OUT/$lane.scope" || { only_csv=""; lanes_csv=""; }
  reused=""
  [ "$reuse" -eq 0 ] || reused=" (reused log)"
  { reds_of "$lane" "$log" "$rc"; grep -q '^TIMEOUT after ' "$log" && echo "timed out"; } | sort -u >"$OUT/$lane.red.all"
  split_flaky keep <"$OUT/$lane.red.all" >"$OUT/$lane.flaky"
  split_flaky drop <"$OUT/$lane.red.all" >"$OUT/$lane.red"
  if [ "$rc" -ne 0 ] && [ ! -s "$OUT/$lane.red" ]; then echo "$lane: exit $rc with no named failure" >"$OUT/$lane.red"; fi
  known_of "$lane" | scope_known "$lane" >"$OUT/$lane.known"
  comm -23 "$OUT/$lane.red" "$OUT/$lane.known" >"$OUT/$lane.new"
  comm -13 "$OUT/$lane.red" "$OUT/$lane.known" >"$OUT/$lane.fixed"
  n_red=$(grep -c . "$OUT/$lane.red" | tr -d ' ')
  n_new=$(grep -c . "$OUT/$lane.new" | tr -d ' ')
  n_fixed=$(grep -c . "$OUT/$lane.fixed" | tr -d ' ')
  n_flaky=$(grep -c . "$OUT/$lane.flaky" | tr -d ' ')
  [ -z "$only_csv" ] || reused="$reused on $(printf '%s' "$only_csv" | tr ',' '\n' | grep -c . | tr -d ' ') program(s)${lanes_csv:+, lanes $lanes_csv}"
  line="gate: $lane$reused $(fmt_secs "${secs:-0}") · $n_red red · $((n_red - n_new)) known · $n_new new"
  [ "$n_fixed" -eq 0 ] || line="$line · $n_fixed known-now-green ($(head -3 "$OUT/$lane.fixed" | paste -sd, - | sed 's/,/, /g'))"
  xp=$(sed -n 's/^.* \([0-9][0-9]*\) xpass$/\1/p' "$log" | tail -1)
  [ -z "$xp" ] || [ "$xp" = 0 ] || line="$line · $xp xpass"
  [ "$n_flaky" -eq 0 ] || line="$line · $n_flaky flaky ($(head -3 "$OUT/$lane.flaky" | paste -sd, - | sed 's/,/, /g'))"
  totals=$(totals_of "$lane" "$log")
  [ -z "$totals" ] || line="$line · $totals case"
  say "$line"
  ran="$ran $lane"
  if [ "$n_fixed" -gt 0 ] && [ "$record" -eq 0 ]; then
    verdict=RED
    while IFS= read -r name; do
      say "  known-now-green: $name"
    done <"$OUT/$lane.fixed"
    say "  the set now lies: drop those from src/test/known-red.json in the commit that fixed them"
  fi
  if [ "$n_new" -gt 0 ] && [ "$record" -eq 0 ]; then
    verdict=RED; stopped=$lane
    while IFS= read -r name; do
      say "  new: $name"
      grep -F -A3 -- "$name" "$log" | sed -n '2,4p' | sed 's/^/       /'
    done <"$OUT/$lane.new"
    say "  log: $log"
  fi
  done
done

if [ "$record" -eq 1 ]; then
  sha=$(git rev-parse --short HEAD)
  [ -f "$KNOWN" ] || echo '{}' >"$KNOWN.prev"
  [ -f "$KNOWN" ] && cp "$KNOWN" "$KNOWN.prev"
  merged=$(cat "$KNOWN.prev")
  for lane in $ran; do
    case " $KNOWN_LANES " in *" $lane "*) ;; *) continue ;; esac
    merged=$(jq -n --argjson prev "$merged" --arg l "$lane" --arg sha "$sha" --rawfile reds "$OUT/$lane.red" '
      ($reds | split("\n") | map(select(length > 0))) as $names
      | $prev + {($l): ($names | map({key: ., value: (($prev[$l] // {})[.] // {since: $sha, note: ""})}) | from_entries)}')
  done
  printf '%s' "$merged" | jq -r '
    "{\n" + ([to_entries | sort_by(.key)[] |
      "  \(.key | @json): {" +
      (if (.value | length) == 0 then "" else
        "\n" + ([.value | to_entries | sort_by(.key)[] | "    \(.key | @json): \(.value | tojson)"] | join(",\n")) + "\n  "
      end) + "}"] | join(",\n")) + "\n}"' >"$KNOWN"
  diff -u "$KNOWN.prev" "$KNOWN" | sed -n '3,$p'
  rm -f "$KNOWN.prev"
  say "gate: RECORDED $(jq '[.[] | length] | add // 0' "$KNOWN") known red(s) at $sha ($(fmt_secs $((SECONDS - start)))) -> src/test/known-red.json"
  exit 0
fi

say "gate: $verdict ($(printf '%s' "$ran" | sed 's/^ //; s/ /, /g')) $(fmt_secs $((SECONDS - start)))"
[ "$verdict" = GREEN ]
