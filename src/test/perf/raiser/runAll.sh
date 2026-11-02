#!/bin/bash
# usage: runAll.sh <msc> [runs]   one TSV row per program and run: program, wall_s, instructions_retired
msc=$1
runs=${2:-3}
here=$(cd "$(dirname "$0")" && pwd)
for prog in startup callFib objectTree stringConcat arrayOps unionDyn closureMapFilter; do
	for ((i = 0; i < runs; i++)); do
		"$here/measure.sh" "$msc" "$here/$prog.ms" raiser
	done
done
for prog in macroHeavy; do
	for ((i = 0; i < runs; i++)); do
		"$here/measure.sh" "$msc" "$here/$prog.ms" build
	done
done
for ((i = 0; i < runs; i++)); do
	"$here/measure.sh" "$msc" "$here/../../corpus/programs/506-jsonCodec.ms" build
done
