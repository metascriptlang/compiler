// @xfail(raiser): output differs from js: the Raiser prints 'late' before 'got 1'
// @serial

import { sleepAsync } from "std/core/promise";

async function late(): Promise<void> {
	await sleepAsync(20);
	console.log("late");
}

async function main(): Promise<void> {
	const h = spawn(() => { late(); return 1; });
	console.log(`got ${await h}`);
	await sleepAsync(300);
	console.log("end");
}

main();
