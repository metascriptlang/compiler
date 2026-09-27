// bug241 — a `return` in a block arm of a match took no type from the match
//
// Symptom:    `return Result.ok(x)` in a block arm failed with "cannot instantiate: 'E'" where an
//             expression arm or an `if` checked; in a statement match `return "s"` from a `uint64`
//             function passed the checker (clang error on C, printed `s` on JS); `return null` in an
//             arm of a match value was compared with the function's return type.
// Root cause: checkReturnStmt checked every return under a match with no expected type, and
//             checkMatchExpr treated a match at statement position as a match value.
// Fix:        as Nim `semCase` hands `expectedType` to each branch, a return in a block arm of a
//             match value takes the match's expected type; a statement match's arms are statements
//             whose returns leave the function, as `lowerMatchExprAsStmt` lowers them.

import { compileToCWithStd } from "../helpers";

function compileError241(body: string): string {
	const result = compileToCWithStd(`
enum Failure { Rejected, TooBig }
class Box { n: uint64 = 0; }
${body}
function main(): int32 { return 0; }
process.exit(main());
`);
	return result.ok ? "" : result.error;
}

test "bug241: Result.ok in a block arm of a returned match takes the declared error type" {
	const error = compileError241(`
function f(value: uint32): Result<uint64, Failure> {
	return match (value) {
		0 => {
			const result: uint64 = 7;
			return Result.ok(result);
		},
		_ => Result.err(Failure.Rejected),
	};
}`);
	assert error == "", error;
}

test "bug241: Result.err in a block arm takes the declared value type" {
	const error = compileError241(`
function f(value: uint32): Result<uint64, Failure> {
	return match (value) {
		0 => Result.ok(5),
		_ => {
			return Result.err(Failure.TooBig);
		},
	};
}`);
	assert error == "", error;
}

test "bug241: a return nested in a block arm takes the match's type" {
	const error = compileError241(`
function f(value: uint32): Result<uint64, Failure> {
	return match (value) {
		0 => Result.err(Failure.Rejected),
		_ => {
			if (value > 10) {
				return Result.err(Failure.TooBig);
			}
			return Result.ok(2);
		},
	};
}`);
	assert error == "", error;
}

test "bug241: a block arm of a match inside a block arm takes the inner match's type" {
	const error = compileError241(`
function f(value: uint32, flag: boolean): Result<uint64, Failure> {
	const outer: Result<uint64, Failure> = match (value) {
		0 => {
			const inner: Result<uint64, Failure> = match (flag) {
				true => {
					return Result.ok(1);
				},
				false => Result.err(Failure.Rejected),
			};
			return inner;
		},
		_ => Result.ok(9),
	};
	return outer;
}`);
	assert error == "", error;
}

test "bug241: a return in a block arm of a statement match takes the function's type" {
	const error = compileError241(`
function f(value: uint32): Result<uint64, Failure> {
	match (value) {
		0 => {
			return Result.ok(3);
		},
		_ => {},
	};
	return Result.err(Failure.Rejected);
}`);
	assert error == "", error;
}

test "bug241: a wrong return in a block arm of a statement match is a return type mismatch" {
	const inMatch = compileError241(`
function f(value: uint32): uint64 {
	match (value) {
		0 => {
			return "s";
		},
		_ => {},
	};
	return 1;
}`);
	const inIf = compileError241(`
function f(value: uint32): uint64 {
	if (value == 0) {
		return "s";
	}
	return 1;
}`);
	assert inMatch != "", inMatch;
	assert inMatch == inIf, `${inMatch} | ${inIf}`;
}

test "bug241: return null in a block arm of a match value is checked against the match" {
	const error = compileError241(`
function f(value: uint32): uint64 {
	const box: Box | null = match (value) {
		0 => {
			return null;
		},
		_ => new Box(),
	};
	return box == null ? 0 : 1;
}`);
	assert error == "", error;
}

test "bug241 control: a function inside a block arm keeps its own return type" {
	const error = compileError241(`
function f(value: uint32): string {
	return match (value) {
		0 => {
			const next = (n: uint64): uint64 => { return n + 1; };
			return \`next \${next(41)}\`;
		},
		_ => "other",
	};
}`);
	assert error == "", error;
}
