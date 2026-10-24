// @xfail(raiser): raiser runtime error: Unknown host function: msSetTimeout
// @serial
// @xfail(san): the timer armed in the spawn task is dropped at exit, so its env and futures are never destroyed; card 2026-10-20-a-timer-armed-inside-a-spawn-task-is-dropped-at-exit.md

import { sleepAsync } from "std/core/promise";

async function late(): Promise<void> {
	await sleepAsync(10);
	console.log("fire-forget ran");
}

const h = spawn(() => {
	late();
	setTimeout(() => { console.log("timeout ran"); }, 60);
	return 1;
});
console.log("entry returns");
