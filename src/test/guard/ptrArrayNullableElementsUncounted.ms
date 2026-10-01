// nim-guard: an array of `Ptr<void> | null` never releases its elements
//
// INVARIANT (Nim): `ptr` is trivial in every container op (liftdestructors.nim:1117-1119
//   tyPtr→defaultOp; forallElements :608-619 drops the empty element loop). A nullable
//   pointer shares the bare `void*` slot and stays trivial. NIM-REF AN-15.
//
// WHAT IT CATCHES: the nullable union bypassing the uncounted-Ptr test and reaching the
//   counted catch-all of classifyArray / the box site. Neither the cast push nor the
//   nullable local adds a count, so a counted destroy releases owners still held by
//   `owners`.
//
// RED MEANS a Probe was destroyed while still owned (the count below, or the ledger's
//   DOUBLE-DESTROY). Run /trace-nim on isUncountedPtrElement's union peel.
//
// Signalling via the exit code: an uncaught throw exits 0 on the C backend.
//
// GUARD-JS

let destroyed: int32 = 0;

class Probe {
	tag: int32;
	constructor(tag: int32) { this.tag = tag; }
	onDestroy(): void { destroyed += 1; }
}

const COUNT: int32 = 64;

function pointAtAll(owners: Probe[]): int32 {
	const addrs: (Ptr<void> | null)[] = [];
	for (let i = 0; i < owners.length; i++) {
		const slot: Ptr<void> | null = owners[i] as Ptr<void>;
		addrs.push(slot);
		addrs.push(owners[i] as Ptr<void>);
	}
	addrs.push(null);
	return addrs.length as int32;
}

function main(): int32 {
	const owners: Probe[] = [];
	for (let i = 0; i < COUNT; i++) owners.push(new Probe(i as int32));

	let pointed = 0;
	for (let round = 0; round < 4; round++) pointed += pointAtAll(owners);
	if (destroyed != 0) {
		console.log(`GUARD RED: dropping a (Ptr<void> | null)[] destroyed ${destroyed} owned probes`);
		return 1;
	}
	for (let i = 0; i < COUNT; i++) {
		if (owners[i].tag != (i as int32)) {
			console.log(`GUARD RED: owner ${i} reads tag ${owners[i].tag}`);
			return 1;
		}
	}
	if (pointed != (COUNT * 2 + 1) * 4) {
		console.log(`GUARD RED: pointed ${pointed}`);
		return 1;
	}
	console.log("GUARD-OK");
	return 0;
}

const guardRc = main();
if (guardRc != 0) process.exit(guardRc);
