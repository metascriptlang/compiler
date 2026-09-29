// Symptom: on JS a narrowing conversion to a signed integer passed unchecked where C stops: `200 as int8` gave 200, `4294967295 as int32` from an int64 gave -1, `3000000000.5 as int32` wrapped; the raiser let a float past int64 and NaN through.
// Root cause: the C range check (rangeCheckInject) ran only in the native pipeline; the JS conversion materializers truncate with `| 0` and `BigInt.asIntN`, and the raiser converted the float before checking it.
// Fix: JS wraps the same conversions C checks in the same-named helpers (std/core/system/index.jms) before truncating, as Nim's JS generator emits chckRange (jsgen.nim:2734-2761); the raiser checks a float against the signed range first. A conversion to an unsigned type stays unchecked on every backend, as on C.
// Runtime: corpus 669 (C and raiser; node reports the thrown error with its own trace).
import { compileToJS } from "../helpers";

function bodyOf(out: string, fn: string): string {
	const at = out.indexOf("function " + fn, 0);
	if (at < 0) return "";
	return out.slice(at, out.indexOf("\n}", at));
}

function unchecked(out: string, fn: string, helper: string): string {
	const body = bodyOf(out, fn);
	return body.indexOf(helper, 0) >= 0 ? "" : `${fn} lacks ${helper}; `;
}

const SRC = `
function toInt8(v: int32): int8 { return v as int8; }
function fromUnsigned(v: uint8): int8 { return v as int8; }
function toInt32(v: int64): int32 { return v as int32; }
function fromFloat(v: float64): int64 { return v as int64; }
function toUnsigned(v: int32): uint8 { return v as uint8; }
function widen(v: int8): int32 { return v as int32; }
console.log(toInt8(1), fromUnsigned(1), toInt32(1 as int64));
console.log(fromFloat(1.5), toUnsigned(1), widen(1));
`;

test "bug634: a signed narrowing conversion is range checked on JS" {
	const r = compileToJS(SRC);
	assert r.ok;
	if (r.ok) {
		const failure = unchecked(r.value, "toInt8", "msCheckRangeI8")
			+ unchecked(r.value, "fromUnsigned", "msCheckRangeI8")
			+ unchecked(r.value, "toInt32", "msCheckRangeI32")
			+ unchecked(r.value, "fromFloat", "msCheckRangeI64");
		assert failure == "", failure;
	}
}

test "bug634: an unsigned or widening conversion stays unchecked on JS" {
	const r = compileToJS(SRC);
	assert r.ok;
	if (r.ok) {
		const toUnsigned = bodyOf(r.value, "toUnsigned");
		const widen = bodyOf(r.value, "widen");
		assert toUnsigned.indexOf("msCheckRange", 0) < 0, toUnsigned;
		assert widen.indexOf("msCheckRange", 0) < 0, widen;
	}
}
