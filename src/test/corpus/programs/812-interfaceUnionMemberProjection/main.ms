// @stdout: circle 75 square 16 ok 42 err boom tri 6 rect 12
import { Poly } from "./shapes";

interface CircleD { kind: "circle"; radius: number }
interface SquareD { kind: "square"; side: number }
type ShapeD = CircleD | SquareD;

function areaD(s: ShapeD): number {
	if (s.kind == "circle") return s.radius * s.radius * 3;
	return s.side * s.side;
}

interface OkB { ok: true; value: number }
interface ErrB { ok: false; error: string }
type ResB = OkB | ErrB;

function showB(r: ResB): string {
	if (r.ok) return `ok ${r.value}`;
	return `err ${r.error}`;
}

function areaP(p: Poly): number {
	if (p.kind == "tri") return p.base * p.height / 2;
	return p.w * p.h;
}

const c: ShapeD = { kind: "circle", radius: 5 };
const sq: ShapeD = { kind: "square", side: 4 };
const good: ResB = { ok: true, value: 42 };
const bad: ResB = { ok: false, error: "boom" };
const t: Poly = { kind: "tri", base: 3, height: 4 };
const r: Poly = { kind: "rect", w: 3, h: 4 };
console.log(`circle ${areaD(c)} square ${areaD(sq)} ${showB(good)} ${showB(bad)} tri ${areaP(t)} rect ${areaP(r)}`);
