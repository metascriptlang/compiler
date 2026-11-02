// Parity program — control: a generic alias union beside `| null` carries the union by value.
//
// @stdout: a|none
// @exit: 0

type Pair<T, E> = { ok: true, value: T } | { ok: false, error: E };

function maybe(g: boolean): Pair<int32, string> | null {
	return g ? { ok: true, value: 5 } : null;
}

const x = maybe(true);
const y = maybe(false);
console.log((x !== null && x.ok ? "a" : "none") + "|" + (y !== null && y.ok ? "a" : "none"));
