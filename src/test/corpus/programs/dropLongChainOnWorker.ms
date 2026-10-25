// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @xfail(raiser): the Raiser VM frees a 1 000 000-link list recursively and overflows its own native stack, on the base compiler as well
// @stdout: worker chain 1000000 sum 499999500000
// @stdout: worker tags 300000 in order
// note: a spawned task runs on a pool thread whose stack is smaller than the main thread's; dropping a 1 000 000-link list there, and a 300 000-link list whose struct hooks must run deepest first, finishes without overflowing that stack
import { lockedUpdate, lockedRead } from "std/core/promise";

class Link {
	next: Link | null = null;
	v: number = 0;
}

struct Order { seen: number; bad: number; }
const order = new Locked<Order>({ seen: 0, bad: 0 });

struct Tag { id: number; }
function onDestroy(this t: Tag): void {
	const id = t.id;
	lockedUpdate(order, (o: Order): Order => {
		return { seen: o.seen + 1, bad: id != o.seen ? o.bad + 1 : o.bad };
	});
}

class Node {
	tag: Tag;
	next: Node | null = null;
	constructor(id: number) { this.tag = { id: id }; }
}

function chain(n: number): number {
	let head = new Link();
	for (let i = 1; i < n; i++) {
		const link = new Link();
		link.v = i;
		link.next = head;
		head = link;
	}
	let s: number = 0;
	let p: Link | null = head.next;
	while (p != null) {
		s += p.v;
		p = p.next;
	}
	return s + head.v;
}

function tags(n: number): string {
	let h: Node | null = null;
	for (let i = 0; i < n; i++) {
		const x = new Node(i);
		x.next = h;
		h = x;
	}
	lockedUpdate(order, (o: Order): Order => { return { seen: 0, bad: 0 }; });
	h = null;
	const o = lockedRead(order, (o: Order): Order => { return o; });
	return o.seen == n && o.bad == 0 ? "in order" : `seen ${o.seen} bad ${o.bad}`;
}

const s = await spawn(() => chain(1000000));
console.log(`worker chain 1000000 sum ${s}`);
const t = await spawn(() => tags(300000));
console.log(`worker tags 300000 ${t}`);
