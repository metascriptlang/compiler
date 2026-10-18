// E2E: `arr.length = n` picks the grow helper by element type. Only a float64
// array may reach msNumberArraySetLen (double slots); a narrower element would
// pass an int32_tArray* as msNumberArray* and grow with the wrong stride.

import { compileToC } from "../helpers";

function emitFor(elem: string): string {
	const c = compileToC(`
		function main(): void {
			const xs: ${elem}[] = [1, 2, 3];
			xs.length = 5;
		}
	`);
	return c.ok ? c.value : "";
}

test "E2E C: length assign on a narrow numeric array uses the element-sized grow" {
	for (const elem of ["int32", "uint8", "int16", "float32", "int64"]) {
		const c = emitFor(elem);
		assert c != "", elem;
		assert c.contains("msGenericArraySetLen("), elem;
		assert !c.contains("msNumberArraySetLen("), elem;
	}
}

test "E2E C: length assign on a float64 array uses the element-sized grow" {
	const c = emitFor("float64");
	assert c != "";
	assert c.contains("msGenericArraySetLen(");
	assert !c.contains("msNumberArraySetLen(");
}
