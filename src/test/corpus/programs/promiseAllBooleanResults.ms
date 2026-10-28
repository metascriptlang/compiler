// @stdout: async true true
// @stdout: spawn true
// @stdout: mixed true false true
// @stdout: each true false true
// @stdout: spawned mixed false true false
// @stdout: uint8 1 2
// @exit: 0
// note: Promise.all over boolean promises collects the values (old C: every element read false, the collector wrote doubles into a uint8 array); the elements read through await and spawn results are checked beside it

async function yes(): Promise<boolean> { return true; }
async function no(): Promise<boolean> { return false; }

async function run(): Promise<void> {
	const both = await Promise.all([yes(), yes()]);
	console.log("async", both[0], both[1]);
	const s = await Promise.all([spawn(() => true)]);
	console.log("spawn", s[0]);
	const mixed = await Promise.all([yes(), no(), yes()]);
	console.log("mixed", mixed[0], mixed[1], mixed[2]);
	console.log("each", await yes(), await no(), await yes());
	const sm = await Promise.all([spawn(() => false), spawn(() => true), spawn(() => false)]);
	console.log("spawned mixed", sm[0], sm[1], sm[2]);
	const u = await Promise.all([spawn((): uint8 => 1 as uint8), spawn((): uint8 => 2 as uint8)]);
	console.log("uint8", u[0], u[1]);
}
await run();
