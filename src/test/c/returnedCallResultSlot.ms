// A returned call whose struct result has the function's own result type writes the caller's
// result slot itself: the callee gets `__result`, with no zeroed temporary and no copy after.
// Runtime behaviour: corpus `returnedCallIntoResultSlot`.

import { compileToC } from "../helpers";

function bodyOf(c: string, fn: string): string {
	for (const line of c.split("\n")) {
		if (line.contains(`void ${fn}__`) && line.endsWith("{")) {
			const open = c.indexOf(line);
			return c.slice(open, c.indexOf("\n}", open));
		}
	}
	return "";
}

test "a returned direct call passes the result slot to the callee" {
	const c = compileToC(`
struct Big { a: int64; b: int64; c: int64; }
function core(n: int64): Big { return { a: n, b: n + 1, c: n + 2 }; }
function forward(n: int64): Big { return core(n); }
function main(): void { console.log(forward(3).c); }
`);
	assert c.ok;
	const body = bodyOf(c.value, "forward");
	assert body.contains("(&(*__result), n);");
	assert !body.contains("*__result =");
}

test "a returned closure call passes the result slot to the callee" {
	const c = compileToC(`
struct Big { a: int64; b: int64; c: int64; }
function forward(make: (n: int64) => Big, n: int64): Big { return make(n); }
function main(): void { console.log(forward((n: int64): Big => ({ a: n, b: n, c: n }), 3).c); }
`);
	assert c.ok;
	const body = bodyOf(c.value, "forward");
	assert body.contains("(&(*__result), n)");
	assert !body.contains("*__result =");
}
