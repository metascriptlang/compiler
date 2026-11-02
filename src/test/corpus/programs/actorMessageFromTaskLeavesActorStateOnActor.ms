// @stdout: spawn send 1 call 2
// @stdout: sendable call 6
// @serial
import { stop, ExitReason } from "std/actor";

class Item { n: int32 = 1; }

class Cache {
	private items: Map<string, Item> = new Map<string, Item>();
	touch(key: string): int32 {
		this.items.delete(key);
		this.items.set(key, new Item());
		return this.items.size as int32;
	}
}

actor Store {
	private cache: Cache = new Cache();
	private hits: int32 = 0;
	record(key: string): void { this.hits += this.cache.touch(key); }
	recordCall(key: string): int32 { return this.cache.touch(key); }
	total(): int32 { return this.hits; }
}

actor Worker {
	private items: Map<string, Item> = new Map<string, Item>();
	run(k: int32): int32 {
		this.items.set("a", new Item());
		this.items.delete("a");
		return this.items.size as int32 + k;
	}
}

type Job = Sendable<(n: int32) => Promise<int32>>;

async function runJob(j: Job): Promise<int32> { return await j(6); }

async function main(): Promise<void> {
	const store = new Store();
	const sent = spawn(() => { store.record("x"); return 0; });
	await sent;
	const called = spawn(() => await store.recordCall("y"));
	console.log(`spawn send ${await store.total()} call ${await called}`);
	const w = new Worker();
	const job = async (n: int32): Promise<int32> => await w.run(n);
	console.log(`sendable call ${await runJob(job)}`);
	stop(store.pid, ExitReason.Normal);
	stop(w.pid, ExitReason.Normal);
}

await main();
