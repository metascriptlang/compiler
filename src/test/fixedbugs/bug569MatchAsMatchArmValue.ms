// bug569 — a match used as the value of another match arm reached codegen unlowered
//
// Symptom:    `Side.Left => match (step) { … }` inside a `return match` or a `const r = match`
//             emitted `/* unsupported expression: kind=MatchExpr */`: C failed to compile, JS
//             returned `undefined` (return) or failed to parse (initializer); as a statement arm
//             the inner match was dropped silently on both backends.
// Root cause: moveInto pushed the destination (return / assign) into blocks and ifs but wrapped
//             a MatchExpr arm value as-is, and a bare statement in a switch case is never re-walked.
// Fix:        moveInto distributes into a MatchExpr the way the reference's distributeAsgn descends
//             into nkCaseStmt: the inner match is lowered in place with the outer destination.

import { compileToC, compileToJS } from "../helpers";

const header = `
enum Side { Left, Right }
`;

const viaReturn = header + `
function f(side: Side, step: int32): int32 {
	return match (side) {
		Side.Left => match (step) { 2 => 20, _ => 10, },
		Side.Right => 30,
	};
}
console.log(f(Side.Left, 2));
`;

const viaLet = header + `
function f(side: Side, step: int32): int32 {
	const r = match (side) {
		Side.Left => match (step) { 2 => 20, _ => 10, },
		Side.Right => 30,
	};
	return r;
}
console.log(f(Side.Left, 2));
`;

const deeper = header + `
function f(side: Side, step: int32, deep: boolean): int32 {
	return match (side) {
		Side.Left => match (step) {
			2 => match (deep) { true => 200, false => 20, },
			_ => 10,
		},
		Side.Right => 30,
	};
}
console.log(f(Side.Left, 2, true));
`;

const byName = `
function f(name: string, step: int32): int32 {
	const r = match (name) {
		"a" => match (step) { 1 => 7, _ => 8, },
		_ => 9,
	};
	return r;
}
console.log(f("a", 1));
`;

const asStatement = header + `
function say(n: int32): int32 { console.log(n); return n; }
function f(side: Side, step: int32): void {
	match (side) {
		Side.Left => match (step) { 2 => say(20), _ => say(10), },
		Side.Right => say(30),
	};
}
f(Side.Left, 2);
`;

function lowered(source: string): boolean {
	const c = compileToC(source);
	const js = compileToJS(source);
	return c.ok && js.ok && !c.value.contains("unsupported") && !js.value.contains("unsupported");
}

test "bug569: a match arm value of a returned match is lowered" {
	assert lowered(viaReturn);
}

test "bug569: a match arm value of a match initializer is lowered" {
	assert lowered(viaLet);
}

test "bug569: a match two levels deep in arm values is lowered" {
	assert lowered(deeper);
}

test "bug569: a match arm value under a string discriminant is lowered" {
	assert lowered(byName);
}

test "bug569: a match arm value of a statement match is kept" {
	const c = compileToC(asStatement);
	const js = compileToJS(asStatement);
	assert c.ok && js.ok;
	if (c.ok && js.ok) {
		assert c.value.contains("(20)");
		assert js.value.contains("(20)");
	}
}
