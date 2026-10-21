// guard: an array of `Cursor<T>` never releases its elements, beside a counted `T[]` of the same T
//
// INVARIANT: a cursor is trivial in every hook, trace included, so a `Cursor<T>[]` cell frees
//   its storage only and is never traced; its ops are keyed apart from `T[]`, whose cell
//   releases and traces every element.
//
// WHAT IT CATCHES: `Cursor<T>` and `T` sharing one op key. The push into the cursor array
//   adds no count, but the cell registered first by `owners` (counted, cyclic) is reused,
//   so dropping the cursor array releases probes still owned by `owners`. Both a class
//   field and a local, plain and `Readonly`, because the compiler's own `TypeVisitSet`
//   died on the field form.
//
// RED MEANS a Probe was destroyed while still owned (the count below, or the ledger's
//   DOUBLE-DESTROY).
//
// Signalling via the exit code: an uncaught throw exits 0 on the C backend.
//
// GUARD-JS

let destroyed: int32 = 0;

class Probe {
	tag: int32;
	next: Probe | null = null;
	constructor(tag: int32) { this.tag = tag; }
	onDestroy(): void { destroyed += 1; }
}

const COUNT: int32 = 64;
const owners: Probe[] = [];

class Visited {
	entries: Cursor<Probe>[];
	constructor() { this.entries = []; }
}

function visitField(): int32 {
	const v = new Visited();
	for (let i = 0; i < owners.length; i++) {
		v.entries.push(owners[i]);
		v.entries.push(owners[i]);
	}
	return v.entries.length as int32;
}

function visitLocalView(): int32 {
	const seen: Cursor<Readonly<Probe>>[] = [];
	for (let i = 0; i < owners.length; i++) seen.push(owners[i]);
	return seen.length as int32;
}

function main(): int32 {
	for (let i = 0; i < COUNT; i++) owners.push(new Probe(i as int32));
	for (let i = 0; i < COUNT; i++) owners[i].next = owners[(i + 1) % COUNT];

	let visited = 0;
	for (let round = 0; round < 4; round++) visited += visitField() + visitLocalView();
	if (destroyed != 0) {
		console.log(`GUARD RED: dropping a cursor array destroyed ${destroyed} owned probes`);
		return 1;
	}
	for (let i = 0; i < COUNT; i++) {
		if (owners[i].tag != (i as int32)) {
			console.log(`GUARD RED: owner ${i} reads tag ${owners[i].tag}`);
			return 1;
		}
	}
	if (visited != COUNT * 3 * 4) {
		console.log(`GUARD RED: visited ${visited}`);
		return 1;
	}
	console.log("GUARD-OK");
	return 0;
}

const guardRc = main();
if (guardRc != 0) process.exit(guardRc);
