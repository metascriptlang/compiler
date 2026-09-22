#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
ROOT=../..
OUT=out/windows
GEN=$OUT/gen
MSC=${MSC:-./msc}

mkdir -p $GEN/g1 $GEN/g2 $GEN/g3 $GEN/g4

build() {
	( cd $ROOT && ${MSC} build "examples/hcrProbe/$1" --hcr \
		--output="examples/hcrProbe/$GEN/$2/module.dll" ) >$OUT/$2.build.log 2>&1
}

build module.ms g1
build moduleBodyEdit.ms g2
build moduleLayoutEdit.ms g3
head -c 512 $GEN/g2/module.dll >$GEN/g4/module.dll

( cd $ROOT && ${MSC} build examples/hcrProbe/hostWindows.ms \
	--output=examples/hcrProbe/$OUT/hcrHostWindows.exe ) >$OUT/host.build.log 2>&1

WINDIR=$(pwd | tr '\\' '/')
"$WINDIR/$OUT/hcrHostWindows.exe" \
	$GEN/g1/module.dll \
	$GEN/g2/module.dll \
	$GEN/g3/module.dll \
	$GEN/g4/module.dll \
	>$OUT/probe.out 2>$OUT/probe.err

cat $OUT/probe.out
cat $OUT/probe.err >&2

fail() { echo "PROBE FAIL: $1"; exit 1; }
line() { grep -qxF "$1" $OUT/probe.out || fail "missing line: $1"; }

S1p=$(sed -n 's/^HCR-PROBE loaded .* state=//p' $OUT/probe.out)
S2p=$(sed -n 's/^HCR-PROBE reloaded .* state=//p' $OUT/probe.out)
[ -n "$S1p" ] && [ "$S1p" = "$S2p" ] || fail "lifted state pointer changed across reload: '$S1p' -> '$S2p'"

line "HCR-PROBE call $GEN/g1/module.dll -> 10"
line "HCR-PROBE call $GEN/g2/module.dll -> 40"
line "HCR-PROBE rejected $GEN/g3/module.dll (layout)"
line "HCR-PROBE call $GEN/g2/module.dll -> 60"
line "HCR-PROBE rejected $GEN/g4/module.dll (load)"
line "HCR-PROBE call $GEN/g2/module.dll -> 80"

grep -q "incompatible state layout change" $OUT/probe.err || fail "missing loud layout diagnostic"
grep -q "LoadLibraryA failed" $OUT/probe.err || fail "missing loud bad-image diagnostic"

echo "PROBE PASS: native Windows state preserved, body-only swap visible, layout + bad-image rejected, current intact"
