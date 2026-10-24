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

import { isArray, needsCopy } from "std/typetraits";

// ===== Concurrent-access guard (Go writing-flag model) =====
@builtin("MapFatal")
extern function msMapFatal(msg: string): never;

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

@builtin("Iterator")
export struct Iterator<T> {
	next: () => IteratorResult<T>;
	return: (() => IteratorResult<T>) | null;
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
export function* toItems<T>(this arr: Vec<T>): Iterator<T> {
	let i = 0;
	while (i < arr.length) {
		yield arr[i];
		i = i + 1;
	}
}

// ===== Hash Functions =====
// An empty Map/Set slot holds hcode 0, so a key that hashes to 0 takes the 314159265 sentinel.

@builtin("LoadLE64")
extern function msLoadLE64(b: Readonly<Span<uint8>>, o: int64): uint64;
@builtin("LoadLE32")
extern function msLoadLE32(b: Readonly<Span<uint8>>, o: int64): uint64;

@inline function farmRotR(v: uint64, bits: uint64): uint64 {
	return (v >> bits) | (v << ((64 as uint64) - bits));
}

@inline function farmShiftMix(v: uint64): uint64 {
	return v ^ (v >> (47 as uint64));
}

@inline function farmLen16(u: uint64, v: uint64, mul: uint64): uint64 {
	let a = (u ^ v) * mul;
	a = a ^ (a >> (47 as uint64));
	let b = (v ^ a) * mul;
	b = b ^ (b >> (47 as uint64));
	return b * mul;
}

@inline function farmLen0To16(b: Readonly<Span<uint8>>): uint64 {
	const len = b.length as int64;
	const k0 = 0xc3a5c85c97cb3127 as uint64;
	const k2 = 0x9ae16a3b2f90404f as uint64;
	const n = len as uint64;
	if (len >= 8) {
		const mul = k2 + n * (2 as uint64);
		const a = msLoadLE64(b, 0) + k2;
		const c = msLoadLE64(b, len - 8);
		return farmLen16(farmRotR(c, 37) * mul + a, (farmRotR(a, 25) + c) * mul, mul);
	}
	if (len >= 4) {
		const mul = k2 + n * (2 as uint64);
		return farmLen16(n + (msLoadLE32(b, 0) << (3 as uint64)), msLoadLE32(b, len - 4), mul);
	}
	if (len > 0) {
		const y = (b[0] as uint64) + ((b[len >> 1] as uint64) << (8 as uint64));
		const z = n + ((b[len - 1] as uint64) << (2 as uint64));
		return farmShiftMix(y * k2 ^ z * k0) * k2;
	}
	return k2;
}

@inline function farmLen17To32(b: Readonly<Span<uint8>>): uint64 {
	const len = b.length as int64;
	const k1 = 0xb492b66fbe98f273 as uint64;
	const k2 = 0x9ae16a3b2f90404f as uint64;
	const mul = k2 + (len as uint64) * (2 as uint64);
	const a = msLoadLE64(b, 0) * k1;
	const c = msLoadLE64(b, 8);
	const d = msLoadLE64(b, len - 8) * mul;
	const e = msLoadLE64(b, len - 16) * k2;
	return farmLen16(
		farmRotR(a + c, 43) + farmRotR(d, 30) + e,
		a + farmRotR(c + k2, 18) + d,
		mul,
	);
}

@inline function farmLen33To64(b: Readonly<Span<uint8>>): uint64 {
	const len = b.length as int64;
	const k2 = 0x9ae16a3b2f90404f as uint64;
	const mul = k2 + (len as uint64) * (2 as uint64);
	const a = msLoadLE64(b, 0) * k2;
	const c = msLoadLE64(b, 8);
	const d = msLoadLE64(b, len - 8) * mul;
	const e = msLoadLE64(b, len - 16) * k2;
	const y = farmRotR(a + c, 43) + farmRotR(d, 30) + e;
	const z = farmLen16(y, a + farmRotR(c + k2, 18) + d, mul);
	const f = msLoadLE64(b, 16) * mul;
	const g = msLoadLE64(b, 24);
	const h = (y + msLoadLE64(b, len - 32)) * mul;
	const i = (z + msLoadLE64(b, len - 24)) * mul;
	return farmLen16(farmRotR(f + g, 43) + farmRotR(h, 30) + i, f + farmRotR(g + a, 18) + h, mul);
}

@inline function farmWeakLen32(
	b: Readonly<Span<uint8>>,
	o: int64,
	seedA: uint64,
	seedB: uint64,
): [uint64, uint64] {
	const z = msLoadLE64(b, o + 24);
	let a = seedA + msLoadLE64(b, o);
	let c = farmRotR(seedB + a + z, 21);
	const first = a;
	a = a + msLoadLE64(b, o + 8) + msLoadLE64(b, o + 16);
	c = c + farmRotR(a, 44);
	return [a + z, c + first];
}

function farmLong(b: Readonly<Span<uint8>>): uint64 {
	const len = b.length as int64;
	const last = b[len - 64..len];
	const k0 = 0xc3a5c85c97cb3127 as uint64;
	const k1 = 0xb492b66fbe98f273 as uint64;
	const k2 = 0x9ae16a3b2f90404f as uint64;
	let y = (81 as uint64) * k1 + (113 as uint64);
	let z = farmShiftMix(y * k2 + (113 as uint64)) * k2;
	let x = (81 as uint64) * k2 + msLoadLE64(b, 0);
	let v: [uint64, uint64] = [0 as uint64, 0 as uint64];
	let w: [uint64, uint64] = [0 as uint64, 0 as uint64];
	let rest = b;
	while (rest.length > 64) {
		const block = rest[0..64];
		x = farmRotR(x + y + v[0] + msLoadLE64(block, 8), 37) * k1;
		y = farmRotR(y + v[1] + msLoadLE64(block, 48), 42) * k1;
		x = x ^ w[1];
		y = y + v[0] + msLoadLE64(block, 40);
		z = farmRotR(z + w[0], 33) * k1;
		v = farmWeakLen32(block, 0, v[1] * k1, x + w[0]);
		w = farmWeakLen32(block, 32, z + w[1], y + msLoadLE64(block, 16));
		const t = z;
		z = x;
		x = t;
		rest = rest[64..rest.length];
	}
	const mul = k1 + ((z & (0xff as uint64)) << (1 as uint64));
	const w0 = w[0] + (((len - 1) & 63) as uint64);
	const v0 = v[0] + w0;
	const w0Mixed = w0 + v0;
	x = farmRotR(x + y + v0 + msLoadLE64(last, 8), 37) * mul;
	y = farmRotR(y + v[1] + msLoadLE64(last, 48), 42) * mul;
	x = x ^ w[1] * (9 as uint64);
	y = y + v0 * (9 as uint64) + msLoadLE64(last, 40);
	z = farmRotR(z + w0Mixed, 33) * mul;
	v = farmWeakLen32(last, 0, v[1] * mul, x + w0Mixed);
	w = farmWeakLen32(last, 32, z + w[1], y + msLoadLE64(last, 16));
	return farmLen16(
		farmLen16(v[0], w[0], mul) + farmShiftMix(y) * k0 + x,
		farmLen16(v[1], w[1], mul) + z,
		mul,
	);
}

export function hashFarm(s: string): int64 {
	const b = s.asBytes();
	const len = b.length as int64;
	if (len <= 16) return int64Bits(farmLen0To16(b));
	if (len <= 32) return int64Bits(farmLen17To32(b));
	if (len <= 64) return int64Bits(farmLen33To64(b));
	return int64Bits(farmLong(b));
}

export function hashString(s: string): int64 {
	const h = hashFarm(s);
	if (h == (0 as int64)) return 314159265 as int64;
	return h;
}

// hashWangYi1 — hiXorLo is the full
// 128-bit product of two uint64, high half XOR low half (msHiXorLo in
// runtime/core/system.h). Every key type reaches this one mixing site.
@builtin("HiXorLo")
extern function msHiXorLo(a: uint64, b: uint64): uint64;

export function int64Bits(u: uint64): int64 {
	return u > 9223372036854775807 ? -((~u) as int64) - 1 : u as int64;
}

// 0 marks an empty Map/Set slot, so a key that mixes to 0 takes the sentinel.
export function hashWangYi1(x: uint64): int64 {
	const p0 = 0xa0761d6478bd642f as uint64;
	const p1 = 0xe7037ed1a0b428db as uint64;
	const p58 = (0xeb44accab455d165 as uint64) ^ (8 as uint64);
	const h = int64Bits(msHiXorLo(msHiXorLo(p0, x ^ p1), p58));
	if (h == (0 as int64)) return 314159265 as int64;
	return h;
}

@builtin("PtrBits")
extern function msPtrBits(p: Readonly<Ptr<void>>): uint64;
@builtin("Float64Bits")
extern function msFloat64Bits(d: number): uint64;

export function hashNumber(n: number): int64 {
	if (n != n) return hashWangYi1(0x7FF8000000000000 as uint64);
	return hashWangYi1(msFloat64Bits(n + 0.0));
}

export function hashPointer(p: Readonly<Ptr<void>>): int64 {
	return hashWangYi1(msPtrBits(p));
}

export function hashCombine(h: int64, v: int64): int64 {
	let r = (h as uint64) + (v as uint64);
	r = r + (r << (10 as uint64));
	r = r ^ (r >> (6 as uint64));
	return int64Bits(r);
}

export function hashFinish(h: int64): int64 {
	let r = (h as uint64) + ((h as uint64) << (3 as uint64));
	r = r ^ (r >> (11 as uint64));
	r = r + (r << (15 as uint64));
	const f = int64Bits(r);
	if (f == (0 as int64)) return 314159265 as int64;
	return f;
}

test "hashWangYi1 matches a 128-bit C product" {
	assert hashWangYi1(0 as uint64) == (-5940405725068231575 as int64);
	assert hashWangYi1(7 as uint64) == (-7855962892973491642 as int64);
	assert hashWangYi1(0xFFFFFFFFFFFFFFFF as uint64) == (8231874320669540605 as int64);
	assert hashWangYi1(0x100000000 as uint64) == (6449840086436371110 as int64);
	const m = new Map<number, string>();
	m.set(4294967295.0, "hi");
	m.set(4294967294.0, "lo");
	assert (m.get(4294967295.0) ?? "") == "hi";
	assert (m.get(4294967294.0) ?? "") == "lo";
}

class HashProbe { n: int32 = 0; }

test "reference hashing routes through the one mixing site" {
	const a = new HashProbe();
	const b = new HashProbe();
	assert a.hash() == hashWangYi1(msPtrBits(a as Ptr<void>));
	assert b.hash() == hashWangYi1(msPtrBits(b as Ptr<void>));
	assert a.hash() == a.hash(), "stable for one identity";
	const seen = new Map<unknown, string>();
	seen.set(a, "A");
	seen.set(b, "B");
	assert (seen.get(a) ?? "") == "A";
	assert (seen.get(b) ?? "") == "B";
}

// Overloaded hash — type-dispatched hash(x: int) and hash(x: string).
// Extension methods: monomorphization resolves via UFCS based on K's concrete type.
// Every scalar key type needs its own entry because UFCS matches `this` exactly —
// a scalar does not transparently widen to number during extension-method
// lookup. Without one, `Map<K, V>`'s `key.hash()` fails to resolve.
export function hash(this s: string): int64 { return hashString(s); }
export function hash(this n: number): int64 { return hashNumber(n); }
export function hash(this f: float64): int64 { return hashNumber(f as number); }
export function hash(this f: float32): int64 { return hashNumber(f as number); }
export function hash(this b: boolean): int64 { return hashWangYi1(b ? (1 as uint64) : (0 as uint64)); }
export function hash(this c: char): int64 { return hashWangYi1(c as uint64); }
export function hash(this i: int8): int64 { return hashWangYi1(i as uint64); }
export function hash(this i: int16): int64 { return hashWangYi1(i as uint64); }
export function hash(this i: int32): int64 { return hashWangYi1(i as uint64); }
export function hash(this i: int64): int64 { return hashWangYi1(i as uint64); }
export function hash(this i: uint8): int64 { return hashWangYi1(i as uint64); }
export function hash(this i: uint16): int64 { return hashWangYi1(i as uint64); }
export function hash(this i: uint32): int64 { return hashWangYi1(i as uint64); }
export function hash(this u: uint64): int64 { return hashWangYi1(u); }
export function hash(this u: Readonly<unknown>): int64 { return hashPointer(u as Readonly<Ptr<void>>); }

function sameKey<T>(a: T, b: T): boolean { return a == b; }
function sameKey(a: number, b: number): boolean { return a == b || (a != a && b != b); }
function sameKey(a: float64, b: float64): boolean { return a == b || (a != a && b != b); }
function sameKey(a: float32, b: float32): boolean { return a == b || (a != a && b != b); }

function keyHash<K>(key: Readonly<K>): int64 {
	when (isArray<K>() && !needsCopy<K>()) {
		return hashPointer(key as Readonly<Ptr<void>>);
	} else {
		const h = key.hash();
		return h == (0 as int64) ? 314159265 as int64 : h;
	}
}

test "a NaN key is found and stored once, like a TypeScript Map" {
	const zero: number = 0.0;
	const nan = zero / zero;
	const m = new Map<number, int32>();
	m.set(nan, 1);
	m.set(nan, 2);
	assert m.has(nan) && m.size == 1 && (m.get(nan) ?? 0) == 2;
	const s = new HashSet<float64>();
	s.add(nan as float64);
	s.add(nan as float64);
	assert s.size == 1 && s.has(nan as float64);
}

test "scalar keys hash by ordinal value and float bits" {
	const low = 7 as uint64;
	assert low.hash() != (low | ((1 as uint64) << (32 as uint64))).hash();
	assert low.hash() == (7 as int64).hash();
	assert (7 as int32).hash() == low.hash();
	assert (-1 as int32).hash() == (-1 as int64).hash();
	assert (0.0).hash() == (-0.0).hash();
	assert (1.0).hash() != (1.5).hash();
}

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

function hashMapRawGet<K, V>(m: Readonly<HashMap<K, V>>, key: Readonly<K>): int32 {
	if (m.data.length == 0) return -1;
	const hc = keyHash<K>(key);
	const mask: int32 = m.data.length - 1;
	let h: int32 = (hc & (mask as int64)) as int32;
	while (m.data[h].hcode != 0) {
		if (m.data[h].hcode == hc && sameKey(m.data[h].key, key)) {
			return h;
		}
		h = (h + 1) & mask;
	}
	return -1 - h;
}

function hashMapEnlarge<K, V>(m: HashMap<K, V>): void {
	let oldData = move m.data;
	const newCap = oldData.length * 2;
	const newData: Vec<HashMapEntry<K, V>> = new Array(newCap);
	m.data = newData;
	let i: int32 = 0;
	while (i < oldData.length) {
		if (oldData[i].hcode != 0) {
			const mask: int32 = newCap - 1;
			let j: int32 = (oldData[i].hcode & (mask as int64)) as int32;
			while (m.data[j].hcode != 0) { j = (j + 1) & mask; }
			m.data[j].hcode = oldData[i].hcode;
			m.data[j].key = move oldData[i].key;
			m.data[j].value = move oldData[i].value;
		}
		i = i + 1;
	}
}

export function set<K, V>(this m: HashMap<K, V>, key: K, value: V): void {
	if (m.writing) { msMapFatal("concurrent map writes"); }
	m.writing = true;
	defer hashMapEndWrite(m);
	if (m.data.length == 0) {
		const init: Vec<HashMapEntry<K, V>> = new Array(INITIAL_CAPACITY);
		m.data = init;
	}
	const hc = keyHash<K>(key);
	const idx = hashMapRawGet(m, key);
	if (idx >= 0) {
		m.data[idx].value = value;
	} else {
		if (m.data.length < (m.size + m.size / 2) || (m.data.length - m.size) < MIN_EMPTY_SLOTS) {
			hashMapEnlarge(m);
		}
		const mask: int32 = m.data.length - 1;
		let h: int32 = (hc & (mask as int64)) as int32;
		while (m.data[h].hcode != 0) { h = (h + 1) & mask; }
		m.data[h].hcode = hc;
		m.data[h].key = key;
		m.data[h].value = value;
		m.size = m.size + 1;
	}
}

export function get<K, V>(this m: HashMap<K, V>, key: Readonly<K>): V | null {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	const idx = hashMapRawGet(m, key);
	if (idx >= 0) return m.data[idx].value;
	return null;
}

export function readonlyGet<K, V>(this m: Readonly<HashMap<K, V>>, key: Readonly<K>): Readonly<V | null> {
	if (m.writing) { msMapFatal("map read during write"); }
	const idx = hashMapRawGet(m, key);
	if (idx < 0) return null;
	return m.data[idx].value;
}

export function has<K, V>(this m: Readonly<HashMap<K, V>>, key: Readonly<K>): boolean {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	return hashMapRawGet(m, key) >= 0;
}

export function delete<K, V>(this m: HashMap<K, V>, key: Readonly<K>): boolean {
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
			if (m.data[i].hcode == 0) return true;
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
		if (m.data[i].hcode != 0) result.push(m.data[i].key);
		i = i + 1;
	}
	return result;
}

export function values<K, V>(this m: HashMap<K, V>): V[] {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	const result: V[] = [];
	let i: int32 = 0;
	while (i < m.data.length) {
		if (m.data[i].hcode != 0) result.push(m.data[i].value);
		i = i + 1;
	}
	return result;
}

export function forEach<K, V>(this m: HashMap<K, V>, fn: (value: V, key: K) => void): void {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	for (const entry of m.data) {
		if (entry.hcode != 0) fn(entry.value, entry.key);
	}
}

// Iterator protocol: toItems() makes HashMap iterable with for...of.
export function* toItems<K, V>(this m: HashMap<K, V>): Iterator<K> {
	for (const entry of m.data) {
		if (m.writing) { msMapFatal("concurrent map iteration and map write"); }
		if (entry.hcode != 0) yield entry.key;
	}
}

export function* toPairs<K, V>(this m: HashMap<K, V>): Iterator<[K, V]> {
	for (const entry of m.data) {
		if (m.writing) { msMapFatal("concurrent map iteration and map write"); }
		if (entry.hcode != 0) {
			const pair: [K, V] = [entry.key, entry.value];
			yield pair;
		}
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

@builtin("StdSet")
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

function hashSetRawGet<T>(s: Readonly<HashSet<T>>, key: Readonly<T>): int32 {
	if (s.data.length == 0) return -1;
	const hc = keyHash<T>(key);
	const mask: int32 = s.data.length - 1;
	let h: int32 = (hc & (mask as int64)) as int32;
	while (s.data[h].hcode != 0) {
		if (s.data[h].hcode == hc && sameKey(s.data[h].key, key)) {
			return h;
		}
		h = (h + 1) & mask;
	}
	return -1 - h;
}

function hashSetEnlarge<T>(s: HashSet<T>): void {
	let oldData = move s.data;
	const newCap = oldData.length * 2;
	const newData: Vec<HashSetEntry<T>> = new Array(newCap);
	s.data = newData;
	let i: int32 = 0;
	while (i < oldData.length) {
		if (oldData[i].hcode != 0) {
			const mask: int32 = newCap - 1;
			let j: int32 = (oldData[i].hcode & (mask as int64)) as int32;
			while (s.data[j].hcode != 0) { j = (j + 1) & mask; }
			s.data[j].hcode = oldData[i].hcode;
			s.data[j].key = move oldData[i].key;
		}
		i = i + 1;
	}
}

export function add<T>(this s: HashSet<T>, value: T): void {
	if (s.writing) { msMapFatal("concurrent map writes"); }
	s.writing = true;
	defer hashSetEndWrite(s);
	if (s.data.length == 0) { s.data = new Array(INITIAL_CAPACITY); }
	const idx = hashSetRawGet(s, value);
	if (idx >= 0) return;
	const hc = keyHash<T>(value);
	if (s.data.length < (s.size + s.size / 2) || (s.data.length - s.size) < MIN_EMPTY_SLOTS) {
		hashSetEnlarge(s);
	}
	const mask: int32 = s.data.length - 1;
	let h: int32 = (hc & (mask as int64)) as int32;
	while (s.data[h].hcode != 0) { h = (h + 1) & mask; }
	s.data[h].hcode = hc;
	s.data[h].key = value;
	s.size = s.size + 1;
}

export function has<T>(this s: Readonly<HashSet<T>>, value: Readonly<T>): boolean {
	if (s.writing) { msMapFatal("concurrent map read and map write"); }
	return hashSetRawGet(s, value) >= 0;
}

export function delete<T>(this s: HashSet<T>, value: Readonly<T>): boolean {
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
			if (s.data[i].hcode == 0) return true;
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
		if (entry.hcode != 0) fn(entry.key);
	}
}

export function* toItems<T>(this s: HashSet<T>): Iterator<T> {
	for (const entry of s.data) {
		if (s.writing) { msMapFatal("concurrent map iteration and map write"); }
		if (entry.hcode != 0) yield entry.key;
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

function orderedMapRawGet<K, V>(m: Readonly<Map<K, V>>, key: Readonly<K>, hc: int64): int32 {
	if (m.indices.length == 0) return -1;
	const mask: int32 = m.indices.length - 1;
	let h: int32 = (hc & (mask as int64)) as int32;
	let firstOpen: int32 = -1;
	while (true) {
		const slot = m.indices[h];
		if (slot == -1) {
			if (firstOpen >= 0) return -1 - firstOpen;
			return -1 - h;
		}
		if (slot == -2) {
			if (firstOpen < 0) firstOpen = h;
		} else if (m.entries[slot].hcode == hc && sameKey(m.entries[slot].key, key)) {
			return h;
		}
		h = (h + 1) & mask;
	}
	return -1;
}

function orderedMapEnlarge<K, V>(m: Map<K, V>): void {
	const newCap = m.indices.length == 0 ? 32 : m.indices.length * 2;
	orderedMapInitIndices(m, newCap);
	const mask: int32 = newCap - 1;
	let i: int32 = 0;
	while (i < m.entries.length) {
		if (m.entries[i].hcode != 0) {
			let h: int32 = (m.entries[i].hcode & (mask as int64)) as int32;
			while (m.indices[h] != -1) { h = (h + 1) & mask; }
			m.indices[h] = i;
		}
		i = i + 1;
	}
}

function orderedMapCompact<K, V>(m: Map<K, V>): void {
	let oldEntries = move m.entries;
	let newEntries: Vec<OrderedMapEntry<K, V>> = [];
	let i: int32 = 0;
	while (i < oldEntries.length) {
		if (oldEntries[i].hcode != 0) {
			const e: OrderedMapEntry<K, V> = {
				hcode: oldEntries[i].hcode,
				key: move oldEntries[i].key,
				value: move oldEntries[i].value,
			};
			newEntries.push(e);
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
		while (m.indices[h] != -1) { h = (h + 1) & mask; }
		m.indices[h] = j;
		j = j + 1;
	}
}

export function set<K, V>(this m: Map<K, V>, key: K, value: V): void {
	if (m.writing) { msMapFatal("concurrent map writes"); }
	m.writing = true;
	defer mapEndWrite(m);
	if (m.indices.length == 0) { orderedMapInitIndices(m, INITIAL_CAPACITY); }
	const hc = keyHash<K>(key);
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
		if (cur == -1) {
			if (firstOpen >= 0) { h = firstOpen; }
			break;
		}
		if (cur == -2 && firstOpen < 0) { firstOpen = h; }
		h = (h + 1) & mask;
	}
	const newEntry: OrderedMapEntry<K, V> = { hcode: hc, key: key, value: value };
	m.entries.push(newEntry);
	m.indices[h] = m.entries.length - 1;
	m.size = m.size + 1;
}

export function get<K, V>(this m: Map<K, V>, key: Readonly<K>): V | null {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	if (m.indices.length == 0) return null;
	const hc = keyHash<K>(key);
	const slot = orderedMapRawGet(m, key, hc);
	if (slot >= 0) return m.entries[m.indices[slot]].value;
	return null;
}

export function readonlyGet<K, V>(this m: Readonly<Map<K, V>>, key: Readonly<K>): Readonly<V | null> {
	if (m.writing) { msMapFatal("map read during write"); }
	if (m.indices.length == 0) return null;
	const slot = orderedMapRawGet(m, key, keyHash<K>(key));
	if (slot < 0) return null;
	return m.entries[m.indices[slot]].value;
}

export function has<K, V>(this m: Map<K, V>, key: Readonly<K>): boolean {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	if (m.indices.length == 0) return false;
	const hc = keyHash<K>(key);
	return orderedMapRawGet(m, key, hc) >= 0;
}

export function delete<K, V>(this m: Map<K, V>, key: Readonly<K>): boolean {
	if (m.writing) { msMapFatal("concurrent map writes"); }
	m.writing = true;
	defer mapEndWrite(m);
	if (m.indices.length == 0) return false;
	const hc = keyHash<K>(key);
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
		if (m.entries[i].hcode != 0) result.push(m.entries[i].key);
		i = i + 1;
	}
	return result;
}

export function values<K, V>(this m: Map<K, V>): V[] {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	const result: V[] = [];
	let i: int32 = 0;
	while (i < m.entries.length) {
		if (m.entries[i].hcode != 0) result.push(m.entries[i].value);
		i = i + 1;
	}
	return result;
}

export function forEach<K, V>(this m: Map<K, V>, fn: (value: V, key: K) => void): void {
	if (m.writing) { msMapFatal("concurrent map read and map write"); }
	for (const entry of m.entries) {
		if (entry.hcode != 0) fn(entry.value, entry.key);
	}
}

export function* toItems<K, V>(this m: Map<K, V>): Iterator<K> {
	for (const entry of m.entries) {
		if (m.writing) { msMapFatal("concurrent map iteration and map write"); }
		if (entry.hcode != 0) yield entry.key;
	}
}

export function* toPairs<K, V>(this m: Map<K, V>): Iterator<[K, V]> {
	for (const entry of m.entries) {
		if (m.writing) { msMapFatal("concurrent map iteration and map write"); }
		if (entry.hcode != 0) {
			const pair: [K, V] = [entry.key, entry.value];
			yield pair;
		}
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

@builtin("StdSet")
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

function orderedSetRawGet<T>(s: Set<T>, key: Readonly<T>, hc: int64): int32 {
	if (s.indices.length == 0) return -1;
	const mask: int32 = s.indices.length - 1;
	let h: int32 = (hc & (mask as int64)) as int32;
	let firstOpen: int32 = -1;
	while (true) {
		const slot = s.indices[h];
		if (slot == -1) {
			if (firstOpen >= 0) return -1 - firstOpen;
			return -1 - h;
		}
		if (slot == -2) {
			if (firstOpen < 0) firstOpen = h;
		} else if (s.entries[slot].hcode == hc && sameKey(s.entries[slot].key, key)) {
			return h;
		}
		h = (h + 1) & mask;
	}
	return -1;
}

function orderedSetEnlarge<T>(s: Set<T>): void {
	const newCap = s.indices.length == 0 ? 32 : s.indices.length * 2;
	orderedSetInitIndices(s, newCap);
	const mask: int32 = newCap - 1;
	let i: int32 = 0;
	while (i < s.entries.length) {
		if (s.entries[i].hcode != 0) {
			let h: int32 = (s.entries[i].hcode & (mask as int64)) as int32;
			while (s.indices[h] != -1) { h = (h + 1) & mask; }
			s.indices[h] = i;
		}
		i = i + 1;
	}
}

function orderedSetCompact<T>(s: Set<T>): void {
	let oldEntries = move s.entries;
	let newEntries: Vec<OrderedSetEntry<T>> = [];
	let i: int32 = 0;
	while (i < oldEntries.length) {
		if (oldEntries[i].hcode != 0) {
			const e: OrderedSetEntry<T> = {
				hcode: oldEntries[i].hcode,
				key: move oldEntries[i].key,
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
		while (s.indices[h] != -1) { h = (h + 1) & mask; }
		s.indices[h] = j;
		j = j + 1;
	}
}

export function add<T>(this s: Set<T>, value: T): void {
	if (s.writing) { msMapFatal("concurrent map writes"); }
	s.writing = true;
	defer setEndWrite(s);
	if (s.indices.length == 0) { orderedSetInitIndices(s, INITIAL_CAPACITY); }
	const hc = keyHash<T>(value);
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
		if (cur == -1) {
			if (firstOpen >= 0) { h = firstOpen; }
			break;
		}
		if (cur == -2 && firstOpen < 0) { firstOpen = h; }
		h = (h + 1) & mask;
	}
	const newEntry: OrderedSetEntry<T> = { hcode: hc, key: value };
	s.entries.push(newEntry);
	s.indices[h] = s.entries.length - 1;
	s.size = s.size + 1;
}

export function has<T>(this s: Set<T>, value: Readonly<T>): boolean {
	if (s.writing) { msMapFatal("concurrent map read and map write"); }
	if (s.indices.length == 0) return false;
	const hc = keyHash<T>(value);
	return orderedSetRawGet(s, value, hc) >= 0;
}

export function delete<T>(this s: Set<T>, value: Readonly<T>): boolean {
	if (s.writing) { msMapFatal("concurrent map writes"); }
	s.writing = true;
	defer setEndWrite(s);
	if (s.indices.length == 0) return false;
	const hc = keyHash<T>(value);
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
		if (entry.hcode != 0) fn(entry.key);
	}
}

export function* toItems<T>(this s: Set<T>): Iterator<T> {
	for (const entry of s.entries) {
		if (s.writing) { msMapFatal("concurrent map iteration and map write"); }
		if (entry.hcode != 0) yield entry.key;
	}
}

// Tests for Set/Map/HashSet/HashMap are in external test files (monomorphized
// constructors can't be tested inline — they emit in the defining module,
// causing typeInfo conflicts).
// ===== BitSet<E> =====
// A set of enum members: bit position = member ordinal. The checker gives
// `E.A | E.B` the type `BitSet<E>` and sizes it by the member count; the four
// operations below are declared without a body and lowered by tag before
// codegen. See docs/LANG-PRIMITIVE.md.
@builtin("SetHas")
export extern function has<E>(this self: BitSet<E>, member: E): boolean;

@builtin("SetIncl")
export extern function incl<E>(this self: BitSet<E>, member: E): BitSet<E>;

@builtin("SetExcl")
export extern function excl<E>(this self: BitSet<E>, member: E): BitSet<E>;

@builtin("SetIsEmpty")
export extern function isEmpty<E>(this self: BitSet<E>): boolean;

@builtin("SetUnion")
export extern function union<E>(this self: BitSet<E>, other: BitSet<E>): BitSet<E>;

@builtin("SetIntersection")
export extern function intersection<E>(this self: BitSet<E>, other: BitSet<E>): BitSet<E>;

@builtin("SetDifference")
export extern function difference<E>(this self: BitSet<E>, other: BitSet<E>): BitSet<E>;

@builtin("SetSymmetricDifference")
export extern function symmetricDifference<E>(this self: BitSet<E>, other: BitSet<E>): BitSet<E>;

@builtin("SetIsSubsetOf")
export extern function isSubsetOf<E>(this self: BitSet<E>, other: BitSet<E>): boolean;

@builtin("SetIsSupersetOf")
export extern function isSupersetOf<E>(this self: BitSet<E>, other: BitSet<E>): boolean;

@builtin("SetIsDisjointFrom")
export extern function isDisjointFrom<E>(this self: BitSet<E>, other: BitSet<E>): boolean;

@builtin("SetSize")
export extern function size<E>(this self: BitSet<E>): int32;

@builtin("SetHash")
export extern function hash<E>(this self: BitSet<E>): int64;

export function toItems<E>(this self: BitSet<E>): E[] {
	const result: E[] = [];
	const count = self.size();
	for (let i = 0; result.length < count; i++) {
		const m = i as E;
		if (self.has(m)) { result.push(m); }
	}
	return result;
}

export function toString<E>(this self: BitSet<E>): string {
	const items = self.toItems();
	let out = "{";
	let i = 0;
	while (i < items.length) {
		if (i > 0) { out = out + ", "; }
		out = out + items[i].toString();
		i = i + 1;
	}
	return out + "}";
}
