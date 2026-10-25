// @stdout: 1 timer a
// @stdout: 2 job from a
// @stdout: 3 timer b
// @stdout: 4 nested job from b
// @stdout: 5 timer c
// @stdout: 6 sleep a resumed
// @stdout: 7 job from sleep a
// @stdout: 8 nested job from sleep a
// @stdout: 9 sleep b resumed
// @xfail(raiser): raiser runtime error: Unknown host function: msSetTimeout

import { sleepAsync } from "std/core/promise";

async function sleeper(name: string, next: string): Promise<void> {
	await sleepAsync(20);
	console.log(name);
	if (next != "") {
		Promise.resolve(1).then((v: int32): void => {
			console.log("7 " + next);
			Promise.resolve(2).then((w: int32): void => { console.log("8 nested " + next); });
		});
	}
}

setTimeout((): void => {
	console.log("1 timer a");
	Promise.resolve(1).then((v: int32): void => { console.log("2 job from a"); });
}, 0);
setTimeout((): void => {
	console.log("3 timer b");
	Promise.resolve(1).then((v: int32): void => {
		Promise.resolve(2).then((w: int32): void => { console.log("4 nested job from b"); });
	});
}, 0);
setTimeout((): void => { console.log("5 timer c"); }, 0);
sleeper("6 sleep a resumed", "job from sleep a");
sleeper("9 sleep b resumed", "");
