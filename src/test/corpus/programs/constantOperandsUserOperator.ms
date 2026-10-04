// @stdout: local=1003 literal=1003 module=1003 wide=77 runtime=1003
// @xfail(raiser): a user operator overload on a built-in type is not lowered for Raiser (NIM-REF CT-27 Open), so Raiser prints the built-in results
// note: a user operator on a built-in type runs on constant operands too: `a / b` over two `const` int32 calls the declared `/` exactly as it does over run-time values, in a function, at module level and for the int64 `%`.
function `/`(this a: int32, b: int32): int32 { return a * 100 + b; }
function `%`(this a: int64, b: int64): int64 { return 77; }
const A: int32 = 10;
const B: int32 = 3;
const Q = A / B;
const W: int64 = 10;
const M = W % (3 as int64);
function run(r: int32): void {
	const a: int32 = 10;
	const b: int32 = 3;
	console.log(`local=${a / b} literal=${a / 3} module=${Q} wide=${M} runtime=${r / b}`);
}
run(10);
