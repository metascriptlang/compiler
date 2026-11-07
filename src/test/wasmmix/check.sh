#!/usr/bin/env bash
set -uo pipefail

MSC=${MSC:-$([ -x ./msc ] && echo ./msc || echo msc)}
HARNESS=${HARNESS:-msc}
command -v emcc >/dev/null || { echo "check.sh: emcc not on PATH; source emsdk_env.sh first" >&2; exit 2; }

UNITS=(
	src/compiler/wasmBoundary/jsSideTest.ms
	src/compiler/wasmBoundary/manifestTest.ms
	src/compiler/wasmBoundary/wasmSideTest.ms
	src/compiler/wasmBoundary/wireKindsTest.ms
	src/compiler/wasmBoundary/placementBuild.ms
	src/test/js/wasmPlacement.ms
	src/test/js/wasmRefusals.ms
	src/test/wasmmix/spec.ms
)

red=0
for unit in "${UNITS[@]}"; do
	out=$("$MSC" test "$unit" --tests-in-dir 2>&1)
	rc=$?
	echo "unit $unit: $(grep -E 'Tests ' <<< "$out" | tail -1 | sed 's/^ *//')"
	[ $rc -eq 0 ] || { red=1; grep -E '×|FAIL' <<< "$out" | head -10; }
done

MSC="$MSC" "$HARNESS" run src/test/wasmmix/run.ms || red=1

[ $red -eq 0 ] && echo "js-wasm check: GREEN" || echo "js-wasm check: RED"
exit $red
