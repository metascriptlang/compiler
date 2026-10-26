#!/usr/bin/env bash
set -euo pipefail
subject=${1:-$(dirname "$0")/gate.sh}
subject=$(cd "$(dirname "$subject")" && pwd)/$(basename "$subject")
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
w="$d/wt"
mkdir -p "$w/tools" "$w/src/test" "$w/out/gate" "$d/home"
cp "$subject" "$w/tools/gate.sh"
printf '#!/bin/sh\nexit 0\n' >"$w/msc"
chmod +x "$w/msc"
cp "$w/msc" "$w/out/gate/msc"
printf 'out/\nmsc*\n' >"$w/.gitignore"
printf '{}\n' >"$w/src/test/known-red.json"
git -C "$w" init -q -b main
git -C "$w" -c user.name=t -c user.email=t@t add -A
git -C "$w" -c user.name=t -c user.email=t@t commit -qm base
bad=0
check() {
  local name=$1 known=$2 want=$3 rc=0 local_known=${4:-}
  [ -n "$local_known" ] || local_known='{}'
  printf '%s\n' "$known" >"$w/src/test/known-red.json"
  printf '%s\n' "$local_known" >"$d/local.json"
  printf 'LOSSY new.ms: token changed\nSECS=1\nRC=1\nEND\n' >"$w/out/gate/fmt.log"
  (cd "$w" && HOME="$d/home" USERPROFILE="$d/home" GATE_WAIT_MAX=-1 GATE_PAR=1 \
    GATE_KNOWN_LOCAL="$d/local.json" GATE_LEDGER="$d/gate.tsv" GATE_SELECT_LEDGER="$d/select.tsv" \
    bash tools/gate.sh --lanes fmt --reuse) >"$d/log" 2>&1 || rc=$?
  if [ "$rc" != "$want" ]; then
    printf 'FAIL failure filter: %s: want exit %s, got %s\n' "$name" "$want" "$rc"
    bad=1
  fi
  if [ "$want" = 1 ] && ! grep -q '^  new: new.ms$' "$d/log"; then
    printf 'FAIL failure filter: %s lost the new failure name\n' "$name"
    bad=1
  fi
}
check 'empty flaky list retains new failures' '{}' 1
check 'an unrelated flaky entry retains new failures' '{"flaky":{"other.ms":{"since":"fixture","note":"fixture"}}}' 1
check 'only a matching flaky entry is classified out' '{"flaky":{"new.ms":{"since":"fixture","note":"fixture"}}}' 0
check 'a local unrelated flaky entry retains new failures' '{}' 1 '{"flaky":{"other.ms":{"since":"fixture","note":"fixture"}}}'
check 'a local matching flaky entry is classified out' '{}' 0 '{"flaky":{"new.ms":{"since":"fixture","note":"fixture"}}}'
printf 'failure filter: 5 checks, status %s\n' "$bad"
exit "$bad"
