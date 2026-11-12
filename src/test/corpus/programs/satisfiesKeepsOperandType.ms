// @stdout: circle 3 5
// @stdout: c:circle 2
// @stdout: a 7
// @stdout: 4
// @stdout: ro 1
interface Shape { kind: string; size: number }
type Kind = "circle" | "square";
function onlyCircle(k: "circle"): string { return "c:" + k; }
function twice(f: (n: int32) => int32, n: int32): int32 { return f(f(n)); }

const k = "circle" satisfies Kind;
const n = 3 satisfies number;
const inc = ((x) => x + 1) satisfies (n: int32) => int32;
console.log(k, n, twice(inc, 3));

const s = { kind: "circle", size: 2 } satisfies Shape;
console.log(onlyCircle(k), s.size);

function label(x: string | null): string {
	if ((x satisfies string | null) != null) return x;
	return "none";
}
const shape: Shape = { kind: "a", size: 7 };
const same = shape satisfies Shape;
console.log(label("a"), same.size);

const total = 1 + 1 satisfies number + 2;
console.log(total);

const view: Readonly<Shape> = { kind: "ro", size: 1 };
const seen = view satisfies Shape;
console.log(seen.kind, seen.size);
