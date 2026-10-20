// @xfail(raiser): raiser runtime error: Unknown host function: msSetTimeout
// @serial

import { sleepAsync } from "std/core/promise";

async function main(): Promise<void> {
	const h = spawn(() => {
		setTimeout(() => { console.log("timeout fired"); }, 10);
		return 1;
	});
	console.log(`got ${await h}`);
	await sleepAsync(300);
	console.log("end");
}

main();
