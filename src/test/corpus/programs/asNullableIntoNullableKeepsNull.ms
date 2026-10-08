// @stdout: kept null null 7 x
// note: `as` out of a value-carried `T | null` into a target that admits null passes an absent value through as null; only a target without null stops on it.

class Row {
	id: int32;
	constructor(id: int32) { this.id = id; }
}

function held(k: int32): int32 | Row | null {
	if (k == 0) return null;
	if (k == 1) return new Row(7);
	return 3;
}

function label(absent: boolean): string | null {
	if (absent) return null;
	return "x";
}

const none = held(0) as Row | null;
const text = label(true) as string | null;
const row = held(1) as Row | null;
const kept = label(false) as string | null;
console.log(`kept ${none == null ? "null" : "row"} ${text == null ? "null" : text} ${row == null ? "null" : row.id} ${kept == null ? "null" : kept}`);
