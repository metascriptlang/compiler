// @stdout: [8 -9 18446744073709551615 2.5 ff|] caught
// @skip-js: onDestroy runs where the DRC runs; JS has no destructors
// @xfail(raiser): the Raiser VM runs no lifecycle hooks, so onDestroy never runs and the line misses its numbers
// note: a destroy hook that runs while an exception unwinds formats every number kind as it would outside one.

struct Probe { a: int32; b: int64; c: uint64; d: float64; }
struct Holder { probe: Probe; tag: string; }
let text = "";

function onDestroy(this p: Probe): void {
	if (p.a != 0) text += p.a.toString() + " " + p.b.toString() + " " + p.c.toString() + " " + p.d.toString() + " " + (255).toString(16) + "|";
}

function makeProbe(): Probe { return { a: 8, b: -9, c: 18446744073709551615, d: 2.5 }; }
function fail(): string { throw new Error("later field"); }

function interrupted(): void {
	const h: Holder = { probe: makeProbe(), tag: fail() };
	console.log("unreached " + h.tag);
}

let caught = "none";
try { interrupted(); } catch (e) { caught = "caught"; }
console.log("[" + text + "] " + caught);
