// @stdout: size 0
// @serial
// @ledger-slack(Hub) 1
// ledger-slack reason: its actor is never stopped, so it is still live at exit
// note: a Sendable closure sent to an actor owns its env, so a sibling closure the sender keeps on the same scope never shares a cell with the actor.

struct Partition {
	label: string;
	tick: (n: int32) => int32;
}

struct Services {
	subscribe: Sendable<(base: int32) => Sendable<() => void>>;
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

function services(hub: Hub, partition: Partition): Services {
	return {
		subscribe: (base: int32): Sendable<() => void> => {
			const id: int64 = base;
			const width = partition.label.length as int32;
			const attached = hub.attach(id, (n: int32): int32 => n + width);
			return () => hub.detach(id);
		},
	};
}

async function main(): Promise<void> {
	const hub = new Hub();
	const partition: Partition = { label: "x", tick: (n: int32): int32 => n + 1 };
	const s = services(hub, partition);
	for (let i = 0; i < 20; i++) {
		const cancel = s.subscribe(i);
		cancel();
	}
	console.log(`size ${await hub.size()}`);
}

await main();
