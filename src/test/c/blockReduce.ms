// Emitted C of guarded block reductions; src/test/corpus/programs/blockReduce*.ms run them.

import { compileToC, builtModuleC } from "../helpers";
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

test "E2E C: the fused loop of values() reduces in guarded blocks, and one that also writes the array does not" {
	const sums = builtModuleC("blockReduce", "valuessum", "function f(xs: int32[]): int32 { let s: int32 = 0; for (const x of xs.values()) s += x; return s; }\nconsole.log(f([1, 2, 3]));\n", ["--release"]);
	assert sums.contains("msSumFitsI32I32("), sums.slice(0, 400);
	const writes = builtModuleC("blockReduce", "valueswrite", "function f(xs: int32[]): int32 { let s: int32 = 0; for (const x of xs.values()) { s += x; xs[0] = 1; } return s; }\nconsole.log(f([1, 2, 3]));\n", ["--release"]);
	assert !writes.startsWith("error:"), writes.slice(0, 400);
	assert !writes.contains("msBlockEnd("), "a values() loop that writes its array was versioned";
}

test "E2E C: the fused loop of keys() reduces in guarded blocks that end below 2^53" {
	const c = builtModuleC("blockReduce", "keyssum", "function f(xs: int32[]): int32 { let s: int32 = 0; for (const k of xs.keys()) s += xs[k]; return s; }\nconsole.log(f([1, 2, 3]));\n", ["--release"]);
	assert c.contains("msSumFitsI32I32("), c.slice(0, 400);
	assert c.contains("<= 9007199254740992"), "a block of masked keys does not stop at 2^53";
}

const upTo = "function* upTo(n: int32): Iterator<int32> { for (let i: int32 = 0; i < n; i++) yield i; }\nfunction* relay(n: int32): Iterator<int32> { for (const x of upTo(n)) yield x; }\nfunction g(x: int32): int32 { return x; }\n";

test "E2E C: a generator's masked reduction runs in range-guarded blocks" {
	const cases: string[][] = [
		["msRangeFitsI32(", "function f(salt: int32): int32 { let total: int32 = 0; for (const x of upTo(70000)) total += (x ^ salt) & 1023; return total; }"],
		["msRangeFitsI32(", "function f(salt: int32): int32 { let total: int32 = 0; for (const x of relay(70000)) total += (x ^ salt) & 1023; return total; }"],
		["-255LL, 0LL)", "function f(salt: int32): int32 { let total: int32 = 0; for (const x of upTo(70000)) total -= 255 & (x | salt); return total; }"],
		["msRangeFitsI64(", "function f(salt: int32): int64 { let total: int64 = 0; for (const x of upTo(70000)) total += x & 7; return total; }"],
	];
	for (const c of cases) {
		const out = builtModuleC("blockReduce", "bounded", `${upTo}${c[1]}\nconsole.log(f(3));\n`, ["--release"]);
		assert out.contains(c[0]), `${c[1]}\n${out.slice(0, 400)}`;
	}
}

test "E2E C: the fused loop of entries() reduces in range-guarded blocks that end below 2^31" {
	const c = builtModuleC("blockReduce", "entriessum", "function f(xs: int32[]): int32 { let s: int32 = 0; for (const [k, x] of xs.entries()) s += x + ((k as int32) & 1); return s; }\nconsole.log(f([1, 2, 3]));\n", ["--release"]);
	assert c.contains("msRangeSumFitsI32I32("), c.slice(0, 400);
	assert c.contains("<= 2147483648"), "a block whose key is narrowed to int32 does not stop at 2^31";
	assert c.contains("msArrayAccessUnchecked("), "the fast block still checks its element read";
}

test "E2E C: a generator reduction without a mask, with an effect or reading its sum keeps the checked loop alone" {
	const cases: string[] = [
		"function f(salt: int32): int32 { let total: int32 = 0; for (const x of upTo(70000)) total += x ^ salt; return total; }",
		"function f(salt: int32): int32 { let total: int32 = 0; for (const x of upTo(70000)) total += g(x) & 1023; return total; }",
		"function f(salt: int32): int32 { let total: int32 = 0; for (const x of upTo(70000)) total += (x + salt) & 1023; return total; }",
		"function f(salt: int32): int32 { let total: int32 = 0; for (const x of upTo(70000)) total += (x ^ total) & 1023; return total; }",
		"function f(salt: int32): int32 { let total: int32 = 0; for (const x of upTo(70000)) total += x & -1; return total; }",
	];
	for (const c of cases) {
		const out = builtModuleC("blockReduce", "unbounded", `${upTo}${c}\nconsole.log(f(3));\n`, ["--release"]);
		assert !out.startsWith("error:"), out.slice(0, 400);
		assert !out.contains("msRangeFits"), c;
	}
}
