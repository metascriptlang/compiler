// @stdout: 10 s9 true 7 2.5 | s9 true | x2 yyb | 4 s9 | 1 s untouched
interface P { a: number; b: string }
interface Q { n: number; s: string; f: boolean; i: int32; d: float64 }
class Cell { x: number = 1; y: string = "y"; }
type Pair = { p: number, q: string };

function main(): void {
	const x: P = { a: 1, b: "s" };
	const y = { ...x, a: 9 };
	const q: Q = { n: 1, s: "s", f: false, i: 3, d: 0.5 };
	const q2 = { ...q, s: "s9", f: true, i: 7, d: 2.5 };
	const annotated: P = { ...x, b: "s9" };
	const first = { a: 0, ...x, b: "s9" };
	const c = new Cell();
	const fromClass = { ...c, x: 2, y: "yb" };
	const pr: Pair = { p: 1, q: "q" };
	const alias = { ...pr, p: 4, q: "s9" };
	console.log((y.a + x.a) + " " + q2.s + " " + q2.f + " " + q2.i + " " + q2.d + " | " + annotated.b + " " + (first.a == 1) + " | x" + fromClass.x + " y" + fromClass.y + " | " + alias.p + " " + alias.q + " | " + x.a + " " + x.b + " untouched");
}
main();
