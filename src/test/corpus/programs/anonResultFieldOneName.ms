// @stdout: 1
// @stdout: 2
// @stdout: 3
// @stdout: 4
// @exit: 0
type Held = { v: Result<int32, string>; t: uint8 };
type Flipped = { v: Result<string, int32>; t: uint8 };
type Nested = { inner: { v: Result<int32, string>; t: uint8 } };

function use<T>(x: T): T {
	return x;
}

const h: Held = { v: Result.ok(1), t: 1 };
console.log(h.t);

const f: Flipped = { v: Result.ok("x"), t: 2 };
console.log(f.t);

const n: Nested = { inner: { v: Result.ok(3), t: 3 } };
console.log(n.inner.t);

const p = use<Held>({ v: Result.ok(4), t: 4 });
console.log(p.t);
