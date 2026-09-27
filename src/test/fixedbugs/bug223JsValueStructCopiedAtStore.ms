// Symptom: on JS a value struct stored through a native call kept aliasing its source: `xs.push(v); v.n = 2` read 2 back (C 1), and `fill`, `slice`, `at`, `concat`, `Map.set` and `[...xs]` shared objects the same way.
// Root cause: native externs know no value semantics, and the JS preludes neither copied a stored argument in nor a returned element out.
// Fix: a value struct passed to a `sink` parameter of a native extern is copied in, a value-struct result of a native extern is copied out, `[...xs]` copies each element, and `fill` assigns every slot on its own.

struct S223 { n: int32; }
struct In223 { v: int32; tags: Vec<int32>; }
struct Out223 { a: int32; inner: In223; }

function keep223(xs: S223[], x: S223): void { xs.push(x); }

test "bug223: push copies into a Vec and a T[]" {
	let v: S223 = { n: 1 };
	const vs: Vec<S223> = [];
	const rs: S223[] = [];
	vs.push(v);
	rs.push(v);
	v.n = 2;
	assert vs[0].n == 1;
	assert rs[0].n == 1;
}

test "bug223: a push inside a callee copies too" {
	let v: S223 = { n: 1 };
	const xs: S223[] = [];
	keep223(xs, v);
	v.n = 2;
	assert xs[0].n == 1;
}

test "bug223: Map.set copies the value, nested struct and Vec field included" {
	let o: Out223 = { a: 1, inner: { v: 2, tags: [1] } };
	const m = new Map<string, Out223>();
	m.set("k", o);
	o.inner.tags.push(5);
	o.inner.v = 7;
	const g = m.get("k")!;
	assert g.inner.v == 2;
	assert g.inner.tags.length == 1;
}

test "bug223: fill gives every slot its own copy" {
	const v: S223 = { n: 1 };
	const xs: S223[] = [{ n: 0 }, { n: 0 }];
	xs.fill(v);
	xs[0].n = 5;
	assert xs[1].n == 1;
	assert v.n == 1;
}

test "bug223: slice, at, concat and spread hand out copies" {
	const xs: S223[] = [{ n: 1 }];
	const s = xs.slice(0, 1);
	let e = xs.at(0)!;
	const c = xs.concat([]);
	const sp: S223[] = [...xs];
	s[0].n = 5;
	e.n = 6;
	c[0].n = 7;
	sp[0].n = 8;
	assert xs[0].n == 1;
}
