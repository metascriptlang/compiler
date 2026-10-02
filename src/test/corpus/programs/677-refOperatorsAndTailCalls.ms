// @stdout: div=9 plus=9,1 field=9 unary=9,1 ext=9 countDown=500000500000 alternate=6,4
// @xfail(raiser): raiser runtime error: cannot assign through a pointer or ref parameter at comptime (a scalar `ref` write, not handled on Raiser)
// note: a user operator with a `ref` parameter, written in operator form, writes through to the caller's variable: compound, binary, a field target, unary and a `this ref` compound. A self tail call that passes its `ref` parameter back loops over the caller's location a million times; one that swaps two `ref` parameters stays recursive. Same output on every backend.

struct P { v: int32; }
class Box { v: int32 = 100; }

function `/=`(ref a: int32, b: int32): void { a = 9; }
function `+`(ref a: P, b: int32): int32 { a = { v: 9 }; return 1; }
function `-`(ref a: P): P { a = { v: 9 }; return { v: 1 }; }
function `%=`(this ref a: int64, b: int64): void { a = 9; }

function countDown(ref acc: int64, n: int64): void {
	if (n == 0) return;
	acc = acc + n;
	return countDown(acc, n - 1);
}

function alternate(ref a: int32, ref b: int32, n: int32): void {
	if (n == 0) return;
	a = a + n;
	return alternate(b, a, n - 1);
}

function main(): void {
	let d: int32 = 100;
	d /= 3;
	let s: P = { v: 100 };
	const r = s + 3;
	const box = new Box();
	box.v /= 3;
	let x: P = { v: 100 };
	const y: P = -x;
	let e: int64 = 100;
	e %= 7;
	let total: int64 = 0;
	countDown(total, 1000000);
	let p: int32 = 0;
	let q: int32 = 0;
	alternate(p, q, 4);
	console.log(`div=${d} plus=${s.v},${r} field=${box.v} unary=${x.v},${y.v} ext=${e} countDown=${total} alternate=${p},${q}`);
}

main();
