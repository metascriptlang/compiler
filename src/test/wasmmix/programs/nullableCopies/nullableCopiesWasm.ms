export struct Pos { x: int32; y: int32 | null; }
export struct Item { id: int32; note: string | null; score: float64 | null; ok: boolean | null; at: Pos; }

@wasm
export function bump(item: Item | null): Item | null {
	if (item == null) { return null; }
	const note = item.note;
	const score = item.score;
	const ok = item.ok;
	const y = item.at.y;
	let nextNote: string | null = null;
	if (note != null) { nextNote = note + "!"; }
	let nextScore: float64 | null = null;
	if (score != null) { nextScore = score * 2; }
	let nextOk: boolean | null = null;
	if (ok != null) { nextOk = !ok; }
	let nextY: int32 | null = null;
	if (y != null) { nextY = y + 10; }
	return { id: item.id + 1, note: nextNote, score: nextScore, ok: nextOk, at: { x: item.at.x + 1, y: nextY } };
}

@wasm
export function firstOr(xs: Vec<int32> | null, fallback: int32): int32 {
	if (xs == null) { return fallback; }
	if (xs.length == 0) { return fallback - 1; }
	return xs[0];
}

@wasm
export function upTo(n: int32): Vec<float32> | null {
	if (n < 0) { return null; }
	let out: Vec<float32> = [];
	let v: float32 = 0;
	for (let i = 0; i < n; i += 1) {
		out.push(v);
		v += 0.5;
	}
	return out;
}

@wasm
export function countTrue(flags: Vec<boolean> | null): int32 {
	if (flags == null) { return -1; }
	let n: int32 = 0;
	for (const f of flags) {
		if (f) { n += 1; }
	}
	return n;
}
