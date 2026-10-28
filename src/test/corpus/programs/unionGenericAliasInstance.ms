// Parity program — a non-null instance of a generic alias union (`Pair<int32, string>`) held in a
// const and read for its discriminant.
//
// @stdout: a|b
// @exit: 0

type Pair<T, E> = { ok: true, value: T } | { ok: false, error: E };

function good(): Pair<int32, string> {
	return { ok: true, value: 5 };
}

function bad(): Pair<int32, string> {
	return { ok: false, error: "no" };
}

const g = good();
const h = bad();
console.log((g.ok ? "a" : "b") + "|" + (h.ok ? "a" : "b"));
