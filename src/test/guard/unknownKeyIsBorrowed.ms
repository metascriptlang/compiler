// nim-guard: `unknown` is a BORROWED handle — containers keyed by it own nothing
//
// INVARIANT (Nim): `pointer` is the untraced top type. Nim's ARC/ORC never
//   emits =destroy/=copy for it, and `Table[pointer, V]` therefore keeps a raw
//   address whose lifetime belongs to whoever created it. Nim splits exactly
//   here: `options.nim:90-99` SomePointer (ptr/pointer/ref/proc/cstring) uses
//   nil-as-sentinel with no wrapper, while value types get one.
// NIM-REF: row 57 "`unknown` top type — repr + conversions" — `unknown` = `void*`
//   (getTypeDesc:713), classified `noRcInfo` beside Ptr because "pointer is
//   RC-inert, may hold foreign handles". Verdict there: DIVERGE-INTENTIONAL.
//
// WHAT IT PROTECTS: `hash(this u: unknown)` was added so `Map<unknown, V>` could
//   key on reference identity (neon's render layer: `type HostNode = unknown`,
//   and reconcileArrays builds a `Map<HostNode, number>` index). Because the key
//   is RC-inert, **the map does not keep it alive** — a key whose only owner
//   went out of scope is dangling, and reading it back yields whatever reused
//   the memory. That is correct-by-design here (the host tree owns its nodes,
//   exactly Nim's "foreign handle" case), but it is load-bearing and invisible:
//   nothing in the type or the API says the key is borrowed.
//
// This guard pins the SAFE half of that contract — a key that IS still owned
//   must survive storage, retrieval and heavy allocation churn, and the map must
//   not finalize a handle it never owned. It deliberately does NOT assert what a
//   dropped key reads back as; that value is undefined and pinning it would
//   enshrine UB.
//
// RED MEANS one of:
//   - the ledger aborts with DOUBLE-DESTROY → something started destroying a
//     borrowed `unknown` handle, i.e. `unknown` is no longer RC-inert;
//   - the value assertions fail → an owned key stopped surviving the container.
//   Either way row 57's classification moved. Run /trace-nim on `unknown`'s
//   classify arm (transform/classify) before "fixing" anything here.
// Run by src/test/guard/run.sh with -DMS_DRC_LEDGER (drc + orc).

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
