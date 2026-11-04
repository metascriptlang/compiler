import { wipeBytes } from "./secret";
import { load64BE, store64BE } from "./endian";
/**
 * The GHASH of AES-GCM (NIST SP 800-38D) without tables: each carry-less product is built from integer multiplies of
 * operands masked to every fourth bit, so no memory access or branch depends on the key or the data. Blocks are read
 * big-endian into two 64-bit halves, and the key is pre-multiplied by x so the products need no bit reflection.
 */
export class Ghash {
	keyHi: uint64;
	keyLo: uint64;
	accHi: uint64;
	accLo: uint64;
	productHi: uint64;
	productLo: uint64;
	tail: uint8[];
}

function wideProduct(a: uint32, b: uint32): uint64 {
	return (a as uint64) * (b as uint64);
}

function carrylessProduct32(x: uint32, y: uint32): uint64 {
	const a0 = x & 0x11111111;
	const a1 = x & 0x22222222;
	const a2 = x & 0x44444444;
	const a3 = x & 0x88888888;
	const b0 = y & 0x11111111;
	const b1 = y & 0x22222222;
	const b2 = y & 0x44444444;
	const b3 = y & 0x88888888;
	const c0 = wideProduct(a0, b0) ^ wideProduct(a1, b3) ^ wideProduct(a2, b2) ^ wideProduct(a3, b1);
	const c1 = wideProduct(a0, b1) ^ wideProduct(a1, b0) ^ wideProduct(a2, b3) ^ wideProduct(a3, b2);
	const c2 = wideProduct(a0, b2) ^ wideProduct(a1, b1) ^ wideProduct(a2, b0) ^ wideProduct(a3, b3);
	const c3 = wideProduct(a0, b3) ^ wideProduct(a1, b2) ^ wideProduct(a2, b1) ^ wideProduct(a3, b0);
	return (c0 & 0x1111111111111111) | (c1 & 0x2222222222222222) | (c2 & 0x4444444444444444) | (c3 & 0x8888888888888888);
}

// The 128-bit carry-less product of two 64-bit halves into `g.productHi:productLo`, Karatsuba over 32-bit quarters.
function carrylessProduct64(g: Ghash, a: uint64, b: uint64): void {
	const a0 = (a & 0xffffffff) as uint32;
	const a1 = (a >> 32) as uint32;
	const b0 = (b & 0xffffffff) as uint32;
	const b1 = (b >> 32) as uint32;
	const lo = carrylessProduct32(a0, b0);
	const hi = carrylessProduct32(a1, b1);
	const mid = carrylessProduct32(a0 ^ a1, b0 ^ b1) ^ lo ^ hi;
	g.productLo = lo ^ (mid << 32);
	g.productHi = hi ^ (mid >> 32);
}

// The low half of the reduction constant x^127 + x^126 + x^121, shifted down 64 bits.
const reductionHalf: uint64 = 0xc200000000000000;

// acc = (acc ^ block) * key, reduced modulo x^128 + x^127 + x^126 + x^121 + 1.
function absorb(g: Ghash, blockHi: uint64, blockLo: uint64): void {
	const xHi = g.accHi ^ blockHi;
	const xLo = g.accLo ^ blockLo;
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
	carrylessProduct64(g, lowLo, reductionHalf);
	const bHi = lowLo ^ g.productHi;
	const bLo = lowHi ^ g.productLo;
	carrylessProduct64(g, bLo, reductionHalf);
	g.accHi = bLo ^ g.productHi ^ highHi;
	g.accLo = bHi ^ g.productLo ^ highLo;
}

function loadBE64(data: Readonly<uint8[]>, at: int32): uint64 {
	let out: uint64 = 0;
	for (let i = 0; i < 8; i++) out = (out << 8) | (data[at + i] as uint64);
	return out;
}

export function storeBE64(out: uint8[], at: int32, value: uint64): void {
	for (let i = 0; i < 8; i++) out[at + i] = ((value >> ((56 - 8 * i) as uint64)) & 0xff) as uint8;
}

/** A GHASH under the 16-byte hash key H. */
export function newGhash(key: Readonly<uint8[]>): Ghash {
	const hHi = loadBE64(key, 0);
	const hLo = loadBE64(key, 8);
	const carry = (0 as uint64) - (hHi >> 63);
	return {
		keyHi: ((hHi << 1) | (hLo >> 63)) ^ (reductionHalf & carry),
		keyLo: (hLo << 1) ^ ((1 as uint64) & carry),
		accHi: 0,
		accLo: 0,
		productHi: 0,
		productLo: 0,
		tail: new Array<uint8>(16),
	};
}

/** Absorbs `data[from, to)` as one segment, zero-padded to a whole block: AAD, cipher text and the length block are separate segments. */
export function updateGhash(g: Ghash, data: Readonly<uint8[]>, from: int32, to: int32): void {
	let at = from;
	while (at + 16 <= to) {
		absorb(g, loadBE64(data, at), loadBE64(data, at + 8));
		at += 16;
	}
	if (at < to) {
		const tail = g.tail;
		for (let i = 0; i < 16; i++) tail[i] = at + i < to ? data[at + i] : 0;
		absorb(g, loadBE64(tail, 0), loadBE64(tail, 8));
	}
}

/** Writes the 16-byte hash to `out[at, at + 16)` and wipes the state. */
export function finishGhash(g: Ghash, out: uint8[], at: int32): void {
	storeBE64(out, at, g.accHi);
	storeBE64(out, at + 8, g.accLo);
	g.keyHi = 0;
	g.keyLo = 0;
	g.accHi = 0;
	g.accLo = 0;
	g.productHi = 0;
	g.productLo = 0;
	for (let i = 0; i < 16; i++) g.tail[i] = 0;
}
