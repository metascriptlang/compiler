#!/usr/bin/env bash
set -uo pipefail
out=${1:?usage: x25519Diff.sh <outDir> [samplesPerRandomAxis [seed [mode]]]   run from the repo root}
samples=${2:-2000}
seed=${3:-0x25519d1ff}
mode=${4:-all}
[ "$#" -le 4 ] || { echo "FAIL expected outDir [samplesPerRandomAxis [seed [mode]]]" >&2; exit 2; }
case "$mode" in
	all) modes=(release danger) ;;
	release|danger) modes=("$mode") ;;
	*) echo "FAIL unknown differential mode: $mode" >&2; exit 2 ;;
esac
success="REQUESTED CHECKS PASSED"
[ "$mode" = all ] && success="ALL CHECKS PASSED"
echo "SCOPE mode=$mode"
tools=$(cd "$(dirname "$0")" && pwd)
harness=src/test/crypto/harness
deps=$out/testDeps
failures=0
mkdir -p "$out"

if [ -z "${MSC:-}" ]; then
	cp "$(command -v msc)" x25519DiffBuilder
	trap 'rm -f x25519DiffBuilder' EXIT
	export MSC=$PWD/x25519DiffBuilder
fi

"$tools/provisionOracles.sh" "$deps" || { echo "FAIL provisioning the oracle packages" >&2; exit 1; }
lib=usr/lib/x86_64-linux-gnu
for a in libssl-dev/$lib/libcrypto.a libsodium-dev/$lib/libsodium.a libmbedtls-dev/$lib/libmbedcrypto.a; do
	echo "archive $a sha256 $(sha256sum "$deps/$a" | cut -d' ' -f1)"
done
echo "clang $(clang --version | head -1)"
"$MSC" --version | sed 's/\x1b\[[0-9;]*m//g'

clang -O2 -g -Wall -Werror -Ivendor/monocypher/src -c vendor/monocypher/src/monocypher.c -o "$out/monocypher.o" || { echo "FAIL compiling the Monocypher reference" >&2; exit 1; }
objcopy --redefine-sym crypto_x25519=ref_crypto_x25519 "$out/monocypher.o" "$out/monocypherRenamed.o" &&
	objcopy --keep-global-symbol=ref_crypto_x25519 "$out/monocypherRenamed.o" "$out/monocypherRef.o" || { echo "FAIL renaming the Monocypher reference symbol" >&2; exit 1; }
[ "$(nm "$out/monocypherRef.o" | grep -c ' T ref_crypto_x25519$')" = 1 ] || { echo "FAIL the reference object does not define ref_crypto_x25519 once" >&2; exit 1; }
echo "reference vendor/monocypher/src/monocypher.c sha256 $(sha256sum vendor/monocypher/src/monocypher.c | cut -d' ' -f1) as ref_crypto_x25519"

mbedArchive=$deps/libmbedtls-dev/$lib/libmbedcrypto.a
nm "$mbedArchive" 2>/dev/null | awk 'NF >= 2 && $NF ~ /^(mbedtls_|psa_)/ { print $NF " oracle_" $NF }' | sort -u >"$out/mbedtlsRename.map"
[ -s "$out/mbedtlsRename.map" ] || { echo "FAIL no mbedtls symbols found in $mbedArchive" >&2; exit 1; }
objcopy --redefine-syms="$out/mbedtlsRename.map" "$mbedArchive" "$out/libmbedcryptoOracle.a" || { echo "FAIL renaming the oracle mbedtls symbols" >&2; exit 1; }
echo "oracle mbedtls: $(wc -l <"$out/mbedtlsRename.map") symbols renamed to oracle_*, so the staticlib's own mbedtls cannot answer for it"

hostFlags=("-I$deps/libssl-dev/usr/include" "-I$deps/libssl-dev/usr/include/x86_64-linux-gnu" "-I$deps/libsodium-dev/usr/include"
	"-I$deps/libmbedtls-dev/usr/include" "$out/monocypherRef.o" "$out/libmbedcryptoOracle.a"
	"$deps/libsodium-dev/$lib/libsodium.a" "$deps/libssl-dev/$lib/libcrypto.a" -ldl)

build() {
	local impl=$1 mode=$2
	X25519_HOST_SOURCE=$harness/x25519DiffHost.c "$tools/x25519Build.sh" "$out" "$impl" "$mode" "" "${hostFlags[@]}" 2>"$out/build.$impl.$mode.log" >"$out/build.$impl.$mode.path" || {
		echo "FAIL build $impl $mode"; tail -n 20 "$out/build.$impl.$mode.log"; failures=$((failures + 1)); return 1; }
	hostPath=$(cat "$out/build.$impl.$mode.path")
	for sym in sodium_init crypto_scalarmult_curve25519 EVP_PKEY_derive EVP_PKEY_new_raw_private_key OpenSSL_version; do
		if nm "$out/x25519.$impl.$mode.a" 2>/dev/null | grep -q " [TDBW] $sym\$"; then
			echo "FAIL $impl $mode: the staticlib defines $sym, which would shadow the pinned oracle"; failures=$((failures + 1)); return 1
		fi
	done
	if ldd "$hostPath" | grep -E 'crypto|sodium|mbed' >&2; then
		echo "FAIL $impl $mode: host links an oracle library dynamically instead of the pinned archive"; failures=$((failures + 1)); return 1
	fi
}

expect() {
	local label=$1 want=$2 got=$3 must=$4 log=$5
	if [ "$got" != "$want" ]; then
		echo "FAIL $label: status $got, wanted $want"; tail -n 25 "$log"; failures=$((failures + 1)); return
	fi
	if [ -n "$must" ] && ! grep -q -- "$must" "$log"; then
		echo "FAIL $label: status $want but '$must' missing"; tail -n 25 "$log"; failures=$((failures + 1)); return
	fi
	echo "ok   $label (status $got${must:+, saw '$must'})"
}

run() {
	local label=$1 want=$2 must=$3 host=$4
	shift 4
	"$host" "$@" >"$out/$label.log" 2>&1
	expect "$label" "$want" "$?" "$must" "$out/$label.log"
}

for mode in "${modes[@]}"; do
	build pilot "$mode" || continue
	pilotHost=$hostPath
	run "diff-pilot-$mode" 0 "RESULT PASS" "$pilotHost" --candidate-label pilot --seed "$seed" --samples "$samples"
	grep -E '^(versions|STAGE|KAT|ITER|axis|    |adapter|TOTAL|RESULT)' "$out/diff-pilot-$mode.log" | grep -v '^    ' | head -60
	grep -E '^    ' "$out/diff-pilot-$mode.log" | head -45
	if [ "$mode" = release ]; then
		for target in candidate monocypher openssl libsodium mbedtls; do
			run "control-corrupt-$target" 20 "FAIL MISMATCH" "$pilotHost" --candidate-label pilot --seed "$seed" --samples 50 --corrupt "$target"
			if grep -q "CONTROL NOT APPLIED" "$out/control-corrupt-$target.log"; then
				echo "FAIL control-corrupt-$target: corruption never applied"; failures=$((failures + 1))
			fi
		done
		for target in openssl libsodium mbedtls; do
			run "control-refuse-$target" 21 "UNEXPECTED REFUSAL by $target" "$pilotHost" --candidate-label pilot --seed "$seed" --samples 50 --force-refuse "$target"
		done
		repro=$(sed -n 's/^    repro    //p' "$out/control-corrupt-openssl.log" | head -1)
		if [ -n "$repro" ]; then
			read -r -a reproArgv <<<"$repro"
			"${reproArgv[@]}" >"$out/control-repro.log" 2>&1
			expect "control-repro-openssl ($repro)" 20 "$?" "FAIL MISMATCH candidate vs openssl\|FAIL MISMATCH monocypher vs openssl" "$out/control-repro.log"
		else
			echo "FAIL control-repro: no repro line in the corrupt-openssl log"; failures=$((failures + 1))
		fi
		run "control-seed-changes-samples" 0 "RESULT PASS" "$pilotHost" --candidate-label pilot --seed 7 --samples 50
		build noop release && run "control-noop-candidate" 10 "KAT FAIL candidate" "$hostPath" --candidate-label noop --seed "$seed" --samples 50
		build monocypher release && run "diff-monocypher-candidate" 0 "RESULT PASS" "$hostPath" --candidate-label monocypher --seed "$seed" --samples "$samples"
	fi
done

[ "$failures" = 0 ] && echo "$success" || { echo "$failures CHECK(S) FAILED"; exit 1; }
