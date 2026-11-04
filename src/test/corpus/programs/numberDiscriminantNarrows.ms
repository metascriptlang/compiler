// @stdout: c4 r6 | c4 r6 | 0:5 1:6 | 5 -6 | leaf:3 pair:7 | s:2 n:-1 | 22 | ok
// note: a number-literal discriminant (`kind: 0 | 1`) is a discriminant as a string one is: `===` and `switch` narrow, a written object builds the arm its literal names, `.kind` reads as the number.

type Circle = { kind: 0; r: int32 };
type Rect = { kind: 1; w: int32; h: int32 };
type Shape = Circle | Rect;

function areaIf(s: Shape): int32 {
	if (s.kind === 0) return s.r * 2;
	return s.w * s.h;
}

function areaSwitch(s: Shape): int32 {
	switch (s.kind) {
		case 0: return s.r * 2;
		case 1: return s.w * s.h;
	}
}

function label(s: Shape): string {
	return s.kind !== 1 ? `c${areaIf(s)}` : `r${areaSwitch(s)}`;
}

type A = { kind: 0; x: int32 };
type B = { kind: 1; x: int32 };
type Same = A | B;

function signed(v: Same): int32 {
	return v.kind == 1 ? 0 - v.x : v.x;
}

type Leaf = { tag: -1; v: int32 };
type Pair = { tag: 2; inner: Shape; extra: int32 };
type Tree = Leaf | Pair;

function weigh(t: Tree): string {
	switch (t.tag) {
		case -1: return `leaf:${t.v}`;
		case 2: return `pair:${areaSwitch(t.inner) + t.extra}`;
	}
}

type Mixed = { kind: "s"; n: int32 } | { kind: "n"; n: int32 };

function mixed(m: Mixed): string {
	switch (m.kind) {
		case "s": return `s:${m.n}`;
		case "n": return `n:${0 - m.n}`;
	}
}

const shapes: Shape[] = [{ kind: 0, r: 2 }, { kind: 1, w: 2, h: 3 }];
const same: Same[] = [{ kind: 0, x: 5 }, { kind: 1, x: 6 }];
const trees: Tree[] = [{ tag: -1, v: 3 }, { tag: 2, inner: { kind: 0, r: 2 }, extra: 3 }];
let sum = 0;
for (const s of shapes) sum += areaIf(s) + areaSwitch(s) - (s.kind == 0 ? 4 : 6) + s.kind * 0;
for (const s of shapes) sum += s.kind === 0 ? s.r * 2 : s.w * s.h;
console.log(`${label(shapes[0])} ${label(shapes[1])} | ${shapes.map(label).join(" ")} | ${same[0].kind}:${same[0].x} ${same[1].kind}:${same[1].x} | ${signed(same[0])} ${signed(same[1])} | ${weigh(trees[0])} ${weigh(trees[1])} | ${mixed({ kind: "s", n: 2 })} ${mixed({ kind: "n", n: 1 })} | ${sum + 2} | ${same[1].kind === 1 ? "ok" : "bad"}`);
