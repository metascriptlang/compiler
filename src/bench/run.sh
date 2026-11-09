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
NOBLE=${NOBLE:-out/bench/noble}
NOBLE_VERSION=2.4.0
mkdir -p "$OUT"

# An area lists its arms in $HERE/arms; base is the first arm's build by MSBENCH_BASE.
read -r -a wanted <<< "$(cat "$HERE/arms" 2>/dev/null || echo candidate node)"
[ -z "${MSBENCH_BASE:-}" ] || wanted=("${wanted[0]}" base "${wanted[@]:1}")
case " ${wanted[*]} " in *" lua"*) src/bench/buildLua.sh out/bench/lua ;; esac

build() { # <arm> <msc> <output>
	case $1 in
		candidate | c) "$2" build "$HERE/bench.ms" --release --output="$OUT/$3" >/dev/null ;;
		js | js-port) "$2" build "$HERE/bench.ms" --target=js --output="$OUT/$3.mjs" >/dev/null ;;
		mixed) "$2" build "$HERE/bench.ms" --target=js --danger --output="$OUT/$3.mjs" >/dev/null ;;
		jsonly) "$2" build "$HERE/bench.ms" --target=js --danger --wasm-placement=off --output="$OUT/$3.mjs" >/dev/null ;;
		mixed-chrome) "$2" build "$HERE/bench.ms" --target=js --danger --output="$OUT/$3.mjs" >/dev/null ;;
		neon)
			cargo build -q --release --manifest-path "$HERE/neon/Cargo.toml" --target-dir "$OUT/neon-target"
			for lib in libneonbench.dylib libneonbench.so neonbench.dll; do
				[ -f "$OUT/neon-target/release/$lib" ] && cp "$OUT/neon-target/release/$lib" "$OUT/neon.node"
			done
			[ -f "$OUT/neon.node" ] || { echo "run.sh: neon built no addon" >&2; exit 2; } ;;
		wasmbindgen)
			cargo build -q --release --target wasm32-unknown-unknown --manifest-path "$HERE/wasmbindgen/Cargo.toml" --target-dir "$OUT/wb-target"
			wasm-bindgen --target nodejs --out-dir "$OUT/wb" "$OUT/wb-target/wasm32-unknown-unknown/release/wbbench.wasm" ;;
		wasmbindgen-chrome)
			cargo build -q --release --target wasm32-unknown-unknown --manifest-path "$HERE/wasmbindgen/Cargo.toml" --target-dir "$OUT/wb-target"
			wasm-bindgen --target web --out-dir "$OUT/wbweb" "$OUT/wb-target/wasm32-unknown-unknown/release/wbbench.wasm" ;;
		rust) rustc -C opt-level=3 "$HERE/bench.rs" -o "$OUT/rust" ;;
		nim) nim c -d:danger --hints:off --nimcache:"$OUT/nimcache" -o:"$PWD/$OUT/nim" "$HERE/bench.nim" >/dev/null ;;
		yyjson-mut) cc -O3 -I"$MSBENCH_YYJSON/src" "$HERE/bench.yyjson.c" "$MSBENCH_YYJSON/src/yyjson.c" -lm -o "$OUT/yyjson-mut" ;;
	esac
}
runArm() { # <arm>
	case $1 in
		candidate | c | rust | nim | yyjson-mut) "$OUT/$1" ;;
		base)
			case ${wanted[0]} in
				raiser) "$MSBENCH_BASE" run --target=raiser "$HERE/bench.ms" ;;
				js | mixed | jsonly) "$NODE" "$OUT/base.mjs" ;;
				*) "$OUT/base" ;;
			esac ;;
		raiser) "$MSC" run --target=raiser "$HERE/bench.ms" ;;
		js) "$NODE" "$OUT/js.mjs" ;;
		# js-port: the js build with crypto.subtle removed, so every row, async included, runs the MetaScript port.
		js-port) "$NODE" --import "data:text/javascript,Object.defineProperty(globalThis.crypto,'subtle',{value:undefined,configurable:true})" "$OUT/js-port.mjs" ;;
		noble) MSBENCH_NOBLE="$PWD/$NOBLE" "$NODE" "$HERE/bench.noble.mjs" ;;
		mixed | jsonly) "$NODE" "$OUT/$1.mjs" ;;
		neon) NEON_ADDON="$PWD/$OUT/neon.node" "$NODE" "$HERE/neon/bench.mjs" ;;
		wasmbindgen) WB_MODULE="$PWD/$OUT/wb/wbbench.js" "$NODE" "$HERE/wasmbindgen/bench.mjs" ;;
		mixed-chrome) "$NODE" src/test/wasmmix/browser/runPage.mjs . "$OUT/mixed-chrome.mjs" --timeout-ms 900000 ;;
		wasmbindgen-chrome) "$NODE" src/test/wasmmix/browser/runPage.mjs . "$HERE/wasmbindgen/browser.mjs" --timeout-ms 900000 ;;
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
		# noble: @noble/hashes, curves and ciphers at NOBLE_VERSION, installed into $NOBLE on first use.
		noble)
			[ -f "$NOBLE/node_modules/@noble/curves/package.json" ] && grep -q "\"version\": \"$NOBLE_VERSION\"" "$NOBLE/node_modules/@noble/curves/package.json" ||
				npm install --silent --no-save --prefix "$NOBLE" "@noble/hashes@$NOBLE_VERSION" "@noble/curves@$NOBLE_VERSION" "@noble/ciphers@$NOBLE_VERSION"
			versions+=" · noble $NOBLE_VERSION" ;;
		# MSBENCH_RUST or MSBENCH_NIM names a twin binary built elsewhere, for a host that lacks that toolchain.
		rust)
			if [ -n "${MSBENCH_RUST:-}" ]; then cp "$MSBENCH_RUST" "$OUT/rust"; versions+=" · rust prebuilt $MSBENCH_RUST"
			else build rust; versions+=" · $(rustc --version) -C opt-level=3"; fi ;;
		nim)
			if [ -n "${MSBENCH_NIM:-}" ]; then cp "$MSBENCH_NIM" "$OUT/nim"; versions+=" · nim prebuilt $MSBENCH_NIM"
			else build nim; versions+=" · nim $(nim --version | head -1 | awk '{ print $4 }') -d:danger"; fi ;;
		# MSBENCH_YYJSON names a yyjson checkout; the twin is built from its src/ with the host's cc -O3.
		yyjson-mut)
			[ -n "${MSBENCH_YYJSON:-}" ] || { echo "skip $arm: no MSBENCH_YYJSON"; continue; }
			build yyjson-mut; versions+=" · yyjson $(cat "$MSBENCH_YYJSON/COMMIT" 2>/dev/null || git -C "$MSBENCH_YYJSON" rev-parse --short HEAD 2>/dev/null || echo unknown) cc -O3 ($(cc --version | head -1))" ;;
		luajit-*) [ -x "$LUAJIT" ] || { echo "skip $arm: no $LUAJIT"; continue; }; [ "$arm" = luajit-jon ] || versions+=" · $("$LUAJIT" -v | cut -d' ' -f1-2)" ;;
		lua54) [ -x "$LUA54" ] || { echo "skip $arm: no $LUA54"; continue; }; versions+=" · $("$LUA54" -v | cut -d' ' -f1-2)" ;;
		neon) command -v cargo >/dev/null || { echo "skip neon: no cargo"; continue; }; versions+=" · $(cargo --version | cut -d' ' -f1-2)"; build neon "$MSC" neon ;;
		wasmbindgen) command -v wasm-bindgen >/dev/null || { echo "skip wasmbindgen: no wasm-bindgen"; continue; }; versions+=" · $(wasm-bindgen --version)"; build wasmbindgen "$MSC" wasmbindgen ;;
		mixed | jsonly) versions+=" · node $("$NODE" --version)"; build "$arm" "$MSC" "$arm" ;;
		# CHROME names the browser runPage.mjs drives headless; without it the browser arms are skipped.
		mixed-chrome | wasmbindgen-chrome)
			[ -n "${CHROME:-}" ] || { echo "skip $arm: no CHROME"; continue; }
			case " ${arms[*]} " in *" mixed-chrome "* | *" wasmbindgen-chrome "*) ;; *) versions+=" · $("$CHROME" --version)" ;; esac
			build "$arm" "$MSC" "$arm" ;;
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
