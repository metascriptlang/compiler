// @exit: 1
// @skip-js: C-only by design: the edge's target is destroyed before the spawn, and JS frees nothing
// @stdout: Error: an Unowned<P> edge was read after its P was destroyed
// note: a worker reading an Unowned edge whose target died before the lend stops, as a read on the owner's thread does.
class P { name: string; constructor(name: string) { this.name = name; } }
class H { at: Unowned<P> | null = null; }
function readAt(h: Readonly<H>): int32 {
	const q = h.at;
	return q != null ? q.name.length : -1;
}
function attach(h: H): void {
	const p = new P("gone");
	h.at = p;
}
function run(): void {
	const h = new H();
	attach(h);
	const a = spawn((): int32 => readAt(h));
	console.log("read " + (await a).toString());
}
run();
