// Emitted C of guarded block reductions; src/test/corpus/programs/blockReduce*.ms run them.

import { compileToC } from "../helpers";
import { hostTargetInfo } from "../../checker/types";

function emitted(src: string): string {
	const c = compileToC(src, hostTargetInfo(), false, true);
	if (!c.ok) throw new Error(`${src}: ${c.error}`);
	return c.value;
}

test "E2E C: a checked reduction over an array runs in guarded blocks" {
	const cases: string[][] = [
		["msSumFitsI32I32(", "function f(xs: int32[]): int32 { let s: int32 = 0; for (const x of xs) s += x; return s; }"],
		["msSumSubI32I32(", "function f(xs: int32[]): int32 { let s: int32 = 0; for (const x of xs) s -= x; return s; }"],
		["msSumFitsI32I32(", "function f(xs: int32[]): int32 { let s: int32 = 0; for (let i = 0; i < xs.length; i++) s += xs[i]; return s; }"],
		["msSumFitsI32I32(", "function f(xs: int32[]): int32 { let s: int32 = 0; for (let i = 2; i < xs.length; ++i) { s += xs[i]; } return s; }"],
		["msSumFitsI8I8(", "function f(xs: int8[]): int8 { let s: int8 = 0; for (const x of xs) s += x; return s; }"],
		["msSumFitsI16I16(", "function f(xs: int16[]): int16 { let s: int16 = 0; for (const x of xs) s += x; return s; }"],
		["msSumFitsI64I64(", "function f(xs: int64[]): int64 { let s: int64 = 0; for (let i: int64 = 0; i < xs.length; i++) s += xs[i]; return s; }"],
		["msSumFitsI64I32(", "function f(xs: int32[]): int64 { let s: int64 = 0; for (const x of xs) s += x; return s; }"],
		["msDotFitsI32(", "function f(a: int32[], b: int32[]): int32 { let s: int32 = 0; for (let k = 0; k < a.length; k++) s += a[k] * b[k]; return s; }"],
		["msDotSubI16(", "function f(a: int16[], b: int16[]): int16 { let s: int16 = 0; for (let k = 0; k < b.length; k++) s -= a[k] * b[k]; return s; }"],
		["msDotFitsI64(", "function f(a: int64[]): int64 { let s: int64 = 0; for (let k = 0; k < a.length; k++) s += a[k] * a[k]; return s; }"],
	];
	for (const c of cases) {
		const out = emitted(c[1]);
		assert out.contains("msBlockEnd(") && out.contains(c[0]), c[1];
	}
}

test "E2E C: a narrow loop index takes a whole block only when the block ends inside its range" {
	assert emitted("function f(xs: int32[]): int32 { let s: int32 = 0; for (let i = 0; i < xs.length; i++) s += xs[i]; return s; }").contains("<= 2147483647) && msSumFitsI32I32(");
	assert !emitted("function f(xs: int32[]): int32 { let s: int32 = 0; for (const x of xs) s += x; return s; }").contains("<= 2147483647");
}

test "E2E C: a loop outside the recognized reduction keeps the checked loop alone" {
	const cases: string[] = [
		"function g(x: int32): int32 { return x; } function f(xs: int32[]): int32 { let s: int32 = 0; for (const x of xs) s += g(x); return s; }",
		"function f(xs: int32[]): int32 { let s: int32 = 0; for (let i = 0; i < xs.length; i++) { s += xs[i]; xs[i] = 0; } return s; }",
		"function f(xs: int32[]): int32 { let s: int32 = 0; for (const x of xs) { if (x == 0) break; s += x; } return s; }",
		"function f(xs: int32[]): int32 { let s: int32 = 0; let t: int32 = 0; for (const x of xs) { s += x; t += x; } return s + t; }",
		"function f(xs: int32[]): int32 { let s: int32 = 0; for (const x of xs) s += x * 2; return s; }",
		"function f(xs: int32[]): int32 { let s: int32 = 0; for (const x of xs) s *= x; return s; }",
		"function f(xs: int32[]): int32 { let s: int32 = 0; for (const x of xs) s = s + x; return s; }",
		"function f(xs: uint32[]): uint32 { let s: uint32 = 0; for (const x of xs) s += x; return s; }",
		"function f(xs: number[]): number { let s: number = 0; for (const x of xs) s += x; return s; }",
		"function f(a: int32[], b: int32[]): int64 { let s: int64 = 0; for (let k = 0; k < a.length; k++) s += a[k] * b[k]; return s; }",
		"function f(a: int32[], b: int32[]): int32 { let s: int32 = 0; for (let k = 0; k < a.length; k++) s += a[k] * b[k + 1]; return s; }",
		"function f(xs: int32[], n: int32): int32 { let s: int32 = 0; for (let i = 0; i < n; i++) s += xs[i]; return s; }",
		"function f(xs: int32[]): int32 { let s: int32 = 0; for (let i = 0; i < xs.length; i += 2) s += xs[i]; return s; }",
		"function f(xs: int32[]): int32 { let s: int32 = 0; const g = (): void => { for (const x of xs) s += x; }; g(); return s; }",
	];
	for (const c of cases) assert !emitted(c).contains("msBlockEnd("), c;
}
