// Parity program — `x op= y`, `++` and `--` on a uint64 store what `x = x op y`
// stores: the value wraps mod 2^64 on every backend, whatever the target is.
//
// @stdout: 18446744073709551615 0 18446744073709551615 0 0 0
// @exit: 0

class Box { v: uint64 = 0; }

let g: uint64 = 0;
let calls = 0;
function at(): int32 { calls += 1; return 0; }

function main(): void {
	const max: uint64 = 18446744073709551615;
	const n: uint32 = 3;

	let a: uint64 = 5;
	a -= (10 as uint64);
	let b: uint64 = max;
	b += (2 as uint64);
	let c: uint64 = max;
	c *= (2 as uint64);
	let d: uint64 = 1;
	d -= n;
	console.log(a, b, c, d);

	const box = new Box();
	box.v -= (1 as uint64);
	const arr: uint64[] = [0 as uint64];
	arr[0] -= (1 as uint64);
	arr[at()] += (2 as uint64);
	g -= (1 as uint64);
	console.log(box.v, arr[0], g, calls);

	let e: uint64 = 0;
	e--;
	let f: uint64 = max;
	f++;
	let h: uint64 = 0;
	const before = h--;
	let k: uint64 = max;
	const after = ++k;
	console.log(e, f, h, before, k, after);

	let u: uint32 = 0;
	u -= (1 as uint32);
	let s: int64 = 5;
	s -= (10 as int64);
	console.log(u, s);
}

main();
