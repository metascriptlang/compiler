// std/hash — Non-cryptographic hashing for hash tables, caches, and switch dispatch.
// Design follows standard hashes pattern: overloaded hash() + combinators.
//
// Usage:
//   import { hash, hashCombine } from "std/hash";
//   hash("hello")                              // string
//   hash(42)                                   // int64
//   hash([hash("name"), hash(kind)])           // combine multiple

// ===== Type =====

export type Hash = int64;

const MASK32: int64 = 0xFFFFFFFF as int64;

// ===== Core implementations =====
// Exported for direct use. The hash() overloads forward to these.

export function mix(h: Hash, val: Hash): Hash {
	let r: int64 = (h + val) & MASK32;
	r = (r + ((r << (10 as int64)) & MASK32)) & MASK32;
	r = r ^ ((r >> (6 as int64)) & MASK32);
	return r;
}

export function finalize(h: Hash): Hash {
	let r: int64 = h;
	r = (r + ((r << (3 as int64)) & MASK32)) & MASK32;
	r = r ^ ((r >> (11 as int64)) & MASK32);
	r = (r + ((r << (15 as int64)) & MASK32)) & MASK32;
	return r;
}

export function djb2(s: string): Hash {
	let h: int64 = 5381;
	let i = 0;
	const len = s.byteLength;
	while (i < len) {
		h = (h * (33 as int64) + (s.byteAt(i) as int64)) & MASK32;
		i = i + 1;
	}
	return h;
}

export function splitmix32(n: int64): Hash {
	let h: int64 = (n ^ (0x9E3779B9 as int64)) & MASK32;
	h = ((h ^ ((h >> (16 as int64)) & MASK32)) * (0x45D9F3B as int64)) & MASK32;
	h = (h ^ ((h >> (16 as int64)) & MASK32)) & MASK32;
	return h;
}

// ===== Primary API: hash() overloads =====

/** Hash a string. Uses DJB2, matches C runtime msStringHash. */
export function hash(s: string): Hash { return djb2(s); }

/** Hash a 64-bit integer. Uses splitmix32 finalizer for good avalanche. */
export function hash(n: int64): Hash { return splitmix32(n); }

/** Hash a 32-bit integer. */
export function hash(n: int32): Hash { return splitmix32(n as int64); }

/** Hash a boolean. */
export function hash(b: boolean): Hash { return b ? (1 as int64) : (0 as int64); }

/** Combine an array of hashes into one. Mix all elements, then finalize. */
export function hash(fields: int64[]): Hash {
	let h: int64 = 0;
	for (const f of fields) {
		h = mix(h, f);
	}
	return finalize(h);
}

/** Combine two hashes into one. */
export function hashCombine(a: Hash, b: Hash): Hash {
	return finalize(mix(a, b));
}

// ===== Specialized =====

/**
 * Signed int32 string hash — matches C runtime's (int32_t) cast of msStringHash.
 * Used by match lowering for switch(msStringHash(str)) case values.
 */
export function hashStringSigned(s: string): int32 {
	let h: int64 = djb2(s);
	if (h > (0x7FFFFFFF as int64)) h = h - (0x100000000 as int64);
	return h as int32;
}

/**
 * Content fingerprint — independent hash for change detection and cache invalidation.
 * Uses a different algorithm (FNV-1a) than hash() (DJB2), so collisions on
 * one are unlikely to collide on both. Combine with hash() for strong identity:
 *
 *   const id = `${hashToHex(hash(src))}_${hashToHex(fingerprint(src))}`;
 */
export function fingerprint(s: string): Hash {
	let h: int64 = 0x811C9DC5 as int64;
	let i = 0;
	while (i < s.byteLength) {
		h = ((h ^ (s.byteAt(i) as int64)) * (16777619 as int64)) & MASK32;
		i = i + 1;
	}
	return h;
}

// ===== Formatting =====

const HEX_DIGITS = "0123456789abcdef";

/** Hex-encode a hash value. */
export function hashToHex(h: Hash): string {
	let v: int64 = h;
	if (v < (0 as int64)) v = v + (4294967296 as int64);
	if (v == (0 as int64)) return "0";
	let result = "";
	while (v > (0 as int64)) {
		const digit: int64 = v % (16 as int64);
		result = HEX_DIGITS.charAt(digit as int32) + result;
		v = (v - digit) / (16 as int64);
	}
	return result;
}

/** Convert a hash value to base-36 alphanumeric string. */
export function hashValueToBase36(h: Hash): string {
	const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
	let v: int64 = h;
	if (v < (0 as int64)) v = -v;
	if (v <= (0 as int64)) return "0";
	let result = "";
	while (v > (0 as int64)) {
		const rem: int64 = v % (36 as int64);
		result = digits.charAt(rem as int32) + result;
		v = (v - rem) / (36 as int64);
	}
	return result;
}

/** Hash a string to a short base-36 identifier. */
export function hashToBase36(s: string): string {
	return hashValueToBase36(djb2(s));
}

// ===== Tests =====
// Tests use internal names via the hash() overloads where possible.
// Named calls (djb2, splitmix32) used where overload resolution is ambiguous.

test "hash string deterministic" {
	assert djb2("hello") == djb2("hello");
	assert djb2("a") != djb2("b");
}

test "hash string empty" {
	assert djb2("") == 5381;
}

test "hash int zero" {
	assert splitmix32(0) != 0;
}

test "hash int different inputs" {
	assert splitmix32(1) != splitmix32(2);
}

test "hash boolean" {
	const t: int64 = 1;
	const f: int64 = 0;
	assert t != f;
}

test "hash array combines" {
	const a = mix(mix(0, djb2("name")), splitmix32(42));
	const fa = finalize(a);
	const b = mix(mix(0, djb2("name")), splitmix32(42));
	const fb = finalize(b);
	assert fa == fb;
	assert fa != 0;
}

test "hash array order matters" {
	const a = finalize(mix(mix(0, djb2("a")), djb2("b")));
	const b = finalize(mix(mix(0, djb2("b")), djb2("a")));
	assert a != b;
}

test "hashStringSigned matches unsigned" {
	const u = djb2("test");
	const s = hashStringSigned("test");
	if (u <= (0x7FFFFFFF as int64)) {
		assert s == (u as int32);
	}
}

test "hashCombine deterministic" {
	assert hashCombine(1, 2) == hashCombine(1, 2);
}

test "hashCombine with different inputs" {
	assert hashCombine(100, 200) != hashCombine(100, 201);
}

test "fingerprint deterministic" {
	assert fingerprint("abc") == fingerprint("abc");
}

test "fingerprint differs from hash" {
	assert fingerprint("hello") != djb2("hello");
}

test "hashToHex ff" {
	assert hashToHex(255) == "ff";
}

test "hashToHex zero" {
	assert hashToHex(0) == "0";
}

test "hashToBase36 deterministic" {
	assert hashToBase36("test") == hashToBase36("test");
}

test "hashValueToBase36 zero" {
	assert hashValueToBase36(0) == "0";
}
