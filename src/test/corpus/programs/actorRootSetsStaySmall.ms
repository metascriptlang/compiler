// @maxrss: 40
// @stdout: actor root sets 20000
// @serial
// @skip-raiser
// note: each live actor keeps a cycle root in its own root set; that set starts small, while the thread's root vector starts at 1024 cells (a 1024-cell start per actor measured 94 MB here on linux-x86_64, the small start 18.8 MB)

import { stop, ExitReason } from "std/actor";

class Cell {
	next: Cell | null = null;
	back: Cell | null = null;
}

actor Holder {
	head: Cell | null = null;
	constructor() {
		const a = new Cell();
		const b = new Cell();
		a.next = b;
		b.back = a;
		this.head = a;
	}
}

const pids: int64[] = [];
for (let i: int32 = 0; i < 20000; i++) {
	const h = new Holder();
	pids.push(h.pid);
}
console.log(`actor root sets ${pids.length}`);
for (const p of pids) stop(p, ExitReason.Normal);
