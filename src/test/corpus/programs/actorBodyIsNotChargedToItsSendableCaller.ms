// @stdout: call 6
// @stdout: send 4
// @stdout: spawn 6
// @xfail(raiser): error: Cannot resolve module 'std/actor'
import { stop, ExitReason } from "std/actor";

interface Box { f: (n: int32) => int32; }

actor Worker {
	private total: int32 = 0;
	run(n: int32): int32 {
		const box: Box = { f: (k: int32): int32 => k * 2 };
		return box.f(n);
	}
	post(n: int32): void {
		const box: Box = { f: (k: int32): int32 => k * 2 };
		this.total += box.f(n);
	}
	sum(): int32 { return this.total; }
}

type Job = Sendable<(n: int32) => Promise<int32>>;

async function runJob(j: Job, n: int32): Promise<int32> { return await j(n); }

async function main(): Promise<void> {
	const w = new Worker();
	const call = async (n: int32): Promise<int32> => await w.run(n);
	console.log(`call ${await runJob(call, 3)}`);
	const send = async (n: int32): Promise<int32> => { w.post(n); return await w.sum(); };
	console.log(`send ${await runJob(send, 2)}`);
	console.log(`spawn ${await spawn(() => await w.run(3))}`);
	stop(w.pid, ExitReason.Normal);
}

await main();
