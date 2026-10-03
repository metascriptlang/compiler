#!/usr/bin/env bash
set -u
SRC=${LQ_SRC:-$(cd "$(dirname "$0")" && pwd)}
RUNNER=$SRC/landQueue.sh
ADAPTER=$SRC/wt.sh
WT=${MSC_WT_TOOL:-$HOME/nerdtools/claude/tools/wt.sh}
[ -f "$WT" ] || { printf 'landQueueTest: the shared entrypoint %s is missing; set MSC_WT_TOOL\n' "$WT"; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/landQueueTest.XXXXXX") || exit 1
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL %s\n' "$1"
  mkdir -p "$T/kept/${1%% *}"
  cp -R "$T/ws/queue" "$T/ctl" "$T/kept/${1%% *}/" 2>/dev/null
  git -C "$R" log --format='%h %s' main >"$T/kept/${1%% *}/main.log" 2>/dev/null
}
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

bounded() {
  local s=$1 pid i
  shift
  "$@" &
  pid=$!
  for ((i = 0; i < s * 4; i++)); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; return; }
    sleep 0.25
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 124
}

stop_runner() {
  [ -d "$T/ctl" ] && touch "$T/ctl/release"
  runner_down 40 || kill "$(cat "$T/ws/queue/runner.lock/pid" 2>/dev/null)" 2>/dev/null
  runner_down 10
}
trap 'stop_runner; if [ "$FAIL" -eq 0 ]; then rm -rf "$T"; else printf "landQueueTest: logs kept in %s\\n" "$T"; fi' EXIT

setup() {
  stop_runner
  rm -rf "$T/ws" "$T/ctl" "$T/fakebin" "$T/decoy" "$T/decoy-wt"; mkdir -p "$T/ws/.wt" "$T/ctl" "$T/fakebin"
  export LQ_TEST=$T/ctl MSC_LAND_QUEUE=$T/ws/queue MSC_WT_TOOL=$WT
  export MSC_LAND_QUEUE_IDLE=${IDLE:-2} MSC_LAND_QUEUE_POLL=1 MSC_LAND_QUEUE_WAIT_POLL=1
  unset MSC_WT_ROOT WT_CARD_ROOT WT_WORKTREE_ROOT WT_BASE CLAUDE_PROJECT_DIR
  R=$T/ws/repo
  git init -q -b main "$R"
  git -C "$R" config user.email t@t; git -C "$R" config user.name t
  mkdir -p "$R/tools"
  cp "$ADAPTER" "$R/tools/wt.sh"; cp "$RUNNER" "$R/tools/landQueue.sh"
  cat >"$R/tools/gate.sh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = --inert ]; then exit "$(cat "$LQ_TEST/inert" 2>/dev/null || echo 0)"; fi
[ "$1" = --tree-key ] && exit 0
name=$(git symbolic-ref --short HEAD)
printf '%s head=%s files=%s\n' "$name" "$(git rev-parse --short HEAD)" "$(git ls-tree --name-only HEAD | grep -v '^tools$' | paste -sd, -)" >>"$LQ_TEST/gates.log"
v=$(cat verdict 2>/dev/null || echo green)
case "$v" in
  green) exit 0 ;;
  red) echo "gate: RED (tests) 0m01s"; exit 1 ;;
  busy) echo "gate: BUSY load 99 > 14 cores after 1800s"; exit 75 ;;
  hold) touch "$LQ_TEST/holding.${name#wt/}"; while [ ! -e "$LQ_TEST/release" ]; do sleep 0.2; done; exit 0 ;;
esac
EOF
  chmod +x "$R/tools/gate.sh"
  echo base >"$R/base.txt"
  git -C "$R" add -A; git -C "$R" commit -qm init
}

mkwt() {
  local n=$1 verdict=${2:-green} w=$T/ws/.wt/wt-$1
  git -C "$R" worktree add -q -b "wt/$n" "$w" main
  echo "$n" >"$w/$n.txt"; printf '%s\n' "$verdict" >"$w/verdict"
  git -C "$w" add -A; git -C "$w" commit -qm "add $n"
}

setverdict() { printf '%s\n' "$2" >"$T/ws/.wt/wt-$1/verdict"; git -C "$T/ws/.wt/wt-$1" commit -qam "verdict $2"; }
sbwt() { env -u WT_CWD -u CLAUDE_PROJECT_DIR bash "$WT" "$@"; }
enqueue() { (cd "$T/ws/.wt/wt-$1" && sbwt land "$1" --async) >"$T/ctl/enq.$1" 2>&1; }
waitfor() { (cd "$T/ws/.wt/wt-$1" && bounded "${2:-60}" sbwt land "$1" --wait) >"$T/ctl/wait.$1" 2>&1; echo $?; }
runner_down() { local i; for i in $(seq 1 ${1:-30}); do [ -d "$T/ws/queue/runner.lock" ] || return 0; sleep 0.5; done; return 1; }
onmain() { git -C "$R" ls-tree --name-only main | grep -qx "$1"; }

echo "== S1 single green land, --wait reports it"
setup; mkwt a
enqueue a
rc=$(waitfor a)
check "S1 wait rc 0" '[ "$rc" = 0 ]'
check "S1 a.txt on main" 'onmain a.txt'
check "S1 .done written" '[ -e "$MSC_LAND_QUEUE/a.done" ]'
check "S1 main checkout file synced" '[ -e "$R/a.txt" ]'
check "S1 runner exits when idle" 'runner_down 20'

echo "== S2 two queued lands: the second is gated on a tree that contains the first"
setup; mkwt a; mkwt b
enqueue a; enqueue b
ra=$(waitfor a); rb=$(waitfor b)
check "S2 both landed" '[ "$ra" = 0 ] && [ "$rb" = 0 ] && onmain a.txt && onmain b.txt'
check "S2 b gated with a.txt in its tree" 'grep -q "^wt/b .*files=.*a\.txt" "$T/ctl/gates.log"'
check "S2 main is linear a then b" '[ "$(git -C "$R" log --format=%s main | grep -c "^add ")" = 2 ]'

echo "== S3 red item: main untouched, wait rc 1, next item still lands"
setup; mkwt r red; mkwt c
enqueue r; enqueue c
rr=$(waitfor r); rc2=$(waitfor c)
check "S3 red wait rc 1" '[ "$rr" = 1 ]'
check "S3 r not on main" '! onmain r.txt'
check "S3 .red holds the gate line" 'grep -q "gate: RED" "$MSC_LAND_QUEUE/r.red"'
check "S3 c landed after the red" '[ "$rc2" = 0 ] && onmain c.txt'

echo "== S4 dirty worktree when its turn comes"
setup; mkwt h hold; mkwt d
enqueue h; enqueue d
for i in $(seq 1 40); do [ -e "$LQ_TEST/holding.h" ] && break; sleep 0.25; done
echo dirt >>"$T/ws/.wt/wt-d/d.txt"
touch "$LQ_TEST/release"
rh=$(waitfor h); rd=$(waitfor d)
check "S4 h landed" '[ "$rh" = 0 ] && onmain h.txt'
check "S4 dirty d reported red, not dropped silently" '[ "$rd" = 1 ] && grep -q "uncommitted" "$MSC_LAND_QUEUE/d.red"'

echo "== S5 main moves during the gate by a tested path: requeued, regated, landed"
setup; mkwt m hold
echo 1 >"$LQ_TEST/inert"
enqueue m
for i in $(seq 1 40); do [ -e "$LQ_TEST/holding.m" ] && break; sleep 0.25; done
echo other >"$R/other.txt"; git -C "$R" add other.txt; git -C "$R" commit -qm "add other on main"
touch "$LQ_TEST/release"
rm=$(waitfor m 60)
check "S5 landed after retry" '[ "$rm" = 0 ] && onmain m.txt && onmain other.txt'
check "S5 gated twice" '[ "$(grep -c "^wt/m " "$T/ctl/gates.log")" = 2 ]'
check "S5 second gate saw other.txt" '[ "$(grep "^wt/m " "$T/ctl/gates.log" | tail -1 | grep -c other\.txt)" = 1 ]'

echo "== S6 gate BUSY is retried, then red after the try limit"
setup; mkwt y busy
enqueue y
ry=$(waitfor y 60)
check "S6 busy ends red after 3 tries" '[ "$ry" = 1 ] && [ "$(grep -c "^wt/y " "$T/ctl/gates.log")" = 3 ]'
check "S6 runner log shows retries" '[ "$(grep -c "y: retry" "$MSC_LAND_QUEUE/runner.log")" = 2 ]'

echo "== S7 enqueue with no name from inside the worktree; hyphen names do not collide"
setup; mkwt alias; mkwt fix-alias
(cd "$T/ws/.wt/wt-fix-alias" && sbwt land --async) >"$T/ctl/enq.fix-alias" 2>&1
(cd "$T/ws/.wt/wt-alias" && sbwt land alias --async) >"$T/ctl/enq.alias" 2>&1
r1=$(waitfor fix-alias); r2=$(waitfor alias)
check "S7 both landed" '[ "$r1" = 0 ] && [ "$r2" = 0 ] && onmain alias.txt && onmain fix-alias.txt'

echo "== S8 stale lock from a dead runner is taken over"
setup; mkwt s
mkdir -p "$MSC_LAND_QUEUE/runner.lock"; echo 999999 >"$MSC_LAND_QUEUE/runner.lock/pid"
enqueue s
rs=$(waitfor s)
check "S8 landed despite stale lock" '[ "$rs" = 0 ] && grep -q "stale lock" "$MSC_LAND_QUEUE/runner.log"'

echo "== S9 a second runner exits while one holds the lock"
setup; mkwt k hold
enqueue k
for i in $(seq 1 40); do [ -e "$LQ_TEST/holding.k" ] && break; sleep 0.25; done
bash "$R/tools/landQueue.sh"; second=$?
check "S9 second runner exits 0 immediately" '[ "$second" = 0 ] && [ "$(grep -c "runner up" "$MSC_LAND_QUEUE/runner.log")" = 1 ]'
touch "$LQ_TEST/release"; waitfor k >/dev/null

echo "== S10 enqueue right as the runner goes idle: nothing stranded"
setup; IDLE=1; export MSC_LAND_QUEUE_IDLE=1
stranded=0
for n in 1 2 3 4 5 6; do
  mkwt "e$n"; sleep 1.$((n * 15 % 10)); enqueue "e$n"
  r=$(waitfor "e$n" 30); [ "$r" = 0 ] || stranded=$((stranded + 1))
done
check "S10 six lands across idle exits, none stranded" '[ "$stranded" = 0 ]'
unset IDLE; export MSC_LAND_QUEUE_IDLE=2

echo "== S11 --wait on a name that was never queued fails loud"
setup; mkwt n
rn=$(waitfor n 10)
check "S11 wait rc nonzero with a reason" '[ "$rn" != 0 ] && grep -q "nothing queued" "$T/ctl/wait.n"'

echo "== S12 an idle msc.exe on the box (an editor's language server) does not hold the land"
setup; export MSC_LAND_QUEUE_BUSY_MAX=600
printf '#!/usr/bin/env bash\necho "Image Name   PID"\necho "=========== ===="\necho "msc.exe      1234"\n' >"$T/fakebin/tasklist"; chmod +x "$T/fakebin/tasklist"
mkwt w
(export PATH=$T/fakebin:$PATH; cd "$T/ws/.wt/wt-w" && sbwt land w --async) >/dev/null 2>&1
rw=$(waitfor w 30)
check "S12 gated at once beside msc.exe" '[ "$rw" = 0 ] && onmain w.txt && ! grep -q "machine busy" "$MSC_LAND_QUEUE/runner.log"'
unset MSC_LAND_QUEUE_BUSY_MAX

echo "== S13 a commit made during the gate, main moved by an inert path: nothing ungated lands"
setup; mkwt g hold
echo 0 >"$LQ_TEST/inert"
enqueue g
for i in $(seq 1 40); do [ -e "$LQ_TEST/holding.g" ] && break; sleep 0.25; done
echo late >"$T/ws/.wt/wt-g/late.txt"; git -C "$T/ws/.wt/wt-g" add late.txt; git -C "$T/ws/.wt/wt-g" commit -qm "add late"
echo other >"$R/other.txt"; git -C "$R" add other.txt; git -C "$R" commit -qm "add other on main"
touch "$LQ_TEST/release"
rg=$(waitfor g 60)
check "S13 late commit not on main" '! onmain late.txt'
check "S13 red names the moved worktree" '[ "$rg" = 1 ] && grep -q "worktree moved during the gate" "$MSC_LAND_QUEUE/g.red"'

echo "== S14 a commit made during the gate, main still: red, nothing lands"
setup; mkwt q hold
enqueue q
for i in $(seq 1 40); do [ -e "$LQ_TEST/holding.q" ] && break; sleep 0.25; done
echo late >"$T/ws/.wt/wt-q/late.txt"; git -C "$T/ws/.wt/wt-q" add late.txt; git -C "$T/ws/.wt/wt-q" commit -qm "add late"
touch "$LQ_TEST/release"
rq=$(waitfor q 60)
check "S14 neither commit on main" '! onmain late.txt && ! onmain q.txt'
check "S14 red names the moved worktree" '[ "$rq" = 1 ] && grep -q "worktree moved during the gate" "$MSC_LAND_QUEUE/q.red"'

echo "== S15 a caller's WT_CWD and CLAUDE_PROJECT_DIR do not steer the sandbox"
setup; mkwt o
D=$T/decoy
git init -q -b main "$D"; git -C "$D" config user.email t@t; git -C "$D" config user.name t
echo d >"$D/d.txt"; git -C "$D" add -A; git -C "$D" commit -qm decoy
git -C "$D" worktree add -q -b wt/o "$T/decoy-wt" main
echo o >"$T/decoy-wt/o.txt"; git -C "$T/decoy-wt" add -A; git -C "$T/decoy-wt" commit -qm "add o in decoy"
decoy_main=$(git -C "$D" rev-parse main)
(export WT_CWD=$T/decoy-wt CLAUDE_PROJECT_DIR=$T/decoy-wt; enqueue o; waitfor o >"$T/ctl/ro")
check "S15 sandbox o landed" '[ "$(cat "$T/ctl/ro")" = 0 ] && onmain o.txt'
check "S15 decoy main untouched" '[ "$(git -C "$D" rev-parse main)" = "$decoy_main" ] && [ ! -e "$D/o.txt" ]'

echo "== S16 a run a dead runner left is queued again by the next runner and lands"
setup; mkwt s; mkwt u
mkdir -p "$MSC_LAND_QUEUE"
printf 'name=s\nworktree=%s\n' "$T/ws/.wt/wt-s" >"$MSC_LAND_QUEUE/1-1.run"
enqueue u
ru=$(waitfor u 60); rs=$(waitfor s 60)
check "S16 the stranded land and the new one both land" '[ "$rs" = 0 ] && [ "$ru" = 0 ] && onmain s.txt && onmain u.txt'
check "S16 the runner log names the recovery" 'grep -q "s: queued again, a dead runner left it running" "$MSC_LAND_QUEUE/runner.log"'

echo "== S17 --async and --wait on a land a dead runner left start a runner instead of refusing or hanging"
setup; mkwt v
mkdir -p "$MSC_LAND_QUEUE"
printf 'name=v\nworktree=%s\n' "$T/ws/.wt/wt-v" >"$MSC_LAND_QUEUE/1-1.run"
enqueue v; ea=$?
rv=$(waitfor v 60)
check "S17 v landed" '[ "$ea" = 0 ] && [ "$rv" = 0 ] && onmain v.txt'

echo "== S18 a runner started without MSC_WT_ROOT beside a stray .wt in the main checkout still finds the queued worktree"
IDLE=30; setup; mkwt x
mkdir -p "$R/.wt"
(cd "$T/ws" && env -u MSC_WT_ROOT nohup bash "$R/tools/landQueue.sh" >/dev/null 2>&1 &)
for i in $(seq 1 40); do [ -d "$MSC_LAND_QUEUE/runner.lock" ] && break; sleep 0.25; done
(export MSC_WT_ROOT=$T/ws/.wt; enqueue x; waitfor x 60 >"$T/ctl/rx")
check "S18 x landed" '[ "$(cat "$T/ctl/rx")" = 0 ] && onmain x.txt'
unset IDLE; export MSC_LAND_QUEUE_IDLE=2

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
