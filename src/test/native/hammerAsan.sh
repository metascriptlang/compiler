#!/usr/bin/env bash
# PARALOCK Amendment G (I16) regression gate — the publish->push UAF on
# cross-thread completion futures only manifests under heavy hammering, and a
# UAF write to freed-but-unreused memory is nearly invisible without ASAN. A
# single normal-build test-native run therefore does NOT guard it. This script
# builds the stored-spawn shape under ASAN + slab-off and hammers it on both GC
# modes, so a regression that reopens the window (e.g. a new spawn variant that
# skips the submit-time incref) fails deterministically.
#
# Usage: src/test/native/hammerAsan.sh [iterations]   (default 200)
set -u

ITERS="${1:-200}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PROG="$ROOT/src/test/native/programs/awaitStructSpawnStored.ms"
OUTDIR="$(mktemp -d)"
EXPECT="await-struct-spawn-stored acc=380000"
CC_FLAGS="-O0 -g -fsanitize=address -DMS_SLAB_MAX=0"
LD_FLAGS="-fsanitize=address"
RC=0

trap 'rm -rf "$OUTDIR"' EXIT

for GC in drc orc; do
	BIN="$OUTDIR/guard-$GC"
	echo "== build guard [$GC + ASAN + slab-off] =="
	# Cold cache can race an empty/missing .o on config switch — retry once.
	if ! msc build "$PROG" --gc="$GC" --cc=clang \
		--passC="$CC_FLAGS" --passL="$LD_FLAGS" --output="$BIN" >/dev/null 2>&1; then
		msc build "$PROG" --gc="$GC" --cc=clang \
			--passC="$CC_FLAGS" --passL="$LD_FLAGS" --output="$BIN" >/dev/null 2>&1
	fi
	if [ ! -x "$BIN" ]; then echo "FAIL: build [$GC]"; RC=1; continue; fi

	PASS=0
	for i in $(seq 1 "$ITERS"); do
		OUT="$("$BIN" 2>&1)"; EXIT=$?
		if [ $EXIT -ne 0 ] || ! printf '%s' "$OUT" | grep -q "$EXPECT"; then
			echo "FAIL [$GC] iter $i: exit=$EXIT"
			printf '%s\n' "$OUT" | grep -iE "ERROR|AddressSanitizer|use-after|SUMMARY" | head -3
			RC=1
			break
		fi
		PASS=$((PASS+1))
	done
	echo "== [$GC] $PASS/$ITERS clean =="
done

if [ $RC -eq 0 ]; then echo "hammerAsan: PASS ($ITERS iters, drc+orc)"; else echo "hammerAsan: FAIL"; fi
exit $RC
