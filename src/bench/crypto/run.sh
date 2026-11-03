#!/usr/bin/env bash
set -euo pipefail

ROUNDS=${1:-3}
HERE=src/bench/crypto
OUT=out/bench/crypto
MSC=${MSC:-$([ -x ./msc ] && echo ./msc || echo msc)}
NODE=${NODE:-node}
mkdir -p "$OUT"

"$MSC" build "$HERE/bench.ms" --release --output="$OUT/candidate" >/dev/null
arms=(candidate)
if [ -n "${MSBENCH_BASE:-}" ]; then
	"$MSBENCH_BASE" build "$HERE/bench.ms" --release --output="$OUT/base" >/dev/null
	arms+=(base)
fi
arms+=(node)

cpu=$( (sysctl -n machdep.cpu.brand_string 2>/dev/null || grep -m1 'model name' /proc/cpuinfo | cut -d: -f2) | sed 's/^ *//')
echo "host $(hostname -s) · $cpu · $(uname -sm)"
echo "commit ${MSBENCH_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)} · $("$MSC" --version 2>/dev/null | head -1) · node $("$NODE" --version)"
echo "load before $(uptime | sed 's/.*load averages*: //')"

: > "$OUT/runs.tsv"
for ((r = 1; r <= ROUNDS; r++)); do
	for arm in "${arms[@]}"; do
		if [ "$arm" = node ]; then "$NODE" "$HERE/bench.node.mjs"; else "$OUT/$arm"; fi |
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
