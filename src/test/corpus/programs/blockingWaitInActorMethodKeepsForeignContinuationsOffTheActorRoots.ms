// @xfail(raiser): the Raiser VM has no actors and no per-thread cycle root sets, which this program pins
// @skip-js: the program pins per-thread cycle root sets, which the JS backend does not have
// @stdout: total 20700
// @serial
// note: an actor method calls a plain function that blocks on an await, and the wait pumps the thread's loop while an async function of the same thread resumes and finishes. That frame env holds a Sendable closure, so it sits in the thread's cycle roots, and it used to be freed under the actor's root set ("M1 owner violation at free"). The wait now runs the loop outside the actor's roots, as it already ran it outside the actor's identity. Reduced from a wings subscribe session close.
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

function blocking(s: Store): int32 {
	return await s.commit();
}

actor Holder {
	run(s: Store): int32 {
		const y = await s.commit();
		return blocking(s) + y;
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
