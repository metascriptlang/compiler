// @stdout: 1 11 12 5 7
// note: typeof tells a closure from a plain object on the Raiser, and a closure literal handed to a union-typed parameter is a temporary pair the call releases, as when the parameter is the function type alone. The second axis is a second struct member.
struct P { a: int32; b: int32; }
struct Q { c: int32; }

function apply(next: P | ((v: P) => P), cur: P): P {
	if (typeof next === "function") { return next(cur); }
	return next;
}

function bump(next: Q | ((v: Q) => Q), cur: Q): Q {
	if (typeof next === "function") { return next(cur); }
	return next;
}

const x: P = { a: 1, b: 2 };
const y: P = { a: 5, b: 6 };
const w: Q = { c: 7 };
console.log(apply(x, x).a.toString() + " " + apply((p: P): P => { return { a: p.a + 10, b: p.b }; }, x).a.toString()
	+ " " + bump((q: Q): Q => { return { c: q.c + 1 }; }, { c: 11 }).c.toString()
	+ " " + apply(y, x).a.toString() + " " + bump(w, w).c.toString());
