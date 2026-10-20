// @stdout: nan true|negzero -Infinity|big Infinity true|call 2.5 -0.5 true|array 3 true|fib 832040
// note: floats cross the Raiser word file as bit patterns: NaN, -0.0 and 1e308 must survive a
//   move, a call argument, a return and an array element, and deep recursion must keep its
//   word window intact.

function pass(x: number): number {
	return x;
}

function pair(a: number, b: number): number {
	return a + b * 0;
}

function fib(n: int32): int32 {
	if (n < 2) return n;
	return fib(n - 1) + fib(n - 2);
}

function main(): void {
	const out: string[] = [];
	const zeroF: number = 0.0;
	const nan = pass(zeroF / zeroF);
	out.push(`nan ${nan != nan}`);
	const zero: number = pass(-0.0);
	out.push(`negzero ${1.0 / zero}`);
	const big: number = pass(1e308);
	out.push(`big ${big * 10} ${big / 1e308 == 1}`);
	out.push(`call ${pair(2.5, 1)} ${pass(-0.5)} ${pass(1e308) == 1e308}`);
	const values: number[] = [nan, zero, big];
	out.push(`array ${values.length} ${values[2] == 1e308 && values[0] != values[0] && 1.0 / values[1] < 0}`);
	out.push(`fib ${fib(30)}`);
	console.log(out.join("|"));
}
main();
