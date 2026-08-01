// MetaScript Structure Prelude — Iterator<T>, Map<K,V>, Set<T>, HashMap<K,V>, HashSet<T>
// Pure MetaScript implementation — monomorphized by the compiler.
// No C runtime, no type erasure, no boxing.
// All code in one file (prelude system loads a single file per module).
//
// Four data structures, all standalone (not wrapped):
//   Map<K,V>                — insertion-ordered hash map (JS/TS spec parity). Default choice.
//   Set<T>                  — insertion-ordered hash set. Entry stores only a key (no value slot).
//   HashMap<K,V>            — unordered open-addressing hash map (Rust/Java/C++ parity).
//   HashSet<T>              — unordered open-addressing hash set. Entry stores only a key.
//
// Design note: Set is NOT "Map<T, T>"; it has its own entry type with no value
// slot, matching reference-compiler stdlib layout. This keeps memory cost minimal
// and keeps each type independently optimizable.

// ===== Concurrent-access guard (Go writing-flag model) =====
extern function msMapFatal(msg: string): void;

function hashMapEndWrite<K, V>(m: HashMap<K, V>): void { if (!m.writing) { msMapFatal("concurrent map writes"); } m.writing = false; }
function hashSetEndWrite<T>(s: HashSet<T>): void { if (!s.writing) { msMapFatal("concurrent map writes"); } s.writing = false; }
function mapEndWrite<K, V>(m: Map<K, V>): void { if (!m.writing) { msMapFatal("concurrent map writes"); } m.writing = false; }
function setEndWrite<T>(s: Set<T>): void { if (!s.writing) { msMapFatal("concurrent map writes"); } s.writing = false; }

// ===== Iterator<T> =====
// Return type for function* generators. Matches generatorLower's output shape.
// Users write: function* range(): Iterator<int32> { yield 1; }

export struct IteratorResult<T> {
	value: T;
	done: boolean;
}

export struct Iterator<T> {
	next: () => IteratorResult<T>;
}

// Drain iterator to array. Uses while+next() (not for...of — would be circular).
export function toItems<T>(this iter: Iterator<T>): T[] {
	const result: T[] = [];
	let r = iter.next();
	while (!r.done) {
		result.push(r.value);
		r = iter.next();
	}
	return result;
}

// Array items iterator — standard library parity (items for openArray).
// Arrays normally hit the fast path in iterableElemType and never need this.
// Exists as fallback: if the fast path fails, the checker's synthetic toItems() call resolves.
// Uses while (not for-of) to avoid circular dependency.
export function* toItems<T>(this arr: T[]): Iterator<T> {
	let i = 0;
	while (i < arr.length) {
		yield arr[i];
		i = i + 1;
	}
}

// ===== Hash Functions =====
// DJB2 algorithm matches std/hash.hashString, except:
// - Returns 314159265 for empty strings (Map/Set "empty slot" sentinel)
// - Returns 314159265 if hash computes to 0 (same sentinel reason)
// Kept inline because struct.ms is a prelude module loaded before std/hash.

export function hashString(s: string): int64 {
	if (s.byteLength === 0) return 314159265 as int64;
	let h: int64 = 5381;
	let i: int64 = 0;
	while (i < s.byteLength) {
		h = (h * (33 as int64) + (s.byteAt(i) as int64)) & (0xFFFFFFFF as int64);
		i = i + (1 as int64);
	}
	if (h === (0 as int64)) return 314159265 as int64;
	return h;
}

// Hash for number keys — Knuth multiplicative hash.
export function hashNumber(n: number): int64 {
	let bits = (n as int64) & (0xFFFFFFFF as int64);
	if (bits === (0 as int64)) bits = 314159265 as int64;
	// Unsigned mixing: bits reaches 2^32-1 and the
	// product exceeds INT64_MAX, which traps under overflow checks. Nim keeps
	// hash mixing in uint64 and casts to the signed Hash last (hashes.nim).
	const mixed = ((bits as uint64) * (2654435761 as uint64)) & (0xFFFFFFFF as uint64);
	const h = mixed as int64;
	if (h === (0 as int64)) return 314159265 as int64;
	return h;
}

// Knuth's constant times a full 32-bit key exceeds INT64_MAX, so mixing the
// hash with signed arithmetic is undefined behaviour and traps under zig cc's
// debug UB checks. Not theoretical: the second copy of this multiply (in the C
// runtime, fed by an ASLR'd pointer) made neon's reconcile tests fail ~1 run in
// 3 for weeks. The two copies are now one — hence the routing assertion below,
// which is what keeps them from drifting apart again.
test "hashNumber mixes without signed overflow at the 32-bit boundary" {
	assert hashNumber(4294967295.0) === (1640531535 as int64);
	assert hashNumber(4294967294.0) === (3281063070 as int64);
	assert hashNumber(2147483648.0) === (2147483648 as int64);
	assert hashNumber(0.0) === (125188177 as int64);
	const m = new Map<number, string>();
	m.set(4294967295.0, "hi");
	m.set(4294967294.0, "lo");
	assert (m.get(4294967295.0) ?? "") === "hi";
	assert (m.get(4294967294.0) ?? "") === "lo";
}

test "reference hashing routes through the one mixing site" {
	const a = new Map<number, string>();
	const b = new Map<number, string>();
	// The pointer path must BE hashNumber(fold), not a second private mix — a
	// reintroduced copy would drift from this equality even while both "work".
	assert a.hash() === hashNumber(msPtrFold(a) as number);
	assert b.hash() === hashNumber(msPtrFold(b) as number);
	// Fold is 32-bit, so the mixed result stays inside the masked range and can
	// never carry the overflowed high bits that used to trap.
	assert a.hash() >= (0 as int64) && a.hash() <= (0xFFFFFFFF as int64);
	assert msPtrFold(a) >= (0 as int64) && msPtrFold(a) <= (0xFFFFFFFF as int64);
	assert a.hash() === a.hash(), "stable for one identity";
	const seen = new Map<unknown, string>();
	seen.set(a, "A");
	seen.set(b, "B");
	assert (seen.get(a) ?? "") === "A";
	assert (seen.get(b) ?? "") === "B";
}

// Overloaded hash — type-dispatched hash(x: int) and hash(x: string).
// Extension methods: monomorphization resolves via UFCS based on K's concrete type.
// int32 needs its own entry because UFCS matches `this` exactly — int32 does
// not transparently widen to number during extension-method lookup. Without
// this, `Map<int32, V>`'s `key.hash()` fails to resolve and codegen emits raw
// member access on a primitive int (invalid C).
export function hash(this s: string): int64 { return hashString(s); }
export function hash(this n: number): int64 { return hashNumber(n); }
export function hash(this i: int32): int64 { return hashNumber(i as number); }
// Reference identity folds to 32 bits in C, then shares hashNumber's avalanche —
// one Knuth site for every key type, so the unsigned-mixing fix cannot be half
// applied again.
extern function msPtrFold(p: unknown): int64;
export function hash(this u: unknown): int64 { return hashNumber(msPtrFold(u) as number); }

// ===== DRY note =====
// The four implementations below (HashMap, HashSet, Map, Set) share ~350 lines
// of near-identical probe/enlarge/compact logic. This duplication is intentional
// for now — MS lacks a shared-impl mechanism (Nim-style `include hashcommon.nim`
// with dirty templates). See docs/GAP.md #7 for the plan. Until that lands,
// keep the four implementations visually parallel so future extraction is mechanical.

// ===== Sizing & Load-Factor Constants =====
// Shared across all four map/set implementations (HashMap, HashSet, Map, Set).
//
// INITIAL_CAPACITY — slot-array size on first insert (must be power of two for
//   mask-based index arithmetic `hc & (len - 1)`).
// MIN_EMPTY_SLOTS — minimum unused slots we preserve in the slot array. When
//   falling below this we grow; keeps probe chains short (expected ~1 lookup hop).
// REHASH_NUMERATOR/DENOMINATOR — the `slots < counter * 1.5` load-factor test:
//   encoded as `slots < counter + counter/2` in int32 arithmetic to avoid float.
// COMPACT_MIN_TOMBSTONES — ordered Map/Set compact when tombstones exceed counter,
//   but only past this floor so tiny tables don't thrash between compactions.

const INITIAL_CAPACITY: int32 = 32;
const MIN_EMPTY_SLOTS: int32 = 4;
const COMPACT_MIN_TOMBSTONES: int32 = 8;

// ===== HashMap<K, V> — unordered open-addressing hash table =====

export struct HashMapEntry<K, V> {
	hcode: int64;
	key: K;
	value: V;
}

@builtin("IndexableMap")
export class HashMap<K, V> {
	data: Vec<HashMapEntry<K, V>>;
	size: int32;
	writing: boolean;
}

function hashMapRawGet<K, V>(m: HashMap<K, V>, key: K): int32 {
	if (m.data.length === 0) return -1;
	const hc = key.hash();
	const mask: int32 = m.data.length - 1;
	let h: int32 = (hc & (mask as int64)) as int32;
	while (m.data[h].hcode !== 0) {
		if (m.data[h].hcode === hc && m.data[h].key === key) {
			return h;
		}
		h = (h + 1) & mask;
	}
	return -1 - h;
}

function hashMapEnlarge<K, V>(m: HashMap<K, V>): void {
	const oldData = m.data;
	const newCap = oldData.length * 2;
	const newData: Vec<HashMapEntry<K, V>> = new Array(newCap);
	m.data = newData;
	let i: int32 = 0;
	while (i < oldData.length) {
		if (oldData[i].hcode !== 0) {
			const mask: int32 = newCap - 1;
			let j: int32 = (oldData[i].hcode & (mask as int64)) as int32;
			while (m.data[j].hcode !== 0) { j = (j + 1) & mask; }
			m.data[j].hcode = oldData[i].hcode;
			m.data[j].key = oldData[i].key;
			m.data[j].value = oldData[i].value;
		}
		i = i + 1;
	}
}

export function set<K, V>(this m: HashMap<K, V>, key: K, value: V): void {
	if (m.writing) { msMapFatal("concurrent map writes"); }
	m.writing = true;
	defer hashMapEndWrite(m);
	if (m.data.length === 0) {
		const init: Vec<HashMapEntry<K, V>> = new Array(INITIAL_CAPACITY);
		m.data = init;
	}
	const hc = key.hash();
	const idx = hashMapRawGet(m, key);
	if (idx >= 0) {
		m.data[idx].value = value;
	} else {
		if (m.data.length < (m.size + m.size / 2) || (m.data.length - m.size) < MIN_EMPTY_SLOTS) {
			hashMapEnlarge(m);
		}
		const mask: int32 = m.data.length - 1;
		let h: int32 = (hc & (mask as int64)) as int32;
		while (m.data[h].hcode !== 0) { h = (h + 1) & mask; }
		m.data[h].hcode = hc;
		m.data[h].key = key;
		m.data[h].value = value;
		m.size = m.size + 1;
	}
}

export function get<K, V>(this m: HashMap<K, V>, key: K): V | null {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	const idx = hashMapRawGet(m, key);
	if (idx >= 0) return m.data[idx].value;
	return null;
}

export function has<K, V>(this m: HashMap<K, V>, key: K): boolean {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	return hashMapRawGet(m, key) >= 0;
}

export function delete<K, V>(this m: HashMap<K, V>, key: K): boolean {
	if (m.writing) { msMapFatal("concurrent map writes"); }
	m.writing = true;
	defer hashMapEndWrite(m);
	let i = hashMapRawGet(m, key);
	if (i < 0) return false;
	const mask: int32 = m.data.length - 1;
	m.size = m.size - 1;
	// Back-shift deletion (Knuth V3 Algo 6.4R)
	while (true) {
		m.data[i].hcode = 0;
		const j = i;
		while (true) {
			i = (i + 1) & mask;
			if (m.data[i].hcode === 0) return true;
			const r: int32 = (m.data[i].hcode & (mask as int64)) as int32;
			if ((i >= r && r > j) || (r > j && j > i) || (j > i && i >= r)) {
				continue;
			}
			break;
		}
		m.data[j].hcode = m.data[i].hcode;
		m.data[j].key = m.data[i].key;
		m.data[j].value = m.data[i].value;
	}
	return true;
}

export function clear<K, V>(this m: HashMap<K, V>): void {
	if (m.writing) { msMapFatal("concurrent map writes"); }
	m.writing = true;
	defer hashMapEndWrite(m);
	let i: int32 = 0;
	while (i < m.data.length) { m.data[i].hcode = 0; i = i + 1; }
	m.size = 0;
}

export function keys<K, V>(this m: HashMap<K, V>): K[] {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	const result: K[] = [];
	let i: int32 = 0;
	while (i < m.data.length) {
		if (m.data[i].hcode !== 0) result.push(m.data[i].key);
		i = i + 1;
	}
	return result;
}

export function values<K, V>(this m: HashMap<K, V>): V[] {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	const result: V[] = [];
	let i: int32 = 0;
	while (i < m.data.length) {
		if (m.data[i].hcode !== 0) result.push(m.data[i].value);
		i = i + 1;
	}
	return result;
}

export function forEach<K, V>(this m: HashMap<K, V>, fn: (value: V, key: K) => void): void {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	for (const entry of m.data) {
		if (entry.hcode !== 0) fn(entry.value, entry.key);
	}
}

// Iterator protocol: toItems() makes HashMap iterable with for...of.
export function* toItems<K, V>(this m: HashMap<K, V>): Iterator<K> {
	for (const entry of m.data) {
		if (m.writing) { msMapFatal("concurrent map iteration and map write"); }
		if (entry.hcode !== 0) yield entry.key;
	}
}

// Bulk-construction helper for HashMap (unordered counterpart of mapFromPairs).
export function hashMapFromPairs<K, V>(keys: K[], values: V[]): HashMap<K, V> {
	const m = new HashMap<K, V>();
	let i: int32 = 0;
	while (i < keys.length) {
		if (i < values.length) {
			m.set(keys[i], values[i]);
		}
		i = i + 1;
	}
	return m;
}

// ===== HashSet<T> — unordered open-addressing hash table =====
// Own entry type: key-only (no value slot). Independent implementation from Set<T>.

export struct HashSetEntry<T> {
	hcode: int64;
	key: T;
}

export class HashSet<T> {
	data: Vec<HashSetEntry<T>>;
	size: int32;
	writing: boolean;

	constructor(items: T[] = []) {
		if (items.length > 0) {
			let cap = INITIAL_CAPACITY;
			const needed = items.length + (items.length >> 1) + MIN_EMPTY_SLOTS;
			while (cap < needed) { cap = cap * 2; }
			this.data = new Array(cap);
		}
		for (const item of items) {
			this.add(item);
		}
	}
}

function hashSetRawGet<T>(s: HashSet<T>, key: T): int32 {
	if (s.data.length === 0) return -1;
	const hc = key.hash();
	const mask: int32 = s.data.length - 1;
	let h: int32 = (hc & (mask as int64)) as int32;
	while (s.data[h].hcode !== 0) {
		if (s.data[h].hcode === hc && s.data[h].key === key) {
			return h;
		}
		h = (h + 1) & mask;
	}
	return -1 - h;
}

function hashSetEnlarge<T>(s: HashSet<T>): void {
	const oldData = s.data;
	const newCap = oldData.length * 2;
	const newData: Vec<HashSetEntry<T>> = new Array(newCap);
	s.data = newData;
	let i: int32 = 0;
	while (i < oldData.length) {
		if (oldData[i].hcode !== 0) {
			const mask: int32 = newCap - 1;
			let j: int32 = (oldData[i].hcode & (mask as int64)) as int32;
			while (s.data[j].hcode !== 0) { j = (j + 1) & mask; }
			s.data[j].hcode = oldData[i].hcode;
			s.data[j].key = oldData[i].key;
		}
		i = i + 1;
	}
}

export function add<T>(this s: HashSet<T>, value: T): void {
	if (s.writing) { msMapFatal("concurrent map writes"); }
	s.writing = true;
	defer hashSetEndWrite(s);
	if (s.data.length === 0) { s.data = new Array(INITIAL_CAPACITY); }
	const idx = hashSetRawGet(s, value);
	if (idx >= 0) return;
	const hc = value.hash();
	if (s.data.length < (s.size + s.size / 2) || (s.data.length - s.size) < MIN_EMPTY_SLOTS) {
		hashSetEnlarge(s);
	}
	const mask: int32 = s.data.length - 1;
	let h: int32 = (hc & (mask as int64)) as int32;
	while (s.data[h].hcode !== 0) { h = (h + 1) & mask; }
	s.data[h].hcode = hc;
	s.data[h].key = value;
	s.size = s.size + 1;
}

export function has<T>(this s: HashSet<T>, value: T): boolean {
	if (s.writing) { msMapFatal("concurrent map read and map write"); }
	return hashSetRawGet(s, value) >= 0;
}

export function delete<T>(this s: HashSet<T>, value: T): boolean {
	if (s.writing) { msMapFatal("concurrent map writes"); }
	s.writing = true;
	defer hashSetEndWrite(s);
	let i = hashSetRawGet(s, value);
	if (i < 0) return false;
	const mask: int32 = s.data.length - 1;
	s.size = s.size - 1;
	while (true) {
		s.data[i].hcode = 0;
		const j = i;
		while (true) {
			i = (i + 1) & mask;
			if (s.data[i].hcode === 0) return true;
			const r: int32 = (s.data[i].hcode & (mask as int64)) as int32;
			if ((i >= r && r > j) || (r > j && j > i) || (j > i && i >= r)) continue;
			break;
		}
		s.data[j].hcode = s.data[i].hcode;
		s.data[j].key = s.data[i].key;
	}
	return true;
}

export function clear<T>(this s: HashSet<T>): void {
	if (s.writing) { msMapFatal("concurrent map writes"); }
	s.writing = true;
	defer hashSetEndWrite(s);
	let i: int32 = 0;
	while (i < s.data.length) { s.data[i].hcode = 0; i = i + 1; }
	s.size = 0;
}

export function forEach<T>(this s: HashSet<T>, fn: (value: T) => void): void {
	if (s.writing) { msMapFatal("concurrent map read and map write"); }
	for (const entry of s.data) {
		if (entry.hcode !== 0) fn(entry.key);
	}
}

export function* toItems<T>(this s: HashSet<T>): Iterator<T> {
	for (const entry of s.data) {
		if (s.writing) { msMapFatal("concurrent map iteration and map write"); }
		if (entry.hcode !== 0) yield entry.key;
	}
}

// ===== Map<K, V> — insertion-ordered (IndexMap pattern) =====
//
// Layout:
//   entries[]  — insertion-ordered log. Tombstones kept in place (hcode === 0) until compaction.
//   indices[]  — hash slot table of int32 indices into entries. Sentinels:
//                  -1 = empty slot  (probe terminates lookup)
//                  -2 = tombstone   (probe continues past it for both insert and lookup)
//   counter    — live entries (excludes tombstones).
//   tombstones — count of dead entries still in entries[].
//
// Divergence from reference compiler stdlib: Nim's OrderedTable stores order
// via a `next: int` field per entry + `first`/`last` on the object (intrusive
// linked list through the slot array). We chose the IndexMap layout (separate
// entries[] + indices[]) used by Python 3.7+ dict and Rust's indexmap crate.
// Trade-off: two arrays vs one, but iteration walks a dense array (cache-friendly)
// instead of pointer-chasing through slots. Both are valid; we favor modern
// IndexMap ergonomics over reference parity here.

export struct OrderedMapEntry<K, V> {
	hcode: int64;
	key: K;
	value: V;
}

@builtin("IndexableMap")
export class Map<K, V> {
	entries: Vec<OrderedMapEntry<K, V>>;
	indices: Vec<int32>;
	size: int32;
	tombstones: int32;
	writing: boolean;
}

function orderedMapInitIndices<K, V>(m: Map<K, V>, cap: int32): void {
	m.indices = new Array(cap);
	let k: int32 = 0;
	while (k < cap) { m.indices[k] = -1; k = k + 1; }
}

function orderedMapRawGet<K, V>(m: Map<K, V>, key: K, hc: int64): int32 {
	if (m.indices.length === 0) return -1;
	const mask: int32 = m.indices.length - 1;
	let h: int32 = (hc & (mask as int64)) as int32;
	let firstOpen: int32 = -1;
	while (true) {
		const slot = m.indices[h];
		if (slot === -1) {
			if (firstOpen >= 0) return -1 - firstOpen;
			return -1 - h;
		}
		if (slot === -2) {
			if (firstOpen < 0) firstOpen = h;
		} else {
			const e = m.entries[slot];
			if (e.hcode === hc && e.key === key) return h;
		}
		h = (h + 1) & mask;
	}
	return -1;
}

function orderedMapEnlarge<K, V>(m: Map<K, V>): void {
	const newCap = m.indices.length === 0 ? 32 : m.indices.length * 2;
	orderedMapInitIndices(m, newCap);
	const mask: int32 = newCap - 1;
	let i: int32 = 0;
	while (i < m.entries.length) {
		const e = m.entries[i];
		if (e.hcode !== 0) {
			let h: int32 = (e.hcode & (mask as int64)) as int32;
			while (m.indices[h] !== -1) { h = (h + 1) & mask; }
			m.indices[h] = i;
		}
		i = i + 1;
	}
}

function orderedMapCompact<K, V>(m: Map<K, V>): void {
	const oldEntries = m.entries;
	const newEntries: Vec<OrderedMapEntry<K, V>> = [];
	let i: int32 = 0;
	while (i < oldEntries.length) {
		if (oldEntries[i].hcode !== 0) {
			newEntries.push(oldEntries[i]);
		}
		i = i + 1;
	}
	m.entries = newEntries;
	m.tombstones = 0;
	let cap = INITIAL_CAPACITY;
	const needed = m.size + (m.size >> 1) + MIN_EMPTY_SLOTS;
	while (cap < needed) { cap = cap * 2; }
	orderedMapInitIndices(m, cap);
	const mask: int32 = cap - 1;
	let j: int32 = 0;
	while (j < m.entries.length) {
		let h: int32 = (m.entries[j].hcode & (mask as int64)) as int32;
		while (m.indices[h] !== -1) { h = (h + 1) & mask; }
		m.indices[h] = j;
		j = j + 1;
	}
}

export function set<K, V>(this m: Map<K, V>, key: K, value: V): void {
	if (m.writing) { msMapFatal("concurrent map writes"); }
	m.writing = true;
	defer mapEndWrite(m);
	if (m.indices.length === 0) { orderedMapInitIndices(m, INITIAL_CAPACITY); }
	const hc = key.hash();
	const slot = orderedMapRawGet(m, key, hc);
	if (slot >= 0) {
		const entryIdx = m.indices[slot];
		m.entries[entryIdx].value = value;
		return;
	}
	if (m.indices.length < (m.size + m.size / 2) || (m.indices.length - m.size - m.tombstones) < MIN_EMPTY_SLOTS) {
		orderedMapEnlarge(m);
	}
	const mask: int32 = m.indices.length - 1;
	let h: int32 = (hc & (mask as int64)) as int32;
	let firstOpen: int32 = -1;
	while (true) {
		const cur = m.indices[h];
		if (cur === -1) {
			if (firstOpen >= 0) { h = firstOpen; }
			break;
		}
		if (cur === -2 && firstOpen < 0) { firstOpen = h; }
		h = (h + 1) & mask;
	}
	const newEntry: OrderedMapEntry<K, V> = { hcode: hc, key: key, value: value };
	m.entries.push(newEntry);
	m.indices[h] = m.entries.length - 1;
	m.size = m.size + 1;
}

export function get<K, V>(this m: Map<K, V>, key: K): V | null {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	if (m.indices.length === 0) return null;
	const hc = key.hash();
	const slot = orderedMapRawGet(m, key, hc);
	if (slot >= 0) return m.entries[m.indices[slot]].value;
	return null;
}

export function has<K, V>(this m: Map<K, V>, key: K): boolean {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	if (m.indices.length === 0) return false;
	const hc = key.hash();
	return orderedMapRawGet(m, key, hc) >= 0;
}

export function delete<K, V>(this m: Map<K, V>, key: K): boolean {
	if (m.writing) { msMapFatal("concurrent map writes"); }
	m.writing = true;
	defer mapEndWrite(m);
	if (m.indices.length === 0) return false;
	const hc = key.hash();
	const slot = orderedMapRawGet(m, key, hc);
	if (slot < 0) return false;
	const entryIdx = m.indices[slot];
	m.entries[entryIdx].hcode = 0;
	m.indices[slot] = -2;
	m.size = m.size - 1;
	m.tombstones = m.tombstones + 1;
	if (m.tombstones > m.size && m.tombstones > COMPACT_MIN_TOMBSTONES) {
		orderedMapCompact(m);
	}
	return true;
}

export function clear<K, V>(this m: Map<K, V>): void {
	if (m.writing) { msMapFatal("concurrent map writes"); }
	m.writing = true;
	defer mapEndWrite(m);
	const empty: Vec<OrderedMapEntry<K, V>> = [];
	m.entries = empty;
	let i: int32 = 0;
	while (i < m.indices.length) { m.indices[i] = -1; i = i + 1; }
	m.size = 0;
	m.tombstones = 0;
}

export function keys<K, V>(this m: Map<K, V>): K[] {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	const result: K[] = [];
	let i: int32 = 0;
	while (i < m.entries.length) {
		if (m.entries[i].hcode !== 0) result.push(m.entries[i].key);
		i = i + 1;
	}
	return result;
}

export function values<K, V>(this m: Map<K, V>): V[] {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	const result: V[] = [];
	let i: int32 = 0;
	while (i < m.entries.length) {
		if (m.entries[i].hcode !== 0) result.push(m.entries[i].value);
		i = i + 1;
	}
	return result;
}

export function forEach<K, V>(this m: Map<K, V>, fn: (value: V, key: K) => void): void {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	for (const entry of m.entries) {
		if (entry.hcode !== 0) fn(entry.value, entry.key);
	}
}

export function* toItems<K, V>(this m: Map<K, V>): Iterator<K> {
	for (const entry of m.entries) {
		if (m.writing) { msMapFatal("concurrent map iteration and map write"); }
		if (entry.hcode !== 0) yield entry.key;
	}
}

// Used by the index-signature literal lowering — `{ "k": v, ... }` assigned
// to a Map<K,V> target is rewritten to mapFromPairs([keys], [values]).
// Returns the ordered Map so the lowering preserves the JS object literal's key order.
export function mapFromPairs<K, V>(keys: K[], values: V[]): Map<K, V> {
	const m = new Map<K, V>();
	let i: int32 = 0;
	while (i < keys.length) {
		if (i < values.length) {
			m.set(keys[i], values[i]);
		}
		i = i + 1;
	}
	return m;
}

// ===== Set<T> — insertion-ordered (IndexMap pattern, key-only entries) =====
//
// Same layout as Map but entries carry only `key` (no value slot).
// Reference-compiler parity: Set / HashSet have their own key-only entry type
// for memory efficiency, independent of Map / Table.

export struct OrderedSetEntry<T> {
	hcode: int64;
	key: T;
}

export class Set<T> {
	entries: Vec<OrderedSetEntry<T>>;
	indices: Vec<int32>;
	size: int32;
	tombstones: int32;
	writing: boolean;

	constructor(items: T[] = []) {
		if (items.length > 0) {
			let cap = INITIAL_CAPACITY;
			const needed = items.length + (items.length >> 1) + MIN_EMPTY_SLOTS;
			while (cap < needed) { cap = cap * 2; }
			this.indices = new Array(cap);
			let k: int32 = 0;
			while (k < cap) { this.indices[k] = -1; k = k + 1; }
		}
		for (const item of items) {
			this.add(item);
		}
	}
}

function orderedSetInitIndices<T>(s: Set<T>, cap: int32): void {
	s.indices = new Array(cap);
	let k: int32 = 0;
	while (k < cap) { s.indices[k] = -1; k = k + 1; }
}

function orderedSetRawGet<T>(s: Set<T>, key: T, hc: int64): int32 {
	if (s.indices.length === 0) return -1;
	const mask: int32 = s.indices.length - 1;
	let h: int32 = (hc & (mask as int64)) as int32;
	let firstOpen: int32 = -1;
	while (true) {
		const slot = s.indices[h];
		if (slot === -1) {
			if (firstOpen >= 0) return -1 - firstOpen;
			return -1 - h;
		}
		if (slot === -2) {
			if (firstOpen < 0) firstOpen = h;
		} else {
			const e = s.entries[slot];
			if (e.hcode === hc && e.key === key) return h;
		}
		h = (h + 1) & mask;
	}
	return -1;
}

function orderedSetEnlarge<T>(s: Set<T>): void {
	const newCap = s.indices.length === 0 ? 32 : s.indices.length * 2;
	orderedSetInitIndices(s, newCap);
	const mask: int32 = newCap - 1;
	let i: int32 = 0;
	while (i < s.entries.length) {
		const e = s.entries[i];
		if (e.hcode !== 0) {
			let h: int32 = (e.hcode & (mask as int64)) as int32;
			while (s.indices[h] !== -1) { h = (h + 1) & mask; }
			s.indices[h] = i;
		}
		i = i + 1;
	}
}

function orderedSetCompact<T>(s: Set<T>): void {
	const oldEntries = s.entries;
	const newEntries: Vec<OrderedSetEntry<T>> = [];
	let i: int32 = 0;
	while (i < oldEntries.length) {
		if (oldEntries[i].hcode !== 0) {
			// See orderedMapCompact comment: explicit field copy so DRC incref correctly.
			const e: OrderedSetEntry<T> = {
				hcode: oldEntries[i].hcode,
				key: oldEntries[i].key,
			};
			newEntries.push(e);
		}
		i = i + 1;
	}
	s.entries = newEntries;
	s.tombstones = 0;
	let cap = INITIAL_CAPACITY;
	const needed = s.size + (s.size >> 1) + MIN_EMPTY_SLOTS;
	while (cap < needed) { cap = cap * 2; }
	orderedSetInitIndices(s, cap);
	const mask: int32 = cap - 1;
	let j: int32 = 0;
	while (j < s.entries.length) {
		let h: int32 = (s.entries[j].hcode & (mask as int64)) as int32;
		while (s.indices[h] !== -1) { h = (h + 1) & mask; }
		s.indices[h] = j;
		j = j + 1;
	}
}

export function add<T>(this s: Set<T>, value: T): void {
	if (s.writing) { msMapFatal("concurrent map writes"); }
	s.writing = true;
	defer setEndWrite(s);
	if (s.indices.length === 0) { orderedSetInitIndices(s, INITIAL_CAPACITY); }
	const hc = value.hash();
	const slot = orderedSetRawGet(s, value, hc);
	if (slot >= 0) return;
	if (s.indices.length < (s.size + s.size / 2) || (s.indices.length - s.size - s.tombstones) < MIN_EMPTY_SLOTS) {
		orderedSetEnlarge(s);
	}
	const mask: int32 = s.indices.length - 1;
	let h: int32 = (hc & (mask as int64)) as int32;
	let firstOpen: int32 = -1;
	while (true) {
		const cur = s.indices[h];
		if (cur === -1) {
			if (firstOpen >= 0) { h = firstOpen; }
			break;
		}
		if (cur === -2 && firstOpen < 0) { firstOpen = h; }
		h = (h + 1) & mask;
	}
	const newEntry: OrderedSetEntry<T> = { hcode: hc, key: value };
	s.entries.push(newEntry);
	s.indices[h] = s.entries.length - 1;
	s.size = s.size + 1;
}

export function has<T>(this s: Set<T>, value: T): boolean {
	if (s.writing) { msMapFatal("concurrent map read and map write"); }
	if (s.indices.length === 0) return false;
	const hc = value.hash();
	return orderedSetRawGet(s, value, hc) >= 0;
}

export function delete<T>(this s: Set<T>, value: T): boolean {
	if (s.writing) { msMapFatal("concurrent map writes"); }
	s.writing = true;
	defer setEndWrite(s);
	if (s.indices.length === 0) return false;
	const hc = value.hash();
	const slot = orderedSetRawGet(s, value, hc);
	if (slot < 0) return false;
	const entryIdx = s.indices[slot];
	s.entries[entryIdx].hcode = 0;
	s.indices[slot] = -2;
	s.size = s.size - 1;
	s.tombstones = s.tombstones + 1;
	if (s.tombstones > s.size && s.tombstones > COMPACT_MIN_TOMBSTONES) {
		orderedSetCompact(s);
	}
	return true;
}

export function clear<T>(this s: Set<T>): void {
	if (s.writing) { msMapFatal("concurrent map writes"); }
	s.writing = true;
	defer setEndWrite(s);
	const empty: Vec<OrderedSetEntry<T>> = [];
	s.entries = empty;
	let i: int32 = 0;
	while (i < s.indices.length) { s.indices[i] = -1; i = i + 1; }
	s.size = 0;
	s.tombstones = 0;
}

export function forEach<T>(this s: Set<T>, fn: (value: T) => void): void {
	if (s.writing) { msMapFatal("concurrent map read and map write"); }
	for (const entry of s.entries) {
		if (entry.hcode !== 0) fn(entry.key);
	}
}

export function* toItems<T>(this s: Set<T>): Iterator<T> {
	for (const entry of s.entries) {
		if (s.writing) { msMapFatal("concurrent map iteration and map write"); }
		if (entry.hcode !== 0) yield entry.key;
	}
}

// Tests for Set/Map/HashSet/HashMap are in external test files (monomorphized
// constructors can't be tested inline — they emit in the defining module,
// causing typeInfo conflicts).
