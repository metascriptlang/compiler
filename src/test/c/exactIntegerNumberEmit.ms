// Emitted C of a range check on a const number converted from an integer; src/test/corpus/programs/exactIntegerNumber*.ms run them.

import { builtModuleC } from "../helpers";

function built(name: string, body: string): string {
	return builtModuleC("exactIntegerNumber", name, `${body}\nconsole.log(f([1, 2, 3], 1));\n`, ["--release"]);
}

test "E2E C: a key of keys() indexes through its integer" {
	const c = built("keys", "function f(xs: int32[], n: int32): int32 { let t: int32 = 0; for (const k of xs.keys()) t += xs[k]; return t; }");
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.contains("msExactI64("), c.slice(0, 400);
	assert !c.contains("msCheckRangeI64("), "a key is converted back from its double";
}

test "E2E C: a key of entries() narrows through its integer" {
	const c = built("entries", "function f(xs: int32[], n: int32): int32 { let t: int32 = 0; for (const [k, x] of xs.entries()) t += x + ((k as int32) & 1); return t; }");
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.contains("msCheckRangeExactI32("), c.slice(0, 400);
}

test "E2E C: a const number of an int32 indexes and narrows through its integer" {
	const c = built("user", "function f(xs: int32[], n: int32): int32 { const k: number = n; const w: int32 = n + 1; const m: number = w; return xs[k] + (m as int8); }");
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.contains("msExactI64(") && c.contains("msCheckRangeExactI8("), c.slice(0, 400);
}

test "E2E C: a const number a closure reads, a let and a number from a float keep the double check" {
	const cases: string[] = [
		"function f(xs: int32[], n: int32): int32 { const k: number = n; const g = (): int32 => xs[k]; return g(); }",
		"function f(xs: int32[], n: int32): int32 { let k: number = n; k = k + 0.5; return xs[k]; }",
		"function f(xs: int32[], n: int32): int32 { const k: number = n * 0.5; return xs[k]; }",
	];
	for (const src of cases) {
		const c = built("double", src);
		assert !c.startsWith("error:"), c.slice(0, 400);
		assert c.contains("msCheckRangeI64("), src;
		assert !c.contains("msExactI64("), src;
	}
}
