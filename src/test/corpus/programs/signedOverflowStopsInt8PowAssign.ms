// @exit: 1
// @stdout: kept 81 64 1162261467 -128
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the power wraps in C instead of stopping
// @skip-raiser: the raiser stops too, with a range error on stderr, which the raiser lane does not read; run it with msc run --target=raiser
// note: `**=` on an int8 local stops when the power leaves int8, as `x = x ** y` does, where it wrapped to -13 on C before;
// an int8 and an int32 power that fit keep their value.

function int8Of(n: int32): int8 { return n as int8; }
function int32Of(n: int32): int32 { return n; }

function bounds(): void {
	let a = int8Of(3);
	a **= int8Of(4);
	const xs: int8[] = [int8Of(2)];
	xs[0] **= int8Of(6);
	let w = int32Of(3);
	w **= int32Of(19);
	let low = int8Of(-2);
	low **= int8Of(7);
	console.log(`kept ${a} ${xs[0]} ${w} ${low}`);
}

function main(): void {
	let a = int8Of(3);
	a **= int8Of(5);
	console.log(`unreachable ${a}`);
}

bounds();
main();
