import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const m = await import(pathToFileURL(resolve(process.argv[2])).href);
const make = () => ({
	s8: -128, u8: 255, s16: -32768, u16: 65535,
	s32: -2147483648, u32: 4294967295,
	s64: -(1n << 63n), u64: (1n << 64n) - 1n,
	f32: 1.25, f64: -0, yes: true,
	nested: { wide: null, unsigned: null, flag: false, real: null },
});
for (const variant of [0, 1, 2]) {
	const value = make();
	if (variant === 1) {
		value.s64 = (1n << 63n) - 1n;
		value.u64 = 0n;
		value.f32 = Infinity;
		value.f64 = NaN;
		value.yes = false;
		value.nested = { wide: value.s64, unsigned: value.u64, flag: null, real: -Infinity };
	} else if (variant === 2) {
		value.f32 = -0;
		value.f64 = Infinity;
		value.nested = { wide: value.s64, unsigned: value.u64, flag: true, real: NaN };
	}
	const first = m.reflect(value);
	assert.deepStrictEqual(first, value);
	assert.equal(m.reflect(null), null);
	let inner;
	const outer = m.afterCallback(value, () => {
		inner = m.reflect(make());
		assert.equal(m.reflect(null), null);
		return 0;
	});
	assert.deepStrictEqual(outer, value);
	assert.deepStrictEqual(inner, make());
	assert.deepStrictEqual(first, value);
}
assert.equal(m.afterCallback(null, () => {
	assert.deepStrictEqual(m.afterCallback(make(), () => 0), make());
	return 0;
}), null, "null outer after nonnull reentry");
const originalUnsigned = BigInt.asUintN;
const outerValue = make();
outerValue.nested = { wide: 7n, unsigned: 8n, flag: true, real: 42 };
const innerValue = make();
innerValue.f64 = 17;
innerValue.nested = { wide: null, unsigned: null, flag: false, real: null };
let inside = false;
let reentrantResult;
try {
	reentrantResult = m.afterCallback(outerValue, () => {
		BigInt.asUintN = (bits, value) => {
			if (!inside) {
				inside = true;
				try { assert.deepStrictEqual(m.afterCallback(innerValue, () => 0), innerValue); }
				finally { inside = false; }
			}
			return originalUnsigned(bits, value);
		};
		return 0;
	});
} finally {
	BigInt.asUintN = originalUnsigned;
}
assert.deepStrictEqual(reentrantResult, outerValue, "wire snapshot before reentrant conversion");
const failure = new RangeError("scalar result conversion failed");
let thrown;
try {
	m.afterCallback(make(), () => {
		BigInt.asUintN = () => { throw failure; };
		return 0;
	});
} catch (error) {
	thrown = error;
} finally {
	BigInt.asUintN = originalUnsigned;
}
assert.equal(thrown, failure, "result conversion exception");
assert.equal(m.reflect(null), null, "the wasm half runs after a failed result conversion");
assert.deepStrictEqual(m.reflect(make()), make(), "a result converts after a failed conversion");
let innerThrown;
const survivor = m.afterCallback(outerValue, () => {
	try { m.afterCallback(make(), () => { BigInt.asUintN = () => { throw failure; }; return 0; }); }
	catch (error) { innerThrown = error; }
	finally { BigInt.asUintN = originalUnsigned; }
	return 0;
});
assert.equal(innerThrown, failure, "nested result conversion exception");
assert.deepStrictEqual(survivor, outerValue, "outer result after a nested failed conversion");
console.log("mixed scalar results: true");
