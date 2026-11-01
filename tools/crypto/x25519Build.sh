#!/usr/bin/env bash
# usage: x25519Build.sh <outDir> <impl> <release|danger> [valgrindRoot [clangArg...]]   run from the repo root; prints the host path
# X25519_HOST_SOURCE=<file.c> replaces the host source (default x25519TaintHost.c); clangArg... are passed to clang
# verbatim, as separate arguments, right after the host source and the library (an empty valgrindRoot means no taint flags).
set -euo pipefail
out=${1:?outDir}
impl=${2:?impl: monocypher|pilot|noop|leakyBranch|leakyIndex}
mode=${3:?mode: release|danger}
vg=${4:-}
harness=src/test/crypto/harness
stem=x25519HostEntry
hostSource=${X25519_HOST_SOURCE:-$harness/x25519TaintHost.c}
lib=$out/x25519.$impl.$mode.a
host=$out/host.$impl.$mode${vg:+.taint}

mkdir -p "$out"
rm -f "$host"
"${MSC:-msc}" build "$harness/$stem.ms" --app=staticlib "-d:x25519Impl=$impl" --cc=clang "--$mode" --lto=off \
	"--cache-dir=$out/cache.$impl.$mode" "--output=$lib" >&2

mangle() {
	local s=$1 o="" c i
	for ((i = 0; i < ${#s}; i++)); do
		c=${s:i:1}
		case $c in
			[a-z0-9]) o+=$c ;;
			[A-Z]) o+=$(printf 'U%02X' "'$c") ;;
			*) echo "x25519Build: cannot mangle '$c'" >&2; return 1 ;;
		esac
	done
	printf '%sOms' "$o"
}
mangled=$(mangle "$stem")
symbols=$(nm "$lib")
findSymbol() {
	local found
	found=$(awk -v re="(^|Z)${mangled}__$1\$" '$2 == "T" && $3 ~ re { print $3 }' <<<"$symbols")
	[ "$(wc -l <<<"$found")" = 1 ] && [ -n "$found" ] || { echo "x25519Build: expected exactly one defined symbol ending ${mangled}__$1 in $lib, found: ${found:-none}" >&2; return 1; }
	printf '%s' "$found"
}
datInit=$(findSymbol DatInit000)
init=$(findSymbol Init000)
count=$(grep -c " T x25519ScalarMult\$" <<<"$symbols" || true)
[ "$count" = 1 ] || { echo "x25519Build: x25519ScalarMult defined $count times in $lib" >&2; exit 1; }
if grep -qw main <<<"$symbols"; then echo "x25519Build: $lib defines main" >&2; exit 1; fi

taintFlags=()
if [ -n "$vg" ]; then
	vg=$(cd "$vg" && pwd)
	taintFlags=(-DX25519_TAINT "-I$vg/valgrind/usr/include")
fi
clang -O2 -g -Wall -Werror "-DMS_ENTRY_DATINIT=$datInit" "-DMS_ENTRY_INIT=$init" "${taintFlags[@]}" \
	"$hostSource" "$lib" "${@:5}" -lm -lpthread -o "$host"
echo "$host"
