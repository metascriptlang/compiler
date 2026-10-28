// @stdout: caught 3 3 3|flat 3 nested 3 sized 3|kept 7
// note: when a later field's call of an aggregate literal throws, the fields already built are released on that exit, for a flat literal, a nested one and a SizedArray one, across a loop
struct V { x: float32; y: float32; }
struct Pair { s: string; v: V; w: V; }
struct Outer { head: string; inner: Pair; tail: V; }
struct Row { a: V; b: V; c: V; }

function mkV(x: float32, y: float32): V { return { x: x, y: y }; }
function text(n: int32): string { return "item" + n.toString() + "-padding-to-own-a-heap-payload"; }
function boom(n: int32): V {
	if (n >= 0) throw new Error("boom");
	return mkV(0.0, 0.0);
}

function flat(n: int32): Pair {
	const p: Pair = { s: text(n), v: mkV(1.0, 2.0), w: boom(n) };
	return p;
}

function nested(n: int32): Outer {
	const o: Outer = { head: text(n), inner: { s: text(n + 1), v: mkV(3.0, 4.0), w: boom(n) }, tail: mkV(5.0, 6.0) };
	return o;
}

function sized(n: int32): V[3] {
	const r: V[3] = [mkV(1.0, 1.0), mkV(2.0, 2.0), boom(n)];
	return r;
}

function main(): void {
	let a = 0;
	let b = 0;
	let c = 0;
	for (let i = 0; i < 3; i += 1) {
		try { flat(i); } catch (e) { a += 1; }
		try { nested(i); } catch (e) { b += 1; }
		try { sized(i); } catch (e) { c += 1; }
	}
	console.log(`caught ${a} ${b} ${c}|flat ${a} nested ${b} sized ${c}|kept ${text(7).length > 0 ? 7 : 0}`);
}
main();
