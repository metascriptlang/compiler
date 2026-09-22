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
[ -f "$WORK/module.hcr.hcrabi" ] || fail "HCR ABI bundle missing"
grep -q '"moduleId": "app"' "$WORK/module.hcr.hcrabi" || fail "app manifest missing"
grep -q '"moduleId": "logic"' "$WORK/module.hcr.hcrabi" || fail "logic manifest missing"
grep -q '"id": "logic::value#0"' "$WORK/module.hcr.hcrabi" || fail "logic slot identity is not project-relative"

awk 'BEGIN { changed = 0 } { if (!changed && /"gcMode": "orc"/) { sub(/"orc"/, "\"drc\""); changed = 1 } print }' "$WORK/module.hcr.hcrabi" >"$TMP/stale.hcrabi"
mv "$TMP/stale.hcrabi" "$WORK/module.hcr.hcrabi"
if ! (cd "$WORK" && env NO_COLOR=1 "$MSC" build app.ms --hcr --output=module.hcr) >"$TMP/stale.log" 2>&1; then
	cat "$TMP/stale.log"
	fail "valid stale ABI bundle recovery failed"
fi
grep -q 'HCR restart required: GC mode changed (drc -> orc)' "$TMP/stale.log" || fail "stale bundle classification missing"

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
grep -q 'HCR reload module: implementation changed (logic)' "$TMP/edit.log" || fail "body edit classification missing"
[ -f "$WORK/module.hcr" ] || fail "linked HCR image missing"

cp "$DIR/fixtures/logicSignatureEdit.ms" "$WORK/logic.ms"
if ! (cd "$WORK" && env NO_COLOR=1 "$MSC" build app.ms --hcr --verbose --output=module.hcr) >"$TMP/signature.log" 2>&1; then
	cat "$TMP/signature.log"
	fail "signature-edit build failed"
fi
grep -q 'HCR reload dependents: export signature changed (logic::value#0)' "$TMP/signature.log" || fail "signature edit classification missing"

cp "$WORK/module.hcr" "$TMP/module.before"
printf '{broken\n' >"$WORK/module.hcr.hcrabi"
if (cd "$WORK" && env NO_COLOR=1 "$MSC" build app.ms --hcr --output=module.hcr) >"$TMP/corrupt.log" 2>&1; then
	fail "corrupt current ABI bundle was accepted"
fi
grep -q "invalid current HCR ABI bundle 'module.hcr.hcrabi': invalid JSON" "$TMP/corrupt.log" || fail "corrupt bundle diagnostic missing"
cmp -s "$TMP/module.before" "$WORK/module.hcr" || fail "corrupt bundle replaced current image"

printf 'ok   hcrModuleAbi\n'
