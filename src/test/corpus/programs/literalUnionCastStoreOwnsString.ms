// @stdout: center|row,column|load:6|wrap|nowrap
// note: a heap string cast to a string-literal union and stored (a nullable field written inside a loop, an array
// element, a struct field returned through a generic) is a counted string like any string, so it outlives the scope
// that built it and is released with its holder: no use after free, no leak (SAN).
type Align = "flex-start" | "center" | "flex-end";
type Dir = "row" | "column";
type Op = "load" | "clear";
type Wrap = "wrap" | "nowrap";

interface Box { alignItems: Align | null; }
struct Step { op: Op; id: int32; }
struct Held<T> { value: T; }

function fresh(word: string, n: int32): string {
	return `${word}${"".padEnd(n, " ").trim()}`;
}

function setField(b: Box, v: number | string | null): void {
	b.alignItems = v as Align | null;
}

function step(s: string): Step { return { op: s as Op, id: 1 }; }
function hold<T>(v: T): Held<T> { return { value: v }; }

const b: Box = { alignItems: null };
for (let i = 0; i < 1; i += 1) { setField(b, fresh("center", 3)); }
const dirs: Dir[] = [];
for (const w of ["row", "column"]) dirs.push(fresh(w, 2) as Dir);
let total = 0;
let last = "";
for (let i = 0; i < 2000; i += 1) {
	const s = step(fresh("load", i % 7));
	total += s.op.length;
	last = s.op;
}
const wraps: Held<Wrap>[] = [];
for (const w of ["wrap", "nowrap"]) wraps.push(hold(fresh(w, 1) as Wrap));
const churn: string[] = [];
for (let i = 0; i < 1000; i += 1) churn.push(fresh(`c${i}`, i % 40));
console.log(`${b.alignItems}|${dirs.join(",")}|${last}:${total / 2000 + 2}|${wraps[0].value}|${wraps[1].value}`);
