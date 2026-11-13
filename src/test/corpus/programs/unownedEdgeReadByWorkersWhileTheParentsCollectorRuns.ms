// @skip-js: the program awaits spawns in a sync function, and JS has no blocking wait
// @stdout: total 1200000 parent 5995
// note: workers read an Unowned edge of a lent holder while the parent's collector, run by its own garbage, trial-counts the target through 64 cycle roots; TSan must stay clean.
class P { name: string; kids: P[] = []; constructor(name: string) { this.name = name; } }
class G { self: G | null = null; }
class H { at: Unowned<P> | null = null; }
function readAll(h: Readonly<H>): int32 {
	let n = 0;
	for (let i = 0; i < 200000; i++) {
		const q = h.at;
		if (q != null) n += q.name.length;
	}
	return n;
}
function link(p: P, k: int32): void {
	const cs: P[] = [];
	for (let i = 0; i < k; i++) {
		const c = new P("c");
		c.kids.push(p);
		p.kids.push(c);
		cs.push(c);
	}
}
function churn(): void {
	for (let j = 0; j < 2000; j++) { const g = new G(); g.self = g; }
}
function run(): void {
	const p = new P("abc");
	link(p, 64);
	const h = new H();
	h.at = p;
	const a = spawn((): int32 => readAll(h));
	const b = spawn((): int32 => readAll(h));
	let mine = 0;
	for (let i = 0; i < 2000; i++) {
		mine += i % 7;
		if (i % 100 == 50) { for (let j = 0; j < 2000; j++) { const g = new G(); g.self = g; } }
	}
	const n = await a + await b;
	console.log("total " + n.toString() + " parent " + mine.toString());
}
run();
