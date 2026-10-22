import { checkOnly } from "../helpers";

test "an unannotated arrow that fits two overloads equally is an error that asks for annotations" {
	const src = `
function fn(cb: (x: int32) => int32): string { return "int"; }
function fn(cb: (x: string) => string): string { return "str"; }
function nf(cb: (x: string) => string): string { return "str"; }
function nf(cb: (x: int32) => int32): string { return "int"; }
function pre(n: int32, cb: (x: int32) => int32): string { return "int"; }
function pre(n: int32, cb: (x: string) => string): string { return "str"; }
class Runner {
	run(cb: (x: int32) => int32): string { return "int"; }
	run(cb: (x: string) => string): string { return "str"; }
}
class Cell { n: int32 = 1; }
function at(this c: Cell, cb: (x: int32) => int32): string { return "int"; }
function at(this c: Cell, cb: (x: string) => string): string { return "str"; }
const a = fn((x) => x + x);
const b = nf((x) => x + x);
const c = pre(1, (x) => x + x);
const d = new Runner().run((x) => x + x);
const e = new Cell().at((x) => x + x);
const ok1 = fn((x: int32): int32 => x + x);
const ok2 = fn((x) => x * 2);
`;
	const errors = checkOnly(src).errors;
	const text = errors.join("\n");
	const hint = "fits more than one overload; annotate its parameter types";
	assert text.contains("Ambiguous call to overloaded function 'fn' — a callback or object literal argument " + hint), "function: " + text;
	assert text.contains("Ambiguous call to overloaded function 'nf' — a callback or object literal argument " + hint), "reversed order: " + text;
	assert text.contains("Ambiguous call to overloaded function 'pre' — a callback or object literal argument " + hint), "after a plain argument: " + text;
	assert text.contains("'run' — a callback or object literal argument " + hint), "method: " + text;
	assert text.contains("Ambiguous call to overloaded extension method 'at' — a callback or object literal argument " + hint), "extension: " + text;
	assert errors.length == 5, "annotated or single-fit arrows resolve: " + text;
}
