/**
 * RSA arithmetic on `ff` limbs for the C backend (the JavaScript backend uses `rsaArith.jms` on BigInt).
 * Private operations, key generation and inversion follow mbedTLS (`mbedtls_rsa_private` with its base and
 * exponent blinding, `mbedtls_rsa_gen_key`, `mbedtls_mpi_gen_prime`, `mbedtls_mpi_inv_mod`).
 */

import {
	Modulus,
	modulusFromUint,
	modulusFromOwnedUint,
	wipeModulus,
	uintFromBytes,
	uintToBytes,
	uintToMinimalBytes,
	uintWiden,
	uintCompare,
	uintAdd,
	uintSub,
	uintMul,
	uintMulAdd,
	uintIsOne,
	uintIsZero,
	uintBitLenPublic,
	uintTrailingZeroBitsPublic,
	uintShiftRightPublic,
	uintDivRem,
	uintDivRemPublic,
	uintGcd,
	uintGcdModinvOdd,
	limbsFor,
	feFromBytes,
	reduce,
	sub,
	mul,
	sq,
	pow,
	powPublic,
	isMinusOne,
} from "./ff";
import {
	RsaPublicData,
	RsaPrivateData,
	rsaModulusBytes,
} from "./rsaKey";
import { randomOctets } from "./random";
import { declassify, wipeBytes, wipeWords } from "./secret";

function uintOf(bytes: Readonly<uint8[]>): uint32[] {
	const value = uintFromBytes(bytes, limbsFor(bytes.length * 8 + 1));
	if (value == null) throw new Error(
		"rsa: an integer does not fit its own width",
	);
	return value;
}

/** The Montgomery constants of a key integer, built once per key; null when it is no odd modulus above 2. */
export function rsaModulusOf(bytes: Readonly<uint8[]>): Modulus | null {
	return modulusFromOwnedUint(uintOf(bytes));
}

// `a * b mod m == 1` for any non-zero `m`.
function productIsOneMod(
	a: Readonly<uint32[]>,
	b: Readonly<uint32[]>,
	m: Readonly<uint32[]>,
): boolean {
	const product = uintMul(a, b);
	const divided = uintDivRem(product, m);
	const one = uintIsOne(divided.remainder);
	for (const scratch of [product, divided.quotient, divided.remainder]) wipeWords(scratch);
	return one;
}

function minusOne(value: Readonly<uint32[]>): uint32[] {
	const out = uintWiden(value, value.length);
	uintSub(out, [1]);
	return out;
}

function productIs(
	p: Readonly<uint32[]>,
	q: Readonly<uint32[]>,
	n: Readonly<uint32[]>,
): boolean {
	const width = n.length;
	if (p.length > width || q.length > width) return false;
	const product = new Array<uint32>(width);
	const wp = uintWiden(p, width);
	const wq = uintWiden(q, width);
	const equal = uintMulAdd(product, wp, wq) == 0 && uintCompare(product, n) == 0;
	for (const scratch of [product, wp, wq]) wipeWords(scratch);
	return equal;
}

/** p * q == n, e * dp == 1 mod (p - 1), e * dq == 1 mod (q - 1) and qi * q == 1 mod p. */
export function rsaKeyConsistent(key: RsaPrivateData): boolean {
	const n = uintOf(key.n);
	const p = uintOf(key.p);
	const q = uintOf(key.q);
	const e = uintOf(key.e);
	const dp = uintOf(key.dp);
	const dq = uintOf(key.dq);
	const qi = uintOf(key.qi);
	const pMinusOne = minusOne(p);
	const qMinusOne = minusOne(q);
	try {
		return productIs(p, q, n) &&
			productIsOneMod(e, dp, pMinusOne) &&
			productIsOneMod(e, dq, qMinusOne) &&
			productIsOneMod(qi, q, p);
	} finally {
		for (const scratch of [n, p, q, e, dp, dq, qi, pMinusOne, qMinusOne]) wipeWords(scratch);
	}
}

// `input^e mod n` as modulus-size bytes; null when the input is not below n.
export function rsaPublicOperation(
	key: RsaPublicData,
	input: Readonly<uint8[]>,
): uint8[] | null {
	const m = key.nModulus;
	if (m == null) return null;
	const x = m.feFromBytes(input);
	if (x == null) return null;
	const y = m.powPublic(x, key.e);
	if (y == null) return null;
	return uintToBytes(y, rsaModulusBytes(key.n));
}

interface Blinding {
	vi: uint32[];
	vf: uint32[];
}

// A uniform value in [1, n), as `mbedtls_mpi_random` with a minimum of 1.
function randomBelow(n: Modulus): uint32[] {
	const bits = uintBitLenPublic(n.v);
	const size = (bits + 7) >> 3;
	for (let count = 0; count < 30; count++) {
		const bytes = randomOctets(size);
		bytes[0] = ((bytes[0] as int32) & (0xff >> (size * 8 - bits))) as uint8;
		const x = n.feFromBytes(bytes);
		if (x != null && !uintIsZero(x)) return x;
	}
	throw new Error("rsa: the random source gives no value below the modulus");
}

// Vi = Vf^-e mod n for a random Vf, as `rsa_prepare_blinding` on a fresh context.
function blindingPair(n: Modulus, e: Readonly<uint8[]>): Blinding {
	for (let count = 0; count < 10; count++) {
		const vf = randomBelow(n);
		const found = uintGcdModinvOdd(vf, n.v);
		if (uintIsOne(found.gcd)) {
			const vi = n.powPublic(found.inverse, e);
			wipeWords(found.inverse);
			if (vi == null) break;
			return { vi, vf };
		}
	}
	throw new Error("rsa: no blinding value is invertible modulo n");
}

// (p - 1) * r + d for a random 28-byte r, as mbedTLS's exponent blinding.
function blindedExponent(p: Readonly<uint32[]>, d: Readonly<uint8[]>): uint8[] {
	const r = uintOf(randomOctets(28));
	const blinded = uintMul(minusOne(p), r);
	const exponent = uintOf(d);
	if (declassify(uintAdd(blinded, exponent)) != 0) throw new Error(
		"rsa: a blinded exponent overflowed its width",
	);
	const bytes = uintToBytes(blinded, (blinded.length * 31 + 7) >> 3) as uint8[];
	wipeWords(r);
	wipeWords(blinded);
	wipeWords(exponent);
	return bytes;
}

// Blinded CRT checked against the public operation, as `mbedtls_rsa_private`; null when the input is not below n.
export function rsaPrivateOperation(
	key: RsaPrivateData,
	input: Readonly<uint8[]>,
): uint8[] | null {
	const n = key.nModulus;
	const mp = key.pModulus;
	const mq = key.qModulus;
	if (n == null || mp == null || mq == null) return null;
	const c = n.feFromBytes(input);
	if (c == null) return null;
	const p = uintOf(key.p);
	const q = uintOf(key.q);
	const qi = uintOf(key.qi);
	const words: uint32[][] = [p, q, qi];
	const bytes: uint8[][] = [];
	try {
		const blinding = blindingPair(n, key.e);
		words.push(blinding.vi);
		words.push(blinding.vf);
		const t = n.mul(c, blinding.vi);
		words.push(t);
		const dpBlinded = blindedExponent(p, key.dp);
		bytes.push(dpBlinded);
		const dqBlinded = blindedExponent(q, key.dq);
		bytes.push(dqBlinded);
		const tp = mp.reduce(t);
		words.push(tp);
		const tq = mq.reduce(t);
		words.push(tq);
		const m1 = mp.pow(tp, dpBlinded);
		if (m1 != null) words.push(m1);
		const m2 = mq.pow(tq, dqBlinded);
		if (m2 != null) words.push(m2);
		if (m1 == null || m2 == null) return null;
		const qiP = mp.reduce(qi);
		words.push(qiP);
		const m2P = mp.reduce(m2);
		words.push(m2P);
		const difference = mp.sub(m1, m2P);
		words.push(difference);
		const h = mp.mul(qiP, difference);
		words.push(h);
		const width = c.length;
		const result = uintWiden(m2, width);
		words.push(result);
		const wh = uintWiden(h, width);
		words.push(wh);
		const wq = uintWiden(q, width);
		words.push(wq);
		const overflow = uintMulAdd(result, wh, wq);
		const check = n.powPublic(result, key.e);
		if (check != null) words.push(check);
		if (check == null || declassify(overflow | (uintCompare(check, t) as uint32)) != 0) return null;
		const opened = n.mul(result, blinding.vf);
		words.push(opened);
		return uintToBytes(opened, rsaModulusBytes(key.n));
	} finally {
		for (const scratch of words) wipeWords(scratch);
		for (const scratch of bytes) wipeBytes(scratch);
	}
}

// The odd primes to 997, the ones mbedTLS's small-factor check divides by.
const smallPrimes: Readonly<int32[]> = [
	3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73,
	79, 83, 89, 97, 101, 103, 107, 109, 113, 127, 131, 137, 139, 149, 151, 157, 163, 167, 173, 179,
	181, 191, 193, 197, 199, 211, 223, 227, 229, 233, 239, 241, 251, 257, 263, 269, 271, 277, 281, 283,
	293, 307, 311, 313, 317, 331, 337, 347, 349, 353, 359, 367, 373, 379, 383, 389, 397, 401, 409, 419,
	421, 431, 433, 439, 443, 449, 457, 461, 463, 467, 479, 487, 491, 499, 503, 509, 521, 523, 541, 547,
	557, 563, 569, 571, 577, 587, 593, 599, 601, 607, 613, 617, 619, 631, 641, 643, 647, 653, 659, 661,
	673, 677, 683, 691, 701, 709, 719, 727, 733, 739, 743, 751, 757, 761, 769, 773, 787, 797, 809, 811,
	821, 823, 827, 829, 839, 853, 857, 859, 863, 877, 881, 883, 887, 907, 911, 919, 929, 937, 941, 947,
	953, 967, 971, 977, 983, 991, 997,
];

// 1 for a small prime, -1 for a small factor, 0 when Miller-Rabin must decide.
function checkSmallFactors(x: Readonly<uint32[]>): int32 {
	if ((x[0] & 1) == 0) return -1;
	for (const prime of smallPrimes) {
		const copy = uintWiden(x, x.length);
		const remainder = uintDivRemPublic(copy, prime);
		wipeWords(copy);
		if (remainder == 0) return uintBitLenPublic(x) <= 10 && x[0] == (prime as uint32) ? 1 : -1;
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
	const words: uint32[][] = [];
	const bytes: uint8[][] = [];
	try {
		const w = minusOne(m.v);
		words.push(w);
		const s = uintTrailingZeroBitsPublic(w);
		const r = uintWiden(w, w.length);
		words.push(r);
		uintShiftRightPublic(r, s);
		const exponent = uintToMinimalBytes(r);
		bytes.push(exponent);
		const bits = uintBitLenPublic(m.v);
		const size = (bits + 7) >> 3;
		const k = uintBitLenPublic(w);
		for (let round = 0; round < rounds; round++) {
			let a: uint32[] = [];
			let count = 0;
			while (true) {
				const octets = randomOctets(size);
				octets[0] = ((octets[0] as int32) & (0xff >> (size * 8 - bits))) as uint8;
				const drawn = uintFromBytes(octets, m.v.length);
				wipeBytes(octets);
				if (drawn == null) throw new Error(
					"rsa: a Miller-Rabin base does not fit its modulus",
				);
				if (uintBitLenPublic(drawn) > k) keepLowBits(drawn, k - 1);
				if (count > 30) {
					wipeWords(drawn);
					return false;
				}
				count += 1;
				if (uintCompare(drawn, w) < 0 && uintBitLenPublic(drawn) > 1) {
					a = drawn;
					break;
				}
				wipeWords(drawn);
			}
			words.push(a);
			const power = m.pow(a, exponent);
			if (power == null) return false;
			words.push(power);
			let y: uint32[] = power;
			if (m.isMinusOne(y) || uintIsOne(y)) continue;
			let j = 1;
			while (j < s && !m.isMinusOne(y)) {
				y = m.sq(y);
				words.push(y);
				if (uintIsOne(y)) break;
				j += 1;
			}
			if (!m.isMinusOne(y) || uintIsOne(y)) return false;
		}
		return true;
	} finally {
		for (const scratch of words) wipeWords(scratch);
		for (const scratch of bytes) wipeBytes(scratch);
		wipeModulus(m);
	}
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
		const top =
			((bytes[0] as uint32) << 24) |
			((bytes[1] as uint32) << 16) |
			((bytes[2] as uint32) << 8) |
			(bytes[3] as uint32);
		if (top < 0xb504f334) {
			wipeBytes(bytes);
			continue;
		}
		const x = uintOf(bytes);
		wipeBytes(bytes);
		if (size * 8 > bits) uintShiftRightPublic(x, size * 8 - bits);
		x[0] = x[0] | 1;
		const small = checkSmallFactors(x);
		if (small > 0) return x;
		if (small == 0 && millerRabin(x, primeRounds(bits))) return x;
		wipeWords(x);
	}
}

// `a^-1 mod n` for an even n with 1 < a < n and a odd, as `mbedtls_mpi_inv_mod_even_in_range`; null when there is none.
function inverseModEven(
	a: Readonly<uint32[]>,
	n: Readonly<uint32[]>,
): uint32[] | null {
	const reduced = uintDivRem(n, a);
	const found = uintGcdModinvOdd(reduced.remainder, a);
	for (const scratch of [reduced.quotient, reduced.remainder]) wipeWords(scratch);
	if (!uintIsOne(found.gcd)) {
		for (const scratch of [found.gcd, found.inverse]) wipeWords(scratch);
		return null;
	}
	const t = uintMul(found.inverse, n);
	uintSub(t, [1]);
	const divided = uintDivRem(t, a);
	const out = uintWiden(n, n.length);
	uintSub(out, divided.quotient);
	for (const scratch of [found.gcd, found.inverse, t, divided.quotient, divided.remainder]) wipeWords(scratch);
	return out;
}

// `a^-1 mod n` for an odd n, as `mbedtls_mpi_inv_mod_odd`; null when there is none.
function inverseModOdd(
	a: Readonly<uint32[]>,
	n: Readonly<uint32[]>,
): uint32[] | null {
	const reduced = uintDivRem(a, n);
	const found = uintGcdModinvOdd(reduced.remainder, n);
	const invertible = uintIsOne(found.gcd);
	for (const scratch of [reduced.quotient, reduced.remainder, found.gcd]) wipeWords(scratch);
	if (invertible) return found.inverse;
	wipeWords(found.inverse);
	return null;
}

// `e^-1 mod lcm(p - 1, q - 1)`, as `mbedtls_rsa_deduce_private_exponent`.
function privateExponent(
	p: Readonly<uint32[]>,
	q: Readonly<uint32[]>,
	e: Readonly<uint32[]>,
): uint32[] | null {
	const k = minusOne(p);
	const l = minusOne(q);
	const g = uintGcd(k, l);
	if (g == null) {
		for (const scratch of [k, l]) wipeWords(scratch);
		return null;
	}
	const product = uintMul(k, l);
	const divided = uintDivRem(product, g);
	const d = inverseModEven(e, divided.quotient);
	for (const scratch of [k, l, g, product, divided.quotient, divided.remainder]) wipeWords(scratch);
	return d;
}

/** A key with e = 65537, as `mbedtls_rsa_gen_key`: |p - q| > 2^(bits/2 - 100), p > q, d > 2^(bits/2). */
export function rsaGenerateKey(bits: int32): RsaPrivateData {
	if (bits < 1024 || bits % 2 != 0) throw new Error(
		`rsaGenerateKey: ${bits} bits is not an even size of at least 1024`,
	);
	const eBytes: uint8[] = [1, 0, 1];
	const e = uintOf(eBytes);
	while (true) {
		let p = generatePrime(bits >> 1);
		let q = generatePrime(bits >> 1);
		const order = uintCompare(p, q);
		const difference = uintWiden(order >= 0 ? p : q, p.length);
		uintSub(difference, order >= 0 ? q : p);
		const farApart = uintBitLenPublic(difference) > (bits >> 1) - 99;
		wipeWords(difference);
		if (!farApart) {
			for (const scratch of [p, q]) wipeWords(scratch);
			continue;
		}
		if (order < 0) {
			const t = p;
			p = q;
			q = t;
		}
		const d = privateExponent(p, q, e);
		if (d == null || uintBitLenPublic(d) <= (bits + 1) / 2) {
			for (const scratch of [p, q]) wipeWords(scratch);
			if (d != null) wipeWords(d);
			continue;
		}
		const n = uintMul(p, q);
		const qi = inverseModOdd(q, p);
		if (qi == null || uintBitLenPublic(n) != bits) throw new Error(
			"rsaGenerate: the generated primes do not form a key",
		);
		const pMinusOne = minusOne(p);
		const qMinusOne = minusOne(q);
		const dpDivided = uintDivRem(d, pMinusOne);
		const dqDivided = uintDivRem(d, qMinusOne);
		const dp = dpDivided.remainder;
		const dq = dqDivided.remainder;
		const key: RsaPrivateData = {
			n: uintToMinimalBytes(n),
			e: eBytes,
			d: uintToMinimalBytes(d),
			p: uintToMinimalBytes(p),
			q: uintToMinimalBytes(q),
			dp: uintToMinimalBytes(dp),
			dq: uintToMinimalBytes(dq),
			qi: uintToMinimalBytes(qi),
			nModulus: modulusFromUint(n),
			pModulus: modulusFromUint(p),
			qModulus: modulusFromUint(q),
		};
		for (const scratch of [
			p,
			q,
			d,
			dp,
			dq,
			qi,
			pMinusOne,
			qMinusOne,
			dpDivided.quotient,
			dqDivided.quotient,
		]) wipeWords(scratch);
		return key;
	}
}

test "Miller-Rabin keeps a large prime and refuses a product of two" {
	const mersenne127: uint32[] = [0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7fffffff, 0x7];
	assert millerRabin(mersenne127, 20);
	for (const limb of mersenne127) assert limb != 0, "millerRabin: borrowed candidate changed";
	const product = uintMul([0x7fffffff, 0x3fffffff], [0x7fffffff]);
	assert checkSmallFactors(product) == 0;
	assert !millerRabin(product, 20);
}

test "a generated 1024-bit key is consistent and inverts its public operation" {
	const key = rsaGenerateKey(1024);
	assert rsaKeyConsistent(key);
	const input = new Array<uint8>(rsaModulusBytes(key.n));
	for (let i = 1; i < input.length; i++) input[i] = i as uint8;
	const opened = rsaPrivateOperation(key, input);
	if (opened == null) throw new Error("private operation refused a generated key");
	const back = rsaPublicOperation({ n: key.n, e: key.e, nModulus: key.nModulus }, opened);
	if (back == null) throw new Error("public operation refused its own output");
	for (let i = 0; i < input.length; i++) assert back[i] == input[i];
}

test "smallPrimes holds exactly the odd primes below 1000" {
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
	assert primes.length == smallPrimes.length;
	for (let i = 0; i < primes.length; i++) assert primes[i] == smallPrimes[i];
}
