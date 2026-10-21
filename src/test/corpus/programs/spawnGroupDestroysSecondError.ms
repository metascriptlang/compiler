// @skip-js: a sync function awaits here, which the JS backend refuses (no blocking wait on JS, checker/syncAwait.ms); the program pins the native sync-context await
// @xfail(raiser): raiser runtime error: Unknown host function: msSpawn
// @serial
// @stdout: two caught 50|three caught 50|async caught 50
// note: `await Promise.all` of spawns rejects with the first failure, as in TS, and the group destroys every later child's error instead of dropping it; nothing is reported, since Promise.all handled each rejection. Two failing children, three, and the async join; the SAN lane checks the Error ledger balances (old compiler: Error destroy is about half of alloc).

function fail(why: string): int32 { throw new Error(why); }

function two(): boolean {
	try {
		const rs = await Promise.all([spawn((): int32 => fail("first")), spawn((): int32 => fail("second"))]);
		return rs[0] == 0;
	} catch (e) { return true; }
}

function three(): boolean {
	try {
		const rs = await Promise.all([spawn((): int32 => fail("a")), spawn((): int32 => fail("b")), spawn((): int32 => fail("c"))]);
		return rs[0] == 0;
	} catch (e) { return true; }
}

async function asyncTwo(): Promise<boolean> {
	try {
		const rs = await Promise.all([spawn((): int32 => fail("first")), spawn((): int32 => fail("second"))]);
		return rs[0] == 0;
	} catch (e) { return true; }
}

let a: int32 = 0;
let b: int32 = 0;
let c: int32 = 0;
for (let i = 0; i < 50; i += 1) {
	if (two()) a += 1;
	if (three()) b += 1;
	if (await asyncTwo()) c += 1;
}
console.log(`two caught ${a}|three caught ${b}|async caught ${c}`);
