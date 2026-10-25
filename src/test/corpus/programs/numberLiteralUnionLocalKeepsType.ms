// @stdout: cast 2
// @stdout: let 3
// @stdout: param 2
// @stdout: call 3
// @stdout: annotated 1
// @stdout: narrowed 2
// @stdout: fresh 70001
// note: an unannotated const or let keeps a number-literal union that came from an `as`, a parameter, a call, an annotated local or a narrowed read, so it returns where that union is required; a literal written in place still widens.

type Narrow = 1 | 2 | 3;
type Wide = 1 | 2 | 3 | 4;

function readNarrow(): Narrow { return 3; }

function cast(): Narrow { const n = 2 as Narrow; return n; }
function letCast(w: Wide): Narrow { let n = w as Narrow; return n; }
function param(w: Narrow): Narrow { const n = w; return n; }
function call(): Narrow { let n = readNarrow(); return n; }
function annotated(): Narrow { const a: Narrow = 1; const n = a; return n; }
function narrowed(v: 1 | 2 | string): 1 | 2 {
	if (typeof v === "number") { const n = v; return n; }
	return 1;
}

function main(): void {
	console.log("cast", cast());
	console.log("let", letCast(3));
	console.log("param", param(2));
	console.log("call", call());
	console.log("annotated", annotated());
	console.log("narrowed", narrowed(2));
	let fresh = 1;
	fresh = 70000;
	fresh = fresh + 1;
	console.log("fresh", fresh);
}
main();
