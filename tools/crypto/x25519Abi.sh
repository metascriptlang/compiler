#!/usr/bin/env bash
set -euo pipefail
out=${1:?usage: x25519Abi.sh <outDir> [pilot|monocypher]}
impl=${2:-pilot}
tools=$(cd "$(dirname "$0")" && pwd)
harness=src/test/crypto/harness

if [ -z "${MSC:-}" ]; then
	[ ! -e x25519AbiBuilder ] || { echo "x25519AbiBuilder already exists" >&2; exit 1; }
	cp "$(command -v msc)" x25519AbiBuilder
	trap 'rm -f x25519AbiBuilder' EXIT
	export MSC=$PWD/x25519AbiBuilder
fi

for mode in release danger; do
	for language in c cpp; do
		source=$harness/x25519TaintHost.c
		[ "$language" != cpp ] || source=$harness/x25519CppHost.cpp
		host=$(X25519_HOST_SOURCE=$source "$tools/x25519Build.sh" "$out" "$impl" "$mode")
		header=$out/entry.$impl.$mode.h
		[ -s "$header" ] || { echo "FAIL missing entry header: $header" >&2; exit 1; }
		log=$out/kat.$impl.$mode.$language.log
		"$host" >"$log"
		count=$(grep -c '^KAT ok ' "$log" || true)
		[ "$count" = 6 ] || { echo "FAIL $language $impl $mode: $count/6 KAT" >&2; exit 1; }
		grep -qx 'STAGE done' "$log"
	done
	cmp "$out/kat.$impl.$mode.c.log" "$out/kat.$impl.$mode.cpp.log"
	echo "ok ABI $impl $mode: C/C++ 6 KAT each, identical stdout"
done

echo "ALL ABI CHECKS PASSED"
