// @exit: 1
// @stdout: sum 1998000
// @stdout: some true every true at 1007
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the sum wraps instead of stopping
// @xfail(san): the arrays alive when the overflow stops the program stay on the ledger, on main as well (inbox 2026-11-15-an-uncaught-overflow-leaves-the-arrays-of-unwound-frames-on-the-san-ledger)
// note: an @inline array method given a pure leaf arrow runs its body in place with the arrow inline, so its
// loops run in sticky blocks, and still stops at the element whose checked sum overflows.

function eager(xs: int32[]): int32 {
	return xs.map((x) => x * 2).filter((x) => x % 3 != 0).reduce((acc: int32, x) => acc + x, 0 as int32);
}

function main(): void {
	const xs: int32[] = [];
	for (let k: int32 = 0; k < 3000; k++) xs.push(k - 1000);
	console.log(`sum ${eager(xs)}`);
	console.log(`some ${xs.some((x) => x > 1400)} every ${xs.every((x) => x < 2000)} at ${xs.findIndex((x) => x == 7)}`);
	const big: int32[] = [];
	for (let k: int32 = 0; k < 3000; k++) big.push(1);
	big[2000] = 536870912;
	big[2001] = 536870912;
	console.log(eager(big));
	console.log("unreachable");
}

main();
