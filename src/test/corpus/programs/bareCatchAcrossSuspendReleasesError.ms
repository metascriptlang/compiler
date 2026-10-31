// @xfail(raiser): the Raiser VM runs no user lifecycle hooks
// @skip-js: onDestroy runs where the DRC runs; JS has no destructors
// @stdout: raised caught=100 freed=100
// @stdout: awaited caught=100 freed=100
// @stdout: nested caught=100 freed=200
// @stdout: generator caught=100 freed=100
// @stdout: finally caught=100 freed=200
// @stdout: string caught=100
// @serial
// note: a state-machine try with no catch binding holds the caught Error in `$curExc` and destroys
// it like a written `catch (e)` does (old compiler: freed=0 and the SAN ledger counted one Error
// per caught raise, because the holder fell back to a raw pointer with no destroy hook).
let freed = 0;
class Boom extends Error {}
function onDestroy(this b: Boom): void { freed += 1; }

async function boom(i: int32): Promise<int32> {
	await Promise.resolve(i);
	throw new Boom(`boom ${i}`);
}

async function bareString(i: int32): Promise<int32> {
	await Promise.resolve(i);
	throw "x";
}

async function raised(): Promise<int32> {
	let caught = 0;
	for (let i = 0; i < 100; i += 1) {
		try { await Promise.resolve(i); throw new Boom("raised"); } catch {}
		caught += 1;
	}
	return caught;
}

async function awaited(): Promise<int32> {
	let caught = 0;
	for (let i = 0; i < 100; i += 1) {
		try { await boom(i); } catch {}
		caught += 1;
	}
	return caught;
}

async function nested(): Promise<int32> {
	let caught = 0;
	for (let i = 0; i < 100; i += 1) {
		try {
			try { await boom(i); } catch { await Promise.resolve(i); throw new Boom("inner"); }
		} catch {}
		caught += 1;
	}
	return caught;
}

function* guarded(): Iterator<int32> {
	try { yield 1; throw new Boom("gen"); } catch {}
	yield 2;
}

async function viaFinally(): Promise<int32> {
	let caught = 0;
	for (let i = 0; i < 100; i += 1) {
		try {
			try { await boom(i); } finally { caught += 1; }
		} catch {}
		try { await Promise.resolve(i); throw new Boom("fin"); } catch {} finally { caught += 0; }
	}
	return caught;
}

async function fromString(): Promise<int32> {
	let caught = 0;
	for (let i = 0; i < 100; i += 1) {
		try { await bareString(i); } catch {}
		caught += 1;
	}
	return caught;
}

async function main(): Promise<void> {
	console.log(`raised caught=${await raised()} freed=${freed}`);
	freed = 0;
	console.log(`awaited caught=${await awaited()} freed=${freed}`);
	freed = 0;
	console.log(`nested caught=${await nested()} freed=${freed}`);
	freed = 0;
	let gen = 0;
	for (let i = 0; i < 100; i += 1) {
		for (const v of guarded()) { if (v == 2) gen += 1; }
	}
	console.log(`generator caught=${gen} freed=${freed}`);
	freed = 0;
	console.log(`finally caught=${await viaFinally()} freed=${freed}`);
	console.log(`string caught=${await fromString()}`);
}

await main();
