// @stdout: global 1,9 grid 7,6 field 4,5 union x 2
struct P { n: int32; name: string; }
struct A { n: int32; }
struct B { s: string; }
type U = A | B;
struct Inner { rows: P[]; one: P; u: U; }
struct Outer { inner: Inner; }

let global: P[] = [{ n: 1, name: "g" }];

function globalRows(): string {
	const alias: P[] = global;
	global = [{ n: 1, name: "a" }, { n: 9, name: "b" }];
	return alias.length.toString() + "," + global[1].n.toString();
}

function grid(): string {
	const m: P[][] = [[{ n: 1, name: "a" }], [{ n: 2, name: "b" }]];
	m[1] = [{ n: 5, name: "c" }, { n: 6, name: "d" }];
	m[0][0] = { n: 7, name: "e" };
	return m[0][0].n.toString() + "," + m[1][1].n.toString();
}

function fields(): string {
	let o: Outer = { inner: { rows: [{ n: 1, name: "a" }], one: { n: 2, name: "b" }, u: { n: 3 } as A } };
	o.inner.rows = [{ n: 4, name: "c" }];
	o.inner.one = { n: 5, name: "d" };
	o.inner.u = { s: "x" } as B;
	return o.inner.rows[0].n.toString() + "," + o.inner.one.n.toString();
}

function unions(): string {
	let o: Outer = { inner: { rows: [], one: { n: 0, name: "z" }, u: { n: 3 } as A } };
	o.inner.u = { s: "x" } as B;
	const first = (o.inner.u as B).s;
	o.inner.u = { n: 2 } as A;
	return first + " " + (o.inner.u as A).n.toString();
}

console.log("global " + globalRows() + " grid " + grid() + " field " + fields() + " union " + unions());
