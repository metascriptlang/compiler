import { argv } from "std/process";

type Circle = { kind: "circle"; r: float64 };
type Rect = { kind: "rect"; w: float64; h: float64 };
type Shape = Circle | Rect;
type Tagged = { kind: int32; r: float64; w: float64; h: float64 };

function area(s: Shape): float64 {
	switch (s.kind) {
		case "circle": return s.r * s.r * 3.0;
		case "rect": return s.w * s.h;
	}
}

function tArea(s: Tagged): float64 {
	switch (s.kind) {
		case 0: return s.r * s.r * 3.0;
		default: return s.w * s.h;
	}
}

function sumShapes(xs: Shape[]): float64 {
	let a: float64 = 0;
	for (const s of xs) a = a + area(s);
	return a;
}

function sumTagged(xs: Tagged[]): float64 {
	let a: float64 = 0;
	for (const s of xs) a = a + tArea(s);
	return a;
}

const shapes: Shape[] = [];
const tagged: Tagged[] = [];
for (let i = 0; i < 10; i = i + 1) {
	if (i % 3 == 0) shapes.push({ kind: "circle", r: i }); else shapes.push({ kind: "rect", w: i, h: 2 });
	tagged.push({ kind: i % 2, r: i, w: i, h: 2 });
}
const reps: int64 = argv.length > 1 ? argv[1].parseInt() as int64 : 1000;
let total: float64 = 0;
for (let i: int64 = 0; i < reps; i = i + 1) total = total + sumShapes(shapes) + sumTagged(tagged);
if (total < 0) console.log("unreachable");
