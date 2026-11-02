// @xfail(raiser): the Raiser VM has no actors and no per-thread cycle root sets, which this program pins
// @skip-js: the program pins per-thread cycle root sets, which the JS backend does not have
// @stdout: total 20700
// @serial
// note: an actor method calls a plain function that awaits a spawn, and that wait runs the queued task on its own thread. The task blocks on an await, whose wait runs the thread's loop while an async function of that thread resumes and frees a frame env from the thread's cycle roots. The inline task used to run with the actor's identity cleared but under the actor's root set, so that free failed "M1 owner violation at free". A task run inline by an actor's wait now runs outside the actor's roots, as it does on another worker.
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

async function foreign(s: Store, c: Cyc, g: Sendable<() => int32>): Promise<int32> {
	let n: int32 = 0;
	const bump = (): int32 => { n += 1; return n + c.v; };
	bump();
	await s.commit();
	await s.commit();
	return bump() + g();
}

function blocking(s: Readonly<Store>): int32 {
	return await s.commit();
}

function viaSpawn(s: Store): int32 {
	return await spawn(() => blocking(s));
}

actor Holder {
	run(s: Store): int32 {
		const y = await s.commit();
		return viaSpawn(s) + y;
	}
}

async function main(): Promise<void> {
	const h = new Holder();
	const s = new Store();
	let total: int32 = 0;
	for (let i = 0; i < 200; i += 1) {
		const kk: int32 = i;
		const f = foreign(s, mk(), () => kk);
		const r = await h.run(s);
		total += r + await f;
	}
	console.log(`total ${total}`);
}

await main();
