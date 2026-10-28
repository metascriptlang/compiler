// @stdout: total 310
// @stdout: size 0
// @serial
// @ledger-slack(Hub) 1
// ledger-slack reason: its actor is never stopped, so it is still live at exit
// note: a Sendable closure held in a struct field and sent to an actor from a nested routine copies its captures from every enclosing scope, so the actor frees it over its own root set.

struct Partition {
	label: string;
	tick: (n: int32) => int32;
}

struct Handler {
	name: string;
	run: Sendable<(n: int32) => int32>;
}

class Entry {
	id: int64;
	handler: Handler;
	constructor(id: int64, handler: Handler) { this.id = id; this.handler = handler; }
}

actor Hub {
	entries: Map<int64, Entry> = new Map<int64, Entry>();
	attach(id: int64, handler: Handler): int64 {
		this.entries.set(id, new Entry(id, handler));
		return id;
	}
	call(id: int64, n: int32): int32 {
		const entry = this.entries.get(id);
		return entry == null ? -1 : entry.handler.run(n);
	}
	detach(id: int64): void {
		this.entries.delete(id);
	}
	size(): int32 { return this.entries.size as int32; }
}

function connect(hub: Hub, partition: Partition, base: int32): Sendable<() => void> {
	const outer = partition.label.length as int32;
	function nested(): Sendable<() => void> {
		const id: int64 = base;
		const inner = outer + 1;
		const handler: Handler = { name: partition.label, run: (n: int32): int32 => n + inner + outer + base };
		const attached = hub.attach(id, handler);
		return () => hub.detach(id);
	}
	return nested();
}

async function main(): Promise<void> {
	const hub = new Hub();
	const partition: Partition = { label: "xy", tick: (n: int32): int32 => n + 1 };
	let total = 0;
	for (let i = 0; i < 20; i++) {
		const cancel = connect(hub, partition, i);
		total += await hub.call(i, 1);
		cancel();
	}
	console.log(`total ${total}`);
	console.log(`size ${await hub.size()}`);
}

await main();
