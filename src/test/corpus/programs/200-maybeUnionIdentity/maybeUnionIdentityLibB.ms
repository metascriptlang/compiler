// Companion module for maybe-union-identity: same shape as LibA but with a
// float32 payload — must get its OWN Maybe/union types, not LibA's.

export interface BoxB {
	w: float32 | string | null;
}

export function readB(b: BoxB): float32 {
	const v = b.w;
	if (v === null) return -1.0 as float32;
	if (typeof v === "string") return -2.0 as float32;
	return v as float32;
}
