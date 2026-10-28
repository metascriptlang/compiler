// @stdout: size 0
// @serial
// @ledger-slack(Hub) 1
// ledger-slack reason: its actor is never stopped, so it is still live at exit
// note: a closure inside Result.ok whose payload slot is Sendable, and one bound to a Sendable const, own their envs, so the actor frees them over its own root set while the sender keeps sibling closures.

struct Partition {
	label: string;
	tick: (n: int32) => int32;
}

class Entry {
	id: int64;
	snap: Sendable<(n: int32) => int32>;
	constructor(id: int64, snap: Sendable<(n: int32) => int32>) { this.id = id; this.snap = snap; }
}

actor Hub {
	entries: Map<int64, Entry> = new Map<int64, Entry>();
	attach(id: int64, snap: Sendable<(n: int32) => int32>): int64 {
		this.entries.set(id, new Entry(id, snap));
		return id;
	}
	detach(id: int64): void {
		this.entries.delete(id);
	}
	size(): int32 { return this.entries.size as int32; }
}

struct Services {
	viaResult: Sendable<(base: int32) => Sendable<() => void>>;
	viaBinding: Sendable<(base: int32) => Sendable<() => void>>;
}

function services(hub: Hub, partition: Partition): Services {
	return {
		viaResult: (base: int32): Sendable<() => void> => {
			const id: int64 = base;
			const width = partition.label.length as int32;
			const made: Result<Sendable<(n: int32) => int32>, string> = Result.ok((n: int32): int32 => n + width + base);
			if (!made.ok) { throw new Error(made.error); }
			const attached = hub.attach(id, made.value);
			return () => hub.detach(id);
		},
		viaBinding: (base: int32): Sendable<() => void> => {
			const id: int64 = base;
			const width = partition.label.length as int32;
			const snap: Sendable<(n: int32) => int32> = (n: int32): int32 => n + width + base;
			const attached = hub.attach(id, snap);
			return () => hub.detach(id);
		},
	};
}

async function main(): Promise<void> {
	const hub = new Hub();
	const partition: Partition = { label: "x", tick: (n: int32): int32 => n + 1 };
	const s = services(hub, partition);
	for (let i = 0; i < 20; i++) {
		const first = s.viaResult(i);
		const second = s.viaBinding(i + 100);
		first();
		second();
	}
	console.log(`size ${await hub.size()}`);
}

await main();
