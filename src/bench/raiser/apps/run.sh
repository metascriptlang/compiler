#!/usr/bin/env bash
set -euo pipefail

ROUNDS=${1:-3}
MSC=${MSC:-msc}
MSC=$(cd "$(dirname "$MSC")" && pwd)/$(basename "$MSC")
cd "$(dirname "$0")"
OUT=../../../../out/bench/raiser/apps
mkdir -p "$OUT"
CC_FLAGS=()
[ "$(uname)" = Darwin ] && CC_FLAGS=(--cc=clang)

median() { sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'; }
field() { sed -n "s/.* $1=\([0-9]*\).*/\1/p"; }

printf '%-8s %10s %10s %8s  %s\n' app "c ms" "raiser ms" ratio check
for app in rowsEl haro; do
	"$MSC" build "$app.ms" --target=c --danger ${CC_FLAGS[@]+"${CC_FLAGS[@]}"} --output="$OUT/$app" >"$OUT/$app.build.log" 2>&1 || { cat "$OUT/$app.build.log" >&2; exit 1; }
	cMs=() rMs=()
	for ((i = 0; i < ROUNDS; i++)); do
		c=$("$OUT/$app")
		r=$("$MSC" run --target=raiser "$app.ms")
		[ "$(echo "$c" | field check)" = "$(echo "$r" | field check)" ] || { echo "run.sh: $app checksums differ: c '$c', raiser '$r'" >&2; exit 1; }
		cMs+=("$(echo "$c" | field ms)") rMs+=("$(echo "$r" | field ms)")
	done
	cMed=$(printf '%s\n' "${cMs[@]}" | median) rMed=$(printf '%s\n' "${rMs[@]}" | median)
	printf '%-8s %10s %10s %7.1fx  %s\n' "$app" "$cMed" "$rMed" "$(echo "$rMed / $cMed" | bc -l)" "$(echo "$c" | field check)"
done
