// @stdout: narrowUnsigned=3 narrowSigned=1 wide=77 exact=1003
// @xfail(raiser): a user operator overload on a built-in type is not lowered for Raiser (NIM-REF CT-27 Open), so Raiser prints the built-in results
// note: an operator whose built-in form matches the operands exactly keeps the built-in when the only user overload needs a conversion: `uint32 / uint32` and `int8 % int8` stay built-in beside `/`(int64, int64) and `%`(int32, int32); an exact user overload still wins.
function `/`(this a: int64, b: int64): int64 { return 77; }
function `%`(this a: int32, b: int32): int32 { return a * 100 + b; }
function run(u: uint32, v: uint32, s: int8, t: int8, w: int64, x: int64, y: int32, z: int32): void {
	console.log(`narrowUnsigned=${u / v} narrowSigned=${s % t} wide=${w / x} exact=${y % z}`);
}
run(10, 3, 10, 3, 10, 3, 10, 3);
