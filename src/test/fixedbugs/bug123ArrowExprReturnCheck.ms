// bug123 — expression-bodied arrow: the implicit return was never checked
//                 against the contextual return type.
// Symptom: `take(() => n())` with `take(f: () => string)` and `n(): number`
//   type-checked silently on BOTH lanes, then C died at clang
//   ("returning 'double' ... incompatible result type 'msString'") while JS
//   "worked" only because console.log is polymorphic. The block-bodied twin
//   `() => { return n(); }` was already rejected with the right message —
//   checkArrowExpr ran fitNode on the body (checkPass parity) but never the
//   assignability step, so the expression form was the one hole.
// Fix:        after the existing fitNode reseat in checkArrowExpr, run the
//   same isAssignable + addError pair checkReturnStmt runs. Void slots keep
//   swallowing (arity-padded callbacks into () => void must stay legal).

import { compileToCWithStd } from "../helpers";

test "bug123: an expr-bodied arrow returning number into a string slot is a checker error" {
	const src = `
function take(f: () => string): void {
	console.log(f());
}

function main(): void {
	const n = (): number => 7;
	take(() => n());
}

main();
`;
	const c = compileToCWithStd(src);
	assert !c.ok;
	assert c.error.indexOf("Return type mismatch in '<arrow>'", 0) >= 0;
	assert c.error.indexOf("expected string, got number", 0) >= 0;
}

test "bug123: a value-returning expr arrow into a void slot still compiles" {
	const src = `
function takeVoid(f: () => void): void {
	f();
}

function main(): void {
	let a: int32[] = [];
	takeVoid(() => a.push(1));
}

main();
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}

test "bug123: a legal widening through an expr arrow keeps its conversion" {
	const src = `
function takeNum(f: () => number): void {
	console.log(f().toString());
}

function main(): void {
	const j = (): int32 => 42;
	takeNum(() => j());
}

main();
`;
	const c = compileToCWithStd(src);
	assert c.ok;
}
