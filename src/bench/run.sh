#!/usr/bin/env bash
set -euo pipefail

AREA=${1:?usage: src/bench/run.sh <area> [rounds]}
ROUNDS=${2:-3}
HERE=src/bench/$AREA
OUT=out/bench/$AREA
MSC=${MSC:-$([ -x ./msc ] && echo ./msc || echo msc)}
NODE=${NODE:-node}
LUAJIT=${LUAJIT:-out/bench/lua/luajit}
LUA54=${LUA54:-out/bench/lua/lua54}
mkdir -p "$OUT"

# An area lists its arms in $HERE/arms; base is the first arm's build by MSBENCH_BASE.
read -r -a wanted <<< "$(cat "$HERE/arms" 2>/dev/null || echo candidate node)"
[ -z "${MSBENCH_BASE:-}" ] || wanted=("${wanted[0]}" base "${wanted[@]:1}")
case " ${wanted[*]} " in *" lua"*) src/bench/buildLua.sh out/bench/lua ;; esac

build() { # <arm> <msc> <output>
	case $1 in
		candidate | c) "$2" build "$HERE/bench.ms" --release --output="$OUT/$3" >/dev/null ;;
		rust) rustc -C opt-level=3 "$HERE/bench.rs" -o "$OUT/rust" ;;
		nim) nim c -d:danger --hints:off --nimcache:"$OUT/nimcache" -o:"$PWD/$OUT/nim" "$HERE/bench.nim" >/dev/null ;;
	esac
}
runArm() { # <arm>
	case $1 in
		candidate | c | rust | nim) "$OUT/$1" ;;
		base) if [ "${wanted[0]}" = raiser ]; then "$MSBENCH_BASE" run --target=raiser "$HERE/bench.ms"; else "$OUT/base"; fi ;;
		raiser) "$MSC" run --target=raiser "$HERE/bench.ms" ;;
		node) "$NODE" "$HERE/bench.node.mjs" ;;
		luajit-joff) "$LUAJIT" -joff "$HERE/bench.lua" ;;
		luajit-jon) "$LUAJIT" -jon "$HERE/bench.lua" ;;
		lua54) "$LUA54" "$HERE/bench.lua" ;;
		*) echo "run.sh: unknown arm $1" >&2; exit 2 ;;
	esac
}

arms=() versions=""
for arm in "${wanted[@]}"; do
	case $arm in
		base) build "${wanted[0]}" "$MSBENCH_BASE" base ;;
		node) versions+=" · node $("$NODE" --version)" ;;
		# MSBENCH_RUST or MSBENCH_NIM names a twin binary built elsewhere, for a host that lacks that toolchain.
		rust)
			if [ -n "${MSBENCH_RUST:-}" ]; then cp "$MSBENCH_RUST" "$OUT/rust"; versions+=" · rust prebuilt $MSBENCH_RUST"
			else build rust; versions+=" · $(rustc --version) -C opt-level=3"; fi ;;
		nim)
			if [ -n "${MSBENCH_NIM:-}" ]; then cp "$MSBENCH_NIM" "$OUT/nim"; versions+=" · nim prebuilt $MSBENCH_NIM"
			else build nim; versions+=" · nim $(nim --version | head -1 | awk '{ print $4 }') -d:danger"; fi ;;
		luajit-*) [ -x "$LUAJIT" ] || { echo "skip $arm: no $LUAJIT"; continue; }; [ "$arm" = luajit-jon ] || versions+=" · $("$LUAJIT" -v | cut -d' ' -f1-2)" ;;
		lua54) [ -x "$LUA54" ] || { echo "skip $arm: no $LUA54"; continue; }; versions+=" · $("$LUA54" -v | cut -d' ' -f1-2)" ;;
		*) build "$arm" "$MSC" "$arm" ;;
	esac
	arms+=("$arm")
done

cpu=$( (sysctl -n machdep.cpu.brand_string 2>/dev/null || grep -m1 'model name' /proc/cpuinfo | cut -d: -f2) | sed 's/^ *//')
echo "host $(hostname -s) · $cpu · $(uname -sm)"
echo "commit ${MSBENCH_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)} · $("$MSC" --version 2>/dev/null | head -1)$versions"
echo "load before $(uptime | sed 's/.*load averages*: //')"

: > "$OUT/runs.tsv"
for ((r = 1; r <= ROUNDS; r++)); do
	for arm in "${arms[@]}"; do
		runArm "$arm" |
			awk -v arm="$arm" '{ name = substr($0, 1, 28); sub(/ +$/, "", name); split(substr($0, 29), f, " "); print arm "\t" name "\t" f[1] "\t" f[2] }' >> "$OUT/runs.tsv"
	done
done
echo "load after $(uptime | sed 's/.*load averages*: //')"

awk -F'\t' -v arms="${arms[*]}" -v rounds="$ROUNDS" '
	function median(list,   n, v, i, j, t) {
		n = split(list, v, " ")
		for (i = 2; i <= n; i++) for (j = i; j > 1 && v[j - 1] + 0 > v[j] + 0; j--) { t = v[j]; v[j] = v[j - 1]; v[j - 1] = t }
		return n % 2 ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2
	}
	!($2 in seen) { seen[$2] = 1; order[++rows] = $2; unit[$2] = $4 }
	{ values[$1, $2] = values[$1, $2] " " $3 }
	END {
		n = split(arms, a, " ")
		printf "%-28s %-6s", "row (median of " rounds ")", "unit"
		for (i = 1; i <= n; i++) printf " %12s", a[i]
		printf "\n"
		for (r = 1; r <= rows; r++) {
			printf "%-28s %-6s", order[r], unit[order[r]]
			for (i = 1; i <= n; i++) printf " %12s", ((a[i], order[r]) in values) ? median(values[a[i], order[r]]) : "-"
			printf "\n"
		}
	}' "$OUT/runs.tsv"
