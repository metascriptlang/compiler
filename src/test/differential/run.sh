#!/usr/bin/env bash
# Differential test — C vs JS observable-behavior parity. Native msc, no Bun.
#
# The backends use different internal representations (C: Maybe struct for T|null;
# JS: native null via the maybeUnwrap pass). That divergence is correct — each
# backend picks the representation that fits it. What must NOT diverge is
# user-observable behavior. This runner compiles each program under programs/ to
# BOTH backends and asserts byte-identical stdout.
#
# JS output runs on `node` — the target JS runtime, NOT a compiler dependency
# (the compiler itself is pure native msc here).
#
#   MSC=/path/to/msc src/test/differential/run.sh   # override the compiler binary
set -uo pipefail

MSC="${MSC:-msc}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
PROG_DIR="$HERE/programs"
OUT="$REPO/out/differential"

cd "$REPO"                 # JS backend bundles to <cwd>/out/<name>.js
mkdir -p "$OUT"

echo
echo "Differential tier — C vs JS observable-behavior parity (msc=$MSC)"
echo

fails=0
for src in "$PROG_DIR"/*.ms; do
	name="$(basename "$src" .ms)"

	"$MSC" build "$src" --target=c --output="$OUT/$name.cbin" >/dev/null 2>&1
	"$MSC" build "$src" --target=js >/dev/null 2>&1

	cout="$("$OUT/$name.cbin" 2>&1)"
	jsout="$(node "$REPO/out/$name.js" 2>&1)"

	if [ "$cout" = "$jsout" ]; then
		lines="$(printf '%s\n' "$cout" | wc -l | tr -d ' ')"
		printf '  \342\234\223 PASS %s (%s lines identical)\n' "$name" "$lines"
	else
		printf '  \342\234\227 FAIL %s\n      C : %s\n      JS: %s\n' "$name" "$cout" "$jsout"
		fails=$((fails + 1))
	fi
done

echo
if [ "$fails" -eq 0 ]; then
	echo "  all pass"
else
	echo "  $fails fail"
	exit 1
fi
