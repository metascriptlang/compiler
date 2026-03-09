// Test: null assignment to value types (interfaces/structs)
// `null as unknown as T` must emit `(T){0}` in C, not `((T)(void*)0)`.

import { compileToC } from "../helpers";

test "null as struct emits zero init" {
	const src = `
interface Point {
	x: number;
	y: number;
}

function makeEmpty(): Point {
	return null as unknown as Point;
}
`;
	const r = compileToC(src);
	if (r.ok) {
		// Should NOT contain ((Point)MS_NIL) — that's casting void* to struct
		const bad = r.value.indexOf("Point)MS_NIL") >= 0;
		assert !bad;
	}
}
