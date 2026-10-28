// @stdout: slept
// @stdout: void fn done
// @stdout: then ran
// @exit: 0
// note: a top-level await on a Promise<void> (a timer future and an async function with no result) reads the future as the void future it is; the card saw msFutureRead overrun the allocation of a smaller void future under ASan, so the pin runs in the SAN lane too

import { sleepAsync } from "std/core/promise";

async function work(): Promise<void> {
	await sleepAsync(1);
}

await sleepAsync(5);
console.log("slept");
await work();
console.log("void fn done");
await work().then((): void => { console.log("then ran"); });
