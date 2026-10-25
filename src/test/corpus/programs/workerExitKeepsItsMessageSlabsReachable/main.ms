// @stdout: 2-slot slab grown on a worker: true
// @stdout: 13-slot slab grown on a worker: true
// @skip-js: binds the C fixture slab.c, which drives a pool worker's message pool directly
// @skip-raiser: binds the C fixture slab.c, whose msTestGrowMessageSlabOnWorker has no Raiser host bridge
// note: a pool worker grows a message slab whose every message sits in its own free list when it
//   exits; the slab stays reachable after the exit, so the SAN lane's leak check reports nothing.

@include("./slab.h")
@compile("./slab.c")
extern function msTestGrowMessageSlabOnWorker(argCount: int32): int32;

function round(argCount: int32): int32 {
	const grown = await Promise.all([
		spawn((): int32 => msTestGrowMessageSlabOnWorker(argCount)),
		spawn((): int32 => msTestGrowMessageSlabOnWorker(argCount)),
		spawn((): int32 => msTestGrowMessageSlabOnWorker(argCount)),
		spawn((): int32 => msTestGrowMessageSlabOnWorker(argCount)),
	]);
	return grown[0] + grown[1] + grown[2] + grown[3];
}

function grownOnWorker(argCount: int32): boolean {
	for (let i: int32 = 0; i < 1000; i++) {
		if (round(argCount) > 0) return true;
	}
	return false;
}

console.log(`2-slot slab grown on a worker: ${grownOnWorker(2)}`);
console.log(`13-slot slab grown on a worker: ${grownOnWorker(13)}`);
