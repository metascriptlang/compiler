// @stdout: circle=3 square=none point=5 line=none label=L
interface Circle { kind: string; r: number; label: string; }
interface Square { kind: string; side: number; }
type Shape = Circle | Square;

type Point = { x: number, y: number, tag: string };
type Span = { from: number, to: number };
type Geo = Point | Span;

function radius(s: Shape): string {
	if (s.kind != "circle") return "none";
	return (s as { kind: string, r: number }).r.toString();
}

function label(s: Shape): string {
	return (s as { label: string }).label;
}

function sum(g: Geo, isPoint: boolean): string {
	if (!isPoint) return "none";
	const v = g as { x: number, y: number };
	return (v.x + v.y).toString();
}

function main(): void {
	const c: Shape = { kind: "circle", r: 3, label: "L" };
	const q: Shape = { kind: "square", side: 2 };
	const p: Geo = { x: 2, y: 3, tag: "p" };
	const l: Geo = { from: 1, to: 4 };
	console.log("circle=" + radius(c) + " square=" + radius(q) + " point=" + sum(p, true) + " line=" + sum(l, false) + " label=" + label(c));
}
main();
