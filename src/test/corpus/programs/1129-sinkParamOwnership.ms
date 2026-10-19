// @maxrss: 30
// @stdout: sink-param-ownership 200000 400000 100000 400000 200000 200000 200000
struct Slot { text: string; tags: string[]; n: int32 }
class Box<T> {
	items: T[] = [];
	push(sink v: T) { this.items.push(v); }
}
class Holder {
	text: string;
	constructor(sink text: string) { this.text = text; }
}
function store(b: Box<string>, sink s: string): void { b.push(s); }
function storeSlot(b: Box<Slot>, sink slot: Slot): void { b.push(slot); }
function measure(sink s: string): number { return s.length; }
function reassigned(sink s: string, tail: string): number {
	s = s + tail;
	return s.length;
}
function oneBranch(b: Box<string>, sink s: string, keep: boolean): number {
	if (keep) {
		b.push(s);
		return 1;
	}
	return 0;
}

const pad = "x".repeat(160);
const strings = new Box<string>();
const slots = new Box<Slot>();
strings.items.push("");
slots.items.push({ text: "", tags: [], n: 0 });
let stored: number = 0;
let slotted: number = 0;
let dropped: number = 0;
let reassignedTotal: number = 0;
let branched: number = 0;
let held: number = 0;
let viaMove: number = 0;
for (let k = 0; k < 200000; k++) {
	const a = `${k} ${pad}`;
	store(strings, move a);
	strings.items.pop();
	stored += 1;
	slots.push({ text: `${k} ${pad}`, tags: [`t${k}`, pad], n: 2 });
	slotted += slots.items.pop()!.n;
	dropped += measure(`${k} ${pad}`) > 0 ? 2 : 0;
	reassignedTotal += reassigned(`${k} ${pad}`, pad) > 0 ? 1 : 0;
	const b = `${k} ${pad}`;
	branched += oneBranch(strings, b, k % 2 == 0) + oneBranch(strings, `${k} ${pad}`, false);
	if (k % 2 == 0) strings.items.pop();
	const h = new Holder(`${k} ${pad}`);
	held += h.text.length > 0 ? 1 : 0;
	const m = `${k} ${pad}`;
	strings.push(move m);
	strings.items.pop();
	viaMove += 1;
}
console.log("sink-param-ownership", stored, slotted, branched, dropped, reassignedTotal, held, viaMove);
