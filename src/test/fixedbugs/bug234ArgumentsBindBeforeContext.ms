// bug234 — the destination type overrode what the arguments bound
//
// Symptom:    `const b: Box<int64> = one(1)` bound `T` to int64 from the declared type, and
//             `Result<number, string> = ok(i32)` preferred the destination's supertype, so the
//             literal and the variable argument saw a type no argument had given them.
// Root cause: the context bound type parameters before the argument walk and, after it,
//             replaced an argument binding with the destination's supertype.
// Fix:        the arguments bind first and the context only fills a parameter they left
//             unbound (reference inheritBindings); before the walk the context reaches only an
//             argument with no type of its own (arrow, function expression, object or array literal).

import { compileToC } from "../helpers";

const header = `
class Box<T> { v: T; constructor(v: T) { this.v = v; } }
function one<T>(a: T): Box<T> { return new Box<T>(a); }
function id<T>(x: T): T { return x; }
function make<T>(): T[] { return []; }
const i: int32 = 3;
`;

function errorOf(body: string): string {
	const c = compileToC(header + body);
	return c.ok ? "" : c.error;
}

test "bug234: a literal argument binds T even under a wider destination" {
	assert errorOf("const b: Box<int64> = one(1);").contains("is not assignable");
}

test "bug234: a variable argument binds T even under a supertype destination" {
	assert errorOf("const r: Box<number> = one(i);").contains("is not assignable");
}

test "bug234: an argument spelled in the destination type binds it" {
	assert errorOf("const b: Box<int64> = one(1 as int64);") == "";
}

test "bug234: the context fills a type parameter no argument binds" {
	assert errorOf("const xs: string[] = make(); xs.push(\"a\");") == "";
}

test "bug234: an arrow argument takes its parameter types from the context" {
	assert errorOf("const f: (x: int32) => int32 = id((x) => x * 2);") == "";
}

test "bug234: an empty array argument takes its element type from the context" {
	assert errorOf("const xs: int32[] = id([]); xs.push(1);") == "";
}
