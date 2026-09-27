// bug578 — a generic call passed as an argument never saw the destination
//
// Symptom:    `return Result.ok(Result.err("inner fail"))` into
//             `Result<Result<number, string>, string>` and `const xs: string[] = pick(make(), ["a"])`
//             failed with "cannot instantiate: 'T'".
// Root cause: after argument-first binding, only an argument without a type of its own (literal,
//             arrow, function expression, object or array literal) received the destination; a
//             generic call whose own arguments leave a parameter unbound has no type of its own
//             either, and was checked against the bare formal `T`.
// Fix:        a call or `new` argument receives the destination for a parameter still unbound
//             at its turn; its own arguments still bind first, so the destination never retypes
//             them (`pick(f(), 1)` into int64 keeps `T = int32`).

import { compileToC, compileToJS } from "../helpers";

const header = `
class Box<T> { v: T; constructor(v: T) { this.v = v; } }
function one<T>(a: T): Box<T> { return new Box<T>(a); }
function pick<T>(a: T, b: T): T { return a; }
function make<T>(): T[] { return []; }
function f(): int32 { return 3; }
`;

function errorOf(body: string): string {
	const c = compileToC(header + body);
	if (!c.ok) return c.error;
	const js = compileToJS(header + body);
	return js.ok ? "" : js.error;
}

function cOf(body: string): string {
	const c = compileToC(header + body);
	return c.ok ? c.value : c.error;
}

test "bug578: Result.err inside Result.ok takes the declared return type" {
	assert errorOf("function f2(): Result<Result<number, string>, string> { return Result.ok(Result.err(\"inner fail\")); } const r = f2();") == "";
}

test "bug578: a generic call one level deeper takes the declared return type" {
	assert errorOf("function f3(): Result<Result<Result<number, string>, string>, string> { return Result.ok(Result.ok(Result.err(\"x\"))); } const r = f3();") == "";
}

test "bug578: a generic call before an array literal takes the declared type" {
	assert errorOf("const xs: string[] = pick(make(), [\"a\"]); xs.push(\"b\");") == "";
}

test "bug578: a generic call after an array literal takes the declared type" {
	assert errorOf("const xs: string[] = pick([\"a\"], make()); xs.push(\"b\");") == "";
}

test "bug578: a user generic call inside Result.ok takes the declared type" {
	assert errorOf("const r: Result<Box<int64>, string> = Result.ok(one(5));") == "";
}

test "bug578: the destination does not retype a call argument with a type of its own" {
	const code = cOf("const d: int64 = pick(f(), 1); console.log(d);");
	assert code.contains("__int32__");
	assert !code.contains("__int64__");
}
