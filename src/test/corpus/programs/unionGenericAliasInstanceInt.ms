// Parity program — the same generic alias union instantiated with two scalar parameters, called
// for effect and then held.
//
// @stdout: a|7
// @exit: 0

type Pair<T, E> = { ok: true, value: T } | { ok: false, error: E };

function good(): Pair<int32, int32> {
	return { ok: true, value: 7 };
}

good();
const g = good();
console.log((g.ok ? "a" : "b") + "|" + (g.ok ? g.value : 0));
