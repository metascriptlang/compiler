#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
GEN=out/gen

mkdir -p out/source "$GEN/g1" "$GEN/g2" "$GEN/g3" "$GEN/g4"

MSC=${MSC:-./msc}
case "$MSC" in
	/*|[A-Za-z]:/*) ;;
	*) MSC="$ROOT/$MSC" ;;
esac
PROBE_CC=zig
if [[ "$(uname -s)" == Linux ]]; then PROBE_CC=gcc; fi
build() {
	cp "$1" out/source/module.ms
	( cd out/source && "$MSC" build module.ms --hcr --os=linux "--cc=$PROBE_CC" \
		--output="../gen/$2/module.so" ) >"out/$2.build.log" 2>&1
}

build module.ms g1
build moduleBodyEdit.ms g2
build moduleLayoutEdit.ms g3

head -c 512 "$GEN/g3/module.so" > "$GEN/g4/module.so"

WINDIR=$(pwd | tr '\\' '/')
case "$WINDIR" in
	[A-Za-z]:/*)
		D=$(printf '%s' "${WINDIR:0:1}" | tr 'A-Z' 'a-z')
		WSLDIR="/mnt/$D${WINDIR:2}"
		;;
	/[A-Za-z]/*)
		WSLDIR="/mnt${WINDIR}"
		;;
	*)
		exec bash ./probe.wsl.sh "$WINDIR"
		;;
esac
exec wsl.exe -e bash -lc "bash '$WSLDIR/probe.wsl.sh' '$WSLDIR'"
