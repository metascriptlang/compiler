// bug234 — the destination type overrode what the arguments bound
//
// Symptom:    `Result<number, string> = ok(i32)` and `Box<number> = one(i32)` bound `T` to the
//             destination's supertype and handed the int32 to a number slot unconverted
//             (`Box<number>` read 3.5e-323); a literal before a variable took the destination
//             and then conflicted with the variable (`Math.max(1, power) as int64`).
// Root cause: the context bound type parameters before the argument walk and, after it,
//             replaced an argument binding with the destination's supertype.
// Fix:        an argument with a type of its own binds first; an argument with none (number
//             literal, arrow, function expression, object or array literal) is checked after them
//             and takes the destination only for a parameter still unbound.

import { compileToC } from "../helpers";

const header = `
class Box<T> { v: T; constructor(v: T) { this.v = v; } }
function one<T>(a: T): Box<T> { return new Box<T>(a); }
function id<T>(x: T): T { return x; }
function pick<T>(a: T, b: T): T { return a; }
function make<T>(): T[] { return []; }
const i: int32 = 3;
`;

function errorOf(body: string): string {
	const c = compileToC(header + body);
	return c.ok ? "" : c.error;
}

test "bug234: a variable argument converts to a number destination" {
	assert errorOf("const r: Box<number> = one(i);") == "";
}

test "bug234: a literal argument takes a wider destination" {
	assert errorOf("const b: Box<int64> = one(1);") == "";
}

test "bug234: a literal in Result.ok takes the declared return type" {
	assert errorOf("function f(): Result<number, string> { return Result.ok(42); } const r = f();") == "";
}

test "bug234: a literal before a variable follows the variable" {
	assert errorOf("const d = pick(1, i) as int64; const e: int64 = Math.max(1, i);") == "";
}

test "bug234: a literal that does not fit the destination is refused" {
	assert errorOf("const b: Box<uint8> = one(300);").contains("cannot convert 300 to uint8");
}

test "bug234: a negative literal that does not fit the destination is refused" {
	assert errorOf("const b: Box<uint64> = one(-1);").contains("cannot convert -1 to uint64");
}

test "bug234: an argument spelled in the destination type binds it" {
	assert errorOf("const b: Box<number> = one(i as number);") == "";
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
