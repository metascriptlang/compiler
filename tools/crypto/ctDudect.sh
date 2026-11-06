#!/usr/bin/env bash
# usage: ctDudect.sh <outDir> [case...]   run from the repo root on x86-64 or AArch64; MSC=<compiler that loads this tree's std>
# dudect timing over the native crypto port: builds src/test/crypto/ct/dudectRun.ms once (--danger, clang), then runs
# every case (default: all of `dudectRun --list`) as fixed-vs-random secret. leakyBranch must report leakage and the
# --null runs must not, or the run proves nothing. On x86-64 the cases with a hardware kernel run again with
# MS_CRYPTO_PORTABLE=1, so the portable code is timed too. A pass is "no leakage evidence within this bound".
# Knobs: DUDECT_MEASUREMENTS (per batch, default 2000), DUDECT_BATCHES (default 20), DUDECT_SEED (0x hex), DUDECT_TIMEOUT
# (seconds per case, default 600), DUDECT_CPU (taskset core).
set -uo pipefail
out=${1:?outDir}
shift
harness=src/test/crypto/harness
measurements=${DUDECT_MEASUREMENTS:-2000}
batches=${DUDECT_BATCHES:-20}
limit=${DUDECT_TIMEOUT:-600}
seed=${DUDECT_SEED:-0x$(od -An -N8 -tx8 /dev/urandom | tr -d ' \n')}
mkdir -p "$out"

pinnedHeaderSha=3fb3b2bd7f9e17ae34b7c92518c1311c67342c56facc80da925d85f121b649da
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
[ "$(sha256 "$harness/dudect/dudect.h")" = "$pinnedHeaderSha" ] || { echo "FAIL dudect.h differs from the pin in $harness/dudect/PROVENANCE" >&2; exit 1; }

if [ -z "${MSC:-}" ]; then
	cp "$(command -v msc)" ctDudectBuilder
	trap 'rm -f ctDudectBuilder' EXIT
	export MSC=$PWD/ctDudectBuilder
fi

arch=$(uname -m)
extra=()
case $arch in
	arm64 | aarch64) extra+=("--passC=-isystem$harness/dudect/armShim") ;;
esac
pin=()
[ -n "${DUDECT_CPU:-}" ] && command -v taskset >/dev/null && pin=(taskset -c "$DUDECT_CPU")

echo "platform $(uname -srm) cpu $(sed -n 's/^model name[^:]*: //p' /proc/cpuinfo 2>/dev/null | head -1)$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
echo "load $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || uptime) governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
echo "clang $(clang --version | head -1)"
"$MSC" --version | sed 's/\x1b\[[0-9;]*m//g' | head -1
echo "dudect upstream oreparaz/dudect dc269651fb2567e46755cfb2a13d3875592968b5 header sha256 $pinnedHeaderSha"
echo "run measurementsPerBatch=$measurements batches=$batches seed=$seed cpu=${DUDECT_CPU:-unpinned} timeout=${limit}s"

bin=$out/dudectRun
"$MSC" build src/test/crypto/ct/dudectRun.ms --danger --cc=clang --lto=off ${extra[@]+"${extra[@]}"} "--cache-dir=$out/cache" "--output=$bin" >"$out/build.log" 2>&1 \
	|| { echo "FAIL build"; tail -n 30 "$out/build.log"; exit 1; }

if [ "$#" -gt 0 ]; then cases=("$@"); else cases=(); while IFS= read -r c; do cases+=("$c"); done < <("$bin" --list); fi

ok=0 red=0
run() {
	local label=$1 want=$2 log=$out/$1.log status
	shift 2
	if command -v timeout >/dev/null; then
		timeout "$limit" ${pin[@]+"${pin[@]}"} "$@" >"$log" 2>&1
	else
		${pin[@]+"${pin[@]}"} "$@" >"$log" 2>&1
	fi
	status=$?
	local summary="$(grep '^meas:' "$log" | tail -n 1 | sed 's/^meas: *//') | $(grep '^RESULT' "$log" | tail -n 1)"
	if [ "$status" = "$want" ]; then
		echo "ok   $label (status $status) $summary"
		ok=$((ok + 1))
	else
		echo "FAIL $label: status $status, wanted $want $summary"
		tail -n 6 "$log"
		red=$((red + 1))
	fi
}

for c in "${cases[@]}"; do
	want=0
	[ "$c" = leakyBranch ] && want=20
	run "$c" "$want" "$bin" "$c" "$measurements" "$batches" "$seed"
	case $arch:$c in
		x86_64:aesGcmSeal | x86_64:aesCbcEncrypt | x86_64:xchachaSeal | x86_64:sha256 | x86_64:hmacSha256)
			run "$c-portable" "$want" env MS_CRYPTO_PORTABLE=1 "$bin" "$c" "$measurements" "$batches" "$seed" ;;
	esac
done
for c in x25519 aesGcmSeal; do
	run "null-$c" 0 "$bin" "$c" "$measurements" "$batches" "$seed" --null
done

echo "ctDudect: $ok ok, $red unexpected"
[ "$red" = 0 ]
