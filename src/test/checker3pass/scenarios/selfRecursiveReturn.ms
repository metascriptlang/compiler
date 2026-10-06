import { checkOnly } from "../helpers";

const BEFORE_ANY_RETURN = "it calls itself before any return gives it a type";

const SRC_BEFORE = `
function ternary(n: number) { return n <= 0 ? 0 : ternary(n - 1) + 1; }
function only(n: number) { return only(n - 1); }
function early(n: number) { const x = early(n - 1); if (n <= 0) return 0; return 1; }
class C { m(n: number) { return n <= 0 ? 0 : this.m(n - 1) + 1; } }
`;

const SRC_WIDENED = `
function halves(n: number) { if (n <= 0) return 0; return halves(n - 1) + 0.5; }
function text(n: number) { if (n <= 0) return 0; return text(n - 1) + "x"; }
class C { m(n: number) { if (n <= 0) return 0; return this.m(n - 1) + 0.5; } }
`;

const SRC_VALID = `
function count(n: number) { if (n <= 0) return 0; return count(n - 1) + 1; }
function fib(n: number) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); }
function letters(n: number) { if (n <= 0) return "a"; return letters(n - 1) + "b"; }
function walk(n: number) { if (n > 0) walk(n - 1); return n; }
async function later(n: number) { if (n <= 0) return 0; return (await later(n - 1)) + 1; }
class C { m(n: int32) { if (n <= 0) return 0; return this.m(n - 1) + n; } }
function annotated(n: number): number { return n <= 0 ? 0 : annotated(n - 1) + 0.5; }
`;

test "a self call read before any return types the function is refused" {
	const errors = checkOnly(SRC_BEFORE).errors;
	let named = 0;
	for (const e of errors) if (e.contains(BEFORE_ANY_RETURN)) named += 1;
	assert named == 4, "ternary, tail-only, early read and a method must be refused: " + errors.join("\n");
}

test "a self call that read a narrower return than the final one is refused" {
	const text = checkOnly(SRC_WIDENED).errors.join("\n");
	assert text.contains("cannot infer the return type of 'halves': this call reads it as 'int32', but a later return makes it 'float64'"), "float widening must fail: " + text;
	assert text.contains("cannot infer the return type of 'text': this call reads it as 'int32', but a later return makes it 'int32 | string'"), "string widening must fail: " + text;
	assert text.contains("cannot infer the return type of 'C.m': this call reads it as 'int32'"), "method widening must fail: " + text;
}

test "self recursion whose returns agree, a discarded self call and an annotated return still check" {
	const result = checkOnly(SRC_VALID);
	assert result.errors.length == 0, "agreeing self recursion must check: " + result.errors.join("\n");
}
