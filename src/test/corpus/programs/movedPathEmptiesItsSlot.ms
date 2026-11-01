// @stdout: nullable null 2 | vec 0 3 | text '' abab | nested null 4 | sink null 6 | struct 0 '' 3 tt
// @xfail(raiser): the Raiser VM compiles `move` as a plain read, so the moved field keeps its value ('nullable kept 2 | vec 3 3 | ...')
// note: a move out of a field takes the value and leaves the slot empty for every other reader, on JS as on C: a nullable slot reads null, a Vec slot empty, a string slot '', a struct slot its zero value.

struct P { x: int32; tag: string; }
class N { id: int32; constructor(id: int32) { this.id = id; } }
class H {
	n: N | null = new N(2);
	xs: Vec<int32> = [1, 2, 3];
	s: string = "ab".repeat(2);
	p: P = { x: 3, tag: "t".repeat(2) };
}
class W { h: H = new H(); }
function take(sink n: N | null): int32 { return n != null ? n.id : -1; }

function run(): void {
	const h = new H();
	const alias = h;
	const k = move h.n;
	const xs = move h.xs;
	const s = move h.s;
	const p = move h.p;
	const outer = new W();
	outer.h.n = new N(4);
	const deep = move outer.h.n;
	const viaSink = new H();
	viaSink.n = new N(6);
	const taken = take(move viaSink.n);
	console.log(`nullable ${alias.n == null ? "null" : "kept"} ${k != null ? k.id : -1} | vec ${alias.xs.length} ${xs.length} | text '${alias.s}' ${s} | nested ${outer.h.n == null ? "null" : "kept"} ${deep != null ? deep.id : -1} | sink ${viaSink.n == null ? "null" : "kept"} ${taken} | struct ${alias.p.x} '${alias.p.tag}' ${p.x} ${p.tag}`);
}
run();
