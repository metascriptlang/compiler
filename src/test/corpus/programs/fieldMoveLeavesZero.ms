// @stdout: 3 0 |
// @stdout: 8 zz 0 []
// @stdout: 7 7 5 5
// @stdout: true
// note: moving a string, a struct holding a string or a nested class's string field out of a class empties the source on both backends; a plain-number struct or scalar field stays as it was
struct P { a: int32; ok: boolean; }
struct Q { a: int32; s: string; }
class Box { t: string = ""; }
class H { s: string; p: P; q: Q; n: int32; nested: Box = new Box(); }
function main(): void {
	const h = new H();
	h.s = "abc".repeat(1);
	h.p = { a: 7, ok: true };
	h.q = { a: 8, s: "zz".repeat(1) };
	h.n = 5;
	h.nested.t = "xy";
	const s = move h.s;
	console.log(`${s.length} ${h.s.length} |${h.s}`);
	const q = move h.q;
	console.log(`${q.a} ${q.s} ${h.q.a} [${h.q.s}]`);
	const p = move h.p;
	const n = move h.n;
	console.log(`${p.a} ${h.p.a} ${n} ${h.n}`);
	const t = move h.nested.t;
	console.log(t == "xy" && h.nested.t.length == 0);
}
main();
