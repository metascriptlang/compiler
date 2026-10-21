// guard: a class field typed `Cursor<T>` or `Cursor<T> | null` never releases what it points at
//
// INVARIANT: a cursor is trivial in every hook, so the object's destroy leaves a cursor field
//   alone whether or not the field is nullable; a store into it adds no count either.
//
// WHAT IT CATCHES: the nullable form reaching the field destroy as a nullable ref, so dropping
//   the holder decrefs a probe the store never counted. Plain and `Readonly` pointees, because
//   the compiler's own `CLoc.locType: Cursor<Readonly<Type>> | null` died on that form.
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

class Holder {
	at: Cursor<Probe> | null = null;
	view: Cursor<Readonly<Probe>> | null = null;
	pinned: Cursor<Probe>;
	constructor(pinned: Cursor<Probe>) { this.pinned = pinned; }
}

function hold(i: int32): int32 {
	const h = new Holder(owners[i]);
	h.at = owners[(i + 1) % COUNT];
	h.view = owners[(i + 2) % COUNT];
	const at = h.at;
	return at == null ? -1 : at.tag;
}

function main(): int32 {
	for (let i = 0; i < COUNT; i++) owners.push(new Probe(i as int32));
	for (let i = 0; i < COUNT; i++) owners[i].next = owners[(i + 1) % COUNT];

	let sum = 0;
	for (let round = 0; round < 4; round++) {
		for (let i = 0; i < COUNT; i++) sum += hold(i as int32);
	}
	if (destroyed != 0) {
		console.log(`GUARD RED: dropping cursor holders destroyed ${destroyed} owned probes`);
		return 1;
	}
	for (let i = 0; i < COUNT; i++) {
		if (owners[i].tag != (i as int32)) {
			console.log(`GUARD RED: owner ${i} reads tag ${owners[i].tag}`);
			return 1;
		}
	}
	if (sum != 4 * (COUNT * (COUNT - 1) / 2)) {
		console.log(`GUARD RED: sum ${sum}`);
		return 1;
	}
	console.log("GUARD-OK");
	return 0;
}

const guardRc = main();
if (guardRc != 0) process.exit(guardRc);
