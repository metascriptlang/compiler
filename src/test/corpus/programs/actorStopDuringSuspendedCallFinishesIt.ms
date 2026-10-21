// @skip-js: lockedUpdate/lockedRead have no JS build, and the spawned task spins until main opens the gate, which needs a second thread
// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @stdout: values 20 noproc 20 bodies 20
// A stop that arrives while an actor method is suspended on its await lets that method finish:
// its CALL reply carries the value, and the CALL queued behind it fails with noproc. The spawned
// task holds the method suspended until main has sent the stop, so the order is fixed.
import { stop, ExitReason } from "std/actor";
import { sleepAsync, lockedUpdate, lockedRead } from "std/core/promise";

struct Gate { started: int32; open: int32; bodies: int32; }

actor Worker {
	n: int32;
	constructor() {
		this.n = 0;
	}
	work(g: Locked<Gate>): int32 {
		const r = await spawn(() => {
			lockedUpdate(g, (v: Gate): Gate => ({ started: v.started + 1, open: v.open, bodies: v.bodies }));
			while (lockedRead(g, (v: Gate): int32 => v.open) == 0) {}
			return 7;
		});
		this.n = this.n + r;
		lockedUpdate(g, (v: Gate): Gate => ({ started: v.started, open: v.open, bodies: v.bodies + 1 }));
		return r;
	}
	tag(): string {
		return "t" + this.n.toString();
	}
}

async function main(): Promise<void> {
	let values = 0;
	let noproc = 0;
	const g: Locked<Gate> = new Locked({ started: 0, open: 0, bodies: 0 });
	for (let i = 0; i < 20; i = i + 1) {
		const w = new Worker();
		const p = w.work(g);
		const q = w.tag();
		while (lockedRead(g, (v: Gate): int32 => v.started) <= i) { await sleepAsync(1); }
		stop(w.pid, ExitReason.Normal);
		lockedUpdate(g, (v: Gate): Gate => ({ started: v.started, open: 1, bodies: v.bodies }));
		try {
			if (await p == 7) { values = values + 1; }
		} catch (e) {
			console.log("work failed: " + e.message);
		}
		try {
			console.log("queued CALL ran: " + await q);
		} catch (e) {
			if (e.message.includes("noproc")) { noproc = noproc + 1; } else { console.log("queued CALL: " + e.message); }
		}
		lockedUpdate(g, (v: Gate): Gate => ({ started: v.started, open: 0, bodies: v.bodies }));
	}
	console.log("values " + values.toString() + " noproc " + noproc.toString() + " bodies " + lockedRead(g, (v: Gate): int32 => v.bodies).toString());
}
main();
