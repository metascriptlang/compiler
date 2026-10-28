// @stdout: 3 13 8 21|2
// note: a declaration whose aggregate literal holds struct-valued call results in its fields, flat and nested, builds the value with nothing left over
struct V { x: float32; y: float32; }
struct Pair { p: V; q: V; }
struct Outer { inner: Pair; n: int32; tail: V; }

function mkV(x: float32, y: float32): V { return { x: x, y: y }; }
function sumV(v: V): float32 { return v.x + v.y; }

function main(): void {
	const pr: Pair = { p: mkV(1.0, 2.0), q: mkV(6.0, 7.0) };
	const o: Outer = { inner: { p: mkV(3.0, 1.0), q: mkV(2.0, 2.0) }, n: 2, tail: mkV(4.0, 4.0) };
	console.log(`${sumV(pr.p)} ${sumV(pr.q)} ${sumV(o.tail)} ${sumV(o.inner.p) + sumV(o.inner.q) + sumV(o.tail) + 5}|${o.n}`);
}
main();
