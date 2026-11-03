#!/bin/bash
# usage: measure.sh <msc> <program.ms> [raiser|build]   prints: program <TAB> wall_s <TAB> instructions_retired
msc=$1
prog=$2
mode=${3:-raiser}
out=$(mktemp)
if [ "$mode" = raiser ]; then
	/usr/bin/time -l "$msc" run --target=raiser "$prog" >/dev/null 2>"$out"
else
	/usr/bin/time -l "$msc" build "$prog" --output="$(mktemp -u)" >/dev/null 2>"$out"
fi
status=$?
if [ "$status" != 0 ]; then
	printf '%s\tFAILED exit %s\n' "$(basename "$prog")" "$status"
	cat "$out" >&2
	exit 1
fi
wall=$(awk '/ real /{print $1}' "$out")
instr=$(awk '/instructions retired/{print $1}' "$out")
printf '%s\t%s\t%s\n' "$(basename "$prog")" "$wall" "$instr"
rm -f "$out"
