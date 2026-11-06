#!/usr/bin/env bash
# usage: ctTaint.sh <outDir> [case...]   run from the repo root on Linux x86_64 whose loader matches tools/crypto/pins.tsv
# Constant-time taint over the native crypto port: builds src/test/crypto/ct/taintRun.ms once (--danger), then runs
# every case (default: all of `taintRun --list`) in its own Valgrind memcheck process with the case's secret marked
# undefined. A memcheck error is a finding; leakyBranch and leakyIndex must produce one, noop must report that taint
# never reached its output (status 14), or the run proves nothing. argon2id must produce one too: its second half indexes
# memory by data (RFC 9106 3.4.1.3), so a clean argon2id would mean the taint stopped short. The build defines
# MS_CT_VALIDATION, which turns msDeclassify (runtime/crypto/ctValidation.h) on for verdicts the caller reveals. MSC=<compiler that loads this tree's std>.
set -uo pipefail
out=${1:?outDir}
shift
tools=$(cd "$(dirname "$0")" && pwd)
deps=$out/testDeps
mkdir -p "$out"

if [ -z "${MSC:-}" ]; then
	cp "$(command -v msc)" ctTaintBuilder
	trap 'rm -f ctTaintBuilder' EXIT
	export MSC=$PWD/ctTaintBuilder
fi

"$tools/provisionValgrind.sh" "$deps" || { echo "FAIL provisioning valgrind" >&2; exit 1; }
export VALGRIND_LIB=$deps/valgrind/usr/libexec/valgrind
vg=("$deps/valgrind/usr/bin/valgrind" --tool=memcheck --error-exitcode=99 --track-origins=yes --leak-check=no
	"--extra-debuginfo-path=$deps/debugroot")
echo "tool $("${vg[0]}" --version) clang $(clang --version | head -1)"
"$MSC" --version | sed 's/\x1b\[[0-9;]*m//g' | head -1

bin=$out/taintRun
"$MSC" build src/test/crypto/ct/taintRun.ms --danger --cc=clang --lto=off "--passC=-g" \
	"--passC=-I$deps/valgrind/usr/include" "--passC=-DMS_CT_VALIDATION" "--cache-dir=$out/cache" "--output=$bin" >"$out/build.log" 2>&1 \
	|| { echo "FAIL build"; tail -n 30 "$out/build.log"; exit 1; }

if [ "$#" -gt 0 ]; then cases=("$@"); else mapfile -t cases < <("$bin" --list); fi

firstFrame() {
	grep -m1 -A2 -E "depends on uninitialised|Use of uninitialised|uninitialised byte" "$1" | grep -m1 -oE "(at|by) 0x[0-9A-F]+: [^ ]+ \([^)]*\)" | sed -E 's/^(at|by) 0x[0-9A-F]+: //'
}

ok=0 red=0
for c in "${cases[@]}"; do
	log=$out/$c.log
	"${vg[@]}" "$bin" "$c" >"$log" 2>&1
	status=$?
	errors=$(sed -n 's/.*ERROR SUMMARY: \([0-9]*\) errors.*/\1/p' "$log" | tail -1)
	case "$c" in
		leakyBranch|leakyIndex) want=99 ;;
		argon2id) want=99 ;;
		noop) want=14 ;;
		*) want=0 ;;
	esac
	if [ "$status" = "$want" ] && { [ "$want" != 0 ] || [ "${errors:-x}" = 0 ]; }; then
		ok=$((ok + 1))
		if [ "$c" = argon2id ]; then
			echo "ok   $c (data-dependent by design, RFC 9106 3.4.1.3: $(firstFrame "$log"))"
		elif [ "$want" = 99 ]; then
			echo "ok   $c (control caught: $(firstFrame "$log"))"
		else
			echo "ok   $c (status $status, ${errors:-?} memcheck errors)"
		fi
	else
		red=$((red + 1))
		if [ "$status" = 99 ]; then
			echo "RED  $c finding: ${errors:-?} memcheck error(s), first in $(firstFrame "$log")"
		elif [ "$want" = 99 ]; then
			echo "RED  $c control missed: status $status, wanted a memcheck finding; the tool proves nothing"
		else
			echo "RED  $c status $status, wanted $want"
		fi
		grep -m1 -A8 -E "depends on uninitialised|Use of uninitialised|uninitialised byte|taint never|changed its output|Error|error" "$log" | sed 's/^/     /'
	fi
done
echo "ctTaint: $ok/$((ok + red)) cases as expected"
[ "$red" = 0 ]
