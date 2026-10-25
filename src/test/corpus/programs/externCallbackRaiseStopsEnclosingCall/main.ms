// Parity program — a call to an extern that is handed a routine can raise through it, so an
// enclosing call, constructor or operand must not run before the raise check that follows it.
// Axes: the extern call nested as an argument, as a constructor argument, as a `??` operand and
// in a conditional arm.
//
// @skip-js: the extern is a C function taking the routine; the JS backend has no C linkage
// @stdout: arg: caught|new: caught|nullish: caught|arm: caught|none: ran,done|wrong: none
// @exit: 0

@include("./apply.h");
extern function corpusApplyCallback(cb: (n: int32) => int32, x: int32): int32;

let log: string[] = [];
function thrower(n: int32): int32 {
	if (n > 2) throw new Error("bad");
	return n;
}
function after(n: int32): int32 { log.push("ran"); return n + 1; }
class Held {
	v: int32;
	constructor(v: int32) { log.push("ran"); this.v = v; }
}
function mark(v: int32): int32 { log.push("done"); return v; }
let fallback: int32 | null = null;

const wrong: string[] = [];
const lines: string[] = [];
function run(name: string, f: () => void, expected: string): void {
	log = [];
	try { f(); } catch (e) { log.push("caught"); }
	const got = log.join(",");
	lines.push(`${name}: ${got}`);
	if (got != expected) wrong.push(name);
}

run("arg", () => { after(corpusApplyCallback(thrower, 5)); }, "caught");
run("new", () => { const h = new Held(corpusApplyCallback(thrower, 5)); mark(h.v); }, "caught");
run("nullish", () => { after(fallback ?? corpusApplyCallback(thrower, 5)); }, "caught");
run("arm", () => { after(log.length == 0 ? corpusApplyCallback(thrower, 5) : 0); }, "caught");
run("none", () => { mark(after(corpusApplyCallback(thrower, 1))); }, "ran,done");
console.log(`${lines.join("|")}|wrong: ${wrong.length == 0 ? "none" : wrong.join(",")}`);
