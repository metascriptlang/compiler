import { wipeBytes } from "./secret";
import { InputBytes, OutputBytes } from "./bytes";
import { store32BE } from "./endian";

when (c) {
	import { load64BE } from "./endian";
}

when (js) {
	import { load32BE } from "./endian";
}
/**
 * The GHASH of AES-GCM (NIST SP 800-38D) without tables, so no memory access or branch depends on the key or the
 * data. On C each carry-less product is built from integer multiplies of operands masked to every fourth bit, on
 * 64-bit halves read big-endian, with the key pre-multiplied by x so the products need no bit reflection. On JS, where
 * a uint64 is a BigInt, it is the bit-serial multiply of SP 800-38D on four uint32 words, each step selected by a mask.
 */

when (c) {
	export class Ghash {
		keyHi: uint64;
		keyLo: uint64;
		accHi: uint64;
		accLo: uint64;
		productHi: uint64;
		productLo: uint64;
		tail: uint8[];
	}

	@include("runtime/core/mulWide.h");

	extern function msMulHi64(a: uint64, b: uint64): uint64;

	// The 128-bit carry-less product of two 64-bit halves into `g.productHi:productLo`, from sixteen 64x64 integer
	// products of operands masked to every fourth bit. `x` leaves out its lowest four bits so no product column can
	// carry into the next one of its group; `extra` adds those four bits' products back.
	function carrylessProduct64(g: Ghash, x: uint64, y: uint64): void {
		const x0 = x & 0x1111111111111110;
		const x1 = x & 0x2222222222222220;
		const x2 = x & 0x4444444444444440;
		const x3 = x & 0x8888888888888880;
		const y0 = y & 0x1111111111111111;
		const y1 = y & 0x2222222222222222;
		const y2 = y & 0x4444444444444444;
		const y3 = y & 0x8888888888888888;
		const z0Lo = (x0 * y0) ^ (x1 * y3) ^ (x2 * y2) ^ (x3 * y1);
		const z0Hi = msMulHi64(x0, y0) ^ msMulHi64(x1, y3) ^ msMulHi64(x2, y2) ^ msMulHi64(x3, y1);
		const z1Lo = (x0 * y1) ^ (x1 * y0) ^ (x2 * y3) ^ (x3 * y2);
		const z1Hi = msMulHi64(x0, y1) ^ msMulHi64(x1, y0) ^ msMulHi64(x2, y3) ^ msMulHi64(x3, y2);
		const z2Lo = (x0 * y2) ^ (x1 * y1) ^ (x2 * y0) ^ (x3 * y3);
		const z2Hi = msMulHi64(x0, y2) ^ msMulHi64(x1, y1) ^ msMulHi64(x2, y0) ^ msMulHi64(x3, y3);
		const z3Lo = (x0 * y3) ^ (x1 * y2) ^ (x2 * y1) ^ (x3 * y0);
		const z3Hi = msMulHi64(x0, y3) ^ msMulHi64(x1, y2) ^ msMulHi64(x2, y1) ^ msMulHi64(x3, y0);
		const e0 = ((0 as uint64) - (x & 1)) & y;
		const e1 = ((0 as uint64) - ((x >> 1) & 1)) & y;
		const e2 = ((0 as uint64) - ((x >> 2) & 1)) & y;
		const e3 = ((0 as uint64) - ((x >> 3) & 1)) & y;
		g.productLo = (z0Lo & 0x1111111111111111) ^ (z1Lo & 0x2222222222222222) ^ (z2Lo & 0x4444444444444444) ^ (z3Lo & 0x8888888888888888) ^
			e0 ^ (e1 << 1) ^ (e2 << 2) ^ (e3 << 3);
		g.productHi = (z0Hi & 0x1111111111111111) ^ (z1Hi & 0x2222222222222222) ^ (z2Hi & 0x4444444444444444) ^ (z3Hi & 0x8888888888888888) ^
			(e1 >> 63) ^ (e2 >> 62) ^ (e3 >> 61);
	}

	// The carry-less product of `v` and 0xc200000000000000 (x^63 + x^62 + x^57, the reduction constant shifted down
	// 64 bits) into `g.productHi:productLo`, as the three shifted copies the constant's set bits select.
	function timesReduction(g: Ghash, v: uint64): void {
		g.productHi = (v >> 1) ^ (v >> 2) ^ (v >> 7);
		g.productLo = (v << 63) ^ (v << 62) ^ (v << 57);
	}

	// acc = (acc ^ block) * key, reduced modulo x^128 + x^127 + x^126 + x^121 + 1.
	function absorb(g: Ghash, data: InputBytes, at: int32): void {
		const xHi = g.accHi ^ load64BE(data, at);
		const xLo = g.accLo ^ load64BE(data, at + 8);
		carrylessProduct64(g, xLo, g.keyLo);
		const loHi = g.productHi;
		const loLo = g.productLo;
		carrylessProduct64(g, xHi, g.keyHi);
		const hiHi = g.productHi;
		const hiLo = g.productLo;
		carrylessProduct64(g, xLo ^ xHi, g.keyLo ^ g.keyHi);
		const midHi = g.productHi ^ loHi ^ hiHi;
		const midLo = g.productLo ^ loLo ^ hiLo;
		const highHi = hiHi;
		const highLo = hiLo ^ midHi;
		const lowHi = loHi ^ midLo;
		const lowLo = loLo;
		timesReduction(g, lowLo);
		const bHi = lowLo ^ g.productHi;
		const bLo = lowHi ^ g.productLo;
		timesReduction(g, bLo);
		g.accHi = bLo ^ g.productHi ^ highHi;
		g.accLo = bHi ^ g.productLo ^ highLo;
	}

	function keyedGhash(key: InputBytes): Ghash {
		const hHi = load64BE(key, 0);
		const hLo = load64BE(key, 8);
		const carry = (0 as uint64) - (hHi >> 63);
		return {
			keyHi: ((hHi << 1) | (hLo >> 63)) ^ ((0xc200000000000000 as uint64) & carry),
			keyLo: (hLo << 1) ^ ((1 as uint64) & carry),
			accHi: 0,
			accLo: 0,
			productHi: 0,
			productLo: 0,
			tail: new Array<uint8>(16),
		};
	}

	function storeAcc(g: Ghash, out: OutputBytes, at: int32): void {
		store32BE(out, at, (g.accHi >> 32) as uint32);
		store32BE(out, at + 4, (g.accHi & 0xffffffff) as uint32);
		store32BE(out, at + 8, (g.accLo >> 32) as uint32);
		store32BE(out, at + 12, (g.accLo & 0xffffffff) as uint32);
	}

	function wipeState(g: Ghash): void {
		g.keyHi = 0;
		g.keyLo = 0;
		g.accHi = 0;
		g.accLo = 0;
		g.productHi = 0;
		g.productLo = 0;
	}
} else {
	export class Ghash {
		h0: uint32;
		h1: uint32;
		h2: uint32;
		h3: uint32;
		acc0: uint32;
		acc1: uint32;
		acc2: uint32;
		acc3: uint32;
		tail: uint8[];
	}

	// acc = (acc ^ block) * H: for each bit of X from the first, Z ^= V when the bit is set, then V = V * x, reduced by
	// 0xe1 in the first byte when a bit falls off the end.
	function absorb(g: Ghash, data: InputBytes, at: int32): void {
		const x0 = g.acc0 ^ load32BE(data, at);
		const x1 = g.acc1 ^ load32BE(data, at + 4);
		const x2 = g.acc2 ^ load32BE(data, at + 8);
		const x3 = g.acc3 ^ load32BE(data, at + 12);
		let z0: uint32 = 0;
		let z1: uint32 = 0;
		let z2: uint32 = 0;
		let z3: uint32 = 0;
		let v0 = g.h0;
		let v1 = g.h1;
		let v2 = g.h2;
		let v3 = g.h3;
		for (let i = 0; i < 128; i++) {
			const word = i < 32 ? x0 : i < 64 ? x1 : i < 96 ? x2 : x3;
			const take = (0 as uint32) - ((word >> ((31 - (i & 31)) as uint32)) & 1);
			z0 ^= v0 & take;
			z1 ^= v1 & take;
			z2 ^= v2 & take;
			z3 ^= v3 & take;
			const carry = (0 as uint32) - (v3 & 1);
			v3 = (v3 >> 1) | (v2 << 31);
			v2 = (v2 >> 1) | (v1 << 31);
			v1 = (v1 >> 1) | (v0 << 31);
			v0 = (v0 >> 1) ^ (0xe1000000 & carry);
		}
		g.acc0 = z0;
		g.acc1 = z1;
		g.acc2 = z2;
		g.acc3 = z3;
	}

	function keyedGhash(key: InputBytes): Ghash {
		return {
			h0: load32BE(key, 0),
			h1: load32BE(key, 4),
			h2: load32BE(key, 8),
			h3: load32BE(key, 12),
			acc0: 0,
			acc1: 0,
			acc2: 0,
			acc3: 0,
			tail: new Array<uint8>(16),
		};
	}

	function storeAcc(g: Ghash, out: OutputBytes, at: int32): void {
		store32BE(out, at, g.acc0);
		store32BE(out, at + 4, g.acc1);
		store32BE(out, at + 8, g.acc2);
		store32BE(out, at + 12, g.acc3);
	}

	function wipeState(g: Ghash): void {
		g.h0 = 0;
		g.h1 = 0;
		g.h2 = 0;
		g.h3 = 0;
		g.acc0 = 0;
		g.acc1 = 0;
		g.acc2 = 0;
		g.acc3 = 0;
	}
}

/** A GHASH under the 16-byte hash key H. */
export function newGhash(key: InputBytes): Ghash {
	return keyedGhash(key);
}

/** Absorbs `data[from, to)` as one segment, zero-padded to a whole block: AAD, cipher text and the length block are separate segments. */
export function updateGhash(g: Ghash, data: InputBytes, from: int32, to: int32): void {
	let at = from;
	while (at + 16 <= to) {
		absorb(g, data, at);
		at += 16;
	}
	if (at < to) {
		const tail = g.tail;
		for (let i = 0; i < 16; i++) tail[i] = at + i < to ? data[at + i] : 0;
		absorb(g, tail, 0);
	}
}

/** Writes the 16-byte hash to `out[at, at + 16)` and wipes the state. */
export function finishGhash(g: Ghash, out: OutputBytes, at: int32): void {
	storeAcc(g, out, at);
	wipeState(g);
	wipeBytes(g.tail);
}
