// @xfail(raiser): the Raiser VM has no actors and no threads, which this program pins
// @skip-js: the program sends closures from spawned threads to actors, which the JS backend does not have
// @stdout: totals 5000 5000 5000 5000
// @serial
// note: four spawned threads each send 500 closures over a captured copy to each of four actors. A closure built in a function used to point at that function's frame env, which the sender and the actor counted with plain rc, so the count could be lost or the env freed under the sender's loop. Each closure now owns an env nothing on the sender touches after the send. Run under MSCORPUS_SAN=1 and MSCORPUS_TSAN=1.

import { stop, ExitReason } from "std/actor";

actor Sink {
	total: int32 = 0;
	take(f: Sendable<() => int32>): void { this.total += f(); }
	read(): int32 { return this.total; }
}

function same(x: int32): int32 { return x; }

async function main(): Promise<void> {
	const a = new Sink();
	const b = new Sink();
	const c = new Sink();
	const d = new Sink();
	const t0 = spawn(() => {
		const n: int32 = same(1);
		for (let i = 0; i < 500; i += 1) {
			a.take(() => n);
			b.take(() => n);
			c.take(() => n);
			d.take(() => n);
		}
		return 500;
	});
	const t1 = spawn(() => {
		const n: int32 = same(2);
		for (let i = 0; i < 500; i += 1) {
			a.take(() => n);
			b.take(() => n);
			c.take(() => n);
			d.take(() => n);
		}
		return 500;
	});
	const t2 = spawn(() => {
		const n: int32 = same(3);
		for (let i = 0; i < 500; i += 1) {
			a.take(() => n);
			b.take(() => n);
			c.take(() => n);
			d.take(() => n);
		}
		return 500;
	});
	const t3 = spawn(() => {
		const n: int32 = same(4);
		for (let i = 0; i < 500; i += 1) {
			a.take(() => n);
			b.take(() => n);
			c.take(() => n);
			d.take(() => n);
		}
		return 500;
	});
	await t0;
	await t1;
	await t2;
	await t3;
	console.log(`totals ${await a.read()} ${await b.read()} ${await c.read()} ${await d.read()}`);
	stop(a.pid, ExitReason.Normal);
	stop(b.pid, ExitReason.Normal);
	stop(c.pid, ExitReason.Normal);
	stop(d.pid, ExitReason.Normal);
}

await main();
