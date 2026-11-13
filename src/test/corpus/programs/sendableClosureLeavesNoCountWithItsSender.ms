// @skip-js: the program sends closures from spawned threads to actors, which the JS backend does not have
// @stdout: totals 3000 3000 3000 3000 400 400
// @serial
// note: a Sendable closure sent to an actor without a reply leaves no count on its env with the sender, whatever held it there: a binding with more calls after the send, a local function declaration, and a closure literal in an async function whose locals live in its frame. Each used to keep a plain count the sender dropped while the actor counted the same env on another thread. Run under MSCORPUS_SAN=1 and MSCORPUS_TSAN=1.

import { stop, ExitReason } from "std/actor";

actor Sink {
	total: int32 = 0;
	take(f: Sendable<() => int32>): void { this.total += f(); }
	read(): int32 { return this.total; }
}

function same(x: int32): int32 { return x; }

function spin(k: int32): int32 {
	let s: int32 = 0;
	for (let i = 0; i < k; i += 1) { s = (s + i) % 7; }
	return s;
}

async function main(): Promise<void> {
	const a = new Sink();
	const b = new Sink();
	const c = new Sink();
	const d = new Sink();
	const e = new Sink();
	const g = new Sink();
	const bound0 = spawn(() => {
		const n: int32 = same(1);
		for (let i = 0; i < 1000; i += 1) {
			const first: Sendable<() => int32> = () => n;
			a.take(first);
			const second: Sendable<() => int32> = () => n;
			b.take(second);
		}
		return 1000;
	});
	const bound1 = spawn(() => {
		const n: int32 = same(2);
		for (let i = 0; i < 1000; i += 1) {
			const first: Sendable<() => int32> = () => n;
			a.take(first);
			const second: Sendable<() => int32> = () => n;
			b.take(second);
		}
		return 1000;
	});
	const named0 = spawn(() => {
		const n: int32 = same(1);
		for (let i = 0; i < 1000; i += 1) {
			function first(): int32 { return n; }
			c.take(first);
			function second(): int32 { return n; }
			d.take(second);
		}
		return 1000;
	});
	const named1 = spawn(() => {
		const n: int32 = same(2);
		for (let i = 0; i < 1000; i += 1) {
			function first(): int32 { return n; }
			c.take(first);
			function second(): int32 { return n; }
			d.take(second);
		}
		return 1000;
	});
	await bound0;
	await bound1;
	await named0;
	await named1;
	const n: int32 = same(1);
	for (let i = 0; i < 400; i += 1) {
		const busy = spawn(() => spin(2000));
		e.take(() => n);
		g.take(() => n);
		await busy;
	}
	console.log(`totals ${await a.read()} ${await b.read()} ${await c.read()} ${await d.read()} ${await e.read()} ${await g.read()}`);
	stop(a.pid, ExitReason.Normal);
	stop(b.pid, ExitReason.Normal);
	stop(c.pid, ExitReason.Normal);
	stop(d.pid, ExitReason.Normal);
	stop(e.pid, ExitReason.Normal);
	stop(g.pid, ExitReason.Normal);
}

await main();
