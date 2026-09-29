// Symptom: `k == null` with a non-nullable fixed array `k: T[N]` passed the checker and failed at clang on C (`invalid operands ... and 'void *'`); JS compared the array object with null.
// Root cause: operatorLower folded a null comparison to a constant only for value structs and dynamic arrays; a fixed array fell through to the native operator.
// Fix: a fixed array takes the value-struct path: it is never null, so `== null` is false and `!= null` true (TypeScript's answer; Nim refuses `array == nil`, comparisons.nim has no such `==`).
// Runtime on every lane: corpus 667.
import { compileToJS } from "../helpers";

function bodyOf(out: string, fn: string): string {
	const at = out.indexOf("function " + fn, 0);
	if (at < 0) return "";
	return out.slice(at, out.indexOf("\n}", at));
}

test "bug631: a fixed array compared with null folds to a constant (JS)" {
	const r = compileToJS(`
function isNull(k: uint8[4]): boolean { return k == null; }
function notNull(k: uint8[4]): boolean { return null != k; }
const k: uint8[4] = [1, 2, 3, 4];
console.log(isNull(k), notNull(k));
`);
	assert r.ok;
	if (r.ok) {
		const isNull = bodyOf(r.value, "isNull");
		const notNull = bodyOf(r.value, "notNull");
		assert isNull.indexOf("return false;", 0) >= 0, isNull;
		assert notNull.indexOf("return true;", 0) >= 0, notNull;
	}
}
