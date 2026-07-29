// Companion module for maybe-union-identity: registers Maybe<number|string>
// in the checker's Maybe cache BEFORE LibB's Maybe<float32|string> is created.

export interface BoxA {
	w: number | string | null;
}

export function readA(b: BoxA): number {
	const v = b.w;
	if (v === null) return -1;
	if (typeof v === "string") return -2;
	return v as number;
}
