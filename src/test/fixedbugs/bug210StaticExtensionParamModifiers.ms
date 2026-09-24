// bug210 — a parameter modifier of a static extension landed on the parameter after it
//
// Symptom:    with `function create(this typeof R, ref c: Ctx, k: int32)`, `R.create(c, 7)` was refused
//             with "arg 1: out parameter requires a variable", `c.n = …` in the body was refused as a
//             write to a value parameter, and `bump(c)` in the body changed a copy.
// Root cause: the parser counted `out`/`ref`/`readonly`/`sink` positions and parameter locations with
//             the `this typeof R` receiver, then dropped the receiver from the declaration's parameters.
// Fix:        positions and locations index the parameters the declaration keeps; fmt prints the
//             receiver ahead of them.

import { compileToC, compileToJS } from "../helpers";

const header = `
struct Ctx { n: int32; }
struct R { k: int32; }
class Box { v: int32 = 0; }
function seven(): int32 { return 7; }
function fresh(): Ctx { return { n: 0 }; }
function create(this typeof R, ref c: Ctx, k: int32): R {
	c.n = c.n + 1;
	return { k: k };
}
function make(this typeof R, k: int32, name: string, ref c: Ctx): R {
	c.n = k;
	return { k: k + name.length };
}
function split(this typeof R, out half: int32, k: int32): R {
	half = k / 2;
	return { k: k };
}
let c: Ctx = { n: 0 };
let h: int32 = 0;
`;

function errorOf(body: string): string {
	const out = compileToC(header + body);
	return out.ok ? "" : out.error;
}

function jsErrorOf(body: string): string {
	const out = compileToJS(header + body);
	return out.ok ? "" : out.error;
}

test "bug210: a ref in the second position takes a variable beside a literal" {
	assert errorOf("R.create(c, 7);") == "";
}

test "bug210: a ref in the second position takes a variable beside a call" {
	assert errorOf("R.create(c, seven());") == "";
}

test "bug210: a ref in the third position takes a variable after a call and a literal" {
	assert errorOf("R.make(seven(), \"ab\", c);") == "";
}

test "bug210: the ref argument of a static extension still has to be a variable" {
	assert errorOf("R.create(fresh(), 7);").indexOf("'create' arg 0: out parameter requires a variable") >= 0;
}

test "bug210: an out in the second position takes a variable beside a literal" {
	assert errorOf("R.split(h, 7);") == "";
}

test "bug210: a readonly parameter of a static extension refuses a write" {
	assert errorOf("function peek(this typeof R, readonly a: Box, b: Box): int32 { a.v = 1; return b.v; }").indexOf("cannot mutate readonly parameter 'a'") >= 0;
}

test "bug210: the parameter after a readonly one stays writable" {
	assert errorOf("function poke(this typeof R, readonly a: Box, b: Box): int32 { b.v = 1; return a.v; }") == "";
}

test "bug210: the JS backend takes a ref in the second and the third position" {
	assert jsErrorOf("R.create(c, seven());\nR.make(7, \"ab\", c);") == "";
}
