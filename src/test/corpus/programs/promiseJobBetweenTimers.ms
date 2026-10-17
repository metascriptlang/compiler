// @stdout: 1 timer a
// @stdout: 2 job from a
// @stdout: 3 timer b
// @stdout: 4 sleep a resumed
// @stdout: 5 job from sleep a
// @stdout: 6 sleep b resumed
// @xfail(raiser): raiser runtime error: Unknown host function: msSetTimeout
// note: a callback queued by one expired timer runs before the next expired timer, as in TypeScript, for a setTimeout callback and for an awaited sleep alike.

import { sleepAsync } from "std/core/promise";

async function sleeper(name: string, next: string): Promise<void> {
	await sleepAsync(20);
	console.log(name);
	if (next != "") {
		Promise.resolve(1).then((v: int32): void => { console.log(next); });
	}
}

setTimeout((): void => {
	console.log("1 timer a");
	Promise.resolve(1).then((v: int32): void => { console.log("2 job from a"); });
}, 0);
setTimeout((): void => { console.log("3 timer b"); }, 0);
sleeper("4 sleep a resumed", "5 job from sleep a");
sleeper("6 sleep b resumed", "");
