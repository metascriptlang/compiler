// The carrier of a bound void result is null on every backend: a bare bind,
// a chained bind, a reassignment, an awaited Promise<void>, and a ternary of
// two void calls all observe the same value, print "null" in string context,
// and compare equal to null. The awaited case is also the compile pin for the
// async env struct: its slot must not be emitted as a C `void` field.

function f(): void {}

async function h(): Promise<void> {}

async function main(): Promise<void> {
	const n = f();
	console.log("n=" + n);
	console.log(n === null);
	const m = n;
	console.log("m=" + m);
	let x: void = f();
	x = f();
	console.log(x === null);
	const aw = await h();
	console.log("aw=" + aw);
	const t = true ? f() : f();
	console.log(t === null);
}

await main();
