// PARALOCK scenario — async only.
//
// Covers: async function definition + composition + await cooperative
// yield. No spawn, no actors. Mirrors PARALOCK §6 baseline await
// lowering in async context.

import { msIoRunOnce } from "std/net";

async function asyncAdd(a: int32, b: int32): Promise<int32> {
	return (a + b) as int32;
}

async function asyncDouble(x: int32): Promise<int32> {
	return (x * 2) as int32;
}

async function asyncChain(x: int32): Promise<int32> {
	const d = await asyncDouble(x);
	const s = await asyncAdd(d, 5 as int32);
	return s;
}

async function run(): Promise<void> {
	const a = await asyncAdd(2 as int32, 3 as int32);
	if (a != (5 as int32)) { console.log("FAIL asyncAdd a=" + (a as int32)); return; }

	const b = await asyncDouble(4 as int32);
	if (b != (8 as int32)) { console.log("FAIL asyncDouble b=" + (b as int32)); return; }

	const c = await asyncChain(3 as int32);
	if (c != (11 as int32)) { console.log("FAIL asyncChain c=" + (c as int32)); return; }

	console.log("PASS: asyncOnly");
}

function main(): void {
	run();
	for (let i: int32 = 0 as int32; i < 50 as int32; i = (i + 1) as int32) {
		msIoRunOnce(10);
	}
}

main();
