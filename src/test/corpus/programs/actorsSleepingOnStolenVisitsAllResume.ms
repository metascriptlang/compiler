// @stdout: done
// @stdout: nested done
// @exit: 0
// @serial
// note: eight actors created on the main thread each await sleepAsync per round, so idle workers steal their visits and arm the timers. A worker fires its own timers (A1): on Linux a worker parked with a resume still on its own callback queue (exit 13, unsettled await, every run); on Windows the loop thread fired a worker's timer and both threads changed the sleep future's count (heap-use-after-free under ASan, 9 of 30 plain runs crashed)
import { sleepAsync } from "std/core/promise";

actor Sleeper {
	nap(round: int64): int64 {
		await sleepAsync(0);
		return round;
	}
}

const sleepers: Sleeper[] = [];
for (let i = 0; i < 8; i++) { sleepers.push(new Sleeper()); }
for (let round: int64 = 0; round < 2000; round++) {
	const a = sleepers[0].nap(round);
	const b = sleepers[1].nap(round);
	const c = sleepers[2].nap(round);
	const d = sleepers[3].nap(round);
	const e = sleepers[4].nap(round);
	const f = sleepers[5].nap(round);
	const g = sleepers[6].nap(round);
	const h = sleepers[7].nap(round);
	const sum = (await a) + (await b) + (await c) + (await d) + (await e) + (await f) + (await g) + (await h);
	if (sum != round * 8) { console.log(`bad sum ${sum}`); }
}
console.log("done");

async function doze(round: int64): Promise<int64> {
	await sleepAsync(0);
	return round;
}

actor Dozer {
	dozeOff(round: int64): int64 {
		return await doze(round);
	}
}

const dozers: Dozer[] = [];
for (let i = 0; i < 4; i++) { dozers.push(new Dozer()); }
for (let round: int64 = 0; round < 500; round++) {
	const a = dozers[0].dozeOff(round);
	const b = dozers[1].dozeOff(round);
	const c = dozers[2].dozeOff(round);
	const d = dozers[3].dozeOff(round);
	const sum = (await a) + (await b) + (await c) + (await d);
	if (sum != round * 4) { console.log(`bad nested sum ${sum}`); }
}
console.log("nested done");
