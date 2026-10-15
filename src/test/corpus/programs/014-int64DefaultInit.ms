// The default value of an int64/uint64 slot (a field left out of a literal, an element of
// a sized array) must use the SAME numeric representation as every other int64 site on
// that backend. A local read before it is assigned is an error, so the slots are fields
// and array elements. The JS backend emitted `0n`
// (BigInt) for the default init while literals and arithmetic stayed Number —
// a mixed state the reference cannot produce, because it gates BOTH the
// representation and the operators behind one switch (optJsBigInt64). The first
// arithmetic op on such a local threw "Cannot mix BigInt and other types".
//
// Values stay far below 2^53 on purpose: fidelity at the int64 boundary is
// 013-int64Fidelity's job. This pins representation CONSISTENCY, which every
// lane must agree on whichever representation is selected, so the cross-lane
// byte compare is the whole assertion — no @stdout.

struct Slot { a: int64; u: uint64 }

function scalarSum(): int64 {
	let slot: Slot = {};
	slot.a = slot.a + 1;
	slot.a = slot.a + 41;
	return slot.a;
}

function sizedArraySum(): int64 {
	let xs: int64[4] = [];
	xs[0] = xs[0] + 10;
	xs[3] = xs[3] + 32;
	let total: int64 = 0;
	for (let i = 0; i < 4; i += 1) {
		total = total + xs[i];
	}
	return total;
}

function unsignedSum(): uint64 {
	let slot: Slot = {};
	slot.u = slot.u + 7;
	return slot.u;
}

function main(): void {
	console.log("scalar=" + scalarSum().toString());
	console.log("sizedArray=" + sizedArraySum().toString());
	console.log("unsigned=" + unsignedSum().toString());
}

main();
