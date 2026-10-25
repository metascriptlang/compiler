// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @xfail(raiser): the Raiser VM runs no lifecycle hooks and frees a 1 000 000-link list recursively
// @stdout: chain 50 ok 50 hooks
// @stdout: chain 1000000 ok 1000000 hooks
// @stdout: deep-first 50 ok 100 hooks
// @stdout: deep-first 300000 ok 600000 hooks
// @stdout: deep-last 50 ok 100 hooks
// @stdout: deep-last 300000 ok 600000 hooks
// note: dropping a long list whose own class has an onDestroy finishes without overflowing the native stack; every hook runs once, before its node's fields are released (it still reads the next node), and in the order the shallow drop runs them: the hook, then the fields last to first. Sibling: dropDeepOrderAcrossBound (hooks on the leaves only)
const log: number[] = [];
let linked = 0;

class Node {
	id: number = 0;
	next: Node | null = null;
}
function onDestroy(this n: Node): void {
	log.push(n.id);
	if (n.next != null && n.next.id == n.id - 1) linked += 1;
}

class Pair {
	id: number;
	a: Pair | null = null;
	b: Pair | null = null;
	constructor(id: number) { this.id = id; }
	onDestroy(): void { log.push(this.id); }
}

function verdict(name: string, n: number, want: number[]): void {
	let bad: number = 0;
	if (log.length != want.length) bad += 1;
	for (let i = 0; i < want.length && i < log.length; i++) if (log[i] != want[i]) bad += 1;
	console.log(`${name} ${n} ${bad == 0 ? "ok" : "BAD " + bad.toString()} ${log.length} hooks`);
	log.length = 0;
}

function chainCase(n: number): void {
	const want: number[] = [];
	for (let i = n - 1; i >= 0; i--) want.push(i);
	let h: Node | null = null;
	for (let i = 0; i < n; i++) {
		const x = new Node();
		x.id = i;
		x.next = h;
		h = x;
	}
	log.length = 0;
	linked = 0;
	h = null;
	if (linked != n - 1) log.push(-1);
	verdict("chain", n, want);
}

function pairCase(name: string, n: number, deepFirst: boolean): void {
	const want: number[] = [];
	for (let i = n - 1; i >= 0; i--) {
		want.push(i * 10);
		if (deepFirst) want.push(i * 10 + 1);
	}
	if (!deepFirst) for (let i = 0; i < n; i++) want.push(i * 10 + 1);
	let h: Pair | null = null;
	for (let i = 0; i < n; i++) {
		const x = new Pair(i * 10);
		const leaf = new Pair(i * 10 + 1);
		if (deepFirst) {
			x.a = h;
			x.b = leaf;
		} else {
			x.b = h;
			x.a = leaf;
		}
		h = x;
	}
	log.length = 0;
	h = null;
	verdict(name, n, want);
}

chainCase(50);
chainCase(1000000);
pairCase("deep-first", 50, true);
pairCase("deep-first", 300000, true);
pairCase("deep-last", 50, false);
pairCase("deep-last", 300000, false);
