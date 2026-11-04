/**
 * RSA arithmetic on `ff` limbs for the C backend (the JavaScript backend uses `rsaArith.jms` on BigInt).
 * Private operations use CRT with a secret-exponent constant-time power; key generation and inversion follow
 * mbedTLS (`mbedtls_rsa_gen_key`, `mbedtls_mpi_gen_prime`, `mbedtls_mpi_inv_mod`).
 */

import {
	Modulus, modulusFromUint, uintFromBytes, uintToBytes, uintToMinimalBytes, uintWiden, uintCompare, uintSub,
	uintMul, uintMulAdd, uintIsOne, uintBitLenPublic, uintTrailingZeroBitsPublic, uintShiftRightPublic,
	uintDivRem, uintDivRemPublic, uintGcdPublic, uintGcdModinvOdd, limbsFor, feFromBytes, reduce, sub, mul, sq,
	pow, powPublic, isMinusOne,
} from "./ff";
import { RsaPublicData, RsaPrivateData, rsaModulusBytes, sameBytes } from "./rsaKey";
import { randomOctets } from "./random";

function uintOf(bytes: Readonly<uint8[]>): uint32[] {
	const value = uintFromBytes(bytes, limbsFor(bytes.length * 8 + 1));
	if (value == null) throw new Error("rsa: an integer does not fit its own width");
	return value;
}

function modulusOf(bytes: Readonly<uint8[]>): Modulus | null {
	return modulusFromUint(uintOf(bytes));
}

// `a * b mod m == 1` for any non-zero `m`.
function productIsOneMod(a: Readonly<uint32[]>, b: Readonly<uint32[]>, m: Readonly<uint32[]>): boolean {
	return uintIsOne(uintDivRem(uintMul(a, b), m).remainder);
}

function minusOne(value: Readonly<uint32[]>): uint32[] {
	const out = uintWiden(value, value.length);
	uintSub(out, [1]);
	return out;
}

/** p * q == n, e * dp == 1 mod (p - 1), e * dq == 1 mod (q - 1) and qi * q == 1 mod p. */
export function rsaKeyConsistent(key: RsaPrivateData): boolean {
	const n = uintOf(key.n);
	const p = uintOf(key.p);
	const q = uintOf(key.q);
	const width = n.length;
	if (p.length > width || q.length > width) return false;
	const product = new Array<uint32>(width);
	if (uintMulAdd(product, uintWiden(p, width), uintWiden(q, width)) != 0 || uintCompare(product, n) != 0) return false;
	const e = uintOf(key.e);
	if (!productIsOneMod(e, uintOf(key.dp), minusOne(p)) || !productIsOneMod(e, uintOf(key.dq), minusOne(q))) return false;
	return productIsOneMod(uintOf(key.qi), q, p);
}

// `input^e mod n` as modulus-size bytes; null when the input is not below n.
export function rsaPublicOperation(key: RsaPublicData, input: Readonly<uint8[]>): uint8[] | null {
	const m = modulusOf(key.n);
	if (m == null) return null;
	const x = m.feFromBytes(input);
	if (x == null) return null;
	const y = m.powPublic(x, key.e);
	if (y == null) return null;
	return uintToBytes(y, rsaModulusBytes(key.n));
}

// CRT with a check that the result opens back to the input; null when the input is not below n.
export function rsaPrivateOperation(key: RsaPrivateData, input: Readonly<uint8[]>): uint8[] | null {
	const n = modulusOf(key.n);
	const mp = modulusOf(key.p);
	const mq = modulusOf(key.q);
	if (n == null || mp == null || mq == null) return null;
	const c = n.feFromBytes(input);
	if (c == null) return null;
	const m1 = mp.pow(mp.reduce(c), key.dp);
	const m2 = mq.pow(mq.reduce(c), key.dq);
	if (m1 == null || m2 == null) return null;
	const h = mp.mul(mp.reduce(uintOf(key.qi)), mp.sub(m1, mp.reduce(m2)));
	const width = c.length;
	const result = uintWiden(m2, width);
	if (uintMulAdd(result, uintWiden(h, width), uintWiden(uintOf(key.q), width)) != 0) return null;
	const size = rsaModulusBytes(key.n);
	const out = uintToBytes(result, size);
	const back = out == null ? null : rsaPublicOperation({ n: key.n, e: key.e }, out);
	const padded = uintToBytes(c, size);
	if (out == null || back == null || padded == null || !sameBytes(back, padded)) return null;
	return out;
}

function oddPrimesBelow1000(): int32[] {
	const primes: int32[] = [];
	for (let candidate = 3; candidate < 1000; candidate += 2) {
		let prime = true;
		for (const known of primes) {
			if (known * known > candidate) break;
			if (candidate % known == 0) {
				prime = false;
				break;
			}
		}
		if (prime) primes.push(candidate);
	}
	return primes;
}

// The odd primes to 997, the ones mbedTLS's small-factor check divides by.
const smallPrimes: Readonly<int32[]> = oddPrimesBelow1000();

// 1 for a small prime, -1 for a small factor, 0 when Miller-Rabin must decide.
function checkSmallFactors(x: Readonly<uint32[]>): int32 {
	if ((x[0] & 1) == 0) return -1;
	for (const prime of smallPrimes) {
		if (uintDivRemPublic(uintWiden(x, x.length), prime) == 0) return uintBitLenPublic(x) <= 10 && x[0] == (prime as uint32) ? 1 : -1;
	}
	return 0;
}

function keepLowBits(x: uint32[], bits: int32): void {
	for (let i = 0; i < x.length; i++) {
		const from = i * 31;
		if (from >= bits) {
			x[i] = 0;
		} else if (bits - from < 31) {
			x[i] = x[i] & (((1 as uint32) << ((bits - from) as uint32)) - 1);
		}
	}
}

function millerRabin(x: Readonly<uint32[]>, rounds: int32): boolean {
	const m = modulusFromUint(x);
	if (m == null) return false;
	const w = minusOne(m.v);
	const s = uintTrailingZeroBitsPublic(w);
	const r = uintWiden(w, w.length);
	uintShiftRightPublic(r, s);
	const exponent = uintToMinimalBytes(r);
	const size = (uintBitLenPublic(m.v) + 7) >> 3;
	const k = uintBitLenPublic(w);
	for (let round = 0; round < rounds; round++) {
		let a = m.v;
		let count = 0;
		while (true) {
			const drawn = uintFromBytes(randomOctets(size), m.v.length);
			if (drawn == null) throw new Error("rsa: a Miller-Rabin base does not fit its modulus");
			a = drawn;
			if (uintBitLenPublic(a) > k) keepLowBits(a, k - 1);
			if (count > 30) return false;
			count += 1;
			if (uintCompare(a, w) < 0 && uintBitLenPublic(a) > 1) break;
		}
		const power = m.pow(a, exponent);
		if (power == null) return false;
		let y: uint32[] = power;
		if (m.isMinusOne(y) || uintIsOne(y)) continue;
		let j = 1;
		while (j < s && !m.isMinusOne(y)) {
			y = m.sq(y);
			if (uintIsOne(y)) break;
			j += 1;
		}
		if (!m.isMinusOne(y) || uintIsOne(y)) return false;
	}
	return true;
}

function primeRounds(bits: int32): int32 {
	if (bits >= 1450) return 4;
	if (bits >= 1150) return 5;
	if (bits >= 1000) return 6;
	if (bits >= 850) return 7;
	if (bits >= 750) return 8;
	if (bits >= 500) return 13;
	if (bits >= 250) return 28;
	if (bits >= 150) return 40;
	return 51;
}

// A prime of exactly `bits` bits at least sqrt(2) * 2^(bits - 1), as `mbedtls_mpi_gen_prime` with the low-error flag.
function generatePrime(bits: int32): uint32[] {
	const size = ((bits + 31) >> 5) * 4;
	while (true) {
		const bytes = randomOctets(size);
		const top = ((bytes[0] as uint32) << 24) | ((bytes[1] as uint32) << 16) | ((bytes[2] as uint32) << 8) | (bytes[3] as uint32);
		if (top < 0xb504f334) continue;
		const x = uintOf(bytes);
		if (size * 8 > bits) uintShiftRightPublic(x, size * 8 - bits);
		x[0] = x[0] | 1;
		const small = checkSmallFactors(x);
		if (small > 0) return x;
		if (small == 0 && millerRabin(x, primeRounds(bits))) return x;
	}
}

// `a^-1 mod n` for an even n with 1 < a < n and a odd, as `mbedtls_mpi_inv_mod_even_in_range`; null when there is none.
function inverseModEven(a: Readonly<uint32[]>, n: Readonly<uint32[]>): uint32[] | null {
	const found = uintGcdModinvOdd(uintDivRem(n, a).remainder, a);
	if (!uintIsOne(found.gcd)) return null;
	const t = uintMul(found.inverse, n);
	uintSub(t, [1]);
	const k = uintDivRem(t, a).quotient;
	const out = uintWiden(n, n.length);
	uintSub(out, k);
	return out;
}

// `a^-1 mod n` for an odd n, as `mbedtls_mpi_inv_mod_odd`; null when there is none.
function inverseModOdd(a: Readonly<uint32[]>, n: Readonly<uint32[]>): uint32[] | null {
	const found = uintGcdModinvOdd(uintDivRem(a, n).remainder, n);
	return uintIsOne(found.gcd) ? found.inverse : null;
}

// `e^-1 mod lcm(p - 1, q - 1)`, as `mbedtls_rsa_deduce_private_exponent`.
function privateExponent(p: Readonly<uint32[]>, q: Readonly<uint32[]>, e: Readonly<uint32[]>): uint32[] | null {
	const k = minusOne(p);
	const l = minusOne(q);
	const g = uintGcdPublic(k, l);
	if (g == null) return null;
	return inverseModEven(e, uintDivRem(uintMul(k, l), g).quotient);
}

/** A key with e = 65537, as `mbedtls_rsa_gen_key`: |p - q| > 2^(bits/2 - 100), p > q, d > 2^(bits/2). */
export function rsaGenerateKey(bits: int32): RsaPrivateData {
	if (bits < 1024 || bits % 2 != 0) throw new Error(`rsaGenerateKey: ${bits} bits is not an even size of at least 1024`);
	const eBytes: uint8[] = [1, 0, 1];
	const e = uintOf(eBytes);
	while (true) {
		let p = generatePrime(bits >> 1);
		let q = generatePrime(bits >> 1);
		const order = uintCompare(p, q);
		const difference = uintWiden(order >= 0 ? p : q, p.length);
		uintSub(difference, order >= 0 ? q : p);
		if (uintBitLenPublic(difference) <= (bits >> 1) - 99) continue;
		if (order < 0) {
			const t = p;
			p = q;
			q = t;
		}
		const d = privateExponent(p, q, e);
		if (d == null || uintBitLenPublic(d) <= (bits + 1) / 2) continue;
		const n = uintMul(p, q);
		const qi = inverseModOdd(q, p);
		if (qi == null || uintBitLenPublic(n) != bits) throw new Error("rsaGenerate: the generated primes do not form a key");
		return {
			n: uintToMinimalBytes(n), e: eBytes, d: uintToMinimalBytes(d), p: uintToMinimalBytes(p), q: uintToMinimalBytes(q),
			dp: uintToMinimalBytes(uintDivRem(d, minusOne(p)).remainder), dq: uintToMinimalBytes(uintDivRem(d, minusOne(q)).remainder),
			qi: uintToMinimalBytes(qi),
		};
	}
}
