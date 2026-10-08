// A narrowing that holds on entry to nested loops holds inside them, and an
// assignment in any of them that undoes it still undoes it on the next pass.

import { compileToC } from "../helpers";

function accepted(source: string): boolean {
	return compileToC(source).ok;
}

const made = "function made(n: int32): Result<int32, int32> { return n > 0 ? Result.ok(n) : Result.err(n); }\n";

test "loop narrowing: a guard before two loops holds in the inner one" {
	assert accepted(made + "function f(): int32 { const r = made(3); if (!r.ok) return 0; let t = 0; for (let i = 0; i < 2; i++) { for (let j = 0; j < 2; j++) { t += r.value; } } return t; }");
	assert accepted(made + "function f(): int32 { const r = made(3); if (!r.ok) return 0; let t = 0; for (let i = 0; i < 2; i++) { let j = 0; while (j < 2) { for (let k = 0; k < 2; k++) { t += r.value; } j++; } } return t; }");
	assert accepted(made + "function f(): int32 { const r = made(3); let t = 0; if (r.ok) { for (let i = 0; i < 2; i++) { for (let j = 0; j < 2; j++) { t += r.value; } } } return t; }");
}

test "loop narrowing: a reassignment in the inner loop undoes the guard" {
	assert !accepted(made + "function f(): int32 { let r = made(3); if (!r.ok) return 0; let t = 0; for (let i = 0; i < 2; i++) { for (let j = 0; j < 2; j++) { t += r.value; r = made(0); } } return t; }");
	assert !accepted(made + "function f(): int32 { let r = made(3); if (!r.ok) return 0; let t = 0; for (let i = 0; i < 2; i++) { for (let j = 0; j < 2; j++) { t += r.value; } r = made(0); } return t; }");
}
