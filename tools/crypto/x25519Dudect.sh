#!/usr/bin/env bash
set -uo pipefail
out=${1:?usage: x25519Dudect.sh <outDir> [impl]  (env knobs: tools/crypto/x25519Dudect.md)}
impl=${2:-monocypher}
tools=$(cd "$(dirname "$0")" && pwd)
harness=src/test/crypto/harness
measurements=${DUDECT_MEASUREMENTS:-5000}
batches=${DUDECT_BATCHES:-40}
modes=${DUDECT_MODES:-"release danger"}
leakSpin=${DUDECT_LEAK_SPIN:-10000}
limit=${DUDECT_TIMEOUT:-300}
seed=${DUDECT_SEED:-0x$(od -An -N8 -tx8 /dev/urandom | tr -d ' \n')}
failures=0

pinnedHeaderSha=3fb3b2bd7f9e17ae34b7c92518c1311c67342c56facc80da925d85f121b649da
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
[ "$(sha256 "$harness/dudect/dudect.h")" = "$pinnedHeaderSha" ] || { echo "FAIL dudect.h differs from the pin in $harness/dudect/PROVENANCE" >&2; exit 1; }

if [ -z "${MSC:-}" ]; then
	cp "$(command -v msc)" x25519DudectBuilder
	trap 'rm -f x25519DudectBuilder' EXIT
	export MSC=$PWD/x25519DudectBuilder
fi
mkdir -p "$out/dudect"

extras=()
case $(uname -m) in
	arm64 | aarch64) extras+=(-isystem "$harness/dudect/armShim") ;;
esac
extras+=(-isystem "$harness/dudect")
pin=()
[ -n "${DUDECT_CPU:-}" ] && command -v taskset >/dev/null && pin=(taskset -c "$DUDECT_CPU")

echo "platform $(uname -srm) cpu $(sed -n 's/^model name[^:]*: //p' /proc/cpuinfo 2>/dev/null | head -1)$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
echo "tsc flags: $(grep -m1 -owE 'constant_tsc|nonstop_tsc|tsc_reliable|tsc_known_freq' /proc/cpuinfo 2>/dev/null | sort -u | tr '\n' ' ')governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a) load $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || uptime)"
echo "clang $(clang --version | head -1)"
"$MSC" --version | sed 's/\x1b\[[0-9;]*m//g'
echo "dudect upstream oreparaz/dudect dc269651fb2567e46755cfb2a13d3875592968b5 header sha256 $pinnedHeaderSha"
implSources=("$harness/x25519HostEntry.ms")
case "$impl" in
	pure)
		implSources+=(std/crypto/pure/{x25519.ms,ed25519Field.ms,fe25519.ms,secret.cms}) ;;
	pilot)
		implSources+=(std/crypto/x25519/{pilot.cms,field.cms}) ;;
	monocypher)
		implSources+=(vendor/monocypher/src/{monocypher.c,monocypher.h}) ;;
	noop|leakyBranch|leakyIndex) ;;
	*)
		echo "FAIL unknown dudect implementation: $impl" >&2; exit 2 ;;
esac
allSrcs=("${implSources[@]}" "$harness/x25519DudectHost.c"
	tools/crypto/x25519Build.sh)
for source in "${allSrcs[@]}"; do
	[ -f "$source" ] || { echo "FAIL source not found: $source" >&2; exit 1; }
done
echo "source sha256: $(for source in "${allSrcs[@]}"; do printf '%s %s; ' "$(sha256 "$source" | cut -c1-16)" "$source"; done)"
echo "run impl=$impl modes=[$modes] measurementsPerBatch=$measurements batches=$batches seed=$seed cpu=${DUDECT_CPU:-unpinned} leakSpin=$leakSpin timeout=${limit}s"
echo "build x25519Build.sh: msc --app=staticlib -d:x25519Impl=<impl> --cc=clang --<mode> --lto=off; clang -O2 -g -Wall -Werror ${extras[*]} host.c lib.a -lm -lpthread"

build() {
	X25519_HOST_SOURCE=$harness/x25519DudectHost.c "$tools/x25519Build.sh" "$out/dudect" "$1" "$2" "" "${extras[@]}" 2>"$out/dudect/build.$1.$2.log" || {
		echo "FAIL build $1 $2"; tail -n 20 "$out/dudect/build.$1.$2.log"; failures=$((failures + 1)); return 1
	}
}

describe() {
	case $1 in
		0) echo "no leakage evidence within the bound" ;;
		10) echo "known answer failed" ;;
		16) echo "usage" ;;
		20) echo "dudect reported leakage" ;;
		21) echo "inconclusive: fewer than 10000 measurements per class" ;;
		124) echo "timeout" ;;
		*) echo "host did not run to its end" ;;
	esac
}

run() {
	local label=$1 want=$2 builtImpl=$3 mode=$4 log=$out/dudect/$1.log
	shift 4
	local host=$out/dudect/host.$builtImpl.$mode status summary
	if command -v timeout >/dev/null; then
		timeout "$limit" "${pin[@]}" "$host" --measurements "$measurements" --batches "$batches" --seed "$seed" "$@" >"$log" 2>&1
	else
		"${pin[@]}" "$host" --measurements "$measurements" --batches "$batches" --seed "$seed" "$@" >"$log" 2>&1
	fi
	status=$?
	summary="$(grep '^meas:' "$log" | tail -n 1 | sed 's/^meas: *//') | $(grep '^RESULT' "$log" | tail -n 1)"
	if [ "$status" = "$want" ]; then
		echo "ok   $label (status $status) $summary"
	else
		echo "FAIL $label: status $status, wanted $want ($(describe "$status")) $summary"
		tail -n 8 "$log"
		failures=$((failures + 1))
	fi
}

for mode in $modes; do
	build "$impl" "$mode" && {
		run "target-$impl-$mode" 0 "$impl" "$mode"
		run "null-$impl-$mode" 0 "$impl" "$mode" --null
		run "control-hostLeak-$impl-$mode" 20 "$impl" "$mode" --leak-spin "$leakSpin"
	}
	build leakyBranch "$mode" && run "control-leakyBranch-$mode" 20 leakyBranch "$mode" --no-kat
done

[ "$failures" = 0 ] && echo "ALL CHECKS PASSED" || { echo "$failures CHECK(S) FAILED"; exit 1; }
