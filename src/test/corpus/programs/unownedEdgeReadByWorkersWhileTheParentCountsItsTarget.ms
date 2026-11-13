// @skip-js: the program awaits spawns in a sync function, and JS has no blocking wait
// @stdout: total 700000 parent 350000
// note: workers read an Unowned edge of a lent holder while the parent counts the same target (const r = h.at): the dead mark they read is not the count word the parent writes; TSan must stay clean.
class P { name: string; constructor(name: string) { this.name = name; } }
class H { at: Unowned<P> | null = null; ups: Unowned<P>[] = []; }
function readAll(h: Readonly<H>): int32 {
	let n = 0;
	for (let i = 0; i < 50000; i++) {
		const q = h.at;
		if (q != null) n += q.name.length;
		for (const u of h.ups) n += u.name.length;
	}
	return n;
}
function run(): void {
	const p = new P("abc");
	const q = new P("x");
	const h = new H();
	h.at = p;
	h.ups.push(p);
	h.ups.push(q);
	const a = spawn((): int32 => readAll(h));
	const b = spawn((): int32 => readAll(h));
	let mine = 0;
	for (let i = 0; i < 50000; i++) {
		const r = h.at;
		if (r != null) mine += r.name.length + p.name.length;
		mine += q.name.length;
	}
	const n = await a + await b;
	console.log("total " + n.toString() + " parent " + mine.toString());
}
run();
