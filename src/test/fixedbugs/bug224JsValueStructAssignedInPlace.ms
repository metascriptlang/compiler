// Symptom: on JS assigning a value struct into a location that already held one rebound it to a new object, so a Ptr to that location went stale: `const p = arr[0] as Ptr<S>; arr[0] = {n: 2}; p.n` read 1 (C 2).
// Root cause: every assignment emitted `x = copy(v)`; Nim's jsgen emits `x = nimCopy(x, y)` and nimCopy writes into the existing object (jssys.nim nimCopy).
// Fix: an assignment into an element, a field or a binding writes into the object in place (msValAssign, msValStore for a location with evaluated parts); a value parameter and a for-of binding are views and still rebind to their own copy.

struct S224 { n: int32; }
struct H224 { s: S224; }
struct In224 { v: int32; tags: Vec<int32>; }
struct Out224 { a: int32; inner: In224; }

function rebind224(x: S224): int32 { x = { n: 9 }; return x.n; }
function rebindVec224(a: Vec<int32>): int32 { a = [4, 4]; return a[0]; }
function idx224(i: int32): int32 { return i; }

test "bug224: a Ptr to an element sees the element's reassignment" {
	let arr: S224[1] = [{ n: 1 }];
	const p = arr[0] as Ptr<S224>;
	arr[0] = { n: 2 };
	assert p.n == 2;
}

test "bug224: a Ptr to a local and to a field see their reassignment" {
	let v: S224 = { n: 1 };
	const pv = v as Ptr<S224>;
	v = { n: 2 };
	let h: H224 = { s: { n: 1 } };
	const pf = h.s as Ptr<S224>;
	h.s = { n: 3 };
	assert pv.n == 2;
	assert pf.n == 3;
}

test "bug224: an element whose index is a call is evaluated once" {
	let arr: S224[2] = [{ n: 1 }, { n: 1 }];
	const p = arr[1] as Ptr<S224>;
	arr[idx224(1)] = { n: 4 };
	assert p.n == 4;
	assert arr[0].n == 1;
}

test "bug224: a nested struct with a Vec field is assigned in place" {
	let arr: Out224[1] = [{ a: 1, inner: { v: 2, tags: [1] } }];
	const p = arr[0] as Ptr<Out224>;
	const src: Out224 = { a: 3, inner: { v: 4, tags: [9, 9] } };
	arr[0] = src;
	assert p.a == 3;
	assert p.inner.tags.length == 2;
	src.inner.tags.push(1);
	assert p.inner.tags.length == 2;
}

test "bug224: a value parameter and a for-of binding rebind, the caller keeps its value" {
	let v: S224 = { n: 1 };
	assert rebind224(v) == 9;
	assert v.n == 1;
	const vv: Vec<int32> = [1, 2];
	assert rebindVec224(vv) == 4;
	assert vv[0] == 1;
	const xs: S224[] = [{ n: 1 }];
	for (let x of xs) { x = { n: 9 }; }
	assert xs[0].n == 1;
}
