#!/usr/bin/env bash
set -euo pipefail
cd "$1"

gcc -O1 -I../.. -o out/hcrHost ../../runtime/hcrHost.c -ldl

SYMBOL=hcrProbeBump

out/hcrHost --probe \
	"$SYMBOL" out/gen/g1/module.so \
	"$SYMBOL" out/gen/g2/module.so \
	"$SYMBOL" out/gen/g3/module.so \
	"$SYMBOL" out/gen/g4/module.so \
	>out/probe.out 2>out/probe.err

cat out/probe.out
cat out/probe.err >&2

fail() { echo "PROBE FAIL: $1"; exit 1; }
line() { grep -qxF "$1" out/probe.out || fail "missing line: $1"; }

S1p=$(sed -n 's/^HCR-PROBE loaded out\/gen\/g1\/module.so state=//p' out/probe.out)
S2p=$(sed -n 's/^HCR-PROBE reloaded out\/gen\/g2\/module.so state=//p' out/probe.out)
S3p=$(sed -n 's/^HCR-PROBE reloaded out\/gen\/g3\/module.so state=//p' out/probe.out)
[ -n "$S1p" ] && [ "$S1p" != "(nil)" ] && [ "$S1p" = "$S2p" ] && [ "$S1p" = "$S3p" ] \
	|| fail "count storage pointer changed: '$S1p' -> '$S2p' -> '$S3p'"

line "HCR-PROBE call out/gen/g1/module.so -> 10"
line "HCR-PROBE call out/gen/g2/module.so -> 40"
line "HCR-PROBE call out/gen/g3/module.so -> 30"
line "HCR-PROBE rejected out/gen/g4/module.so (dlopen)"
line "HCR-PROBE call out/gen/g3/module.so -> 40"

[ "$(wc -l <out/probe.out)" -eq 8 ] || fail "unexpected probe output"

echo "PROBE PASS: count preserved, body swap visible, added variable accepted, bad image rejected, current intact"
