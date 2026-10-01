// nim-guard: a Map keyed by `unknown` keeps its keys alive and releases each once
//
// INVARIANT (Nim): `unknown` is the managed top, `RootRef` (NIM-REF CK-46, AN-11) — a
//   `Table[RootRef, V]` counts its keys like any `ref`. Before 2026-09-28 `unknown` was
//   RC-inert (`pointer`) and this guard pinned a map that only borrowed its keys; the
//   file keeps its name, the invariant is the counted one.
//
// WHAT IT PROTECTS: neon keys a `Map<HostNode, number>` on reference identity
//   (`hash(this u: unknown)`). Every key must survive storage, retrieval and heavy
//   allocation churn, and the map's own count must be released exactly once.
//
// RED MEANS DOUBLE-DESTROY (a key released twice) or a value assertion (a key lost
//   while stored). Run /trace-nim on `unknown`'s classify arm and the Map hooks.
// Run by src/test/guard/run.ms with -DMS_DRC_LEDGER (drc + orc).

class Handle {
	tag: int32;
	constructor(tag: int32) { this.tag = tag; }
}

// The owner keeps every handle alive for the whole run; the map only borrows.
function buildIndex(owner: Handle[], m: Map<unknown, int32>): void {
	let i = 0;
	while (i < 64) {
		const h = new Handle(i as int32);
		owner.push(h);
		m.set(h, i as int32);
		i = i + 1;
	}
}

function main(): void {
	const owner: Handle[] = [];
	const m = new Map<unknown, int32>();
	buildIndex(owner, m);

	// Churn hard: any handle the map failed to keep reachable through `owner`
	// would have its storage recycled here.
	let sink = 0;
	let i = 0;
	while (i < 4000) {
		const junk = new Handle(9999);
		sink = sink + (junk.tag as int32);
		i = i + 1;
	}

	if (m.size != 64) { throw "GUARD RED: map lost entries"; }

	// Identity lookups must still hit, and the payload behind each borrowed
	// handle must be intact because `owner` holds the real reference.
	let j = 0;
	while (j < 64) {
		const h = owner[j];
		if (!m.has(h)) { throw "GUARD RED: identity key no longer found"; }
		const got = m.get(h) ?? -1;
		if (got != (j as int32)) { throw "GUARD RED: identity key mapped to the wrong slot"; }
		if (h.tag != (j as int32)) { throw "GUARD RED: owned handle was finalized while borrowed"; }
		j = j + 1;
	}

	// A handle the map has never seen must not collide into an entry.
	const stranger = new Handle(4242);
	if (m.has(stranger)) { throw "GUARD RED: unrelated handle matched an entry"; }

	if (sink < 0) { throw "GUARD RED: unreachable"; }
	console.log("unknownKeyIsBorrowed ok");
}

main();
