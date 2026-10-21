// @stdout: kept 64 sum 2016 head 0
// A ring the collector cannot prove dead (a module array holds it) survives 40 000 junk-ring
// collections and reads valid afterwards; the SAN lane sees no ASan report and a balanced ledger.
class Node {
	next: Node | null = null;
	tag: int32;
	constructor(tag: int32) { this.tag = tag; }
}
function makeRing(n: int32): Node {
	const head = new Node(0);
	let prev = head;
	for (let i: int32 = 1; i < n; i += 1) { const node = new Node(i); prev.next = node; prev = node; }
	prev.next = head;
	return head;
}
const kept: Node[] = [];
function churn(): int32 {
	let s: int32 = 0;
	for (let i: int32 = 0; i < 20000; i += 1) { const g = makeRing(3); s += g.tag; }
	return s;
}
function main(): void {
	kept.push(makeRing(64));
	churn();
	let n: int32 = 0;
	let sum: int32 = 0;
	let cur = kept[0];
	for (let i: int32 = 0; i < 64; i += 1) { sum += cur.tag; n += 1; const nx = cur.next; if (nx != null) cur = nx; }
	churn();
	console.log(`kept ${n} sum ${sum} head ${cur.tag}`);
}
main();
