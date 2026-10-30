// @stdout: sync
// @stdout: promise
// @stdout: t0
// @stdout: t5
// @stdout: tick 1
// @stdout: tick 2
// @stdout: tick 3
// @stdout: done
// note: setTimeout runs after the promise callbacks already queued, in delay order; a cleared timeout never runs; an interval repeats until it is cleared.

import { sleepAsync } from "std/core/promise";

let ticks = 0;
let interval: number = 0;

async function main(): Promise<void> {
	const cancelled = setTimeout((): void => { console.log("cancelled"); }, 1);
	setTimeout((): void => { console.log("t5"); }, 5);
	setTimeout((): void => { console.log("t0"); }, 0);
	clearTimeout(cancelled);
	Promise.resolve(0).then((v: int32): void => { console.log("promise"); });
	console.log("sync");
	interval = setInterval((): void => {
		ticks += 1;
		console.log(`tick ${ticks}`);
		if (ticks == 3) clearInterval(interval);
	}, 10);
	while (ticks < 3) await sleepAsync(10);
	console.log("done");
}
main();
