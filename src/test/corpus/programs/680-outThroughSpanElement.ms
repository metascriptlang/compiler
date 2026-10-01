// @exit: 1
// @stdout: 1 42 3 7 5 9 | 3 | 10 11
// @xfail(c): C loses an out write through a span element; native Span/ref location is span-cast-void's bug653/corpus 678
// @xfail(orc): C loses an out write through a span element; native Span/ref location is span-cast-void's bug653/corpus 678
// @xfail(danger): C loses an out write through a span element; native Span/ref location is span-cast-void's bug653/corpus 678
// @xfail(san): C loses an out write through a span element; native Span/ref location is span-cast-void's bug653/corpus 678
// @xfail(raiser): the Raiser VM refuses an out write into a scalar ("writes in place only into a struct or an array")
function setInt(out v: int32, n: int32): void {
	v = n;
}

function forward(out v: int32, n: int32): void {
	setInt(v, n);
}

function fill(xs: Span<int32>): void {
	setInt(xs[0], 10);
	forward(xs[1], 11);
}

function run(): void {
	const dyn: int32[] = [1, 2, 3, 4, 5, 6];
	const v: Span<int32> = dyn[1..6];
	setInt(v[0], 42);
	const inner: Span<int32> = v[2..5];
	setInt(inner[0], 7);
	forward(inner[2], 9);
	let fixed: int32[4] = [0, 0, 0, 0];
	fill(fixed[2...3]);
	console.log(`${dyn[0]} ${dyn[1]} ${dyn[2]} ${dyn[3]} ${dyn[4]} ${dyn[5]} | ${inner.length} | ${fixed[2]} ${fixed[3]}`);
	setInt(dyn[9], 1);
	console.log(`unreached ${dyn.length}`);
}

run();
