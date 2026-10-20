// @xfail(raiser): raiser runtime error: Unknown host function: msSetInterval
// @serial

import { sleepAsync } from "std/core/promise";

async function main(): Promise<void> {
	const h = spawn(() => {
		let ticks = 0;
		return setInterval(() => {
			ticks++;
			if (ticks == 1) console.log("ticking");
		}, 5);
	});
	const id = await h;
	await sleepAsync(200);
	clearInterval(id);
	console.log("cleared");
	await sleepAsync(50);
	console.log("end");
}

main();
