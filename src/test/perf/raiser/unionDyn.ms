type Shape = { kind: "circle"; r: number } | { kind: "rect"; w: number; h: number } | { kind: "dot" };

function area(s: Shape): number {
	if (s.kind == "circle") return s.r * s.r * 3;
	if (s.kind == "rect") return s.w * s.h;
	return 0;
}

function weight(v: number | string | boolean): number {
	if (typeof v == "number") return v;
	if (typeof v == "string") return v.length;
	return v ? 1 : 0;
}

const shapes: Shape[] = [];
for (let i = 0; i < 30000; i += 1) {
	if (i % 3 == 0) shapes.push({ kind: "circle", r: i % 5 });
	else if (i % 3 == 1) shapes.push({ kind: "rect", w: i % 4, h: i % 6 });
	else shapes.push({ kind: "dot" });
}
let total: number = 0;
for (let round = 0; round < 25; round += 1) {
	for (const s of shapes) total += area(s);
}
const mixed: (number | string | boolean)[] = [];
for (let i = 0; i < 30000; i += 1) mixed.push(i % 3 == 0 ? i : i % 3 == 1 ? "ab" : i % 2 == 0);
let w: number = 0;
for (let round = 0; round < 25; round += 1) {
	for (const v of mixed) w += weight(v);
}
console.log(`union ${total} ${w}`);
