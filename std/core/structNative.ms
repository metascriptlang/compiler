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

// ===== Hash Functions =====
// DJB2 algorithm matches std/hash.hashString, except:
// - Returns 314159265 for empty strings (Map/Set "empty slot" sentinel)
// - Returns 314159265 if hash computes to 0 (same sentinel reason)
// Kept inline because structNative.ms is a prelude module loaded before std/hash.

export function hashString(s: string): int64 {
	if (s.byteLength == 0) return 314159265 as int64;
	let h: int64 = 5381;
	let i: int64 = 0;
	while (i < s.byteLength) {
		h = (h * (33 as int64) + (s.byteAt(i as int32) as int64)) & (0xFFFFFFFF as int64);
		i = i + (1 as int64);
	}
	if (h == (0 as int64)) return 314159265 as int64;
	return h;
}

// hashWangYi1 — hiXorLo is the full
// 128-bit product of two uint64, high half XOR low half (msHiXorLo in
// runtime/core/system.h). Every key type reaches this one mixing site.
@builtin("HiXorLo")
extern function msHiXorLo(a: uint64, b: uint64): uint64;

// 0 marks an empty Map/Set slot, so a key that mixes to 0 takes the sentinel.
export function hashWangYi1(x: uint64): int64 {
	const p0 = 0xa0761d6478bd642f as uint64;
	const p1 = 0xe7037ed1a0b428db as uint64;
	const p58 = (0xeb44accab455d165 as uint64) ^ (8 as uint64);
	const h = msHiXorLo(msHiXorLo(p0, x ^ p1), p58) as int64;
	if (h == (0 as int64)) return 314159265 as int64;
	return h;
}

@builtin("PtrBits")
extern function msPtrBits(p: Ptr<void>): uint64;
@builtin("Float64Bits")
extern function msFloat64Bits(d: number): uint64;

export function hashNumber(n: number): int64 { return hashWangYi1(msFloat64Bits(n + 0.0)); }

export function hashCombine(h: int64, v: int64): int64 {
	let r = (h as uint64) + (v as uint64);
	r = r + (r << (10 as uint64));
	r = r ^ (r >> (6 as uint64));
	return r as int64;
}

export function hashFinish(h: int64): int64 {
	let r = (h as uint64) + ((h as uint64) << (3 as uint64));
	r = r ^ (r >> (11 as uint64));
	r = r + (r << (15 as uint64));
	const f = r as int64;
	if (f == (0 as int64)) return 314159265 as int64;
	return f;
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
export function hash(this u: unknown): int64 { return hashWangYi1(msPtrBits(u as Ptr<void>)); }

test "scalar keys hash by ordinal value and float bits" {
	const low = 7 as uint64;
	assert low.hash() != (low | ((1 as uint64) << (32 as uint64))).hash();
	assert low.hash() == (7 as int64).hash();
	assert (7 as int32).hash() == low.hash();
	assert (-1 as int32).hash() == (-1 as int64).hash();
	assert (0.0).hash() == (-0.0).hash();
	assert (1.0).hash() != (1.5).hash();
}

export struct HashMapEntry<K, V> {
	hcode: int64;
	key: K;
	value: V;
}


export struct HashSetEntry<T> {
	hcode: int64;
	key: T;
}

export struct OrderedMapEntry<K, V> {
	hcode: int64;
	key: K;
	value: V;
}

export struct OrderedSetEntry<T> {
	hcode: int64;
	key: T;
}


@builtin("SetHash")
export extern function hash<E>(this self: BitSet<E>): int64;
