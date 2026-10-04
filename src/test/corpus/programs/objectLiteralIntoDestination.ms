// @stdout: nested=1,2,3 ok=7:9 err=poor swapped=2,1 loop=3,6 named=ada!,ada!! returned=5,4
// note: an object literal that initializes a local or is returned is built in that local or the caller's result, a nested literal in its field and a union literal in its variant; an assignment whose literal reads its destination still swaps through a temporary. Same output on every lane.
struct Inner { a: int32; b: int32; }
struct Outer { inner: Inner; n: int32; }
struct Pair { x: int32; y: int32; }
struct Named { name: string; count: int32; }
enum Fault { Poor }

function outer(a: int32, b: int32): Outer { return { inner: { a: a, b: b }, n: a + b }; }
function settle(p: Pair, ok: boolean): Result<Pair, Fault> {
	if (!ok) return Result.err(Fault.Poor);
	return Result.ok({ x: p.x + 6, y: p.y + 7 });
}
function swappedOf(p: Pair): Pair { return { x: p.y, y: p.x }; }

function main(): void {
	const o: Outer = { inner: { a: 1, b: 2 }, n: 3 };
	const good = settle({ x: 1, y: 2 }, true);
	const bad = settle({ x: 1, y: 2 }, false);
	let p: Pair = { x: 1, y: 2 };
	p = { x: p.y, y: p.x };
	let cur: Pair = { x: 1, y: 2 };
	for (let i: int32 = 0; i < 2; i++) {
		const next: Pair = { x: cur.y, y: cur.x + cur.y + i };
		cur = next;
	}
	let names = "";
	let label = "ada";
	for (let i: int32 = 0; i < 2; i++) {
		label = label + "!";
		const n: Named = { name: label, count: i };
		names = names == "" ? n.name : names + "," + n.name;
	}
	let q: Pair = { x: 4, y: 5 };
	q = swappedOf(q);
	const nested = outer(o.inner.a, o.inner.b);
	console.log(`nested=${nested.inner.a},${nested.inner.b},${nested.n} ok=${good.ok ? `${good.value.x}:${good.value.y}` : "no"} err=${bad.ok ? "no" : "poor"} swapped=${p.x},${p.y} loop=${cur.x},${cur.y} named=${names} returned=${q.x},${q.y}`);
}
main();
