// @stdout: act A1 B15
// @exit: 0
// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// note: two modules each keep a private actor `Counter`. An actor's init routine is a symbol owned by its module, so the two lower to distinct C functions; C used to define `Counter_init` twice and fail at link.

import { fromA } from "./a";
import { fromB } from "./b";

async function main(): Promise<void> {
	const a = await fromA();
	const b = await fromB();
	console.log("act " + a + " " + b);
}
await main();
