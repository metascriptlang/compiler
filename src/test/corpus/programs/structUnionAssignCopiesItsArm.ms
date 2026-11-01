// @stdout: field=y source=z
// @stdout: element=y source=z
// @stdout: local=y source=z
// @stdout: nested=1 source=9
struct A { a: string; }
struct B { b: string; }
struct P { n: int32; }
struct Q { m: int32; }
struct WithP { inner: P; }
struct WithQ { inner: Q; }

class Holder {
	value: A | B;
	constructor(value: A | B) { this.value = value; }
}

function put(holder: Holder, value: A | B): void { holder.value = value; }
function putAt(items: (A | B)[], value: A | B): void { items[0] = value; }
function readB(v: A | B): string { return (v as B).b; }

function run(): void {
	const holder = new Holder({ a: "x" });
	let b: B = { b: "y" };
	put(holder, b);
	b.b = "z";
	console.log(`field=${readB(holder.value)} source=${b.b}`);

	const items: (A | B)[] = [{ a: "x" }];
	let e: B = { b: "y" };
	putAt(items, e);
	e.b = "z";
	console.log(`element=${readB(items[0])} source=${e.b}`);

	let local: A | B = { a: "x" };
	let l: B = { b: "y" };
	local = l;
	l.b = "z";
	console.log(`local=${readB(local)} source=${l.b}`);

	const start: WithQ = { inner: { m: 0 } };
	let nested: WithP | WithQ = start;
	let w: WithP = { inner: { n: 1 } };
	nested = w;
	w.inner.n = 9;
	console.log(`nested=${(nested as WithP).inner.n} source=${w.inner.n}`);
}
run();
