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

IND="$TMP/indirect"
mkdir -p "$IND"
cp "$DIR/fixtures/indirect/app.ms" "$DIR/fixtures/indirect/logic.ms" "$DIR/fixtures/indirect/host.ms" "$IND/"

failIndirect() {
	printf 'FAIL hcrIndirect: %s\n' "$1"
	exit 1
}

emitIndirect() {
	rm -rf "$IND/out"
	if ! (cd "$IND" && env NO_COLOR=1 "$MSC" build app.ms "$@" --emit=c) >"$TMP/indirect.log" 2>&1; then
		cat "$TMP/indirect.log"
		failIndirect "C emission failed ($*)"
	fi
	APP_C=$(ls "$IND"/out/debug/*appOms.c)
	LOGIC_C=$(ls "$IND"/out/debug/*logicOms.c)
	DISPATCH_C="$IND/out/debug/_dispatch.c"
}

emitIndirect
if grep -q 'msHcr\|_ms_hcr' "$APP_C" "$LOGIC_C" "$DISPATCH_C"; then
	failIndirect "a build without --hcr emitted HCR indirection"
fi

emitIndirect --hcr
VALUE=$(sed -n 's/^int32_t \(value__[A-Za-z0-9_]*\)(void);$/\1/p' "$LOGIC_C")
BASE=$(sed -n 's/^int32_t \(base__[A-Za-z0-9_]*\)(void);$/\1/p' "$LOGIC_C")
PAIR=$(sed -n 's/^void \(pair__[A-Za-z0-9_]*\)(.* __result, int32_t scale);$/\1/p' "$LOGIC_C")
[ -n "$VALUE" ] && [ -n "$BASE" ] && [ -n "$PAIR" ] || failIndirect "logic exports not found in emitted C"
grep -qF "#define $VALUE ((__typeof__(&$VALUE))_ms_hcr_m0->current[2])" "$APP_C" ||
	failIndirect "cross-module call to logic::value is not lowered through its table slot"
grep -qF '_ms_hcr_m0 = msHcrHandle("logic");' "$APP_C" || failIndirect "app does not resolve the logic handle"
grep -qF "$VALUE()" "$APP_C" || failIndirect "app call site changed shape"
grep -qF 'msHcrPublish("logic", _ms_hcr_table, 3);' "$LOGIC_C" || failIndirect "logic does not publish its table"
grep -qF "(void*)&$BASE, (void*)&$PAIR, (void*)&$VALUE" "$LOGIC_C" || failIndirect "logic table is not in manifest slot order"
if grep -q "#define $BASE \|#define $VALUE " "$LOGIC_C"; then
	failIndirect "same-module calls in logic are indirected"
fi
grep -qF "return ($BASE() + offset__" "$LOGIC_C" || failIndirect "same-module and private calls are not direct"
grep -qF 'MS_HCR_EXPORT void DatInit000(void) { MsPreMainInner(); }' "$DISPATCH_C" ||
	failIndirect "HCR image does not export its dependency-ordered DatInit"

case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*)
		if ! (cd "$IND" && env NO_COLOR=1 "$MSC" build app.ms --hcr --output=module.dll) >"$TMP/indirect.log" 2>&1; then
			cat "$TMP/indirect.log"
			failIndirect "HCR image link failed"
		fi
		if ! (cd "$IND" && env NO_COLOR=1 "$MSC" build host.ms --output=host.exe) >"$TMP/indirect.log" 2>&1; then
			cat "$TMP/indirect.log"
			failIndirect "host build failed"
		fi
		called=$(cd "$IND" && ./host.exe module.dll 2>&1)
		[ "$called" = "HCR-HOST call -> 37" ] || failIndirect "call through the table returned '$called'"
		printf 'ok   hcrIndirect\n'
		if ! MSC="$MSC" bash "$ROOT/examples/hcrProbe/runWindows.sh" >"$TMP/reload.log" 2>&1; then
			cat "$TMP/reload.log"
			printf 'FAIL hcrWindowsReload: single-image reload probe failed\n'
			exit 1
		fi
		printf 'ok   hcrWindowsReload\n'
		;;
	*)
		printf 'ok   hcrIndirect (emission only: this runner has no host adapter for %s)\n' "$(uname -s)"
		;;
esac
