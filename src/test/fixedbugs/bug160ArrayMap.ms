// bug160 — Array.map was missing from std
// Symptom: `xs.map(fn)` reported "Property 'map' does not exist on type 'Array'" on every backend,
//          even for `number[]`.
// Root cause: std/core/array declared no map on any lane; only the non-callback methods existed. Once
//             declared, two more holes fired on C: a generic extension was instantiated from the receiver
//             alone (`U` never bound — see handoff extGenericFromArg), and the untyped arrayMethodInline
//             transform rewrote every used `.map` result into a loop over a `none`-typed temp.
// Fix: a portable `map<T, U>(this arr: T[], fn: (x: T, i: number) => U): U[]` on the C and Erlang
//      lanes beside sortBy/slice, the native `#.map(#)` binding on the JS lane, instantiation deferred
//      until the arguments bind the rest, and the inliner removed from the transform pipeline.

interface P160 { x: number; tag: string; }

test "bug160: map over numbers keeps the length and applies the mapper in order" {
	const xs: number[] = [1, 2, 3];
	const ys = xs.map((x: number): number => x * 2);
	assert ys.length === 3, "length " + ys.length.toString();
	assert ys[0] === 2 && ys[1] === 4 && ys[2] === 6, "values " + ys[0].toString() + ys[1].toString() + ys[2].toString();
	assert xs[0] === 1, "source untouched";
}

test "bug160: the mapper receives the index and may change the element type" {
	const xs: string[] = ["a", "b"];
	const tagged = xs.map((s: string, i: number): string => s + i.toString());
	assert tagged[0] === "a0" && tagged[1] === "b1", tagged[0] + tagged[1];
	const lens = xs.map((s: string): number => s.length + 1);
	assert lens[0] === 2 && lens[1] === 2, lens[0].toString();
}

test "bug160: map over interface structs and into them" {
	const ps: P160[] = [{ x: 3, tag: "p" }, { x: 4, tag: "q" }];
	const xs = ps.map((p: P160): number => p.x);
	assert xs[0] === 3 && xs[1] === 4, xs[1].toString();
	const back = xs.map((n: number): P160 => ({ x: n * 10, tag: "m" }));
	assert back[1].x === 40 && back[1].tag === "m", back[1].tag;
}

test "bug160: an empty array maps to an empty array" {
	const none: number[] = [];
	const ys = none.map((x: number): number => x);
	assert ys.length === 0;
}
