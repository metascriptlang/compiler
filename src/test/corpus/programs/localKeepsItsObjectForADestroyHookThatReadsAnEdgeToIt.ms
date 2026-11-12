// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: a b
// note: a destroy hook that reads through an Unowned edge counts as a reader for the local the edge points at. A local declared before `p` is handed over dies before `p`'s scope ends, in an inner scope or at a `return`, and its hook reads the edge; `p` keeps its object until then. Before the fix `p`'s last read moved the object and the hook stopped with "an Unowned<P> edge was read after its P was destroyed".
class P { name: string; constructor(name: string) { this.name = name; } }
class H { up: Unowned<P> | null = null; }
class Box { own: P | null = null; }
class W { h: H; constructor(h: H) { this.h = h; } }
let seen = "none";
function onDestroy(this w: W): void { seen = w.h.up!.name; }
function drop(sink p: P): int32 { return p.name.length; }

function hookOfALocalInAnInnerScope(): string {
	const h = new H();
	const p = new P("a");
	h.up = p;
	{
		const w = new W(h);
		{ const b = new Box(); b.own = p; }
	}
	return seen;
}

function handsOverAtAReturn(h: H): int32 {
	const p = new P("b");
	h.up = p;
	const w = new W(h);
	return drop(p);
}

function hookOfALocalThatDiesAtAReturn(): string {
	const h = new H();
	handsOverAtAReturn(h);
	return seen;
}

console.log([hookOfALocalInAnInnerScope(), hookOfALocalThatDiesAtAReturn()].join(" "));
