#!/usr/bin/env bash
set -euo pipefail
subject=${1:-$(dirname "$0")/gate.sh}
subject=$(cd "$(dirname "$subject")" && pwd)/$(basename "$subject")
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
w="$d/wt"
mkdir -p "$w/tools" "$w/src/test" "$d/home"
cp "$subject" "$w/tools/gate.sh"
printf 'out/\nmsc*\n' >"$w/.gitignore"
printf '{"corpus":{"old.ms":{"since":"x","note":"card"}}}\n' >"$w/src/test/known-red.json"
git -C "$w" init -q -b main
git -C "$w" -c user.name=t -c user.email=t@t add -A
git -C "$w" -c user.name=t -c user.email=t@t commit -qm base
git -C "$w" checkout -q -b slice
bad=0
check() {
  local name=$1 known=$2 want=$3 named=${4:-} rc=0
  printf '%s\n' "$known" >"$w/src/test/known-red.json"
  (cd "$w" && HOME="$d/home" USERPROFILE="$d/home" GATE_KNOWN_LOCAL="$d/local.json" \
    GATE_LEDGER="$d/gate.tsv" GATE_SELECT_LEDGER="$d/select.tsv" bash tools/gate.sh) >"$d/log" 2>&1 || rc=$?
  if [ "$rc" != "$want" ]; then
    printf 'FAIL known approval: %s: want exit %s, got %s\n%s\n' "$name" "$want" "$rc" "$(cat "$d/log")"
    bad=1
  fi
  if [ -n "$named" ] && ! grep -qF "  needs approval: $named" "$d/log"; then
    printf 'FAIL known approval: %s does not name %s\n' "$name" "$named"
    bad=1
  fi
}
check 'an added row without approved is red' \
  '{"corpus":{"old.ms":{"since":"x","note":"card"},"new.ms":{"since":"y","note":"card"}}}' 1 'corpus · new.ms'
check 'an added flaky row without approved is red' \
  '{"corpus":{"old.ms":{"since":"x","note":"card"}},"flaky":{"f.ms":{"since":"y","note":"card"}}}' 1 'flaky · f.ms'
check 'an added row with approved passes' \
  '{"corpus":{"old.ms":{"since":"x","note":"card"},"new.ms":{"since":"y","note":"card","approved":"2026-10-29 yes"}}}' 0
check 'a removed row passes' '{"corpus":{}}' 0
check 'an edited note passes' '{"corpus":{"old.ms":{"since":"x","note":"other card"}}}' 0
printf '{"corpus":{"old.ms":{"since":"x","note":"card"},"new.ms":{"since":"y","note":"card"}}}\n' >"$w/src/test/known-red.json"
git -C "$w" -c user.name=t -c user.email=t@t commit -qam add
check 'a committed added row without approved is red' \
  '{"corpus":{"old.ms":{"since":"x","note":"card"},"new.ms":{"since":"y","note":"card"}}}' 1 'corpus · new.ms'
printf 'known approval: 6 checks, status %s\n' "$bad"
exit "$bad"
