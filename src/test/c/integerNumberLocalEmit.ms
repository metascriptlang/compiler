// E2E C: a const number holding a masked integer is cast back from that integer, not from a double; runtime
// results of keys() and entries(): corpus keysIntegerIndex.

import { compileToC, builtModuleC } from "../helpers";
import { hostTargetInfo } from "../../checker/types";

function emitted(body: string): string {
	const c = compileToC(`
function f(xs: int32[], i: int64, v: number): int32 {
	${body}
}
const ys: int32[] = [1, 2, 3];
console.log(f(ys, 1, 1));`, hostTargetInfo(), false, true, false);
	return c.ok ? c.value : "error: " + c.error;
}

test "integer number local: an index from a masked integer skips the double check" {
	const c = emitted("const k = (i & 9007199254740991) as number; return xs[k];");
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes("msCheckRangeI64("), "the index still round-trips a double";
}

test "integer number local: a narrowing cast checks the integer" {
	const c = emitted("const k = (i & 9007199254740991) as number; return (k as int32) & 1;");
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.includes("msCheckRangeI32(dollarint_"), "the narrowing check does not read the integer";
}

test "integer number local: a mask wider than 53 bits keeps the double" {
	const c = emitted("const k = (i & 18014398509481983) as number; return xs[k];");
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.includes("msCheckRangeI64("), "a value a double cannot hold was taken as exact";
}

test "integer number local: a number from elsewhere keeps the double" {
	const c = emitted("const k = v; return xs[k];");
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert c.includes("msCheckRangeI64("), "an arbitrary number lost its check";
}

test "integer number local: a keys() index in a release build reads the integer" {
	const c = builtModuleC("integerNumberLocal", "keyssum", "function f(xs: int32[]): int32 { let s: int32 = 0; for (const k of xs.keys()) s += xs[k]; return s; }\nconsole.log(f([1, 2, 3]));\n", ["--release"]);
	assert !c.startsWith("error:"), c.slice(0, 400);
	assert !c.includes("msCheckRangeI64("), "the keys() index still round-trips a double";
}
