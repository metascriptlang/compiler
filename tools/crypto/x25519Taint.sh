#!/usr/bin/env bash
# usage: x25519Taint.sh <outDir> [impl]   run from the repo root (impl defaults to monocypher; pilot after integration)
set -uo pipefail
out=${1:?outDir}
impl=${2:-monocypher}
tools=$(cd "$(dirname "$0")" && pwd)
deps=$out/testDeps
failures=0

if [ -z "${MSC:-}" ]; then
	cp "$(command -v msc)" x25519TaintBuilder
	trap 'rm -f x25519TaintBuilder' EXIT
	export MSC=$PWD/x25519TaintBuilder
fi

"$tools/provisionValgrind.sh" "$deps" || { echo "FAIL provisioning valgrind" >&2; exit 1; }
vgRoot=$deps
export VALGRIND_LIB=$deps/valgrind/usr/libexec/valgrind
vg=("$deps/valgrind/usr/bin/valgrind" --tool=memcheck --error-exitcode=99 --track-origins=yes --leak-check=no
	"--extra-debuginfo-path=$deps/debugroot")
echo "tool $("${vg[0]}" --version) clang $(clang --version | head -1)"
"$MSC" --version | sed 's/\x1b\[[0-9;]*m//g'

expect() {
	local label=$1 want=$2 got=$3 must=${4:-} log=$5
	if [ "$got" != "$want" ]; then
		echo "FAIL $label: status $got, wanted $want"; tail -n 20 "$log"; failures=$((failures + 1)); return
	fi
	if [ -n "$must" ] && ! grep -q "$must" "$log"; then
		echo "FAIL $label: status $want but '$must' missing"; tail -n 20 "$log"; failures=$((failures + 1)); return
	fi
	echo "ok   $label (status $got${must:+, saw '$must'})"
}

frameIn() {
	local label=$1 function=$2 log=$out/$1.log
	if ! grep -A1 -E "depends on uninitialised|Use of uninitialised" "$log" | grep -q "at 0x[0-9A-F]*: $function "; then
		echo "FAIL $label: first frame of the memcheck error is not in $function"; grep -m1 -A3 -E "uninitialised" "$log"; failures=$((failures + 1))
	fi
}

run() {
	local label=$1 want=$2 must=$3 host=$4
	shift 4
	local log=$out/$label.log
	"${vg[@]}" "$host" "$@" >"$log" 2>&1
	expect "$label" "$want" "$?" "$must" "$log"
}

native() {
	local label=$1 want=$2 must=$3 host=$4
	shift 4
	local log=$out/$label.log
	"$host" "$@" >"$log" 2>&1
	expect "$label" "$want" "$?" "$must" "$log"
}

for mode in release danger; do
	build() { "$tools/x25519Build.sh" "$out" "$1" "$mode" ${2:+"$2"} 2>"$out/build.$1.$mode.log" || { echo "FAIL build $1 $mode"; tail -n 20 "$out/build.$1.$mode.log"; failures=$((failures + 1)); return 1; }; }
	hostFor() { echo "$out/host.$1.$mode${2:+.taint}"; }

	build "$impl" && native "kat-native-$impl-$mode" 0 "STAGE kat ok" "$(hostFor "$impl")"
	build "$impl" "$vgRoot" && run "taint-$impl-$mode" 0 "STAGE taint ok" "$(hostFor "$impl" t)" --taint
	grep -q "ERROR SUMMARY: 0 errors from 0 contexts" "$out/taint-$impl-$mode.log" || { echo "FAIL taint-$impl-$mode: valgrind reported errors"; failures=$((failures + 1)); }

	build leakyBranch "$vgRoot" && run "control-leakyBranch-$mode" 99 "Conditional jump or move depends on uninitialised value" "$(hostFor leakyBranch t)" --no-kat --taint --no-output-taint-check
	frameIn "control-leakyBranch-$mode" x25519ScalarMult
	grep -q "STAGE taint ok" "$out/control-leakyBranch-$mode.log" || { echo "FAIL control-leakyBranch-$mode: host did not finish its stages, status 99 is not from the kernel alone"; failures=$((failures + 1)); }
	build leakyIndex "$vgRoot" && run "control-leakyIndex-$mode" 99 "Use of uninitialised value of size" "$(hostFor leakyIndex t)" --no-kat --taint --no-output-taint-check
	frameIn "control-leakyIndex-$mode" x25519ScalarMult
	grep -q "STAGE taint ok" "$out/control-leakyIndex-$mode.log" || { echo "FAIL control-leakyIndex-$mode: host did not finish its stages, status 99 is not from the kernel alone"; failures=$((failures + 1)); }
	build noop && native "control-noop-kat-$mode" 10 "KAT FAIL" "$(hostFor noop)"
	build noop "$vgRoot" && run "control-noop-taint-$mode" 14 "taint never reached the output" "$(hostFor noop t)" --no-kat --taint
done

[ "$failures" = 0 ] && echo "ALL CHECKS PASSED" || { echo "$failures CHECK(S) FAILED"; exit 1; }
