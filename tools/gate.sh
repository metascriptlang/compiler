#!/usr/bin/env bash
set -uo pipefail

INERT='\.md$|^docs/|^\.claude/|^\.github/|^\.gitignore$|^LICENSE|^src/test/known-red\.json$'
RULES=(
  'tools|^tools/'
  'build,suite,guard|^src/test/guard/'
  'build,suite,corpus|^src/test/corpus/'
  'build,suite,corpus|^(src/(codegen|analyzer|transform)|runtime)/'
  'build,suite,san,guard|^src/analyzer/|^runtime/(drc\.|arena\.h|manual\.h)|^src/transform/lowering/(destructorLifting|deferLower|ctorLower)\.ms$'
)
DEFAULT_LANES="build suite"
ORDER="tools build suite suite-orc corpus san guard"
LADDER="build suite suite-orc corpus san guard"
KNOWN_LANES="suite suite-orc corpus san guard"

usage() {
  cat <<'USAGE'
usage: tools/gate.sh [--base <rev>] [--release] [--lanes a,b] [--dry-run] [--record]

Pick the verification lanes from the paths a change touches, run them one
after another, and compare every red against src/test/known-red.json.

  --base <rev>   diff against <rev> (default: main); uncommitted paths count too
  --release      the full ladder, whatever the diff says
  --lanes a,b    run exactly these lanes: tools build suite suite-orc corpus san guard
  --dry-run      print the chosen lanes and the paths that pulled each one in
  --record       run the ladder on a clean main and rewrite known-red.json
  --reuse        read a lane log that already ended instead of running that lane again
  --reds <lane> <log>  print the failure names the gate reads out of a lane log

exit: 0 no new red · 1 new red · 2 usage · 75 machine busy past GATE_WAIT_MAX
env:  GATE_WAIT_MAX seconds to wait for load <= cores (default 1800, 0 = do not wait)
USAGE
}

say() { printf '%s\n' "$*"; }
die() { printf 'gate: %s\n' "$*" >&2; exit 2; }

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git checkout"
cd "$TOP" || die "cannot enter $TOP"
KNOWN="$TOP/src/test/known-red.json"
OUT="$TOP/out/gate"
CAND="$OUT/msc"

reds_of() {
  local lane=$1 log=$2 rc=$3
  case "$lane" in
    build) [ "$rc" -eq 0 ] || echo "build" ;;
    tools) sed -n 's/^FAIL \(.*\): bash -n$/\1/p' "$log" ;;
    suite|suite-orc)
      sed $'s/\x1b\\[[0-9;]*m//g' "$log" | awk -v top="$TOP/" '
        /^ FAIL  / { f=$0; sub(/^ FAIL  /,"",f); if (index(f,top)==1) f=substr(f,length(top)+1); next }
        /^  × / { t=$0; sub(/^  × /,"",t); print f " > " t }
      '
      ;;
    corpus|san) sed -n 's/^ *✗ FAIL \([^]]*\]\).*$/\1/p' "$log" ;;
    guard) sed -n 's/^FAIL \([^:]*\):.*$/\1/p' "$log" ;;
  esac | sort -u
}

base=main release=0 dry=0 record=0 reuse=0 lanes_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base=${2:?--base needs a rev}; shift ;;
    --release) release=1 ;;
    --lanes) lanes_arg=${2:?--lanes needs a list}; shift ;;
    --dry-run) dry=1 ;;
    --record) record=1 ;;
    --reuse) reuse=1 ;;
    --reds) reds_of "${2:?--reds needs a lane}" "${3:?--reds needs a log}" 1; exit 0 ;;
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

lanes_for_path() {
  local p=$1 r matched=0
  if printf '%s\n' "$p" | grep -Eq "$INERT"; then return; fi
  for r in "${RULES[@]}"; do
    if printf '%s\n' "$p" | grep -Eq "${r#*|}"; then
      printf '%s\n' "${r%%|*}" | tr ',' '\n'
      matched=1
    fi
  done
  [ "$matched" -eq 1 ] || printf '%s\n' $DEFAULT_LANES
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
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    for l in $(lanes_for_path "$p"); do printf '%s\t%s\n' "$l" "$p" >>"$OUT/why"; done
  done <<<"$paths"
  sort -u -o "$OUT/why" "$OUT/why"
  chosen=$(cut -f1 "$OUT/why" | sort -u)
fi

lanes=""
for l in $ORDER; do
  if printf '%s\n' $chosen | grep -qx "$l"; then lanes="$lanes $l"; fi
done
lanes=${lanes# }

explain() {
  local l n
  for l in $lanes; do
    n=$(awk -F'\t' -v l="$l" '$1==l' "$OUT/why" | wc -l | tr -d ' ')
    say "gate: $l <- $(awk -F'\t' -v l="$l" '$1==l{print $2}' "$OUT/why" | head -3 | paste -sd, - | sed 's/,/, /g')$([ "$n" -gt 3 ] && printf ' (+%d more)' $((n - 3)))"
  done
  case " $lanes " in
    *" corpus "*) [ "$release" -eq 0 ] && [ "$record" -eq 0 ] && say "gate: a narrow rule fix can use the emit-diff selector instead of the full corpus (src/test/CLAUDE.md 5.3), then --lanes" ;;
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
  off_main=$(changed_paths | while IFS= read -r p; do
    [ -n "$p" ] && [ -n "$(lanes_for_path "$p" | grep -vx tools)" ] && printf '%s\n' "$p"
  done)
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
    suite) printf '%s test src/index.ms' "$BUILDER" ;;
    suite-orc) printf '%s test src/index.ms --gc=orc' "$BUILDER" ;;
    corpus) printf 'MSC=%s %s run src/test/corpus/run.ms' "$CAND" "$BUILDER" ;;
    san) printf 'MSCORPUS_SAN=1 MSC=%s %s run src/test/corpus/run.ms' "$CAND" "$BUILDER" ;;
    guard) printf 'MSC=%s src/test/guard/run.sh' "$CAND" ;;
  esac
}

run_tools_lane() {
  local p rc=0
  while IFS=$'\t' read -r _ p; do
    case "$p" in *.sh) [ -f "$p" ] && { bash -n "$p" || { printf 'FAIL %s: bash -n\n' "$p"; rc=1; }; } ;; esac
  done < <(awk -F'\t' '$1=="tools"' "$OUT/why")
  return $rc
}

known_of() {
  [ -f "$KNOWN" ] || return 0
  jq -r --arg l "$1" '.[$l] // {} | keys[]' "$KNOWN" | sort -u
}

need_cand() {
  [ -x "$CAND" ] || die "lane '$1' tests the candidate compiler; include the build lane"
}

fmt_secs() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }

start=$SECONDS
ran="" verdict=GREEN stopped=""
case " $lanes " in *" build "*|*" suite "*|*" suite-orc "*|*" corpus "*|*" san "*|*" guard "*) admit ;; esac

for lane in $lanes; do
  if [ -n "$stopped" ]; then say "gate: $lane skipped, $stopped has a new red"; continue; fi
  log="$OUT/$lane.log"
  t0=$SECONDS
  reused=""
  if [ "$reuse" -eq 1 ] && [ "$(tail -1 "$log" 2>/dev/null)" = END ]; then
    rc=$(sed -n 's/^RC=\([0-9][0-9]*\)$/\1/p' "$log" | tail -1); reused=" (reused log)"
  else case "$lane" in
    tools) run_tools_lane >"$log" 2>&1; rc=$? ;;
    corpus|san|guard) need_cand "$lane"; NO_COLOR=1 bash -c "$(lane_cmd "$lane")" >"$log" 2>&1; rc=$? ;;
    *) env -u NO_COLOR -u FORCE_COLOR bash -c "$(lane_cmd "$lane")" >"$log" 2>&1; rc=$? ;;
  esac
  printf '\nRC=%d\nEND\n' "$rc" >>"$log"
  fi
  reds_of "$lane" "$log" "$rc" >"$OUT/$lane.red"
  if [ "$rc" -ne 0 ] && [ ! -s "$OUT/$lane.red" ]; then echo "$lane: exit $rc with no named failure" >"$OUT/$lane.red"; fi
  known_of "$lane" >"$OUT/$lane.known"
  comm -23 "$OUT/$lane.red" "$OUT/$lane.known" >"$OUT/$lane.new"
  comm -13 "$OUT/$lane.red" "$OUT/$lane.known" >"$OUT/$lane.fixed"
  n_red=$(grep -c . "$OUT/$lane.red" | tr -d ' ')
  n_new=$(grep -c . "$OUT/$lane.new" | tr -d ' ')
  n_fixed=$(grep -c . "$OUT/$lane.fixed" | tr -d ' ')
  line="gate: $lane$reused $(fmt_secs $((SECONDS - t0))) · $n_red red · $((n_red - n_new)) known · $n_new new"
  [ "$n_fixed" -eq 0 ] || line="$line · $n_fixed known-now-green ($(head -3 "$OUT/$lane.fixed" | paste -sd, - | sed 's/,/, /g'))"
  xp=$(sed -n 's/^.* \([0-9][0-9]*\) xpass$/\1/p' "$log" | tail -1)
  [ -z "$xp" ] || [ "$xp" = 0 ] || line="$line · $xp xpass"
  say "$line"
  ran="$ran $lane"
  if [ "$n_new" -gt 0 ] && [ "$record" -eq 0 ]; then
    verdict=RED; stopped=$lane
    while IFS= read -r name; do
      say "  new: $name"
      grep -F -A3 -- "$name" "$log" | sed -n '2,4p' | sed 's/^/       /'
    done <"$OUT/$lane.new"
    say "  log: $log"
  fi
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
