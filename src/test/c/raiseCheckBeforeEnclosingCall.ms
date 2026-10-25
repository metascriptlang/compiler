// A call that can raise, nested in an enclosing call, is its own statement so the raise check
// follows it before the enclosing call runs. An extern handed a routine can raise through it; an
// extern handed none cannot, and stays inline.
// Runtime behaviour: corpus `externCallbackRaiseStopsEnclosingCall`.

import { compileToC } from "../helpers";

function lineWith(c: string, needle: string): string {
	for (const line of c.split("\n")) {
		if (line.contains(needle)) return line;
	}
	return "";
}

const EXTERNS = `
extern function applyCallback(cb: (n: int32) => int32, x: int32): int32;
extern function plainExtern(x: int32): int32;
function take(n: int32): int32 { return n + 1; }
function ident(n: int32): int32 { return n; }
`;

test "an extern handed a routine is bound before the call that encloses it" {
	const c = compileToC(`${EXTERNS}
function run(n: int32): int32 { return take(applyCallback(ident, n)); }
function main(): void { console.log(run(1)); }
`);
	assert c.ok;
	const call = lineWith(c.value, "applyCallback(");
	assert call != "";
	assert !call.contains("take__");
}

test "an extern handed a routine inside a constructor argument is bound before the constructor" {
	const c = compileToC(`${EXTERNS}
class Held { v: int32; constructor(v: int32) { this.v = v; } }
function run(n: int32): int32 { return new Held(applyCallback(ident, n)).v; }
function main(): void { console.log(run(1)); }
`);
	assert c.ok;
	const call = lineWith(c.value, "applyCallback(");
	assert call != "";
	assert !call.contains("Held");
}

test "an extern handed no routine stays inline in the enclosing call" {
	const c = compileToC(`${EXTERNS}
function run(n: int32): int32 { return take(plainExtern(n)); }
function main(): void { console.log(run(1)); }
`);
	assert c.ok;
	assert lineWith(c.value, "plainExtern(").contains("take__");
}
