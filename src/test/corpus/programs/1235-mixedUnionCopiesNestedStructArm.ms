// @stdout: 1 1 1|7
// @stdout: 3 3|8
// @stdout: y y
struct Inner { n: int32 }
struct S { kind: "s"; inner: Inner }
class C { kind: "r" = "r"; name: string = "x" }
type U = S | C;
struct Holder { u: U }
struct Outer { h: Holder; tail: U[] }
struct T { ok: true; n: int32 }
class F { ok: false = false; name: string = "x" }
type B = T | F;
struct Flag { b: B }

function show(u: U): string {
	if (u.kind === "s") return u.inner.n.toString();
	return u.name;
}

function read(b: B): number {
	return b.ok ? b.n : -1;
}

function main(): void {
	let s: S = { kind: "s", inner: { n: 1 } };
	const u: U = s;
	const outer: Outer = { h: { u }, tail: [u] };
	const copy = outer;
	s.inner.n = 7;
	console.log(`${show(copy.h.u)} ${show(copy.tail[0])} ${show(u)}|${s.inner.n}`);
	let t: T = { ok: true, n: 3 };
	const flag: Flag = { b: t };
	const flagCopy = flag;
	t.n = 8;
	console.log(`${read(flagCopy.b)} ${read(flag.b)}|${t.n}`);
	const c = new C();
	const hc: Holder = { u: c };
	const hc2 = hc;
	c.name = "y";
	console.log(`${show(hc.u)} ${show(hc2.u)}`);
}
main();
