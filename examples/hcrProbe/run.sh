#!/usr/bin/env bash
# S0 single-image HCR probe: builds three generations of one module plus one
# corrupt candidate, then asserts the reload contract inside WSL.
#
# Contracts asserted (probe.wsl.sh):
#   1. body-only reload preserves lifted global state (pointer + values);
#   2. an incompatible _GlobalState layout is rejected loudly;
#   3. a failed reload never replaces the running image.
#
# This Windows host has no dlfcn.h in any Windows-targeting toolchain, so the
# module cross-builds to Linux ELF via zig (--os=linux) and the POSIX side
# (host build + dlopen execution) runs in WSL.
#
# Red on a compiler without entry-scoped HCR symbols: the g1 link fails with
# duplicate DatInit000/Init000.
#
# msc runs from the worktree root (its object cache lives there); `pwd` in
# this shell prints Windows backslash paths, so the WSL path is derived by
# rewriting that form.

set -euo pipefail
cd "$(dirname "$0")"
ROOT=../..
GEN=out/gen

mkdir -p $GEN/g1 $GEN/g2 $GEN/g3 $GEN/g4

MSC=${MSC:-./msc}
build() {
	( cd $ROOT && ${MSC} build "examples/hcrProbe/$1" --hcr --os=linux --cc=zig \
		--output="examples/hcrProbe/$GEN/$2/module.so" ) >out/$2.build.log 2>&1
}

build module.ms g1
build moduleBodyEdit.ms g2
build moduleLayoutEdit.ms g3

# g4: truncated image — dlopen must reject it without disturbing current.
head -c 512 $GEN/g2/module.so > $GEN/g4/module.so

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
		echo "PROBE FAIL: unhandled pwd form: $WINDIR" >&2
		exit 1
		;;
esac
exec wsl.exe -e bash -lc "bash '$WSLDIR/probe.wsl.sh' '$WSLDIR'"
