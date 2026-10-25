// @xfail(raiser): raiser runtime error: Unknown host function: msSetTimeout
// @serial

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
