// bug570 — the type a generic call's result goes to retyped its literal argument
//
// Symptom:    `Math.max(power, 1) as int64` and `const d: int64 = pick(power, 1)` with
//             `power: int32` failed with "arg 1: got int64, expected int32 — 'T' was bound by
//             argument 0": the destination type reached the literal as its expected type.
// Root cause: deriveCallBindings bound `T` backward from the expected type before the argument
//             walk, for every return shape; inferGenericReturn and tryInstantiateGenericCallee
//             skip a naked `T` return and let the arguments alone bind it.
// Fix:        the context reaches an argument before the walk only when it has no type of its
//             own, so a literal sees the binding the earlier arguments made (reference
//             inheritBindings: arguments win); the general rule is pinned by bug571.

import { compileToC, compileToJS } from "../helpers";

const header = `
function pick<T>(a: T, b: T): T { return a; }
const power: int32 = 7;
`;

function errorOf(body: string): string {
	const c = compileToC(header + body);
	if (!c.ok) return c.error;
	const js = compileToJS(header + body);
	return js.ok ? "" : js.error;
}

test "bug570: a cast of Math.max leaves its literal argument to T" {
	assert errorOf("const d = Math.max(power, 1) as int64; console.log(d);") == "";
}

test "bug570: an unsigned cast of Math.min leaves its literal argument to T" {
	assert errorOf("const d = Math.min(power, 1) as uint64; console.log(d);") == "";
}

test "bug570: a cast of a user generic leaves its literal argument to T" {
	assert errorOf("const d = pick(power, 1) as int64; console.log(d);") == "";
}

test "bug570: a declared destination leaves the literal argument to T" {
	assert errorOf("const d: int64 = pick(power, 1); console.log(d);") == "";
}

test "bug570: a literal first argument binds T before the variable" {
	assert errorOf("const d = Math.max(1, power) as int64; console.log(d);") == "";
}
