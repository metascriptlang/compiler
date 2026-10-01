#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C

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
ORDER="tools build boundary suite hcr tests fmt corpus san guard"
LADDER="build boundary suite hcr tests fmt corpus san guard"
KNOWN_LANES="boundary suite hcr tests fmt corpus san guard"
RAISER_PATHS='^src/(raiser|codegen/raiser)/|^src/transform/raiserLowering\.ms$|\.rms$|^src/test/corpus/run\.ms$'
SELECT_BLIND='^(runtime|std|vendor)/|^src/test/corpus/[^/]*$|^src/(raiser|codegen/raiser)/|^src/transform/raiserLowering\.ms$|^src/compiler/meta/hostTable\.ms$|^src/compiler/(buildConfig|cache|cc|compile|defines|options|toolchain)\.ms$'

usage() {
  cat <<'USAGE'
usage: tools/gate.sh [--base <rev>] [--release] [--lanes a,b] [--dry-run] [--record]

Pick the verification lanes from the paths a change touches, run them one
after another, and compare every red against src/test/known-red.json.

  --base <rev>   diff against <rev> (default: main); uncommitted paths count too
  --release      the full ladder, whatever the diff says
  --lanes a,b    run exactly these lanes: tools build boundary suite hcr tests fmt corpus san guard
  --dry-run      print the chosen lanes and the paths that pulled each one in
  --record       run the ladder on a clean main and rewrite known-red.json
  --reuse        read a lane log that already ended instead of running that lane again
  --reds <lane> <log>  print the failure names the gate reads out of a lane log
  --inert <from> <to>  exit 0 when every path changed from..to picks no lane
  --select       print the corpus programs whose emitted C or JS differs from the merge base
  --tree-key <rev>  print the key of the src and std tree at <rev> (what msc.key holds)
  --route        read paths on stdin, print "lane<TAB>path" for each lane a path picks
  --self-test    check the routing table and the red parsers against fixed cases

One gate at a time runs per machine: a run with any lane besides tools, and
--select, queues first-come first-served in ~/.metascript/gates and starts when
every gate ahead of it has finished or died. It names the gate it waits behind
about once a minute; the wait is not capped by GATE_WAIT_MAX and shows in the
ledger wait column. Only the running gate counts when worker slots are split.
--dry-run, a tools-only run and the --emit-one children of a running gate never
queue. An empty registry file is a running gate whose gate.sh predates the queue;
it is waited for like any other. A registry file that does not parse stops the
run and names the file.

A GREEN run whose build lane produced the candidate for the clean src and std tree
of HEAD makes that candidate the worktree builder ./msc (the old one stays as
msc.prev, the tree key goes to msc.key); a failed swap prints "builder not
refreshed" and changes neither verdict nor exit code. --tree-key <rev> prints
the key for any rev, which tools/wt.sh land compares with msc.key.

Every path that is not inert and not under tools/ gets build and suite; a rule
only adds lanes to that floor. The tests lane compiles its tiers with the
candidate, so a pin there tests the change rather than the previous compiler.
It runs every tier when the compiler changed (a path under src/ outside
src/test/, or one select cannot see), else only the tiers whose module graph
holds a changed path.

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
env:  GATE_WAIT_MAX seconds to wait for load <= cores once the queue is passed (default 1800, 0 = do not wait)
      GATE_PAR outer lane slots; when set, also caps selector emit and corpus build workers
      MSCORPUS_BUILD_JOBS optional corpus build ceiling, kept across phases
      these limits do not cap aggregate processes or compiler-internal parallelism
ledger: one row per lane and per run (lane secs rc red known new flaky wait) appended to GATE_LEDGER (default ~/.metascript/gate.tsv)
        one row per selection decision (step secs kept total differ_c differ_js touched) appended to
        GATE_SELECT_LEDGER (default ~/.metascript/gate-select.tsv); step is tier-select, select,
        select-whole or select-off; select-off has zero seconds and empty counts
USAGE
}

say() { printf '%s\n' "$*"; }
die() { printf 'gate: %s\n' "$*" >&2; exit 2; }
cap_jobs() {
  local jobs=$1 cap
  for cap in "$@"; do
    [ -n "$cap" ] || continue
    [[ "$cap" =~ ^[0-9]+$ ]] && [ "$cap" -gt 0 ] 2>/dev/null || die "worker limit must be a positive integer: '$cap'"
    cap=$((10#$cap))
    [ "$jobs" -le "$cap" ] || jobs=$cap
  done
  printf '%s\n' "$((10#$jobs))"
}
ledger_fmt() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
ledger() {
  [ -s "$GATE_LEDGER" ] || printf 'ts\ttree\tlane\tsecs\trc\tred\tknown\tnew\tflaky\twait\n' >"$GATE_LEDGER"
  ledger_fmt "$(date '+%F %T')" "$(basename "$TOP")" "$@" >>"$GATE_LEDGER"
}
select_ledger_fmt() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
select_ledger() {
  [ -s "$GATE_SELECT_LEDGER" ] || printf 'ts\ttree\tstep\tsecs\tkept\ttotal\tdiffer_c\tdiffer_js\ttouched\n' >"$GATE_SELECT_LEDGER"
  select_ledger_fmt "$(date '+%F %T')" "$(basename "$TOP")" "$@" >>"$GATE_SELECT_LEDGER"
}
record_select_off() {
  [ -n "$select_why" ] && [ -n "$select_label" ] || return 0
  select_ledger select-off 0 "" "" "" "" ""
}
build_ctl() {
  local sha=$1 key ctl_dir ctl
  key=$(tree_key "$sha")
  [ -n "$key" ] || return 1
  ctl_dir="$OUT/ctl-$key" ctl="$ctl_dir/msc"
  if [ ! -x "$ctl" ]; then
    rm -rf "$ctl_dir" "$OUT/ctl-src"
    mkdir -p "$ctl_dir" "$OUT/ctl-src"
    git archive "$sha" src | tar -x -C "$OUT/ctl-src" || return 1
    (cd "$OUT/ctl-src" && bounded env -u NO_COLOR -u FORCE_COLOR $BUILDER build src/index.ms --gc=drc --danger $CC_FLAG --output="$ctl") >"$OUT/ctl.log" 2>&1
    [ -x "$ctl" ] || return 1
  fi
  touch "$ctl_dir"
  printf '%s' "$key"
}
compiler_changed() { grep -E '^src/' | grep -vqE '^src/test/'; }

tier_touched() {
  awk -v deps="$1" -v top="$2" 'BEGIN { while ((getline d < deps) > 0) mods[d] = 1 }
    (top "/" $0) in mods { hit = 1; exit }
    END { exit !hit }'
}

tier_select() {
  local f dir deps emits="" t0=$SECONDS n=0 all
  all=$(set -- $TIERS; printf '%s' "$#")
  if awk -F'\t' '{ print $2 }' "$OUT/why" | grep -Eq "$SELECT_BLIND"; then
    say "tier-select: blind paths in the diff, whole"; select_ledger tier-select 0 "$all" "$all" "" "" ""; return 1
  fi
  if awk -F'\t' '{ print $2 }' "$OUT/why" | compiler_changed; then
    say "tier-select: the compiler changed, whole"; select_ledger tier-select 0 "$all" "$all" "" "" ""; return 1
  fi
  rm -rf "$OUT/tier"; mkdir -p "$OUT/tier"
  for f in $TIERS; do
    n=$((n + 1)); dir="$OUT/tier/$n"; mkdir -p "$dir"
    (cd "$dir" && bounded env -u FORCE_COLOR NO_COLOR=1 "$CAND" build "$TOP/$f" --emit=c --gendeps >log 2>&1) &
    emits="$emits $!"
  done
  wait $emits
  n=0
  for f in $TIERS; do
    n=$((n + 1)); deps=$(ls "$OUT/tier/$n"/out/*/*.deps 2>/dev/null | head -1)
    if [ -z "$deps" ] || [ ! -s "$deps" ] || awk -F'\t' '{ print $2 }' "$OUT/why" | tier_touched "$deps" "$TOP"; then printf '%s\n' "$f"; fi
  done >"$OUT/tier/keep"
  say "tier-select: $(grep -c . "$OUT/tier/keep" | tr -d ' ')/$n tiers compile a changed path, $(fmt_secs $((SECONDS - t0)))"
  ledger tier-select $((SECONDS - t0)) 0 0 0 0 0 "${ADMIT_WAITED:-0}"
  select_ledger tier-select "$((SECONDS - t0))" "$(grep -c . "$OUT/tier/keep" | tr -d ' ')" "$n" "" "" ""
  return 0
}

inert_range() {
  local paths
  paths=$(git diff --name-only --no-renames "$1" "$2") || return 2
  ! printf '%s\n' "$paths" | grep -Ev "$INERT" | grep -q .
}

digest() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1; }
tree_key() {
  local t
  t=$({ git ls-tree "$1" src/ | grep -v $'\tsrc/test$'; git ls-tree "$1" std; } 2>/dev/null)
  [ -n "$t" ] && printf '%s\n' "$t" | git hash-object --stdin
}
refresh_builder() {
  local src=$1 dest=$2 key=$3 tmp="$2.new" prev="${2%.exe}.prev"
  cp "$src" "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; say "gate: builder not refreshed: cannot copy $src to $tmp"; return 1; }
  if [ -e "$dest" ]; then
    rm -f "$prev"
    mv "$dest" "$prev" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; say "gate: builder not refreshed: cannot move $dest aside"; return 1; }
  fi
  mv "$tmp" "$dest" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null; [ ! -e "$prev" ] || mv "$prev" "$dest" 2>/dev/null
    say "gate: builder not refreshed: cannot move the new builder to $dest"; return 1
  }
  printf '%s\n' "$key" >"${dest%.exe}.key" 2>/dev/null || { say "gate: builder not refreshed: cannot write ${dest%.exe}.key"; return 1; }
  say "gate: builder refreshed: $dest is the candidate for tree ${key:0:12} (previous kept as ${prev##*/})"
}

adopt_builder() {
  local verdict=$1 ran=$2 dest="$TOP/msc"
  [ "$verdict" = GREEN ] || return 0
  case " $ran " in *" build "*) ;; *) return 0 ;; esac
  [ -n "$cand_key" ] && [ "$(cat "$CAND.key" 2>/dev/null)" = "$cand_key" ] || return 0
  [ -z "$(git -C "$TOP" status --porcelain -- src std)" ] && [ "$(cd "$TOP" && tree_key HEAD)" = "$cand_key" ] || return 0
  [ ! -e "$TOP/msc.exe" ] || dest="$TOP/msc.exe"
  if [ "$(cat "$TOP/msc.key" 2>/dev/null)" = "$cand_key" ]; then
    say "gate: builder already current for tree ${cand_key:0:12}"
    return 0
  fi
  refresh_builder "$CAND" "$dest" "$cand_key" || return 0
}

differ_c() { awk -F'\t' '$2 != $6 || $4 != 0 || $8 != 0 { print $1 }'; }

list_programs() {
  local e n dir=${1:-$TOP/src/test/corpus/programs}
  for e in "$dir"/* "$dir"/.[!.]*; do
    [ -e "$e" ] || continue
    n=${e##*/}
    if [ -d "$e" ]; then
      [ -f "$e/main.ms" ] && printf '%s %s\n' "$n" "$e/main.ms"
    else
      case "$n" in *.ms) printf '%s %s\n' "${n%.ms}" "$e" ;; esac
    fi
  done
}

narrow_for() {
  narrow="" only_csv="" lanes_csv=""
  [ "$select" -eq 1 ] || return 0
  [ "$1" != tests ] || return 0
  only_csv=$(paste -sd, "$EMIT/only.$1")
  [ -n "$only_csv" ] || return 0
  narrow="MSCORPUS_ONLY=$only_csv "
  if [ "$1" = corpus ] && [ ! -s "$EMIT/only.san" ]; then
    lanes_csv="c,drc,js,esm$([ "$raiser_on" -eq 0 ] || printf ',raiser')"
    narrow="${narrow}MSCORPUS_LANES=$lanes_csv "
  fi
}

select_leaves_nothing() {
  [ "$1" != tests ] && [ "$select" -eq 1 ] && [ -z "$only_csv" ]
}

control_todo() {
  awk -v dir="$1" -v keys="$2" '
    BEGIN { while ((getline l < keys) > 0) { split(l, a, " "); key[a[1]] = a[2] } }
    { f = dir "/" $1; have = ""; sig = ""
      if (($1 in key) && (getline have < (f ".key")) > 0 && have == key[$1] && (getline sig < (f ".sig")) > 0 \
        && split(sig, s, "\t") >= 4 && s[4] == "0") { close(f ".key"); close(f ".sig"); next }
      close(f ".key"); close(f ".sig"); print }'
}

TIERS="src/test/fixedbugs/index.ms src/test/c/index.ms src/test/js/index.ms src/test/handoff/index.ms src/test/checker3pass/index.ms src/test/lang/index.ms src/test/fmt/index.ms src/test/helpers.ms"
SHARDED_TIERS="src/test/fixedbugs/index.ms src/test/c/index.ms"
TEST_SHARDS=${GATE_TEST_SHARDS:-3}

test_jobs() {
  local f i
  for f in $TIERS; do
    case " $SHARDED_TIERS " in
      *" $f "*) if [ "$TEST_SHARDS" -gt 1 ]; then for ((i = 0; i < TEST_SHARDS; i++)); do printf '%s %s\n' "$f" "$i/$TEST_SHARDS"; done; continue; fi ;;
    esac
    printf '%s -\n' "$f"
  done
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
  set -m; "$@" <&0 & pid=$!; set +m
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

hash_files() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }

emit_one() {
  local bin=$1 name=$3 entry=$4 d="$GATE_EMIT_DIR/$2" c_rc js_rc c js cs
  rm -rf "$d"; mkdir -p "$d" && cd "$d" || exit 1
  "$bin" build "$entry" --emit=c --gc=drc >c.log 2>&1; c_rc=$?
  "$bin" build "$entry" --emit=c --gc=drc --danger >>c.log 2>&1 || c_rc=1
  mapfile -t cs < <(find out -name '*.c' 2>/dev/null | LC_ALL=C sort)
  c=$({ echo "rc=$c_rc"; [ "$c_rc" -eq 0 ] || cat c.log; [ "${#cs[@]}" -eq 0 ] || hash_files "${cs[@]}"; } | digest)
  "$bin" build "$entry" --target=js --output=out.js >js.log 2>&1; js_rc=$?
  js=$({ echo "rc=$js_rc"; if [ "$js_rc" -eq 0 ]; then cat out.js; else cat js.log; fi; } 2>/dev/null | digest)
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$c" "$js" "$c_rc" "${#cs[@]}"
}

if [ "${1:-}" = --emit-one ]; then emit_one "${2:?}" "${3:?}" "${4:?}" "${5:?}"; exit 0; fi
if [ "${1:-}" = --tree-key ]; then tree_key "${2:?--tree-key needs a rev}"; exit $?; fi

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git checkout"
cd "$TOP" || die "cannot enter $TOP"
KNOWN="$TOP/src/test/known-red.json"
OUT="$TOP/out/gate"
CAND="$OUT/msc"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) CAND="$CAND.exe" ;;
esac
EMIT="$OUT/emit"
GATE_LEDGER=${GATE_LEDGER:-$HOME/.metascript/gate.tsv}
GATE_SELECT_LEDGER=${GATE_SELECT_LEDGER:-$HOME/.metascript/gate-select.tsv}

reds_of() {
  local lane=$1 log=$2 rc=$3
  case "$lane" in
    build) [ "$rc" -eq 0 ] || echo "build" ;;
    boundary) sed -n 's/^FAIL  \(.*\)  expected=.*$/\1/p; s/^boundary: setup step failed: \(.*\) (root .*$/setup: \1/p' "$log" ;;
    tools) sed -nE 's/^FAIL (.*): (bash -n|self-test|check)$/\1/p' "$log" ;;
    suite|tests)
      sed $'s/\x1b\\[[0-9;]*m//g' "$log" | awk -v top="$TOP/" '
        /^NORESULT / { sub(/^NORESULT /,""); print; next }
        /^ FAIL  / { f=$0; sub(/^ FAIL  /,"",f); if (index(f,top)==1) f=substr(f,length(top)+1); next }
        /^  × / { t=$0; sub(/^  × /,"",t); print f " > " t }
      '
      ;;
    corpus|san) sed -n 's/^ *✗ FAIL \([^]]*\]\).*$/\1/p' "$log" ;;
    guard|hcr) sed -n 's/^FAIL \([^:]*\):.*$/\1/p' "$log" ;;
    fmt) sed -nE 's/^(LOSSY|UNSTABLE|NO-FMT|UNREADABLE) (.*\.ms).*$/\2/p' "$log" ;;
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

cores() { sysctl -n hw.ncpu 2>/dev/null || nproc; }

GATES_DIR="${HOME:-$USERPROFILE}/.metascript/gates"
QUEUE_POLL=2

queue_write() { printf '%s %s %s\n' "$MY_TICKET" "$1" "$(basename "$TOP")" >"$GATES_DIR/.w.$$" && mv -f "$GATES_DIR/.w.$$" "$GATES_DIR/$$"; }

queue_scan() {
  local f p t s n rows="" left ahead_pid ahead_name
  Q_MAX=0 Q_HOLDERS=0 Q_FIRST="" Q_AHEAD=0 Q_BEHIND="" Q_BEHIND_PID=""
  for f in "$GATES_DIR"/.w.* "$GATES_DIR"/.m.*; do
    [ -e "$f" ] || continue
    kill -0 "${f##*.}" 2>/dev/null || rm -rf "$f"
  done
  for f in "$GATES_DIR"/*; do
    [ -e "$f" ] || continue
    p=${f##*/}
    [[ "$p" =~ ^[0-9]+$ ]] || die "gate queue: unexpected file $f"
    kill -0 "$p" 2>/dev/null || { rm -f "$f"; continue; }
    if [ -e "$f" ] && [ ! -s "$f" ]; then Q_HOLDERS=$((Q_HOLDERS + 1)); Q_BEHIND_PID=$p Q_BEHIND="a gate.sh without the queue"; continue; fi
    if ! IFS=' ' read -r t s n <"$f" 2>/dev/null; then [ -e "$f" ] || continue; die "gate queue: unparseable registry file $f"; fi
    [[ "$t" =~ ^[0-9]+$ ]] && { [ "$s" = wait ] || [ "$s" = hold ]; } && [ -n "$n" ] || die "gate queue: unparseable registry file $f"
    [ "$t" -le "$Q_MAX" ] || Q_MAX=$t
    if [ "$s" = hold ]; then Q_HOLDERS=$((Q_HOLDERS + 1)); Q_BEHIND_PID=$p Q_BEHIND=$n; else rows="$rows$t $p $n"$'\n'; fi
  done
  [ -n "$rows" ] || return 0
  rows=$(printf '%s' "$rows" | sort -k1,1n -k2,2n)
  Q_FIRST=$(awk 'NR == 1 { print $2 }' <<<"$rows")
  left=$(awk -v p="$$" '$2 == p { exit } { n++; l = $2 " " $3 } END { print n + 0, l }' <<<"$rows")
  read -r Q_AHEAD ahead_pid ahead_name <<<"$left"
  if [ "$Q_HOLDERS" -eq 0 ] && [ "$Q_AHEAD" -gt 0 ]; then Q_BEHIND_PID=$ahead_pid Q_BEHIND=$ahead_name; fi
  return 0
}

queue_lock() {
  local m tmp="$GATES_DIR/.m.$$" try
  for try in 1 2; do
    rm -rf "$tmp"; mkdir -p "$tmp/$$" || die "gate queue: cannot create $tmp"
    mv -T "$tmp" "$GATES_DIR/.lock" 2>/dev/null && return 0
    rm -rf "$tmp"
    for m in "$GATES_DIR/.lock"/*; do
      [ -e "$m" ] || continue
      m=${m##*/}
      [[ "$m" =~ ^[0-9]+$ ]] || die "gate queue: unexpected entry $GATES_DIR/.lock/$m"
      ! kill -0 "$m" 2>/dev/null || return 1
      rmdir "$GATES_DIR/.lock/$m" 2>/dev/null
    done
    rmdir "$GATES_DIR/.lock" 2>/dev/null
  done
  return 1
}

queue_acquire() {
  local t0=$SECONDS shown=-60
  mkdir -p "$GATES_DIR" || die "cannot create $GATES_DIR"
  queue_scan; MY_TICKET=$((Q_MAX + 1))
  queue_write wait || die "gate queue: cannot write $GATES_DIR/$$"
  while :; do
    queue_scan
    if [ "$Q_HOLDERS" -eq 0 ] && [ "$Q_FIRST" = "$$" ] && queue_lock; then queue_write hold || die "gate queue: cannot write $GATES_DIR/$$"; break; fi
    if [ $((SECONDS - t0 - shown)) -ge 60 ]; then
      shown=$((SECONDS - t0))
      say "gate: queued behind ${Q_BEHIND:-another gate} (pid ${Q_BEHIND_PID:-?}), $Q_AHEAD waiting ahead, ${shown}s"
    fi
    sleep "$QUEUE_POLL"
  done
  ADMIT_WAITED=$((${ADMIT_WAITED:-0} + SECONDS - t0))
  [ "$shown" -lt 0 ] || say "gate: left the queue after $((SECONDS - t0))s"
}

queue_release() {
  rm -f "$GATES_DIR/$$"
  rmdir "$GATES_DIR/.lock/$$" 2>/dev/null && rmdir "$GATES_DIR/.lock" 2>/dev/null
  return 0
}

live_gates() {
  queue_scan
  [ "$Q_HOLDERS" -ge 1 ] || Q_HOLDERS=1
  echo "$Q_HOLDERS"
}

share_of_cores() {
  local g w
  g=$(live_gates) || exit $?
  w=$(( $(cores) / g / $1 ))
  [ "$w" -ge 1 ] || w=1
  echo "$w"
}

adopt_self_test() {
  local bad=0 d got saveTOP=$TOP saveCAND=$CAND savekey=${cand_key-} g="git -c user.name=t -c user.email=t@t"
  d=$(mktemp -d) || return 1
  TOP="$d/wt"; CAND="$d/wt/out/gate/msc.exe"
  mkdir -p "$TOP/src" "$TOP/std" "$TOP/out/gate"
  printf 'a\n' >"$TOP/src/a.ms"; printf 'b\n' >"$TOP/std/b.ms"
  (cd "$TOP" && git init -q . && $g add -A src std && $g commit -qm x) >/dev/null 2>&1
  local k; k=$(cd "$TOP" && tree_key HEAD)
  got=$(cd "$TOP" && bash "$saveTOP/tools/gate.sh" --tree-key HEAD)
  [ -n "$k" ] && [ "$got" = "$k" ] || { printf 'FAIL adopt: --tree-key "%s" is not tree_key "%s"\n' "$got" "$k"; bad=1; }
  got=$(cd "$saveTOP" && bash tools/gate.sh --tree-key HEAD)
  [ "$got" = "$(tree_key HEAD)" ] || { printf 'FAIL adopt: --tree-key HEAD differs from tree_key in the real checkout\n'; bad=1; }
  reset() { rm -rf "$TOP"/msc "$TOP"/msc.exe "$TOP"/msc.key "$TOP"/msc.prev "$TOP"/msc.new; printf 'old\n' >"$TOP/msc"; printf 'new\n' >"$CAND"; printf '%s\n' "$k" >"$CAND.key"; cand_key=$k; }
  reset; adopt_builder GREEN " tools build suite" >/dev/null
  { [ "$(cat "$TOP/msc")" = new ] && [ "$(cat "$TOP/msc.prev")" = old ] && [ "$(cat "$TOP/msc.key")" = "$k" ] && [ ! -e "$TOP/msc.new" ]; } \
    || { printf 'FAIL adopt: GREEN with a matching key did not swap (msc=%s prev=%s)\n' "$(cat "$TOP/msc" 2>&1)" "$(cat "$TOP/msc.prev" 2>&1)"; bad=1; }
  printf 'newer\n' >"$CAND"; rm -f "$TOP/msc.key"; adopt_builder GREEN " build" >/dev/null
  { [ "$(cat "$TOP/msc")" = newer ] && [ "$(cat "$TOP/msc.prev")" = new ]; } || { printf 'FAIL adopt: .prev was not rotated\n'; bad=1; }
  got=$(adopt_builder GREEN " build"); printf 'x\n' >"$CAND"
  adopt_builder GREEN " build" >/dev/null
  { [ "$(cat "$TOP/msc")" = newer ] && [[ "$got" == *"already current"* ]]; } || { printf 'FAIL adopt: swapped although msc.key already equals the key: "%s"\n' "$got"; bad=1; }
  reset; adopt_builder RED " build" >/dev/null
  { [ "$(cat "$TOP/msc")" = old ] && [ ! -e "$TOP/msc.key" ]; } || { printf 'FAIL adopt: adopted on RED\n'; bad=1; }
  reset; adopt_builder GREEN " tools" >/dev/null
  { [ "$(cat "$TOP/msc")" = old ] && [ ! -e "$TOP/msc.key" ]; } || { printf 'FAIL adopt: adopted when the build lane did not run\n'; bad=1; }
  reset; printf 'other\n' >"$CAND.key"; adopt_builder GREEN " build" >/dev/null
  [ "$(cat "$TOP/msc")" = old ] || { printf 'FAIL adopt: adopted a candidate whose key does not match\n'; bad=1; }
  reset; cand_key=""; adopt_builder GREEN " build" >/dev/null
  [ "$(cat "$TOP/msc")" = old ] || { printf 'FAIL adopt: adopted although the tree was dirty at the start\n'; bad=1; }
  reset; printf 'dirty\n' >>"$TOP/src/a.ms"; adopt_builder GREEN " build" >/dev/null
  [ "$(cat "$TOP/msc")" = old ] || { printf 'FAIL adopt: adopted although src is dirty now\n'; bad=1; }
  (cd "$TOP" && git checkout -q -- src/a.ms)
  reset; rm -f "$CAND"; mkdir "$TOP/msc.new"
  got=$(adopt_builder GREEN " build"); rc=$?
  { [ "$rc" -eq 0 ] && [[ "$got" == "gate: builder not refreshed: "* ]] && [ "$(cat "$TOP/msc")" = old ]; } \
    || { printf 'FAIL adopt: failure path: rc=%s, out "%s"\n' "$rc" "$got"; bad=1; }
  rm -rf "$TOP/msc.new"; reset; mv "$TOP/msc" "$TOP/msc.exe"
  adopt_builder GREEN " build" >/dev/null
  { [ "$(cat "$TOP/msc.exe")" = new ] && [ "$(cat "$TOP/msc.prev")" = old ]; } || { printf 'FAIL adopt: msc.exe naming\n'; bad=1; }
  TOP=$saveTOP CAND=$saveCAND cand_key=$savekey
  rm -rf "$d"
  return $bad
}

queue_self_test() {
  local bad=0 keep_dir=$GATES_DIR keep_poll=$QUEUE_POLL out h w w2 a i got rc home pids=""
  GATES_DIR=$(mktemp -d) || return 1
  out="$GATES_DIR.out" QUEUE_POLL=0.2
  fake() { printf '%s %s fake\n' "$3" "$2" >"$GATES_DIR/$1"; }
  live() { sleep 120 >/dev/null 2>&1 & LIVE=$!; pids="$pids $LIVE"; }
  settle() { rm -rf "$GATES_DIR"/* "$GATES_DIR"/.lock; }
  seen() { for ((i = 0; i < 100; i++)); do grep -q "$1" "$2" 2>/dev/null && return 0; sleep 0.2; done; return 1; }
  held() { for ((i = 0; i < 50; i++)); do grep -q ' hold ' "$GATES_DIR/$$" 2>/dev/null && return 0; sleep 0.2; done; return 1; }
  queue_acquire >"$out"
  { [[ "$(<"$GATES_DIR/$$")" == "1 hold "* ]] && [ -d "$GATES_DIR/.lock/$$" ] && [ ! -s "$out" ]; } || { printf 'FAIL queue: acquire when free\n'; bad=1; }
  queue_release
  { [ ! -e "$GATES_DIR/$$" ] && [ ! -e "$GATES_DIR/.lock" ]; } || { printf 'FAIL queue: release leaves the file or the lock\n'; bad=1; }
  live; h=$LIVE; fake "$h" hold 1; mkdir -p "$GATES_DIR/.lock/$h"
  ( queue_acquire >"$out" ) & a=$!
  seen "behind fake" "$out"
  { [ "$(cut -d' ' -f2 "$GATES_DIR/$$")" = wait ] && kill -0 "$a" 2>/dev/null && grep -q "behind fake (pid $h)" "$out"; } || { printf 'FAIL queue: wait while a live holder exists\n'; bad=1; }
  kill "$h"; wait "$h" 2>/dev/null
  held || { printf 'FAIL queue: no reclaim from a dead holder\n'; bad=1; }
  { [ -d "$GATES_DIR/.lock/$$" ] && [ ! -e "$GATES_DIR/.lock/$h" ] && [ ! -e "$GATES_DIR/$h" ]; } || { printf 'FAIL queue: dead holder left its marker or file\n'; bad=1; }
  wait "$a"; queue_release; settle
  live; h=$LIVE; live; w=$LIVE; fake "$h" hold 1; mkdir -p "$GATES_DIR/.lock/$h"; fake "$w" wait 2
  ( queue_acquire >"$out" ) & a=$!
  seen "behind fake" "$out"
  [ "$(cut -d' ' -f1 "$GATES_DIR/$$")" = 3 ] || { printf 'FAIL queue: ticket after two live gates: got "%s"\n' "$(<"$GATES_DIR/$$")"; bad=1; }
  kill "$h"; wait "$h" 2>/dev/null
  sleep 2
  { [ "$(cut -d' ' -f2 "$GATES_DIR/$$")" = wait ] && [ ! -d "$GATES_DIR/.lock/$$" ]; } || { printf 'FAIL queue: FIFO, took the lock ahead of an older waiter\n'; bad=1; }
  kill "$w"; wait "$w" 2>/dev/null
  held || { printf 'FAIL queue: FIFO, did not start once the older waiter was gone\n'; bad=1; }
  wait "$a"; queue_release; settle
  live; h=$LIVE; live; w=$LIVE; live; w2=$LIVE; fake "$h" hold 1; fake "$w" wait 2; fake "$w2" wait 3
  got="$(live_gates) $(share_of_cores 1) $(cores)"
  [ "$got" = "1 $(cores) $(cores)" ] || { printf 'FAIL queue: waiters counted by live_gates/share_of_cores: got "%s"\n' "$got"; bad=1; }
  settle; fake "$w" wait 1; fake "$w2" wait 2
  [ "$(live_gates)" = 1 ] || { printf 'FAIL queue: live_gates with waiters only\n'; bad=1; }
  fake "$h" hold 3; fake "$w" hold 1
  [ "$(live_gates)" = 2 ] || { printf 'FAIL queue: live_gates with two holders\n'; bad=1; }
  settle; printf 'junk\n' >"$GATES_DIR/$h"
  got=$( (queue_scan) 2>&1 ); rc=$?
  { [ "$rc" -eq 2 ] && [[ "$got" == *"$GATES_DIR/$h"* ]]; } || { printf 'FAIL queue: junk registry file: rc=%s, got "%s"\n' "$rc" "$got"; bad=1; }
  : >"$GATES_DIR/$h"; fake "$w" hold 1
  got=$( (live_gates) 2>&1 ); rc=$?
  { [ "$rc" -eq 0 ] && [ "$got" = 2 ]; } || { printf 'FAIL queue: a pre-queue gate (empty file) is not a holder: rc=%s, got "%s"\n' "$rc" "$got"; bad=1; }
  settle; : >"$GATES_DIR/$h"
  ( queue_acquire >"$out" ) & a=$!
  seen "behind a gate.sh without the queue (pid $h)" "$out" || { printf 'FAIL queue: no wait behind a pre-queue gate\n'; bad=1; }
  kill "$h"; wait "$h" 2>/dev/null
  held || { printf 'FAIL queue: no start once the pre-queue gate died\n'; bad=1; }
  wait "$a"; queue_release
  settle; : >"$GATES_DIR/notapid"
  got=$( (queue_scan) 2>&1 ); rc=$?
  { [ "$rc" -eq 2 ] && [[ "$got" == *"$GATES_DIR/notapid"* ]]; } || { printf 'FAIL queue: foreign file in the registry: rc=%s\n' "$rc"; bad=1; }
  home=$(mktemp -d)
  GATE_EMIT_DIR="$home/e" HOME="$home" USERPROFILE="$home" bash "$TOP/tools/gate.sh" --emit-one true 1 x "$home/x.ms" >/dev/null 2>&1
  { [ -d "$home/e/1" ] && [ ! -e "$home/.metascript" ]; } || { printf 'FAIL queue: --emit-one touched the queue or did not run\n'; bad=1; }
  kill $pids 2>/dev/null
  rm -rf "$home" "$GATES_DIR" "$out"
  GATES_DIR=$keep_dir QUEUE_POLL=$keep_poll
  return $bad
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
  printf ' FAIL  %s/src/test/c/json.ms\n  × parses numbers\n\342\234[LSP-OPEN] /a.ms parse=1ms\n\223 %s/src/test/c/ok.ms\n FAIL  %s/src/test/c/bigint.ms\n  × unary plus\n' \
    "$TOP" "$TOP" "$TOP" >"$log"
  got=$(reds_of tests "$log" 1 | paste -sd'|' -)
  want="src/test/c/bigint.ms > unary plus|src/test/c/json.ms > parses numbers"
  [ "$got" = "$want" ] || { printf 'FAIL reds tests across a split character: want "%s", got "%s"\n' "$want" "$got"; bad=1; }
  printf '%s\n' "FAIL  when branch after a -d: value change  expected=two actual=other" \
    "boundary: setup step failed: source baseline (root C:/tmp/msc-native-boundary-1)" "pass  argv  expected=1 actual=1" >"$log"
  got=$(reds_of boundary "$log" 1 | paste -sd'|' -)
  want="setup: source baseline|when branch after a -d: value change"
  [ "$got" = "$want" ] || { printf 'FAIL reds boundary: want "%s", got "%s"\n' "$want" "$got"; bad=1; }
  printf '%s\n' 'LOSSY src/test/fixedbugs/bug228.ms: fmt changes `await` at 84:10 into `(` at 81:11 of the output' \
    'UNSTABLE src/test/lang/a.ms: second pass differs' '1648 files · 1 lossy · 1 unstable · 0 no-fmt' >"$log"
  got=$(reds_of fmt "$log" 1 | paste -sd'|' -)
  want="src/test/fixedbugs/bug228.ms|src/test/lang/a.ms"
  [ "$got" = "$want" ] || { printf 'FAIL reds fmt: want "%s", got "%s"\n' "$want" "$got"; bad=1; }
  printf '%s\n' 'FAIL tools/gate.sh: self-test' 'FAIL tools/wt.sh: bash -n' 'ok   tools/x.sh: check' >"$log"
  got=$(reds_of tools "$log" 1 | paste -sd'|' -)
  want="tools/gate.sh|tools/wt.sh"
  [ "$got" = "$want" ] || { printf 'FAIL reds tools: want "%s", got "%s"\n' "$want" "$got"; bad=1; }
  rm -f "$log"
  got=$(printf 'key\t%s\tsrc/test/corpus/programs/%s\n' o1 100-file.ms o2 200-dir o3 630-escapes.ms o4 802-nested o5 803-up o6 804-dirty \
    | cat - <(printf 'ref\t\tsrc/test/corpus/programs/%s\n' '630-escapes.ms:"../../../' '802-nested/app/direct.ms:"../' '802-nested/main.ms:"./' '803-up/main.ms:"../') \
      <(printf 'dirty\t\tsrc/test/corpus/programs/%s\n' 804-dirty/main.ms 900-new/main.ms) \
    | program_keys | sort | paste -sd'|' -)
  want="100-file o1|200-dir o2|802-nested o4"
  [ "$got" = "$want" ] || { printf 'FAIL control reuse: want "%s", got "%s"\n' "$want" "$got"; bad=1; }
  got=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    same c1 j1 0 9 c1 j1 0 9  changed c1 j1 0 9 c2 j1 0 9  bothfail c1 j1 1 9 c1 j1 1 9  candfail c1 j1 0 9 c1 j1 1 9 \
    | differ_c | paste -sd'|' -)
  want="changed|bothfail|candfail"
  [ "$got" = "$want" ] || { printf 'FAIL differ in C: want "%s", got "%s"\n' "$want" "$got"; bad=1; }
  log=$(mktemp) || return 1
  printf 'x\ny\n' >"$log"
  got=$({ bounded cat; } <"$log" | paste -sd'|' -)
  rm -f "$log"
  [ "$got" = "x|y" ] || { printf 'FAIL bounded inside a pipeline: want "x|y", got "%s"\n' "$got"; bad=1; }
  got=$(TEST_SHARDS=3; test_jobs | awk '{ n++; if ($2 != "-") s++ } NR == 1 { first = $0 } END { printf "%d %d %s", n, s, first }')
  [ "$got" = "12 6 src/test/fixedbugs/index.ms 0/3" ] || { printf 'FAIL test jobs with 3 shards: got "%s"\n' "$got"; bad=1; }
  got=$(TEST_SHARDS=1; test_jobs | awk '$2 != "-" { s++ } END { printf "%d %d", NR, s }')
  [ "$got" = "8 0" ] || { printf 'FAIL test jobs unsharded: got "%s"\n' "$got"; bad=1; }
  log=$(mktemp -d) || return 1
  printf 'ok k1\nfailed k2\nstale k3\nnew k4\n' >"$log/keys"
  printf 'k1\n' >"$log/ok.key"; printf 'ok\tc\tj\t0\t9\n' >"$log/ok.sig"
  printf 'k2\n' >"$log/failed.key"; printf 'failed\tc\tj\t1\t9\n' >"$log/failed.sig"
  printf 'k0\n' >"$log/stale.key"; printf 'stale\tc\tj\t0\t9\n' >"$log/stale.sig"
  got=$(printf '%s p\n' ok failed stale new | control_todo "$log" "$log/keys" | cut -d' ' -f1 | paste -sd'|' -)
  rm -rf "$log"
  [ "$got" = "failed|stale|new" ] || { printf 'FAIL control reuse of emits: want "failed|stale|new", got "%s"\n' "$got"; bad=1; }
  got=$(ledger_fmt "2026-09-26 21:00:00" recompiler suite 553 0 2 2 0 0 30 | tr '\t' '|')
  want='2026-09-26 21:00:00|recompiler|suite|553|0|2|2|0|0|30'
  [ "$got" = "$want" ] || { printf 'FAIL ledger fmt: want "%s", got "%s"\n' "$want" "$got"; bad=1; }
  local keep_sl=${GATE_SELECT_LEDGER:-}; GATE_SELECT_LEDGER=$(mktemp); : >"$GATE_SELECT_LEDGER"
  select_ledger tier-select 18 2 8 "" "" ""
  select_ledger select 540 14 442 2 0 12
  local select_why="--lanes runs a lane whole" select_label="corpus and san"
  record_select_off
  select_label=san
  record_select_off
  select_label=""
  record_select_off
  select_label=corpus select_why=""
  record_select_off
  got=$(cut -f3- "$GATE_SELECT_LEDGER" | tr '\t' '|' | paste -sd'#' -)
  want='step|secs|kept|total|differ_c|differ_js|touched#tier-select|18|2|8|||#select|540|14|442|2|0|12#select-off|0|||||#select-off|0|||||'
  [ "$got" = "$want" ] || { printf 'FAIL select ledger: want "%s", got "%s"\n' "$want" "$got"; bad=1; }
  rm -f "$GATE_SELECT_LEDGER"; GATE_SELECT_LEDGER=$keep_sl
  if ! printf 'src/checker/a.ms\n' | compiler_changed; then printf 'FAIL compiler changed: checker\n'; bad=1; fi
  if printf 'src/test/c/x.ms\ndocs/a.md\n' | compiler_changed; then printf 'FAIL compiler changed: tests only\n'; bad=1; fi
  local progs; progs=$(mktemp -d)
  mkdir -p "$progs/010-numbered" "$progs/unnumberedDir" "$progs/noMain"
  : >"$progs/010-numbered/main.ms"; : >"$progs/unnumberedDir/main.ms"; : >"$progs/plain.ms"; : >"$progs/notes.txt"
  got=$(list_programs "$progs" | cut -d' ' -f1 | sort | paste -sd'|' -)
  rm -rf "$progs"
  [ "$got" = "010-numbered|plain|unnumberedDir" ] || { printf 'FAIL programs as the corpus runner finds them: want "010-numbered|plain|unnumberedDir", got "%s"\n' "$got"; bad=1; }
  local depsf; depsf=$(mktemp)
  printf 'C:/w/src/test/c/index.ms\nC:/w/src/test/helpers.ms\n' >"$depsf"
  if ! printf 'src/test/helpers.ms\n' | tier_touched "$depsf" C:/w; then printf 'FAIL tier touched: its helper\n'; bad=1; fi
  if printf 'src/test/lang/x.ms\n' | tier_touched "$depsf" C:/w; then printf 'FAIL tier touched: another tier\n'; bad=1; fi
  if printf 'test/helpers.ms\n' | tier_touched "$depsf" C:/w; then printf 'FAIL tier touched: partial segment\n'; bad=1; fi
  rm -f "$depsf"
  local keep_select=${select:-0} keep_emit=${EMIT:-} raiser_on=0 only_csv="" narrow="" lanes_csv=""
  select=1 EMIT=$(mktemp -d)
  narrow_for tests
  [ -z "$only_csv" ] || { printf 'FAIL tests narrowed by program: got "%s"\n' "$only_csv"; bad=1; }
  if select_leaves_nothing tests; then printf 'FAIL tests skipped when select keeps no program\n'; bad=1; fi
  printf 'p1\np2\n' >"$EMIT/only.corpus"
  narrow_for corpus
  [ "$only_csv" = "p1,p2" ] || { printf 'FAIL corpus narrowed by program: want "p1,p2", got "%s"\n' "$only_csv"; bad=1; }
  : >"$EMIT/only.san"
  narrow_for san
  if ! select_leaves_nothing san; then printf 'FAIL san runs when select keeps no program\n'; bad=1; fi
  rm -rf "$EMIT"
  select=$keep_select EMIT=$keep_emit
  local jobs cap1 cap2 invalid rc
  while IFS='|' read -r jobs cap1 cap2 want; do
    got=$(cap_jobs "$jobs" "$cap1" "$cap2")
    [ "$got" = "$want" ] || { printf 'FAIL worker caps %s/%s/%s: want "%s", got "%s"\n' "$jobs" "$cap1" "$cap2" "$want" "$got"; bad=1; }
  done <<'CASES'
32|||32
32|3||3
32|3|2|2
32|3|64|3
1|3|2|1
32||2|2
32|03|02|2
CASES
  for invalid in 0 -1 three 9223372036854775808; do
    got=$(cap_jobs 32 "$invalid" 2>/dev/null); rc=$?
    [ "$rc" -eq 2 ] && [ -z "$got" ] || { printf 'FAIL invalid worker cap %s: rc=%s, jobs="%s"\n' "$invalid" "$rc" "$got"; bad=1; }
  done
  queue_self_test || bad=1
  adopt_self_test || bad=1
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
corpus_build_limit=${MSCORPUS_BUILD_JOBS:-}
cap_jobs 1 "${GATE_PAR:-}" "$corpus_build_limit" >/dev/null

if [ "$record" -eq 1 ]; then
  base=main
  off_main=$(changed_paths | route_paths | awk -F'\t' '$1 != "tools" { print $2 }' | sort -u)
  [ -z "$off_main" ] || die "--record: this checkout differs from main on paths the lanes test:
$(printf '%s\n' "$off_main" | head -5 | sed 's/^/  /')"
fi

if [ -x "$TOP/msc" ]; then BUILDER="$TOP/msc"; else BUILDER=$(command -v msc) || die "no ./msc and no msc on PATH"; fi
cand_key=""
[ -n "$(git status --porcelain -- src std)" ] || cand_key=$(tree_key HEAD)
CC_FLAG=""
[ "$(uname -s)" = Darwin ] && command -v clang >/dev/null 2>&1 && CC_FLAG="--cc=clang"

load1() {
  if [ -r /proc/loadavg ]; then cut -d' ' -f1 /proc/loadavg; else sysctl -n vm.loadavg | awk '{print $2}'; fi
}
admit() {
  local max=${GATE_WAIT_MAX:-1800} waited=0 n l
  n=$(cores)
  while :; do
    l=$(load1)
    awk -v l="$l" -v n="$n" 'BEGIN{exit !(l<=n)}' && { ADMIT_WAITED=$((ADMIT_WAITED + waited)); return 0; }
    [ "$waited" -lt "$max" ] || { ADMIT_WAITED=$((ADMIT_WAITED + waited)); ledger busy 0 75 0 0 0 0 "$ADMIT_WAITED"; say "gate: BUSY load $l > $n cores after ${waited}s"; exit 75; }
    say "gate: waiting, load $l > $n cores (${waited}s/${max}s)"
    sleep 60; waited=$((waited + 60))
  done
}

lane_cmd() {
  case "$1" in
    build) printf '%s build src/index.ms --gc=drc --danger %s --output=%s' "$BUILDER" "$CC_FLAG" "$CAND" ;;
    boundary) printf '%s run --target=raiser src/test/nativeBuildBoundary.ms %s' "$CAND" "$CAND" ;;
    hcr) printf 'MSC=%s %s run --target=raiser src/test/hcr/run.ms' "$CAND" "$CAND" ;;
    corpus) printf '%s%sMSC=%s %s run src/test/corpus/run.ms' "$narrow" "$([ "$raiser_on" -eq 1 ] && printf 'MSCORPUS_RAISER=1 ')" "$CAND" "$BUILDER" ;;
    san) printf '%sMSCORPUS_SAN=1 MSC=%s %s run src/test/corpus/run.ms' "$narrow" "$CAND" "$BUILDER" ;;
    fmt) printf '%s run src/test/fmt/run.ms' "$BUILDER" ;;
  esac
}

run_tools_lane() {
  local p rc=0 queue=0
  while IFS=$'\t' read -r _ p; do
    [ -f "$p" ] || continue
    case "$p" in
      *.sh)
        if ! bash -n "$p"; then printf 'FAIL %s: bash -n\n' "$p"; rc=1
        elif [ "$p" = tools/gate.sh ] && ! bash "$p" --self-test; then printf 'FAIL %s: self-test\n' "$p"; rc=1
        fi
        case "$p" in tools/wt.sh | tools/landQueue.sh | tools/landQueueTest.sh) queue=1 ;; esac ;;
      *.ms) "$BUILDER" check "$p" || { printf 'FAIL %s: check\n' "$p"; rc=1; } ;;
    esac
  done < <(awk -F'\t' '$1=="tools"' "$OUT/why")
  if [ "$queue" -eq 1 ] && ! bash tools/landQueueTest.sh; then printf 'FAIL %s: self-test\n' tools/landQueueTest.sh; rc=1; fi
  return $rc
}


part_of() { printf '%s/%s.%s.part' "$OUT" "$1" "$(printf '%s' "$2" | tr '/.' '__')"; }

test_one() {
  local bin=$1 f=$2 part=$3; shift 3
  env -u NO_COLOR -u FORCE_COLOR "$bin" test "$f" "$@" >"$part" 2>&1
  echo $? >"$part.rc"
}


run_test_lane() {
  local rc=0 f shard part jobs="src/index.ms -" noresult=" "
  case "$1" in
    suite) with_test_binary with_slot test_one "$BUILDER" src/index.ms "$(part_of suite src/index.ms)" ;;
    tests)
      jobs=$(test_jobs)
      if [ -z "$lanes_arg" ] && [ "$release" -eq 0 ] && [ "$record" -eq 0 ] && tier_select; then
        jobs=$(awk -v k="$OUT/tier/keep" 'BEGIN { while ((getline l < k) > 0) w[l] = 1 } w[$1] { print }' <<<"$jobs")
      else
        rm -f "$OUT/tier/keep"
      fi
      while read -r f shard; do
        [ -n "$f" ] || continue
        if [ "$shard" = - ]; then
          with_slot test_one "$CAND" "$f" "$(part_of tests "$f")" --tests-in-dir &
        else
          with_slot test_one "$CAND" "$f" "$(part_of tests "$f.$shard")" --tests-in-dir "--tests-shard=$shard" &
        fi
      done <<<"$jobs"
      wait ;;
  esac
  while read -r f shard; do
    [ -n "$f" ] || continue
    if [ "$shard" = - ]; then part=$(part_of "$1" "$f"); else part=$(part_of "$1" "$f.$shard"); fi
    cat "$part"
    [ "$(cat "$part.rc" 2>/dev/null)" = 0 ] || rc=1
    if ! sed $'s/\x1b\\[[0-9;]*m//g' "$part" | grep -Eq '^ *Test Files +[0-9]'; then
      case "$noresult" in *" $f "*) ;; *) printf 'NORESULT %s > no result\n' "$f"; noresult="$noresult$f " ;; esac
      sed $'s/\x1b\\[[0-9;]*m//g' "$part" | grep -E '^(error|internal|fatal)' | head -3
      rc=1
    fi
    rm -f "$part" "$part.rc"
  done <<<"$jobs"
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
    suite|tests)
      sed $'s/\x1b\\[[0-9;]*m//g' "$log" | awk '
        /^ *Tests +[0-9]/ {
          for (i = 2; i <= NF; i++) if ($i == "passed") p += $(i - 1)
          if (match($0, /\([0-9]+\)$/)) t += substr($0, RSTART + 1, RLENGTH - 2)
        }
        END { if (t) printf "%d/%d", p, t }' ;;
  esac
}


emit_side() {
  local jobs
  jobs=$(cap_jobs "$(share_of_cores 2)" "${GATE_PAR:-}") || return $?
  mkdir -p "$2"
  awk '{ print NR, $0 }' | bounded env -u FORCE_COLOR GATE_EMIT_DIR="$2" NO_COLOR=1 xargs -r -P "$jobs" -L1 "$TOP/tools/gate.sh" --emit-one "$1"
}

reusable_programs() {
  local dir=src/test/corpus/programs
  {
    git ls-tree HEAD "$dir/" | awk -F'\t' '{ split($1, m, " "); print "key\t" m[3] "\t" $2 }'
    git status --porcelain --untracked-files=all -- "$dir" | awk '{ print "dirty\t\t" substr($0, 4) }'
    grep -rEo '"\.{1,2}/(\.\./)*' "$dir" | awk '{ print "ref\t\t" $0 }'
  } | program_keys
}


keep_emits() {
  local dir=$1 side=$2
  mkdir -p "$dir"
  awk -v dir="$dir" -v keys="$EMIT/ctl.keys" '
    BEGIN { while ((getline l < keys) > 0) { split(l, a, " "); key[a[1]] = a[2] } }
    ($1 in key) { f = dir "/" $1; print > (f ".sig"); close(f ".sig"); print key[$1] > (f ".key"); close(f ".key") }' "$side"
}

adopt_candidate() {
  local dir="$OUT/ctl-$cand_key"
  [ -n "$cand_key" ] && [ -x "$CAND" ] && [ "$(cat "$CAND.key" 2>/dev/null)" = "$cand_key" ] || return 0
  [ -x "$dir/msc" ] && return 0
  mkdir -p "$dir.tmp" && cp "$CAND" "$dir.tmp/msc" && keep_emits "$dir.tmp/emit" "$EMIT/cand.sig" \
    && rm -rf "$dir" && mv "$dir.tmp" "$dir" || rm -rf "$dir.tmp"
  ls -dt "$OUT"/ctl-[0-9a-f]*/ 2>/dev/null | tail -n +4 | xargs -r rm -rf
}

emit_control() {
  local dir="$2/emit"
  mkdir -p "$dir"
  reusable_programs >"$EMIT/ctl.keys"
  control_todo "$dir" "$EMIT/ctl.keys" <"$EMIT/programs" >"$EMIT/ctl.todo"
  emit_side "$1" "$EMIT/ctrl" <"$EMIT/ctl.todo" | awk -v dir="$dir" -v keys="$EMIT/ctl.keys" '
    BEGIN { while ((getline l < keys) > 0) { split(l, a, " "); key[a[1]] = a[2] } }
    { f = dir "/" $1; print > (f ".sig"); close(f ".sig"); printf "%s", (($1 in key) ? key[$1] "\n" : "") > (f ".key"); close(f ".key") }'
  awk -v dir="$dir" '{ f = dir "/" $1 ".sig"; if ((getline l < f) > 0) print l; close(f) }' "$EMIT/programs" | sort >"$EMIT/ctl.sig"
}

select_whole() {
  select=0; say "gate: select gave up, no narrowing for $select_label ($1)"
  select_ledger select-whole "$((SECONDS - ${t0:-$SECONDS}))" "" "" "" "" ""
}

select_programs() {
  local sha key ctl_dir ctl t0=$SECONDS n_all line
  sha=$(git merge-base "$base" HEAD) || { select_whole "no merge base with $base"; return; }
  rm -rf "$OUT/ctl"
  key=$(build_ctl "$sha") || { select_whole "no control compiler at $(printf '%s' "$sha" | cut -c1-8), log: $OUT/ctl.log"; return; }
  ctl_dir="$OUT/ctl-$key" ctl="$ctl_dir/msc"
  rm -rf "$EMIT"
  mkdir -p "$EMIT"
  list_programs >"$EMIT/programs"
  emit_control "$ctl" "$ctl_dir"
  emit_side "$CAND" "$EMIT/cand" <"$EMIT/programs" | sort >"$EMIT/cand.sig"
  adopt_candidate
  n_all=$(grep -c . "$EMIT/programs")
  if [ "$(grep -c . "$EMIT/ctl.sig")" -ne "$n_all" ] || [ "$(grep -c . "$EMIT/cand.sig")" -ne "$n_all" ]; then
    select_whole "an emit pass lost programs"; return
  fi
  if awk -F'\t' '$4 == 0 && $5 == 0 { bad = 1 } END { exit !bad }' "$EMIT/ctl.sig" "$EMIT/cand.sig"; then
    select_whole "a clean --emit=c left no C file to compare"; return
  fi
  join -t "$(printf '\t')" "$EMIT/ctl.sig" "$EMIT/cand.sig" >"$EMIT/both"
  differ_c <"$EMIT/both" >"$EMIT/differ.c"
  awk -F'\t' '$3 != $7 { print $1 }' "$EMIT/both" >"$EMIT/differ.js"
  printf '%s\n' "$paths" | sed -n 's|^src/test/corpus/programs/\([^/]*\).*$|\1|p' | sed 's/\.ms$//' | sort -u >"$EMIT/touched.all"
  cut -d' ' -f1 "$EMIT/programs" | sort | comm -12 - "$EMIT/touched.all" >"$EMIT/touched"
  sort -u "$EMIT/differ.c" "$EMIT/differ.js" "$EMIT/touched" >"$EMIT/only.corpus"
  sort -u "$EMIT/differ.c" "$EMIT/touched" >"$EMIT/only.san"
  line="gate: select $(fmt_secs $((SECONDS - t0))) · $n_all programs · $(grep -c . "$EMIT/differ.c" | tr -d ' ') differ in C · $(grep -c . "$EMIT/differ.js" | tr -d ' ') in JS · $(grep -c . "$EMIT/touched" | tr -d ' ') touched"
  [ -s "$EMIT/only.corpus" ] || line="$line — byte-neutral for the corpus; if this is a fix, its repro belongs in corpus/programs"
  say "$line"
  select_ledger select "$((SECONDS - t0))" "$(grep -c . "$EMIT/only.corpus" | tr -d ' ')" "$n_all" \
    "$(grep -c . "$EMIT/differ.c" | tr -d ' ')" "$(grep -c . "$EMIT/differ.js" | tr -d ' ')" "$(grep -c . "$EMIT/touched" | tr -d ' ')"
  selected=1
}


scope_known() {
  local tierkeep=""
  [ "$1" = tests ] && [ -f "$OUT/tier/keep" ] && tierkeep="$OUT/tier/keep"
  awk -v only="$only_csv" -v lanes="$lanes_csv" -v tierkeep="$tierkeep" -v drop_raiser="$([ "$1" = corpus ] && [ "$raiser_on" -eq 0 ] && echo 1)" '
    BEGIN { n = split(only, a, ","); for (i = 1; i <= n; i++) keep[a[i]] = 1
            m = split(lanes, b, ","); for (i = 1; i <= m; i++) lane_kept[b[i]] = 1
            scoped = 0
            if (tierkeep != "") { while ((getline t < tierkeep) > 0) { tier[t] = 1; td[t] = t; if (sub(/\/index\.ms$/, "/", td[t])) dirscope[t] = td[t]; else dirscope[t] = "\001none" } scoped = 1 } }
    { prog = $0; sub(/ \[.*$/, "", prog); lane = $0; sub(/^.*\[/, "", lane); sub(/\].*$/, "", lane)
      if (drop_raiser == 1 && lane == "raiser") next
      if (scoped == 1) { file = $0; sub(/ > .*$/, "", file); hit = 0
        for (t in tier) { if (file == t) { hit = 1; break } if (dirscope[t] != "\001none" && index(file, dirscope[t]) == 1) { hit = 1; break } }
        if (hit == 0) next }
      if (n > 0 && !(prog in keep)) next
      if (m > 0 && lane != "parity" && !(lane in lane_kept)) next
      print }'
}




need_cand() {
  [ -x "$CAND" ] || die "lane '$1' tests the candidate compiler; include the build lane"
}

fmt_secs() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }

if [ "$select_only" -eq 1 ]; then
  need_cand select
  trap queue_release EXIT
  queue_acquire
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
record_select_off

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
    (with_slot env -u FORCE_COLOR NO_COLOR=1 GUARD_SHARD="$i/$n" MSC="$CAND" "$CAND" run --target=raiser src/test/guard/run.ms >"$part" 2>&1; echo $? >"$part.rc") &
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
  [ "$lane" != build ] || rm -f "$CAND.key"
  case "$lane" in
    tools) bounded run_tools_lane >"$log" 2>&1; rc=$? ;;
    tests|suite) bounded run_test_lane "$lane" >"$log" 2>&1; rc=$? ;;
    guard) bounded run_guard_lane >"$log" 2>&1; rc=$? ;;
    boundary|corpus|san|hcr) with_slot bounded env -u FORCE_COLOR NO_COLOR=1 bash -c "$(lane_cmd "$lane")" >"$log" 2>&1; rc=$? ;;
    *) with_slot bounded env -u NO_COLOR -u FORCE_COLOR bash -c "$(lane_cmd "$lane")" >"$log" 2>&1; rc=$? ;;
  esac
  if [ "$lane" = build ] && [ "$rc" -eq 0 ] && [ -n "$cand_key" ] && [ -z "$(git status --porcelain -- src std)" ] \
    && [ "$(tree_key HEAD)" = "$cand_key" ]; then
    printf '%s\n' "$cand_key" >"$CAND.key"
  fi
  printf '\nSECS=%d\nRC=%d\nEND\n' "$((SECONDS - t0))" "$rc" >>"$log"
}

PHASES=("tools build" "boundary suite hcr tests fmt" "corpus guard" "san")

start=$SECONDS
ran="" blocked="" verdict=GREEN stopped="" selected=0 narrow="" only_csv="" lanes_csv="" ADMIT_WAITED=0 red_sum=0 new_sum=0 flaky_sum=0
trap queue_release EXIT
[ "$lanes" = tools ] || queue_acquire
PAR=$(cap_jobs "${GATE_PAR:-$(share_of_cores 5)}") || exit $?
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
  MSCORPUS_BUILD_JOBS=$(cap_jobs "$(share_of_cores "$heavy")" "${GATE_PAR:-}" "$corpus_build_limit") || exit $?
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
    case "$lane" in corpus|san|tests)
      if [ -n "$select_pid" ]; then wait "$select_pid"; select_pid=""; read -r select selected <"$OUT/select.state"; fi
      [ "$select" -eq 0 ] || [ "$selected" -eq 1 ] || select_programs
      narrow="" only_csv="" lanes_csv=""
      narrow_for "$lane"
      if select_leaves_nothing "$lane"; then say "gate: $lane skipped, no program's emitted $([ "$lane" = san ] && printf 'C' || printf 'C or JS') differs"; continue; fi
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
  if [ "$lane" = san ] && [ "$rc" = 77 ] && grep -q '!! SAN BLOCKED' "$log"; then
    say "gate: san $(fmt_secs "${secs:-0}") · BLOCKED on this host, $(sed -n 's/^ *!! SAN BLOCKED — //p' "$log" | head -1)"
    blocked="$blocked san"
    ledger san "${secs:-0}" "$rc" 0 0 0 0 "$ADMIT_WAITED"
    continue
  fi
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
  red_sum=$((red_sum + n_red)); new_sum=$((new_sum + n_new)); flaky_sum=$((flaky_sum + n_flaky)); ledger "$lane" "${secs:-0}" "$rc" "$n_red" "$((n_red - n_new))" "$n_new" "$n_flaky" "$ADMIT_WAITED"
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
  merged="$OUT/known.merged"
  jq --arg lanes "$KNOWN_LANES flaky" 'with_entries(select(.key as $k | $lanes | split(" ") | index($k)))' "$KNOWN.prev" >"$merged" \
    || die "--record: cannot read $KNOWN.prev"
  for lane in $ran; do
    case " $KNOWN_LANES " in *" $lane "*) ;; *) continue ;; esac
    jq --arg l "$lane" --arg sha "$sha" --rawfile reds "$OUT/$lane.red" '
      . as $prev
      | ($reds | split("\n") | map(select(length > 0))) as $names
      | $prev + {($l): ($names | map({key: ., value: (($prev[$l] // {})[.] // {since: $sha, note: ""})}) | from_entries)}' "$merged" >"$merged.next" \
      && mv "$merged.next" "$merged" || die "--record: merging the $lane reds failed"
  done
  jq -r '
    "{\n" + ([to_entries | sort_by(.key)[] |
      "  \(.key | @json): {" +
      (if (.value | length) == 0 then "" else
        "\n" + ([.value | to_entries | sort_by(.key)[] | "    \(.key | @json): \(.value | tojson)"] | join(",\n")) + "\n  "
      end) + "}"] | join(",\n")) + "\n}"' "$merged" >"$KNOWN" || die "--record: writing $KNOWN failed"
  diff -u "$KNOWN.prev" "$KNOWN" | sed -n '3,$p'
  rm -f "$KNOWN.prev"
  say "gate: RECORDED $(jq '[.[] | length] | add // 0' "$KNOWN") known red(s) at $sha ($(fmt_secs $((SECONDS - start)))) -> src/test/known-red.json"
  ledger total $((SECONDS - start)) 0 "$red_sum" "$((red_sum - new_sum))" "$new_sum" "$flaky_sum" "$ADMIT_WAITED"
  exit 0
fi

say "gate: $verdict ($(printf '%s' "$ran" | sed 's/^ //; s/ /, /g')) $(fmt_secs $((SECONDS - start)))${blocked:+ · not run on this host:$blocked}"
ledger total $((SECONDS - start)) "$([ "$verdict" = GREEN ] && echo 0 || echo 1)" "$red_sum" "$((red_sum - new_sum))" "$new_sum" "$flaky_sum" "$ADMIT_WAITED"
if [ "$verdict" = GREEN ]; then adopt_builder GREEN "$ran"; exit 0; fi
exit 1
