// Trans-Am String Interner — deduplicates symbol names
//
// Each unique string gets a sequential ID. Interned strings are permanent
// (never evicted). Linear scan lookup O(n) — acceptable for <10k symbols.



// ===== Interned String Storage =====

export interface TaInternEntry {
	id: int32;
	value: string;
}

export class TaStringInterner {
	entries: TaInternEntry[];
	nextId: int32;
	index: HashMap<string, int32>;  // string → id (O(1) dedup lookup)
}

export function createStringInterner(): TaStringInterner {
	return {
		entries: [],
		nextId: 0,
		index: new HashMap<string, int32>(),
	};
}

// ===== Interner API =====

// Intern a string, returning its unique ID. Deduplicates via Map lookup.
export function internString(interner: TaStringInterner, s: string): int32 {
	if (interner.index.has(s)) return interner.index.get(s) as int32;
	const id = interner.nextId;
	interner.nextId = interner.nextId + 1;
	const entry: TaInternEntry = { id: id, value: s };
	interner.entries.push(entry);
	interner.index.set(s, id);
	return id;
}

// Retrieve interned string by ID. O(1) via direct index (id === array index).
export function lookupInterned(interner: TaStringInterner, id: int32): string {
	if (id >= 0 && id < interner.entries.length) return interner.entries[id].value;
	return "";
}

// Number of unique interned strings.
export function internedCount(interner: TaStringInterner): int32 {
	return interner.entries.length;
}

// ===== Tests =====
test "empty interner has zero count" {
	const interner = createStringInterner();
	assert internedCount(interner) === 0;
}

test "intern returns sequential IDs" {
	const interner = createStringInterner();
	const id0 = internString(interner, "hello");
	const id1 = internString(interner, "world");
	assert id0 === 0;
	assert id1 === 1;
}

test "same string returns same ID" {
	const interner = createStringInterner();
	const id1 = internString(interner, "hello");
	const id2 = internString(interner, "hello");
	assert id1 === id2;
	assert internedCount(interner) === 1;
}

test "different strings get different IDs" {
	const interner = createStringInterner();
	const a = internString(interner, "foo");
	const b = internString(interner, "bar");
	assert a !== b;
	assert internedCount(interner) === 2;
}

test "lookup retrieves correct string" {
	const interner = createStringInterner();
	const id = internString(interner, "test");
	assert lookupInterned(interner, id) === "test";
}

test "lookup unknown ID returns empty" {
	const interner = createStringInterner();
	assert lookupInterned(interner, 999) === "";
}

test "intern many strings" {
	const interner = createStringInterner();
	internString(interner, "a");
	internString(interner, "b");
	internString(interner, "c");
	internString(interner, "a");
	internString(interner, "b");
	assert internedCount(interner) === 3;
}

test "lookup after multiple interns" {
	const interner = createStringInterner();
	const idA = internString(interner, "alpha");
	const idB = internString(interner, "beta");
	const idG = internString(interner, "gamma");
	assert lookupInterned(interner, idA) === "alpha";
	assert lookupInterned(interner, idB) === "beta";
	assert lookupInterned(interner, idG) === "gamma";
}
