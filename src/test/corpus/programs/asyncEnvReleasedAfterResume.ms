// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: destroyed 7
// @stdout: caught
// @stdout: destroyed 8
// @stdout: settled 8
// @stdout: then 9
// @stdout: destroyed 9
// @stdout: end
// note: the locals of an async function that resumed after an await, and the captures of a .then callback, are destroyed once it finishes, whether it returned or threw.

class Box {
	n: int32 = 0;
	onDestroy(): void { console.log(`destroyed ${this.n}`); }
}

async function throwsAfterAwait(): Promise<int32> {
	const b = new Box();
	b.n = 7;
	await Promise.resolve(0);
	if (b.n == 7) throw new Error("x");
	return 1;
}

async function settlesAfterAwait(): Promise<int32> {
	const b = new Box();
	b.n = 8;
	await Promise.resolve(0);
	return b.n;
}

function viaThen(): Promise<void> {
	const b = new Box();
	b.n = 9;
	return Promise.resolve(0).then((x: int32): void => { console.log(`then ${b.n}`); });
}

async function main(): Promise<void> {
	try { await throwsAfterAwait(); } catch (e) { console.log("caught"); }
	const r = await settlesAfterAwait();
	console.log(`settled ${r}`);
	await viaThen();
	console.log("end");
}
await main();
