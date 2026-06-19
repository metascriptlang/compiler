// Reference-array T[] of managed value-elements (struct, generic-instance struct, named
// value-union) with owned heap fields must run each element's destructor on cleanup, not a
// free-only buffer wipe. The boxed cell's destroyFn = the array TYPE's single per-type
// <Name>ArrayDestroy walker (NIM-REF §2), selected once via arrayElementNeedsCleanup — not
// a per-element-kind match at the box site. Regression for the ~617MB-per-kind leaks the
// prior number[]/string[]/interface-element tests missed (struct, generic, union).

struct Cell { buf: string; }
struct Pair<T> { key: string; val: T; }
type Shape = { tag: "a"; name: string } | { tag: "b"; label: string };

function bigStr(seed: string): string {
	let s = seed;
	let i = 0;
	while (i < 8) { s = s + s; i = i + 1; }
	return s;
}

function churn(): void {
	const cells: Cell[] = [];
	const pairs: Pair<string>[] = [];
	const shapes: Shape[] = [];
	let n = 0;
	while (n < 10) {
		cells.push({ buf: bigStr("x") });
		pairs.push({ key: bigStr("k"), val: bigStr("v") });
		shapes.push({ tag: "a", name: bigStr("s") });
		n = n + 1;
	}
}

function main(): void {
	let m = 0;
	while (m < 200000) { churn(); m = m + 1; }
	console.log("ref-array-struct-elem done");
}

main();
