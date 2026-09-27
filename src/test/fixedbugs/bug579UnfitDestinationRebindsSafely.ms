// bug579 — a typed argument refused a destination it converts to without loss
//
// Symptom:    `return Result.ok(r - 1)` with `let r = 0` into `Result<number, string>`,
//             `return Result.ok(circle)` into `Result<Circle | Square, string>` and
//             `const b: Box<number> = one(i32)` failed with "Result<int32, string> is not
//             assignable": argument-first binding kept `T = int32` although the result did not
//             fit the destination.
// Root cause: the destination only filled a parameter no argument bound.
// Fix:        when the result the arguments give does not fit the destination, the destination
//             binds the parameters it names, provided every argument converts to its rebound
//             formal without loss (integers widen within their signedness, any number becomes
//             `number`, a variant becomes its union); the arguments are converted at the call.
//             A result that fits keeps the argument binding (`pick(power, 1) as int64`).

import { compileToC, compileToJS } from "../helpers";

const header = `
class Box<T> { v: T; constructor(v: T) { this.v = v; } }
interface Circle { kind: "circle"; r: float64; }
interface Square { kind: "square"; s: float64; }
type Shape = Circle | Square;
function one<T>(a: T): Box<T> { return new Box<T>(a); }
function pick<T>(a: T, b: T): T { return a; }
function wrap<T>(xs: T[]): Box<T[]> { return new Box<T[]>(xs); }
const i: int32 = 3;
const w: int64 = 5;
const u: uint16 = 7;
const circle: Circle = { kind: "circle", r: 1.5 };
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

test "bug579: an int32 expression in Result.ok takes a number return type" {
	assert errorOf("function f(): Result<number, string> { let r = 0; return Result.ok(r - 1); } const x = f();") == "";
}

test "bug579: a variant in Result.ok takes its union" {
	assert errorOf("function f(): Result<Shape, string> { return Result.ok(circle); } const x = f();") == "";
}

test "bug579: a user generic takes a number destination" {
	assert errorOf("const b: Box<number> = one(i);") == "";
}

test "bug579: integers widen within their signedness" {
	assert errorOf("const b: Box<int64> = one(i); const c: Box<uint32> = one(u);") == "";
}

test "bug579: a signed argument does not rebind an unsigned destination" {
	assert errorOf("const b: Box<uint32> = one(i);").contains("'Box<int32>' is not assignable to type 'Box<uint32>'");
}

test "bug579: a wider argument does not rebind a narrower destination" {
	assert errorOf("const b: Box<int32> = one(w);").contains("'Box<int64>' is not assignable to type 'Box<int32>'");
}

test "bug579: an array argument does not rebind another element type" {
	const xs = "const xs: int32[] = [1, 2]; const b: Box<number[]> = wrap(xs);";
	assert errorOf(xs).contains("'Box<int32[]>' is not assignable to type 'Box<number[]>'");
}

test "bug579: explicit type arguments are never rebound" {
	assert errorOf("const b: Box<number> = one<int32>(i);").contains("'Box<int32>' is not assignable to type 'Box<number>'");
}

test "bug579: a result that fits keeps the argument binding" {
	const code = cOf("const d: int64 = pick(i, 1); const e = pick(i, 2) as int64; console.log(d, e);");
	assert code.contains("__int32__");
	assert !code.contains("__int64__");
}
