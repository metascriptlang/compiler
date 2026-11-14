// @skip-js: the program runs actors beside pool workers, which the JS backend does not have
// @stdout: totals 400 400 400 7
// @serial
// note: an awaited actor call lends its closure argument until the reply: the caller's frame keeps the closure, and the actor drops its own copy before the reply is completed, so the two never count the env at the same time. The actor used to drop its copy after the reply, on its own thread, while the caller's frame went on to drop its own. A closure handed to a method without a result is the actor's to keep. Run under MSCORPUS_SAN=1 and MSCORPUS_TSAN=1.

import { stop, ExitReason } from "std/actor";

class Box { v: int32 = 1; }

actor Sink {
	total: int32 = 0;
	kept: Sendable<() => int32> | null = null;
	apply(f: Sendable<() => int32>): int32 { this.total += f(); return this.total; }
	hold(f: Sendable<() => int32>): void { this.kept = f; }
	useKept(): int32 { const f = this.kept; return f != null ? f() : 0; }
	read(): int32 { return this.total; }
}

function same(x: int32): int32 { return x; }

function spin(k: int32): int32 {
	let s: int32 = 0;
	for (let i = 0; i < k; i += 1) { s = (s + i) % 7; }
	return s;
}

async function main(): Promise<void> {
	const overScalar = new Sink();
	const overObject = new Sink();
	const bound = new Sink();
	const keeper = new Sink();
	const n: int32 = same(1);
	const box = new Box();
	let last: int32 = 0;
	for (let i = 0; i < 400; i += 1) {
		const busy = spawn(() => spin(2000));
		last = await overScalar.apply(() => n);
		last = await overObject.apply(() => box.v);
		const f: Sendable<() => int32> = () => n;
		last = await bound.apply(f);
		last += await busy;
	}
	const seven: int32 = same(7);
	keeper.hold(() => seven);
	console.log(`totals ${await overScalar.read()} ${await overObject.read()} ${await bound.read()} ${await keeper.useKept()}`);
	stop(overScalar.pid, ExitReason.Normal);
	stop(overObject.pid, ExitReason.Normal);
	stop(bound.pid, ExitReason.Normal);
	stop(keeper.pid, ExitReason.Normal);
}

await main();
