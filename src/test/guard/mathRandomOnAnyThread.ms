// INVARIANT: ULTRALOCK V0 (Math.random keeps its generator per thread, so no thread shares it).
// RED MEANS: Math.random is refused from an actor or a spawn thunk on one backend, or leaves [0, 1).
// GUARD-JS

import { exit } from "std/process";

actor Roller {
	roll(): float64 { return Math.random(); }
}

function inRange(x: float64): boolean {
	return x >= 0.0 && x < 1.0;
}

const roller = new Roller();
const task = spawn((): float64 => Math.random());
const fromActor = await roller.roll();
const fromTask = await task;
const fromMain = Math.random();
if (!inRange(fromActor) || !inRange(fromTask) || !inRange(fromMain)) {
	console.log(`GUARD-FAIL ${fromActor} ${fromTask} ${fromMain}`);
	exit(1);
}
console.log("GUARD-OK");
