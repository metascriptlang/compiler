// bug192 — calling a value that is not a function reached the C compiler
//
// Symptom:    `const dispose = mount(); dispose();` with `mount(): void`
//             compiled clean through the checker and died in clang with
//             "called object type 'void *' is not a function or function
//             pointer"; an `int32` or `string` value in call position did the
//             same.
// Cause:      `checkCallExpr` checked arguments only for a `Function` callee
//             and let every other callee type fall through undiagnosed; only
//             the nullable-function carrier had its own rejection.
// Reference:  a call whose callee has no call signature is a type error at the
//             call (`semcall.nim` `notFoundError`: "expression '…' cannot be
//             called"; TS2349 "This expression is not callable").
import { compileToCWithStd } from "../helpers";

function errorOf(source: string): string {
	const c = compileToCWithStd(source);
	return c.ok ? "" : c.error;
}

test "bug192: a void value in call position is a type error" {
	const e = errorOf(`
function mount(): void {}
function main(): void {
	const dispose = mount();
	dispose();
}
`);
	assert e.contains("not callable: type 'void'"), e;
}

test "bug192: a number or string value in call position is a type error" {
	assert errorOf(`function main(): void { const n: int32 = 1; n(); }\n`).contains("not callable: type 'int32'");
	assert errorOf(`function main(): void { const s = "a"; s(); }\n`).contains("not callable");
}

test "bug192: calling the void result of a call is a type error" {
	assert errorOf(`function mount(): void {}\nfunction main(): void { mount()(); }\n`).contains("not callable: type 'void'");
}

test "bug192: a conversion call through a type name is still a call" {
	const e = errorOf(`
function main(): void {
	const x: float64 = 2.5;
	const n = int32(x);
	console.log(String(n));
}
`);
	assert !e.contains("not callable"), e;
}
