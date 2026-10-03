// nim-guard: a class or struct field of type `Ptr<void>[]` never releases its elements
//
// INVARIANT (Nim): an object's `=destroy` runs its fields' hooks, and a `seq[ptr T]`
//   field's hook frees the payload only (liftdestructors.nim:1117-1119 tyPtr→defaultOp,
//   fillSeqOp :676-679). NIM-REF AN-15.
//
// WHAT IT CATCHES: the field's array cell destroyed through the counted ref family. The
//   field holds a boxed array cell, so the owner's destroy decrefs the cell and the cell's
//   TypeInfo destroyFn decides what happens to the elements (codegen refArrayDestroyFn).
//
// RED MEANS a Probe was destroyed while still owned (the count below, or the ledger's
//   DOUBLE-DESTROY). Run /trace-nim on refArrayDestroyFn and the cell's TypeInfo wiring.
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

class Holder {
	addrs: Ptr<void>[] = [];
}

struct Bag {
	addrs: Ptr<void>[];
}

const COUNT: int32 = 64;

function holdInClass(owners: Probe[]): int32 {
	const h = new Holder();
	for (let i = 0; i < owners.length; i++) h.addrs.push(owners[i] as Ptr<void>);
	return h.addrs.length as int32;
}

function holdInStruct(owners: Probe[]): int32 {
	const b: Bag = { addrs: [] };
	for (let i = 0; i < owners.length; i++) b.addrs.push(owners[i] as Ptr<void>);
	return b.addrs.length as int32;
}

function main(): int32 {
	const owners: Probe[] = [];
	for (let i = 0; i < COUNT; i++) owners.push(new Probe(i as int32));

	let held = 0;
	for (let round = 0; round < 4; round++) held += holdInClass(owners);
	if (destroyed != 0) {
		console.log(`GUARD RED: dropping a class with a Ptr<void>[] field destroyed ${destroyed} owned probes`);
		return 1;
	}
	for (let round = 0; round < 4; round++) held += holdInStruct(owners);
	if (destroyed != 0) {
		console.log(`GUARD RED: dropping a struct with a Ptr<void>[] field destroyed ${destroyed} owned probes`);
		return 1;
	}
	if (held != COUNT * 8) {
		console.log(`GUARD RED: held ${held}`);
		return 1;
	}
	console.log("GUARD-OK");
	return 0;
}

const guardRc = main();
if (guardRc != 0) process.exit(guardRc);
