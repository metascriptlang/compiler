// @xfail(raiser): the Raiser VM has no actors and no per-thread cycle root sets, which this program pins
// @skip-js: the program pins per-thread cycle root sets, which the JS backend does not have
// @stdout: call 64
// @stdout: send 64
// @stdout: done
// @serial
// note: a Sendable closure is sent to an actor while a sibling closure of the same function stays with the sender. Both used to read one env counted with plain rc on two threads, and the actor freed a cell rooted on the sender's thread ("M1 owner violation at free"). The sent closure now owns an env that holds copies of its captures. Reduced from a wings subscribe session. Covers the replying call through a sink parameter and the send without a reply.

class Node {
	next: Node | null = null;
}

struct Held {
	node: Node;
	actor: Keeper;
}

type Probe = Sendable<(n: int32) => int32>;

class Entry {
	id: int64;
	probe: Probe;
	constructor(id: int64, probe: Probe) {
		this.id = id;
		this.probe = probe;
	}
}

actor Keeper {
	entries: Map<int64, Entry> = new Map();
	attach(id: int64, probe: Probe): int64 {
		this.entries.set(id, new Entry(id, probe));
		return id;
	}
	put(id: int64, probe: Probe): void {
		this.entries.set(id, new Entry(id, probe));
	}
	detach(id: int64): int64 {
		this.entries.delete(id);
		return id;
	}
}

function attachTo(held: Readonly<Held>, id: int64, sink probe: Probe): int64 {
	const attached = held.actor.attach(id, probe);
	return id;
}

type Services = {
	open: Sendable<(id: int64) => Sendable<() => void>>;
	openSend: Sendable<(id: int64) => Sendable<() => void>>;
};

function services(held: Held): Services {
	return {
		open: (id: int64): Sendable<() => void> => {
			const base = id as int32;
			const got = attachTo(held, id, (n: int32): int32 => n + base);
			return () => { held.actor.detach(got); };
		},
		openSend: (id: int64): Sendable<() => void> => {
			const base = id as int32;
			held.actor.put(id, (n: int32): int32 => n + base);
			return () => { held.actor.detach(id); };
		},
	};
}

function openAndClose(open: Sendable<(id: int64) => Sendable<() => void>>, id: int64): void {
	const close = open(id);
	close();
}

async function main(): Promise<void> {
	const held: Held = { node: new Node(), actor: new Keeper() };
	const s = services(held);
	for (let i = 0; i < 64; i += 1) {
		openAndClose(s.open, i as int64);
		await sleepAsync(1);
	}
	console.log(`call ${await held.actor.detach(64)}`);
	for (let i = 0; i < 64; i += 1) {
		openAndClose(s.openSend, i as int64);
		await sleepAsync(1);
	}
	console.log(`send ${await held.actor.detach(64)}`);
	console.log("done");
}
main();
