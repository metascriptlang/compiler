// @stdout: raised 100
// @stdout: awaited 100
// @stdout: nested 100
// @stdout: string 100
// @stdout: generator 100
// note: every shape of a bare `catch {}` around a suspend runs on every backend; the Raiser's program-end ledger
// and the SAN ledger are the leak signal. Hook counts are in bareCatchAcrossSuspendReleasesError.
async function reject(i: int32): Promise<int32> {
	await Promise.resolve(i);
	throw new Error(`reject ${i}`);
}

async function rejectString(i: int32): Promise<int32> {
	await Promise.resolve(i);
	throw "x";
}

function* guarded(): Iterator<int32> {
	try { yield 1; throw new Error("gen"); } catch {}
	yield 2;
}

async function main(): Promise<void> {
	let raised = 0;
	let awaited = 0;
	let nested = 0;
	let str = 0;
	let gen = 0;
	for (let i = 0; i < 100; i += 1) {
		try { await Promise.resolve(i); throw new Error("raised"); } catch {}
		raised += 1;
		try { await reject(i); } catch {}
		awaited += 1;
		try {
			try { await reject(i); } catch { await Promise.resolve(i); throw new Error("inner"); }
		} catch {}
		nested += 1;
		try { await rejectString(i); } catch {}
		str += 1;
		for (const v of guarded()) { if (v == 2) gen += 1; }
	}
	console.log(`raised ${raised}`);
	console.log(`awaited ${awaited}`);
	console.log(`nested ${nested}`);
	console.log(`string ${str}`);
	console.log(`generator ${gen}`);
}

await main();
