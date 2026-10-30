// @xfail(raiser): the Raiser VM has no actors and no per-thread cycle root sets, which this program pins
// @stdout: open 1
// @stdout: beat enters
// @stdout: beat 1000
// @stdout: call 7
// @stdout: done
// @serial
// note: a guest that became a cycle root on the main thread is captured by a closure inside a struct moved into an actor's constructor. The actor later disowns a result whose custody walk goes through that closure env to the guest. Before the fix the guest kept its root entry in main's set and the walk stopped with "M1 owner violation". Reduced from a wings fact caller.

type Host = { get: () => int32 };
class CallState { db: Host | null = null; }
class Guest {
	state: CallState;
	constructor() { this.state = new CallState(); }
}
struct Info { name: string; call: (db: Host) => int32; }
function callGuest(guest: Guest, db: Host): int32 {
	guest.state.db = db;
	const got = db.get();
	guest.state.db = null;
	return got;
}
function touch(guest: Guest): void {
	const alias = guest;
	alias.state.db = null;
}
function load(): Info {
	const guest = new Guest();
	touch(guest);
	return { name: "m", call: (db: Host): int32 => callGuest(guest, db) };
}
class Worker {
	info: Info;
	n: int32 = 0;
	constructor(info: Info) { this.info = info; }
}
actor Caller {
	info: Info;
	worker: Worker | null = null;
	spare: Guest = new Guest();
	constructor(sink info: Info) { this.info = info; }
	open(): int32 {
		const info = this.info;
		this.worker = new Worker(info);
		return 1;
	}
	beat(): int32 {
		touch(this.spare);
		console.log("beat enters");
		const w = this.opened();
		let parts: Vec<string> = [];
		for (let i = 0; i < 1000; i++) { parts.push(`x${i}`); }
		w.n += parts.length;
		return w.n;
	}
	private opened(): Worker {
		const w = this.worker;
		if (w === null) { throw new Error("not open"); }
		return w;
	}
	call(): int32 {
		const w = this.worker;
		if (w === null) { return 0; }
		return w.info.call({ get: (): int32 => 7 });
	}
}
async function main(): Promise<void> {
	const info = load();
	const caller = new Caller(move info);
	console.log(`open ${await caller.open()}`);
	console.log(`beat ${await caller.beat()}`);
	console.log(`call ${await caller.call()}`);
	console.log("done");
}
await main();
