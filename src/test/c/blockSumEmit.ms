// Emitted C of a checked reduction run in sticky blocks; src/test/corpus/programs/blockSum*.ms run them.

import { builtModuleC } from "../helpers";

const upTo = "function* upTo(n: int32): Iterator<int32> { for (let i: int32 = 0; i < n; i++) yield i; }\nfunction g(x: int32): int32 { return x; }\n";

function built(name: string, fn: string): string {
	return builtModuleC("blockSum", name, `${upTo}${fn}\nconsole.log(f([1, 2, 3], 3));\n`, ["--release"]);
}

test "E2E C: a checked reduction of any pure integer term runs in sticky blocks" {
	const fns: string[] = [
		"function f(xs: int32[], n: int32): int32 { let t: int32 = 0; for (const x of upTo(n)) t += (x ^ n) & 1023; return t; }",
		"function f(xs: int32[], n: int32): int32 { let t: int32 = 0; for (const x of upTo(n)) t -= x * 3 + 1; return t; }",
		"function f(xs: int32[], n: int32): int32 { let t: int32 = 0; for (const k of xs.keys()) t += xs[k]; return t; }",
		"function f(xs: int32[], n: int32): int32 { let t: int32 = 0; for (const [k, x] of xs.entries()) t += x + ((k as int32) & 1); return t; }",
		"function f(xs: int32[], n: int32): int32 { let i: int32 = -3; let t: int32 = 0; while (i < n) { const v: int32 = i * 3; t += v & 255; i++; } return t; }",
		"function f(xs: int32[], n: int32): int16 { let t: int16 = 0; for (let x: int32 = 0; x < n; x++) t += ((x & 7) - 3) as int16; return t; }",
		"function f(xs: int32[], n: int32): int32 { let t: int32 = 0; for (let i: int32 = 0; i < n; i++) t += xs[i + 1]; return t; }",
		"function f(xs: int32[], n: int32): int32 { let t: int32 = 0; for (let k = 0; k < xs.length; k++) t += xs[k] * xs[k + 1]; return t; }",
		"function f(xs: int32[], n: int32): int32 { let t: int32 = 0; for (let i = 0; i < n; i++) t += xs[i]; return t; }",
	];
	for (const fn of fns) {
		const c = built("sticky", fn);
		assert !c.startsWith("error:"), c.slice(0, 400);
		assert c.contains("msBlockSumFits("), fn;
	}
}

test "E2E C: a reduction with a call, a division, a read of its sum, a wide sum or another statement keeps the checked loop alone" {
	const fns: string[] = [
		"function f(xs: int32[], n: int32): int32 { let t: int32 = 0; for (const x of upTo(n)) t += g(x); return t; }",
		"function f(xs: int32[], n: int32): int32 { let t: int32 = 0; for (const x of upTo(n)) t += 100 / (x + 1); return t; }",
		"function f(xs: int32[], n: int32): int32 { let t: int32 = 0; for (const x of upTo(n)) t += t & x; return t; }",
		"function f(xs: int32[], n: int32): int64 { let t: int64 = 0; for (const x of upTo(n)) t += x & 7; return t; }",
		"function f(xs: int32[], n: int32): int32 { let t: int32 = 0; for (const x of upTo(n)) { if (x > 2) t += x; } return t; }",
	];
	for (const fn of fns) {
		const c = built("checked", fn);
		assert !c.startsWith("error:"), c.slice(0, 400);
		assert !c.contains("msBlockSumFits("), fn;
	}
}
