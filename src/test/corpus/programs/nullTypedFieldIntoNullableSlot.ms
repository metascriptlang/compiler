// @stdout: class 0 0 0 0 0 0
// @stdout: kept 0 0 calls 2
// @stdout: number 0 0 0 0
// @stdout: string 0 0 0
// @stdout: slots 0 0 0
class T { x: number = 1; }
class Inner { n: null = null; }
class Holder {
	n: null = null;
	inner: Inner = new Inner();
	own(): number { return isNullClass(this.n); }
}

function isNullClass(a: T | null): number { return a == null ? 0 : 1; }
function isNullNumber(a: number | null): number { return a == null ? 0 : 1; }
function isNullString(a: string | null): number { return a == null ? 0 : 1; }
function id<U>(u: U): U { return u; }

let calls = 0;
const shared = new Holder();
function holder(): Holder {
	calls += 1;
	return shared;
}
function at(): number {
	calls += 1;
	return 0;
}

function main(): void {
	const h = new Holder();
	const arr = [null, null];
	const t = { k: null };
	console.log("class", isNullClass(h.n), isNullClass(arr[0]), isNullClass(t.k), isNullClass(id(null)), isNullClass(h.inner.n), h.own());
	console.log("kept", isNullClass(holder().n), isNullClass(arr[at()]), "calls", calls);
	console.log("number", isNullNumber(h.n), isNullNumber(t.k), isNullNumber(h.inner.n), isNullNumber(shared.n));
	console.log("string", isNullString(h.n), isNullString(t.k), isNullString(h.inner.n));
	const w: number | null = h.n;
	let s: string | null = "set";
	s = t.k;
	const c: T | null = h.inner.n;
	console.log("slots", w == null ? 0 : 1, s == null ? 0 : 1, c == null ? 0 : 1);
}

main();
