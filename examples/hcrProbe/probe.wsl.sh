#!/usr/bin/env bash
set -euo pipefail
cd "$1"

gcc -O1 -o out/hcrHost ../../runtime/hcrHost.c -ldl

SYMBOL=hcrProbeBump

# g4 is a truncated copy of g2; its pair only matters if dlopen wrongly succeeds.
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

S1p=$(sed -n 's/^HCR-PROBE loaded .* state=//p' out/probe.out)
S2p=$(sed -n 's/^HCR-PROBE reloaded .* state=//p' out/probe.out)
[ -n "$S1p" ] && [ "$S1p" = "$S2p" ] || fail "lifted state pointer changed across reload: '$S1p' -> '$S2p'"

line "HCR-PROBE call out/gen/g1/module.so -> 10"
line "HCR-PROBE call out/gen/g2/module.so -> 40"
line "HCR-PROBE rejected out/gen/g3/module.so (layout)"
line "HCR-PROBE call out/gen/g2/module.so -> 60"
line "HCR-PROBE rejected out/gen/g4/module.so (dlopen)"
line "HCR-PROBE call out/gen/g2/module.so -> 80"

grep -q "incompatible state layout change" out/probe.err || fail "missing loud layout diagnostic"

echo "PROBE PASS: state preserved, body-only swap visible, layout + bad-image rejected, current intact"
