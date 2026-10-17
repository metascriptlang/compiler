// @stdout: mismatches 0 stops 17007 fast blocks 37614
// @skip-js: binds the C fixture guardFuzz.c, which drives the runtime's block-reduction helpers
// note: a fixed-seed differential fuzz of the block guard: per block, msSumFits/msDotFits and the plain sum against the checked
// loop, every width and += / -=; equal value when nothing overflows, the same stop element when something does.

@compile("./guardFuzz.c");

import { msTestBlockReduceMismatches, msTestBlockReduceStops, msTestBlockReduceFastBlocks } from "./guardFuzz.h";

function main(): void {
	const bad = msTestBlockReduceMismatches(4000);
	console.log(`mismatches ${bad} stops ${msTestBlockReduceStops()} fast blocks ${msTestBlockReduceFastBlocks()}`);
}

main();
