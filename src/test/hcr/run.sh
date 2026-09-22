#!/usr/bin/env bash
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
[ -n "${MSC:-}" ] || { [ -x "$ROOT/msc" ] && MSC="$ROOT/msc"; }
MSC="${MSC:-msc}"
case "$MSC" in */*) MSC="$(cd "$(dirname "$MSC")" && pwd)/$(basename "$MSC")";; esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WORK="$TMP/work"
mkdir -p "$WORK"
cp "$DIR/fixtures/app.ms" "$WORK/app.ms"
cp "$DIR/fixtures/logic.ms" "$WORK/logic.ms"

fail() {
	printf 'FAIL hcrModuleObjectCache: %s\n' "$1"
	exit 1
}

if ! (cd "$WORK" && env NO_COLOR=1 "$MSC" build app.ms --hcr --verbose --output=module.hcr) >"$TMP/first.log" 2>&1; then
	cat "$TMP/first.log"
	fail "cold build failed"
fi

cp "$DIR/fixtures/logicBodyEdit.ms" "$WORK/logic.ms"
if ! (cd "$WORK" && env NO_COLOR=1 "$MSC" build app.ms --hcr --verbose --output=module.hcr) >"$TMP/edit.log" 2>&1; then
	cat "$TMP/edit.log"
	fail "body-edit build failed"
fi

cc_count=$(grep -c '^    cc ' "$TMP/edit.log" || true)
[ "$cc_count" -eq 1 ] || fail "body edit compiled $cc_count modules, expected 1"
grep '^    cc ' "$TMP/edit.log" | grep -q 'logic_x_ms' || fail "logic object was not compiled"
if grep '^    cc ' "$TMP/edit.log" | grep -q 'app_x_ms'; then
	fail "unchanged app object was compiled"
fi
grep -qE '^[[:space:]]+cached .*app\.ms$' "$TMP/edit.log" || fail "unchanged app object was not reported cached"
[ -f "$WORK/module.hcr" ] || fail "linked HCR image missing"

printf 'ok   hcrModuleObjectCache\n'
