// Parity program — a module reached through import() that statically imports a module
// the program already initialized at startup reuses it: the shared body runs once, before
// the importer's code, and the lazy body sees the shared state as the program left it.
//
// @stdout: shared body
// @stdout: main hit
// @stdout: lazy body sees 1
// @stdout: hits 2

import { hit } from "./shared";

async function run(): Promise<void> {
	const m = await import("./lazy");
	console.log(m.report());
}

hit();
console.log("main hit");
run();
