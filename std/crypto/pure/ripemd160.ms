// Derived from @noble/hashes 1.8.0, MIT, Paul Miller (https://paulmillr.com).
// Reference: tools/solana/node_modules/@noble/hashes/src/legacy.ts, RIPEMD160.
// Algorithm: https://homes.esat.kuleuven.be/~bosselae/ripemd160.html
// Licence: std/crypto/pure/LICENSE.ripemd160

import { encodeHex } from "../../core/encoding";

// idxL[g*16..g*16+15] = Rho160^g applied to Id160; verifiable at reference source line ~270.
const idxL: uint8[80] = [
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
	7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
	3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
	1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
	4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13,
];

// idxR[g*16..g*16+15] = Rho160^g applied to Pi160 = (9i+5) mod 16.
const idxR: uint8[80] = [
	5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
	6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
	15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
	8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
	12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11,
];

// sL[g*16+i] = shifts160[g][ idxL[g*16+i] ]; reference shiftsL160[].
const sL: uint8[80] = [
	11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
	7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
	11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
	11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
	9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6,
];

// sR[g*16+i] = shifts160[g][ idxR[g*16+i] ]; reference shiftsR160[].
const sR: uint8[80] = [
	8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
	9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
	9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
	15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
	8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11,
];

const KL: uint32[5] = [0x00000000, 0x5a827999, 0x6ed9eba1, 0x8f1bbcdc, 0xa953fd4e];
const KR: uint32[5] = [0x50a28be6, 0x5c4dd124, 0x6d703ef3, 0x7a6d76e9, 0x00000000];

export class Ripemd160State {
	h: uint32[5];
	w: uint32[16];
	block: uint8[];
	filled: int32;
	length: number;
	finished: boolean;
}

export function newRipemd160(): Ripemd160State {
	return {
		h: [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0],
		w: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
		block: new Array<uint8>(64),
		filled: 0,
		length: 0,
		finished: false,
	};
}

function rotl(v: uint32, c: uint32): uint32 {
	return (v << c) | (v >> (32 - c));
}

function f(group: int32, x: uint32, y: uint32, z: uint32): uint32 {
	if (group == 0) return x ^ y ^ z;
	if (group == 1) return (x & y) | (~x & z);
	if (group == 2) return (x | ~y) ^ z;
	if (group == 3) return (x & z) | (y & ~z);
	return x ^ (y | ~z);
}

function compress(s: Ripemd160State, data: Readonly<uint8[]>, off: int32): void {
	for (let i = 0; i < 16; i++) {
		const at = off + i * 4;
		s.w[i] =
			(data[at] as uint32) |
			((data[at + 1] as uint32) << 8) |
			((data[at + 2] as uint32) << 16) |
			((data[at + 3] as uint32) << 24);
	}
	let al = s.h[0];
	let bl = s.h[1];
	let cl = s.h[2];
	let dl = s.h[3];
	let el = s.h[4];
	let ar = s.h[0];
	let br = s.h[1];
	let cr = s.h[2];
	let dr = s.h[3];
	let er = s.h[4];
	for (let group = 0; group < 5; group++) {
		const rGroup = 4 - group;
		const kl = KL[group];
		const kr = KR[group];
		const base = group * 16;
		for (let i = 0; i < 16; i++) {
			const tl =
				rotl(
					al + f(group, bl, cl, dl) + s.w[idxL[base + i] as int32] + kl,
					sL[base + i] as uint32,
				) + el;
			al = el;
			el = dl;
			dl = rotl(cl, 10);
			cl = bl;
			bl = tl;
		}
		for (let i = 0; i < 16; i++) {
			const tr =
				rotl(
					ar + f(rGroup, br, cr, dr) + s.w[idxR[base + i] as int32] + kr,
					sR[base + i] as uint32,
				) + er;
			ar = er;
			er = dr;
			dr = rotl(cr, 10);
			cr = br;
			br = tr;
		}
	}
	const t = s.h[1] + cl + dr;
	s.h[1] = s.h[2] + dl + er;
	s.h[2] = s.h[3] + el + ar;
	s.h[3] = s.h[4] + al + br;
	s.h[4] = s.h[0] + bl + cr;
	s.h[0] = t;
}

export function updateRipemd160(s: Ripemd160State, data: Readonly<uint8[]>): void {
	if (s.finished) throw new Error("ripemd160: already finished");
	const end = data.length as int32;
	let at = 0;
	s.length += end;
	if (s.filled > 0) {
		while (at < end && s.filled < 64) {
			s.block[s.filled] = data[at];
			s.filled += 1;
			at += 1;
		}
		if (s.filled < 64) return;
		compress(s, s.block, 0);
		s.filled = 0;
	}
	while (at + 64 <= end) {
		compress(s, data, at);
		at += 64;
	}
	while (at < end) {
		s.block[s.filled] = data[at];
		s.filled += 1;
		at += 1;
	}
}

export function finishRipemd160(s: Ripemd160State): uint8[] {
	if (s.finished) throw new Error("ripemd160: already finished");
	s.block[s.filled] = 0x80;
	s.filled += 1;
	if (s.filled > 56) {
		while (s.filled < 64) {
			s.block[s.filled] = 0;
			s.filled += 1;
		}
		compress(s, s.block, 0);
		s.filled = 0;
	}
	while (s.filled < 56) {
		s.block[s.filled] = 0;
		s.filled += 1;
	}
	const bits = s.length * 8;
	const high = Math.floor(bits / 4294967296) as uint32;
	const low = (bits - Math.floor(bits / 4294967296) * 4294967296) as uint32;
	for (let i = 0; i < 4; i++) {
		const shift = (8 * i) as uint32;
		s.block[56 + i] = ((low >> shift) & 255) as uint8;
		s.block[60 + i] = ((high >> shift) & 255) as uint8;
	}
	compress(s, s.block, 0);
	s.finished = true;
	const out = new Array<uint8>(20);
	for (let i = 0; i < 5; i++) {
		const word = s.h[i];
		out[4 * i + 0] = (word & 255) as uint8;
		out[4 * i + 1] = ((word >> 8) & 255) as uint8;
		out[4 * i + 2] = ((word >> 16) & 255) as uint8;
		out[4 * i + 3] = ((word >> 24) & 255) as uint8;
	}
	return out;
}

export function ripemd160Of(data: Readonly<uint8[]>): uint8[] {
	const s = newRipemd160();
	updateRipemd160(s, data);
	return finishRipemd160(s);
}

function hashStr(text: string): string {
	return ripemd160Of(text.asBytes().slice(0)).encodeHex();
}

test "ripemd160 empty" {
	assert hashStr("") == "9c1185a5c5e9fc54612808977ee8f548b2258d31";
}

test "ripemd160 abc" {
	assert hashStr("abc") == "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc";
}

test "ripemd160 message digest" {
	assert hashStr("message digest") == "5d0689ef49d2fae572b881b123a85ffa21595f36";
}

test "ripemd160 lowercase alphabet" {
	assert hashStr("abcdefghijklmnopqrstuvwxyz") == "f71c27109c692c1b56bbdceb5b9d2865b3708dbc";
}

test "ripemd160 padding boundary 56 bytes forces second block" {
	assert hashStr("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") == "12a053384a9c0c88e405a06c27dcf49ada62eb2b";
}

test "ripemd160 62-byte alphanumeric" {
	assert hashStr("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") == "b0e20b6e3116640286ed3a87a5713079b21f5189";
}

test "ripemd160 multiblock 80-byte decimal string" {
	assert hashStr("12345678901234567890123456789012345678901234567890123456789012345678901234567890") == "9b752e45573d4b39f4dbd3323cab82bf63326bfb";
}

test "ripemd160 split feed matches single" {
	const s = newRipemd160();
	updateRipemd160(s, "a".asBytes().slice(0));
	updateRipemd160(s, "bc".asBytes().slice(0));
	assert finishRipemd160(s).encodeHex() == "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc";
}

test "ripemd160 update after finish throws" {
	const s = newRipemd160();
	finishRipemd160(s);
	let threw = false;
	try {
		updateRipemd160(s, []);
	} catch (e) {
		threw = true;
	}
	assert threw;
}

test "ripemd160 finish after finish throws" {
	const s = newRipemd160();
	finishRipemd160(s);
	let threw = false;
	try {
		finishRipemd160(s);
	} catch (e) {
		threw = true;
	}
	assert threw;
}

function hashRepeat(byte: uint8, n: int32): string {
	const data = new Array<uint8>(n);
	for (let i = 0; i < n; i++) data[i] = byte;
	return ripemd160Of(data).encodeHex();
}

test "ripemd160 a" {
	assert hashStr("a") == "0bdc9d2d256b3ee9daae347be6f4dc835a467ffe";
}

test "ripemd160 padding boundaries 55 56 64" {
	assert hashRepeat(0x61, 55) == "0d8a8c9063a48576a7c97e9f95253a6e53ff6765";
	assert hashRepeat(0x61, 56) == "e72334b46c83cc70bef979e15453706c95b888be";
	assert hashRepeat(0x61, 64) == "9dfb7d374ad924f3f88de96291c33e9abed53e32";
}

test "ripemd160 million a" {
	assert hashRepeat(0x61, 1000000) == "52783243c1697bdbe16d37f97f68f08325dc1528";
}

test "ripemd160 streaming split across blocks" {
	const text = "12345678901234567890123456789012345678901234567890123456789012345678901234567890".asBytes().slice(0);
	for (const cut of [1, 7, 63, 64, 65, 79]) {
		const s = newRipemd160();
		updateRipemd160(s, text.slice(0, cut));
		updateRipemd160(s, text.slice(cut));
		assert finishRipemd160(s).encodeHex() == "9b752e45573d4b39f4dbd3323cab82bf63326bfb";
	}
}
