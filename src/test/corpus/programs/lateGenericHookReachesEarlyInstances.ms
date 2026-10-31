// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// @stdout: v 7
// @stdout: h 8
// @stdout: destroyed 2

struct Box<T> { v: T; }
struct Holder { b: Box<int32>; }

function make(n: int32): Box<int32> { return { v: n }; }
function makeHolder(n: int32): Holder { return { b: { v: n } }; }

let destroyed = 0;
function onDestroy<T>(this x: Box<T>): void { destroyed = destroyed + 1; }

function run(): void {
	const b = make(7);
	console.log(`v ${b.v}`);
	const h = makeHolder(8);
	console.log(`h ${h.b.v}`);
}
run();
console.log(`destroyed ${destroyed}`);
