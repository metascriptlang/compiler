// @stdout: shl huge caught Maximum BigInt size exceeded
// @stdout: shr huge ok 0
// @xfail(raiser): the Raiser bigint has no size limit and stops the VM on a shift count past 2^40 (inbox 2026-11-04-raiser-bigint-past-size-limit-stops-the-vm)
// note: a result past the size limit throws a catchable RangeError on C, as JS does past its own; a right shift past the bit length is 0 or -1; an asUintN/asIntN width wider than the value keeps it. C used to abort with exit 134.

function show(label: string, f: () => bigint): void {
	try {
		console.log(`${label} ok ${f()}`);
	} catch (e) {
		console.log(`${label} caught ${e.message}`);
	}
}

function huge(): bigint { return 2n ** 64n; }

show("shl huge", (): bigint => 1n << huge());
show("shr huge", (): bigint => 5n >> huge());
show("shr huge negative", (): bigint => -5n >> huge());
show("shl negative huge", (): bigint => 5n << -huge());
show("pow huge", (): bigint => 2n ** (2n ** 40n));
show("asUintN wide", (): bigint => BigInt.asUintN(1099511627776, 5n));
show("asIntN wide", (): bigint => BigInt.asIntN(1099511627776, -5n));
console.log("after");
