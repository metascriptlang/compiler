// @stdout: ops div=1003 divAssign=-13 modOnly=77 modAssign=1 orAssign=1003 xorOnly=7 xorAssign=13
// @xfail(raiser): raiser runtime error: cannot evaluate 'ops' at comptime: symbol kind is Module (a namespace-qualified call on Raiser)
// note: on a built-in type a compound assignment is its own operator: `c /= b` calls the declared `/=`, and `n %= v` keeps the built-in `%` because only `%` is declared; `o |= b` calls the declared `|=` and `y ^= one` keeps the built-in `^`. Same output on C, JS, ESM, orc and danger.
import * as ops from "./lib/ops";
function run(a: int32, b: int32, w: int64, v: int64): void {
	const q = a / b;
	let c: int32 = a;
	c /= b;
	const m = w % v;
	let n: int64 = w;
	n %= v;
	let o: int32 = a;
	o |= b;
	const x = (a + 2) as uint32;
	const one = (b - 2) as uint32;
	const xo = x ^ one;
	let y: uint32 = x;
	y ^= one;
	console.log(`${ops.opsTag()} div=${q} divAssign=${c} modOnly=${m} modAssign=${n} orAssign=${o} xorOnly=${xo} xorAssign=${y}`);
}
run(10, 3, 10, 3);
