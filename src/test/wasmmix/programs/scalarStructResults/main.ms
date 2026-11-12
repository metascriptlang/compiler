// @stdout: true
// @stdout: true
// @stdout: true
// @foreign-stdout: mixed scalar results: true
export { reflect, afterCallback } from "./scalarStructResultsWasm";
import { Scalars, reflect, afterCallback } from "./scalarStructResultsWasm";

const value: Scalars = {
	s8: -128, u8: 255, s16: -32768, u16: 65535,
	s32: -2147483648, u32: 4294967295,
	s64: -7, u64: 9, f32: 1.25, f64: 2.5, yes: true,
	nested: { wide: null, unsigned: null, flag: false, real: null },
};
const result = reflect(value);
console.log(result != null && result.s8 == -128 && result.u32 == 4294967295 && result.f32 == 1.25 && result.nested.flag == false);
console.log(reflect(null) == null);
const outer = afterCallback(value, (n: int32): int32 => {
	reflect(null);
	return n;
});
console.log(outer != null && outer.s64 == -7 && outer.nested.wide == null);
