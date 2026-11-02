// @xfail(raiser): the Raiser VM has no actors and no per-thread cycle root sets, which this program pins
// @skip-js: the program pins per-thread cycle root sets, which the JS backend does not have
// @stdout: total 2400
// @serial
// note: the pool-worker twin of blockingWaitInActorMethodKeepsForeignContinuationsOffTheActorRoots. Spawned tasks start an async function and return while it is suspended, so its continuation waits on that worker's loop; Holder actors visited on the same worker block in a plain function's await, whose wait pumps the worker loop. The continuation frees a frame env from the worker's cycle roots, which used to happen under the actor's root set ("M1 owner violation at free"). The worker pump now runs outside the actor's roots, as the main loop already did.
// Run under MSCORPUS_SAN=1.

class Cyc { other: Cyc | null = null; v: int32 = 0; }

function mk(): Cyc {
	const a = new Cyc();
	const b = new Cyc();
	a.other = b;
	b.other = a;
	return a;
}

actor Store {
	commit(): int32 { return 1; }
}

async function foreign(s: Readonly<Store>, c: Cyc, g: Sendable<() => int32>): Promise<int32> {
	let n: int32 = 0;
	const bump = (): int32 => { n += 1; return n + c.v; };
	bump();
	await s.commit();
	await s.commit();
	return bump() + g();
}

function blocking(s: Store): int32 {
	return await s.commit();
}

actor Holder {
	run(s: Store): int32 {
		const y = await s.commit();
		return blocking(s) + blocking(s) + y;
	}
}

function starter(s: Readonly<Store>, k: int32): int32 {
	for (let j: int32 = 0; j < 4; j += 1) {
		const kk: int32 = k + j;
		foreign(s, mk(), () => kk);
	}
	return k;
}

async function main(): Promise<void> {
	const s = new Store();
	const holders: Holder[] = [];
	for (let i = 0; i < 8; i += 1) holders.push(new Holder());
	let total: int32 = 0;
	for (let r: int32 = 0; r < 100; r += 1) {
		const ts: Promise<int32>[] = [];
		for (let i: int32 = 0; i < 8; i += 1) { const ii: int32 = i; ts.push(spawn(() => starter(s, ii))); }
		const rs: Promise<int32>[] = [];
		for (const h of holders) rs.push(h.run(s));
		for (const t of ts) total += (await t) * 0;
		for (const x of rs) total += await x;
	}
	console.log(`total ${total}`);
}

await main();
