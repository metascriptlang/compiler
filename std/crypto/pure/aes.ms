import { newGhash, updateGhash, finishGhash, storeBE32 } from "./ghash";

when (c) {
	import { Buffer } from "std/core/buffer";
	import { aesHwAvailable, aesGcmHwSeal, aesGcmHwOpen, aesGcmHwOpenFresh, aesCbcHwEncrypt, aesCbcHwDecrypt } from "./hw";
}

/**
 * AES-128/192/256 in GCM (12-byte nonce) and CBC with PKCS#7, with no table indexed by the key or the data, the key
 * schedule included. Serial and short work is fixsliced (Adomnicai and Peyrin, "Fixslicing AES-like ciphers", 2020):
 * four blocks in eight uint64 words on C, two blocks in eight uint32 words on JS, where a uint64 is a BigInt. Long
 * counter-mode runs, and long CBC decryption on JS, take the bitsliced cipher with eight blocks per 32-bit lane, which
 * costs less per block there. A key schedule holds both round-key layouts, the same words for both directions.
 */

when (c) {
	type Word = uint64;
	/** Two eight-block 32-bit lanes per wide word. */
	type Wide = uint64;

	const BLOCKS: int32 = 4;
	const WIDE_BLOCKS: int32 = 16;
	// Measured on x86-64: a wide pass costs about 3.4 fixsliced passes, and wide decryption never beats fixsliced.
	const WIDE_FROM: int32 = 208;
	const WIDE_DECRYPT_FROM: int32 = 0x7fffffff;

	function splatLike(x: uint32, like: Wide): Wide {
		return (x as uint64) | ((x as uint64) << 32);
	}

	function laneWord(lo: uint32, hi: uint32): Wide {
		return (lo as uint64) | ((hi as uint64) << 32);
	}

	function laneOf(w: Wide, g: int32): uint32 {
		return ((w >> ((32 * g) as uint64)) & 0xffffffff) as uint32;
	}

	function laneRotl(x: Wide, by: Wide): Wide {
		const low = splatLike(((1 as uint32) << (by as uint32)) - 1, x);
		return ((x << by) & ~low) | ((x >> (32 - by)) & low);
	}
	const WIDTH: Word = 64;
	const ROW: Word = 16;
	const COL: Word = 4;
	const SWAP1: Word = 0x5555555555555555;
	const SWAP2: Word = 0x3333333333333333;
	const SWAP4: Word = 0x0f0f0f0f0f0f0f0f;
	const ROT11: Word = 0x0fff0fff0fff0fff;
	const ROT12: Word = 0x00ff00ff00ff00ff;
	const ROT13: Word = 0x000f000f000f000f;
	const SHIFT_ROWS_2: Word = 0x00ff000000ff0000;
	const SHIFT_ROWS_1: Word = 0x00f000ff000f0000;
	const SHIFT_ROWS_3: Word = 0x000f00ff00f00000;
	const SHIFT_ROWS_ODD: Word = 0x0f0f00000f0f0000;

	// Bytes 0-3 and 8-11 of the block at `at`, interleaved byte by byte.
	function readReordered(src: Readonly<uint8[]>, at: int32): Word {
		return (src[at] as Word) | ((src[at + 1] as Word) << 16) | ((src[at + 2] as Word) << 32) | ((src[at + 3] as Word) << 48) |
			((src[at + 8] as Word) << 8) | ((src[at + 9] as Word) << 24) | ((src[at + 10] as Word) << 40) | ((src[at + 11] as Word) << 56);
	}

	function writeReordered(out: uint8[], at: int32, w: Word): void {
		out[at] = (w & 0xff) as uint8;
		out[at + 1] = ((w >> 16) & 0xff) as uint8;
		out[at + 2] = ((w >> 32) & 0xff) as uint8;
		out[at + 3] = ((w >> 48) & 0xff) as uint8;
		out[at + 8] = ((w >> 8) & 0xff) as uint8;
		out[at + 9] = ((w >> 24) & 0xff) as uint8;
		out[at + 10] = ((w >> 40) & 0xff) as uint8;
		out[at + 11] = (w >> 56) as uint8;
	}

	// Words 2p and 2p + 1 hold bytes [0, 4) + [8, 12) and [4, 8) + [12, 16) of block p; blocks from `count` on are zero.
	function loadWords(st: Word[], src: Readonly<uint8[]>, at: int32, count: int32): void {
		for (let p = 0; p < 4; p++) {
			st[p] = p < count ? readReordered(src, at + p * 16) : 0;
			st[p + 4] = p < count ? readReordered(src, at + p * 16 + 4) : 0;
		}
	}

	function storeWords(st: Readonly<Word[]>, out: uint8[]): void {
		for (let p = 0; p < 4; p++) {
			writeReordered(out, p * 16, st[p]);
			writeReordered(out, p * 16 + 4, st[p + 4]);
		}
	}

} else {
	type Word = uint32;

	const BLOCKS: int32 = 2;
	const WIDTH: Word = 32;
	const ROW: Word = 8;
	const COL: Word = 2;
	const SWAP1: Word = 0x55555555;
	const SWAP2: Word = 0x33333333;
	const SWAP4: Word = 0x0f0f0f0f;
	const ROT11: Word = 0x3f3f3f3f;
	const ROT12: Word = 0x0f0f0f0f;
	const ROT13: Word = 0x03030303;
	const SHIFT_ROWS_2: Word = 0x0f000f00;
	const SHIFT_ROWS_1: Word = 0x0c0f0300;
	const SHIFT_ROWS_3: Word = 0x030f0c00;
	const SHIFT_ROWS_ODD: Word = 0x33003300;

	/** One eight-block lane per wide word. */
	type Wide = uint32;

	const WIDE_BLOCKS: int32 = 8;
	// Measured on node: a wide pass costs about two fixsliced passes, and wins CBC decryption from a full pass on.
	const WIDE_FROM: int32 = 64;
	const WIDE_DECRYPT_FROM: int32 = 8;

	function splatLike(x: uint32, like: Wide): Wide {
		return x;
	}

	function laneWord(lo: uint32, hi: uint32): Wide {
		return lo;
	}

	function laneOf(w: Wide, g: int32): uint32 {
		return w;
	}

	function laneRotl(x: Wide, by: Wide): Wide {
		return (x << by) | (x >> (32 - by));
	}

	// Word 2w + p is the little-endian word w of block p; blocks from `count` on are zero.
	function loadWords(st: Word[], src: Readonly<uint8[]>, at: int32, count: int32): void {
		for (let p = 0; p < 2; p++) {
			for (let w = 0; w < 4; w++) st[2 * w + p] = p < count ? loadLE(src, at + p * 16 + w * 4) : 0;
		}
	}

	function storeWords(st: Readonly<Word[]>, out: uint8[]): void {
		for (let p = 0; p < 2; p++) {
			for (let w = 0; w < 4; w++) storeLE(out, p * 16 + w * 4, st[2 * w + p]);
		}
	}
}

function loadLE(data: Readonly<uint8[]>, at: int32): uint32 {
	return (data[at] as uint32) | ((data[at + 1] as uint32) << 8) | ((data[at + 2] as uint32) << 16) | ((data[at + 3] as uint32) << 24);
}

function storeLE(out: uint8[], at: int32, word: uint32): void {
	out[at] = (word & 0xff) as uint8;
	out[at + 1] = ((word >> 8) & 0xff) as uint8;
	out[at + 2] = ((word >> 16) & 0xff) as uint8;
	out[at + 3] = (word >> 24) as uint8;
}

function swapBytes(n: uint32): uint32 {
	return ((n & 0xff) << 24) | (((n >> 8) & 0xff) << 16) | (((n >> 16) & 0xff) << 8) | (n >> 24);
}

function ror(x: Word, by: Word): Word {
	return (x >> by) | (x << (WIDTH - by));
}

function swapPair(st: Word[], a: int32, b: int32, shift: Word, mask: Word): void {
	const t = (st[a] ^ (st[b] >> shift)) & mask;
	st[a] ^= t;
	st[b] ^= t << shift;
}

// Moves the bit index (block, column, row, bit) to (bit, row, column, block); it is its own inverse.
function interleave(st: Word[]): void {
	swapPair(st, 1, 0, 1, SWAP1);
	swapPair(st, 3, 2, 1, SWAP1);
	swapPair(st, 5, 4, 1, SWAP1);
	swapPair(st, 7, 6, 1, SWAP1);
	swapPair(st, 2, 0, 2, SWAP2);
	swapPair(st, 3, 1, 2, SWAP2);
	swapPair(st, 6, 4, 2, SWAP2);
	swapPair(st, 7, 5, 2, SWAP2);
	swapPair(st, 4, 0, 4, SWAP4);
	swapPair(st, 5, 1, 4, SWAP4);
	swapPair(st, 6, 2, 4, SWAP4);
	swapPair(st, 7, 3, 4, SWAP4);
}

// Loads `count` blocks of `src` from `at` into the state, zero blocks after them.
function loadBlocks(st: Word[], src: Readonly<uint8[]>, at: int32, count: int32): void {
	loadWords(st, src, at, count);
	interleave(st);
}

function storeBlocks(st: Word[], out: uint8[]): void {
	interleave(st);
	storeWords(st, out);
}

// The S-box circuit of Boyar, Peralta and Calik without its four NOTs, which the round keys carry.
function subBytes(st: Word[]): void {
	const u7 = st[0];
	const u6 = st[1];
	const u5 = st[2];
	const u4 = st[3];
	const u3 = st[4];
	const u2 = st[5];
	const u1 = st[6];
	const u0 = st[7];
	const y14 = u3 ^ u5;
	const y13 = u0 ^ u6;
	const y12 = y13 ^ y14;
	const t1 = u4 ^ y12;
	const y15 = t1 ^ u5;
	const t2 = y12 & y15;
	const y6 = y15 ^ u7;
	const y20 = t1 ^ u1;
	const y9 = u0 ^ u3;
	const y11 = y20 ^ y9;
	const t12 = y9 & y11;
	const y7 = u7 ^ y11;
	const y8 = u0 ^ u5;
	const t0 = u1 ^ u2;
	const y10 = y15 ^ t0;
	const y17 = y10 ^ y11;
	const t13 = y14 & y17;
	const t14 = t13 ^ t12;
	const y19 = y10 ^ y8;
	const t15 = y8 & y10;
	const t16 = t15 ^ t12;
	const y16 = t0 ^ y11;
	const y21 = y13 ^ y16;
	const t7 = y13 & y16;
	const y18 = u0 ^ y16;
	const y1 = t0 ^ u7;
	const y4 = y1 ^ u3;
	const t5 = y4 & u7;
	const t6 = t5 ^ t2;
	const t18 = t6 ^ t16;
	const t22 = t18 ^ y19;
	const y2 = y1 ^ u0;
	const t10 = y2 & y7;
	const t11 = t10 ^ t7;
	const t20 = t11 ^ t16;
	const t24 = t20 ^ y18;
	const y5 = y1 ^ u6;
	const t8 = y5 & y1;
	const t9 = t8 ^ t7;
	const t19 = t9 ^ t14;
	const t23 = t19 ^ y21;
	const y3 = y5 ^ y8;
	const t3 = y3 & y6;
	const t4 = t3 ^ t2;
	const t17 = t4 ^ y20;
	const t21 = t17 ^ t14;
	const t26 = t21 & t23;
	const t27 = t24 ^ t26;
	const t31 = t22 ^ t26;
	const t25 = t21 ^ t22;
	const t28 = t25 & t27;
	const t29 = t28 ^ t22;
	const z14 = t29 & y2;
	const z5 = t29 & y7;
	const t30 = t23 ^ t24;
	const t32 = t31 & t30;
	const t33 = t32 ^ t24;
	const t35 = t27 ^ t33;
	const t36 = t24 & t35;
	const t38 = t27 ^ t36;
	const t39 = t29 & t38;
	const t40 = t25 ^ t39;
	const t43 = t29 ^ t40;
	const z3 = t43 & y16;
	const tc12 = z3 ^ z5;
	const z12 = t43 & y13;
	const z13 = t40 & y5;
	const z4 = t40 & y1;
	const tc6 = z3 ^ z4;
	const t34 = t23 ^ t33;
	const t37 = t36 ^ t34;
	const t41 = t40 ^ t37;
	const z8 = t41 & y10;
	const z17 = t41 & y8;
	const t44 = t33 ^ t37;
	const z0 = t44 & y15;
	const z9 = t44 & y12;
	const z10 = t37 & y3;
	const z1 = t37 & y6;
	const tc5 = z1 ^ z0;
	const tc11 = tc6 ^ tc5;
	const z11 = t33 & y4;
	const t42 = t29 ^ t33;
	const t45 = t42 ^ t41;
	const z7 = t45 & y17;
	const tc8 = z7 ^ tc6;
	const z16 = t45 & y14;
	const z6 = t42 & y11;
	const tc16 = z6 ^ tc8;
	const z15 = t42 & y9;
	const tc20 = z15 ^ tc16;
	const tc1 = z15 ^ z16;
	const tc2 = z10 ^ tc1;
	const tc21 = tc2 ^ z11;
	const tc3 = z9 ^ tc2;
	const s0 = tc3 ^ tc16;
	const s3 = tc3 ^ tc11;
	const s1 = s3 ^ tc16;
	const tc13 = z13 ^ tc1;
	const z2 = t33 & u7;
	const tc4 = z0 ^ z2;
	const tc7 = z12 ^ tc4;
	const tc9 = z8 ^ tc7;
	const tc10 = tc8 ^ tc9;
	const tc17 = z14 ^ tc10;
	const s5 = tc21 ^ tc17;
	const tc26 = tc17 ^ tc20;
	const s2 = tc26 ^ z17;
	const tc14 = tc4 ^ tc12;
	const tc18 = tc13 ^ tc14;
	const s6 = tc10 ^ tc18;
	const s7 = z12 ^ tc18;
	const s4 = tc14 ^ s3;
	st[0] = s7;
	st[1] = s6;
	st[2] = s5;
	st[3] = s4;
	st[4] = s3;
	st[5] = s2;
	st[6] = s1;
	st[7] = s0;
}

// The four NOTs `subBytes` leaves out.
function subBytesNots(st: Word[]): void {
	st[0] = ~st[0];
	st[1] = ~st[1];
	st[5] = ~st[5];
	st[6] = ~st[6];
}

// The inverse S-box circuit of Boyar, Peralta and Calik, its NOTs included, so it inverts `subBytes` + `subBytesNots`.
function invSubBytes(st: Word[]): void {
	const u7 = st[0];
	const u6 = st[1];
	const u5 = st[2];
	const u4 = st[3];
	const u3 = st[4];
	const u2 = st[5];
	const u1 = st[6];
	const u0 = st[7];
	const t23 = u0 ^ u3;
	const t8 = u1 ^ t23;
	const m2 = t23 & t8;
	const t4 = u4 ^ t8;
	const t22 = u1 ^ u3;
	const t2 = u0 ^ u1;
	const t1 = u3 ^ u4;
	const t9 = u7 ^ t1;
	const m7 = t22 & t9;
	const t24 = u4 ^ u7;
	const t10 = t2 ^ t24;
	const m14 = t2 & t10;
	const r5 = u6 ^ u7;
	const t3 = t1 ^ r5;
	const t13 = t2 ^ r5;
	const t19 = t22 ^ r5;
	const t17 = u2 ^ t19;
	const t25 = u2 ^ t1;
	const r13 = u1 ^ u6;
	const t20 = t24 ^ r13;
	const m9 = t20 & t17;
	const r17 = u2 ^ u5;
	const t6 = t22 ^ r17;
	const m1 = t13 & t6;
	const y5 = u0 ^ r17;
	const m4 = t19 & y5;
	const m5 = m4 ^ m1;
	const m17 = m5 ^ t24;
	const r18 = u5 ^ u6;
	const t27 = t1 ^ r18;
	const t15 = t10 ^ t27;
	const m11 = t1 & t15;
	const m15 = m14 ^ m11;
	const m21 = m17 ^ m15;
	const m12 = t4 & t27;
	const m13 = m12 ^ m11;
	const t14 = t10 ^ r18;
	const m3 = t14 ^ m1;
	const m16 = m3 ^ m2;
	const m20 = m16 ^ m13;
	const r19 = u2 ^ u4;
	const t16 = r13 ^ r19;
	const t26 = t3 ^ t16;
	const m6 = t3 & t16;
	const m8 = t26 ^ m6;
	const m18 = m8 ^ m7;
	const m22 = m18 ^ m13;
	const m25 = m22 & m20;
	const m26 = m21 ^ m25;
	const m10 = m9 ^ m6;
	const m19 = m10 ^ m15;
	const m23 = m19 ^ t25;
	const m28 = m23 ^ m25;
	const m24 = m22 ^ m23;
	const m30 = m26 & m24;
	const m39 = m23 ^ m30;
	const m48 = m39 & y5;
	const m57 = m39 & t19;
	const m36 = m24 ^ m25;
	const m31 = m20 & m23;
	const m27 = m20 ^ m21;
	const m32 = m27 & m31;
	const m29 = m28 & m27;
	const m37 = m21 ^ m29;
	const m42 = m37 ^ m39;
	const m52 = m42 & t15;
	const m61 = m42 & t1;
	const p0 = m52 ^ m61;
	const p16 = m57 ^ m61;
	const m60 = m37 & t20;
	const m51 = m37 & t17;
	const m33 = m27 ^ m25;
	const m38 = m32 ^ m33;
	const m43 = m37 ^ m38;
	const m49 = m43 & t16;
	const p6 = m49 ^ m60;
	const p13 = m49 ^ m51;
	const m58 = m43 & t3;
	const m50 = m38 & t9;
	const m59 = m38 & t22;
	const p1 = m58 ^ m59;
	const p7 = p0 ^ p1;
	const m34 = m21 & m22;
	const m35 = m24 & m34;
	const m40 = m35 ^ m36;
	const m41 = m38 ^ m40;
	const m45 = m42 ^ m41;
	const m53 = m45 & t27;
	const p8 = m50 ^ m53;
	const p23 = p7 ^ p8;
	const m62 = m45 & t4;
	const p14 = m49 ^ m62;
	const s6 = p14 ^ p23;
	const m54 = m41 & t10;
	const p2 = m54 ^ m62;
	const p22 = p2 ^ p7;
	const s0 = p13 ^ p22;
	const p17 = m58 ^ p2;
	const p15 = m54 ^ m59;
	const m63 = m41 & t2;
	const m44 = m39 ^ m40;
	const m46 = m44 & t6;
	const p5 = m46 ^ m51;
	const p18 = m63 ^ p5;
	const p24 = p5 ^ p7;
	const p12 = m46 ^ m48;
	const s3 = p12 ^ p22;
	const m55 = m44 & t13;
	const p9 = m55 ^ m63;
	const s7 = p9 ^ p16;
	const m47 = m40 & t8;
	const p3 = m47 ^ m50;
	const p19 = p2 ^ p3;
	const s5 = p19 ^ p24;
	const p11 = p0 ^ p3;
	const p26 = p9 ^ p11;
	const m56 = m40 & t23;
	const p4 = m48 ^ m56;
	const p20 = p4 ^ p6;
	const p29 = p15 ^ p20;
	const s1 = p26 ^ p29;
	const p10 = m57 ^ p4;
	const p27 = p10 ^ p18;
	const s4 = p23 ^ p27;
	const p25 = p6 ^ p10;
	const p28 = p11 ^ p25;
	const s2 = p17 ^ p28;
	st[0] = s7;
	st[1] = s6;
	st[2] = s5;
	st[3] = s4;
	st[4] = s3;
	st[5] = s2;
	st[6] = s1;
	st[7] = s0;
}

// The row and column rotations of the fixsliced MixColumns: round r % 4 rotates by `firstRotation(x, r % 4)` and
// `secondRotation(x, r % 4)`.
@inline
function firstRotation(x: Word, variant: int32): Word {
	if (variant == 0) return ror(x, ROW);
	if (variant == 1) return (ror(x, ROW + COL) & ROT11) | (ror(x, COL) & ~ROT11);
	if (variant == 2) return (ror(x, ROW + 2 * COL) & ROT12) | (ror(x, 2 * COL) & ~ROT12);
	return (ror(x, ROW + 3 * COL) & ROT13) | (ror(x, 3 * COL) & ~ROT13);
}

@inline
function secondRotation(x: Word, variant: int32): Word {
	if ((variant & 1) == 0) return ror(x, 2 * ROW);
	return (ror(x, 2 * ROW + 2 * COL) & ROT12) | (ror(x, ROW + 2 * COL) & ~ROT12);
}

@inline
function mixColumns(st: Word[], variant: int32): void {
	const a0 = st[0];
	const a1 = st[1];
	const a2 = st[2];
	const a3 = st[3];
	const a4 = st[4];
	const a5 = st[5];
	const a6 = st[6];
	const a7 = st[7];
	const b0 = firstRotation(a0, variant);
	const b1 = firstRotation(a1, variant);
	const b2 = firstRotation(a2, variant);
	const b3 = firstRotation(a3, variant);
	const b4 = firstRotation(a4, variant);
	const b5 = firstRotation(a5, variant);
	const b6 = firstRotation(a6, variant);
	const b7 = firstRotation(a7, variant);
	const c0 = a0 ^ b0;
	const c1 = a1 ^ b1;
	const c2 = a2 ^ b2;
	const c3 = a3 ^ b3;
	const c4 = a4 ^ b4;
	const c5 = a5 ^ b5;
	const c6 = a6 ^ b6;
	const c7 = a7 ^ b7;
	st[0] = b0 ^ c7 ^ secondRotation(c0, variant);
	st[1] = b1 ^ c0 ^ c7 ^ secondRotation(c1, variant);
	st[2] = b2 ^ c1 ^ secondRotation(c2, variant);
	st[3] = b3 ^ c2 ^ c7 ^ secondRotation(c3, variant);
	st[4] = b4 ^ c3 ^ c7 ^ secondRotation(c4, variant);
	st[5] = b5 ^ c4 ^ secondRotation(c5, variant);
	st[6] = b6 ^ c5 ^ secondRotation(c6, variant);
	st[7] = b7 ^ c6 ^ secondRotation(c7, variant);
}

@inline
function invMixColumns(st: Word[], variant: int32): void {
	const a0 = st[0];
	const a1 = st[1];
	const a2 = st[2];
	const a3 = st[3];
	const a4 = st[4];
	const a5 = st[5];
	const a6 = st[6];
	const a7 = st[7];
	const c0 = a0 ^ firstRotation(a0, variant);
	const c1 = a1 ^ firstRotation(a1, variant);
	const c2 = a2 ^ firstRotation(a2, variant);
	const c3 = a3 ^ firstRotation(a3, variant);
	const c4 = a4 ^ firstRotation(a4, variant);
	const c5 = a5 ^ firstRotation(a5, variant);
	const c6 = a6 ^ firstRotation(a6, variant);
	const c7 = a7 ^ firstRotation(a7, variant);
	const d0 = a0 ^ c7;
	const d1 = a1 ^ c0 ^ c7;
	const d2 = a2 ^ c1;
	const d3 = a3 ^ c2 ^ c7;
	const d4 = a4 ^ c3 ^ c7;
	const d5 = a5 ^ c4;
	const d6 = a6 ^ c5;
	const d7 = a7 ^ c6;
	const e0 = c0 ^ d6;
	const e1 = c1 ^ d6 ^ d7;
	const e2 = c2 ^ d0 ^ d7;
	const e3 = c3 ^ d1 ^ d6;
	const e4 = c4 ^ d2 ^ d6 ^ d7;
	const e5 = c5 ^ d3 ^ d7;
	const e6 = c6 ^ d4;
	const e7 = c7 ^ d5;
	st[0] = d0 ^ e0 ^ secondRotation(e0, variant);
	st[1] = d1 ^ e1 ^ secondRotation(e1, variant);
	st[2] = d2 ^ e2 ^ secondRotation(e2, variant);
	st[3] = d3 ^ e3 ^ secondRotation(e3, variant);
	st[4] = d4 ^ e4 ^ secondRotation(e4, variant);
	st[5] = d5 ^ e5 ^ secondRotation(e5, variant);
	st[6] = d6 ^ e6 ^ secondRotation(e6, variant);
	st[7] = d7 ^ e7 ^ secondRotation(e7, variant);
}

function swapWithin(x: Word, shift: Word, mask: Word): Word {
	const t = (x ^ (x >> shift)) & mask;
	return x ^ t ^ (t << shift);
}

// ShiftRows applied `times` (1 to 3) times.
function shiftRows(st: Word[], times: int32): void {
	for (let i = 0; i < 8; i++) {
		if (times == 2) {
			st[i] = swapWithin(st[i], 2 * COL, SHIFT_ROWS_2);
		} else {
			st[i] = swapWithin(swapWithin(st[i], 2 * COL, times == 1 ? SHIFT_ROWS_1 : SHIFT_ROWS_3), COL, SHIFT_ROWS_ODD);
		}
	}
}

function addRoundKey(st: Word[], keys: Readonly<Word[]>, round: int32): void {
	const at = round * 8;
	for (let i = 0; i < 8; i++) st[i] ^= keys[at + i];
}

// Round r runs MixColumns variant r % 4; callers pass it as a constant, so each inlined round folds its rotations.
@inline
function encryptRound(st: Word[], keys: Readonly<Word[]>, r: int32, variant: int32): void {
	subBytes(st);
	mixColumns(st, variant);
	addRoundKey(st, keys, r);
}

@inline
function decryptRound(st: Word[], keys: Readonly<Word[]>, r: int32, variant: int32): void {
	addRoundKey(st, keys, r);
	invMixColumns(st, variant);
	invSubBytes(st);
}

// The bulk path: the bitsliced cipher with eight blocks per 32-bit lane, WIDE_BLOCKS per pass, which runs many blocks
// faster than fixsliced passes.
function wideSbox(u: Wide[], at: int32): void {
	const s0 = u[at + 4] ^ u[at + 16];
	const s1 = u[at + 20] ^ u[at + 28];
	const s2 = u[at + 12] ^ s0;
	const s3 = u[at + 0] ^ u[at + 8];
	const q0 = s1 ^ s2;
	const s4 = u[at + 0] ^ u[at + 24];
	const s5 = u[at + 8] ^ u[at + 24];
	const s6 = u[at + 12] ^ s1;
	const s7 = u[at + 20] ^ s3;
	const q1 = s1 ^ s5;
	const q2 = u[at + 8] ^ q0;
	const q3 = s4 ^ s2;
	const q4 = s3 ^ q0;
	const s8 = u[at + 16] ^ s3;
	const q5 = s6 ^ s8;
	const q6 = u[at + 8] ^ u[at + 12];
	const q7 = u[at + 24] ^ s2;
	const s9 = u[at + 24] ^ s0;
	const q8 = s3 ^ s9;
	const q9 = s4 ^ s6;
	const q10 = s0 ^ s5;
	const q12 = u[at + 28] ^ s2;
	const q13 = u[at + 4] ^ s7;
	const q14 = u[at + 28] ^ s3;
	const q15 = s2 ^ s7;
	const q16 = u[at + 4] ^ s1;
	const q17 = u[at + 4] ^ u[at + 28];
	const q11 = u[at + 20];
	const t20 = q6 & q12;
	const t21 = q3 & q14;
	const t22 = q1 & q16;
	const t23 = q2 & q17;
	const x0 = ((q3 | q14) ^ (q0 & q7)) ^ (t20 ^ t22);
	const x1 = ((q4 | q13) ^ (q10 & q11)) ^ (t21 ^ t20);
	const x2 = ((q2 | q17) ^ (q5 & q9)) ^ (t21 ^ t22);
	const x3 = ((q8 | q15) ^ t23) ^ (t21 ^ (q4 & q13));
	const a = x1 & ~x3;
	const b = x0 & ~x3;
	const c = x3 & ~x1;
	const d = x2 & ~x1;
	const e = x0 ^ a;
	const y0 = x3 ^ (x2 & ~e);
	const f = x1 ^ b;
	const y1 = c ^ (x2 & f);
	const g = x2 ^ c;
	const y2 = x1 ^ (x0 & ~g);
	const h = x3 ^ d;
	const y3 = a ^ (x0 & h);
	const y02 = y2 ^ y0;
	const y13 = y3 ^ y1;
	const y23 = y3 ^ y2;
	const y01 = y1 ^ y0;
	const y00 = y02 ^ y13;
	const a0 = y01 & q11;
	const a1 = y0 & q12;
	const a2 = y1 & q0;
	const a3 = y23 & q17;
	const a4 = y2 & q5;
	const a5 = y3 & q15;
	const a6 = y13 & q14;
	const a7 = y00 & q16;
	const a8 = y02 & q13;
	const a9 = y01 & q7;
	const a10 = y0 & q10;
	const a11 = y1 & q6;
	const a12 = y23 & q2;
	const a13 = y2 & q9;
	const a14 = y3 & q8;
	const a15 = y13 & q3;
	const a16 = y00 & q1;
	const a17 = y02 & q4;
	const r0 = a1 ^ a5;
	const r1 = a9 ^ a15;
	const r2 = a4 ^ r0;
	const r3 = a2 ^ a10;
	const r4 = a11 ^ a17;
	const r5 = a8 ^ r1;
	const r6 = a0 ^ a16;
	const r7 = a7 ^ a13;
	const r8 = a11 ^ a14;
	const r9 = r3 ^ r4;
	const r10 = r5 ^ r6;
	const r11 = r2 ^ r9;
	const r12 = a3 ^ r0;
	const r13 = r7 ^ r8;
	const r14 = r12 ^ r13;
	u[at + 0] = r10 ^ r14;
	const r15 = a6 ^ a10;
	const r16 = r15 ^ r2;
	u[at + 4] = ~(r10 ^ r16);
	u[at + 8] = ~(a2 ^ r2);
	const r17 = a12 ^ a13;
	const r18 = a15 ^ r17;
	u[at + 12] = r18 ^ r11;
	const r19 = a1 ^ a14;
	const r20 = a17 ^ r3;
	const r21 = r7 ^ r19;
	const r22 = r5 ^ r20;
	u[at + 16] = r21 ^ r22;
	const r23 = a9 ^ a12;
	u[at + 20] = r8 ^ r23;
	u[at + 24] = ~(r1 ^ r4);
	u[at + 28] = ~(a16 ^ r11);
}

function wideMixColumns(st: Wide[]): void {
	const t2_0 = st[0] ^ st[1];
	const t2_1 = st[1] ^ st[2];
	const t2_2 = st[2] ^ st[3];
	const t2_3 = st[3] ^ st[0];
	let t0_0 = st[28] ^ st[29];
	let t0_1 = st[29] ^ st[30];
	let t0_2 = st[30] ^ st[31];
	let t0_3 = st[31] ^ st[28];
	let t = st[28];
	st[28] = t2_0 ^ t0_2 ^ st[29];
	st[29] = t2_1 ^ t0_2 ^ t;
	t = st[30];
	st[30] = t2_2 ^ t0_0 ^ st[31];
	st[31] = t2_3 ^ t0_0 ^ t;
	let t1_0 = st[24] ^ st[25];
	let t1_1 = st[25] ^ st[26];
	let t1_2 = st[26] ^ st[27];
	let t1_3 = st[27] ^ st[24];
	t = st[24];
	st[24] = t0_0 ^ t2_0 ^ st[25] ^ t1_2;
	let t_bis = st[25];
	st[25] = t0_1 ^ t2_1 ^ t1_2 ^ t;
	t = st[26];
	st[26] = t0_2 ^ t2_2 ^ t1_3 ^ t_bis;
	st[27] = t0_3 ^ t2_3 ^ t1_0 ^ t;
	t0_0 = st[20] ^ st[21];
	t0_1 = st[21] ^ st[22];
	t0_2 = st[22] ^ st[23];
	t0_3 = st[23] ^ st[20];
	t = st[20];
	st[20] = t1_0 ^ t0_1 ^ st[23];
	t_bis = st[21];
	st[21] = t1_1 ^ t0_2 ^ t;
	t = st[22];
	st[22] = t1_2 ^ t0_3 ^ t_bis;
	st[23] = t1_3 ^ t0_0 ^ t;
	t1_0 = st[16] ^ st[17];
	t1_1 = st[17] ^ st[18];
	t1_2 = st[18] ^ st[19];
	t1_3 = st[19] ^ st[16];
	t = st[16];
	st[16] = t0_0 ^ t2_0 ^ t1_1 ^ st[19];
	t_bis = st[17];
	st[17] = t0_1 ^ t2_1 ^ t1_2 ^ t;
	t = st[18];
	st[18] = t0_2 ^ t2_2 ^ t1_3 ^ t_bis;
	st[19] = t0_3 ^ t2_3 ^ t1_0 ^ t;
	t0_0 = st[12] ^ st[13];
	t0_1 = st[13] ^ st[14];
	t0_2 = st[14] ^ st[15];
	t0_3 = st[15] ^ st[12];
	t = st[12];
	st[12] = t1_0 ^ t2_0 ^ t0_1 ^ st[15];
	t_bis = st[13];
	st[13] = t1_1 ^ t2_1 ^ t0_2 ^ t;
	t = st[14];
	st[14] = t1_2 ^ t2_2 ^ t0_3 ^ t_bis;
	st[15] = t1_3 ^ t2_3 ^ t0_0 ^ t;
	t1_0 = st[8] ^ st[9];
	t1_1 = st[9] ^ st[10];
	t1_2 = st[10] ^ st[11];
	t1_3 = st[11] ^ st[8];
	t = st[8];
	st[8] = t0_0 ^ t1_1 ^ st[11];
	t_bis = st[9];
	st[9] = t0_1 ^ t1_2 ^ t;
	t = st[10];
	st[10] = t0_2 ^ t1_3 ^ t_bis;
	st[11] = t0_3 ^ t1_0 ^ t;
	t0_0 = st[4] ^ st[5];
	t0_1 = st[5] ^ st[6];
	t0_2 = st[6] ^ st[7];
	t0_3 = st[7] ^ st[4];
	t = st[4];
	st[4] = t1_0 ^ t0_1 ^ st[7];
	t_bis = st[5];
	st[5] = t1_1 ^ t0_2 ^ t;
	t = st[6];
	st[6] = t1_2 ^ t0_3 ^ t_bis;
	st[7] = t1_3 ^ t0_0 ^ t;
	t = st[0];
	st[0] = t0_0 ^ t2_1 ^ st[3];
	t_bis = st[1];
	st[1] = t0_1 ^ t2_2 ^ t;
	t = st[2];
	st[2] = t0_2 ^ t2_3 ^ t_bis;
	st[3] = t0_3 ^ t2_0 ^ t;
}

function wideSubBytes(st: Wide[]): void {
	wideSbox(st, 0);
	wideSbox(st, 1);
	wideSbox(st, 2);
	wideSbox(st, 3);
}

function wideShiftRows(st: Wide[]): void {
	for (let i = 0; i < 32; i += 4) {
		st[i + 1] = laneRotl(st[i + 1], 24);
		st[i + 2] = laneRotl(st[i + 2], 16);
		st[i + 3] = laneRotl(st[i + 3], 8);
	}
}

function wideSwapMove(st: Wide[], a: int32, b: int32, mask: uint32, n: Wide): void {
	const tmp = (st[b] ^ (st[a] >> n)) & splatLike(mask, st[a]);
	st[b] ^= tmp;
	st[a] ^= tmp << n;
}

function wideTranspose(st: Wide[]): void {
	for (let k = 0; k < 4; k++) {
		wideSwapMove(st, k + 4, k, 0x55555555, 1);
		wideSwapMove(st, k + 12, k + 8, 0x55555555, 1);
		wideSwapMove(st, k + 20, k + 16, 0x55555555, 1);
		wideSwapMove(st, k + 28, k + 24, 0x55555555, 1);
		wideSwapMove(st, k + 8, k, 0x33333333, 2);
		wideSwapMove(st, k + 12, k + 4, 0x33333333, 2);
		wideSwapMove(st, k + 24, k + 16, 0x33333333, 2);
		wideSwapMove(st, k + 28, k + 20, 0x33333333, 2);
		wideSwapMove(st, k + 16, k, 0x0f0f0f0f, 4);
		wideSwapMove(st, k + 20, k + 4, 0x0f0f0f0f, 4);
		wideSwapMove(st, k + 24, k + 8, 0x0f0f0f0f, 4);
		wideSwapMove(st, k + 28, k + 12, 0x0f0f0f0f, 4);
	}
}

function widePack(st: Wide[]): void {
	for (let i = 0; i < 32; i += 4) {
		wideSwapMove(st, i, i + 1, 0x00ff00ff, 8);
		wideSwapMove(st, i + 2, i + 3, 0x00ff00ff, 8);
		wideSwapMove(st, i, i + 2, 0x0000ffff, 16);
		wideSwapMove(st, i + 1, i + 3, 0x0000ffff, 16);
	}
	wideTranspose(st);
}

function wideUnpack(st: Wide[]): void {
	wideTranspose(st);
	for (let i = 0; i < 32; i += 4) {
		wideSwapMove(st, i, i + 2, 0x0000ffff, 16);
		wideSwapMove(st, i + 1, i + 3, 0x0000ffff, 16);
		wideSwapMove(st, i, i + 1, 0x00ff00ff, 8);
		wideSwapMove(st, i + 2, i + 3, 0x00ff00ff, 8);
	}
}

function wideAddRoundKey(st: Wide[], keys: Readonly<Word[]>, at: int32): void {
	for (let i = 0; i < 32; i++) st[i] ^= keys[at + i] as Wide;
}

function wideEncrypt(keys: Readonly<Word[]>, st: Wide[]): void {
	const rounds = roundsOf(keys);
	const base = 8 * (rounds + 1);
	wideAddRoundKey(st, keys, base);
	for (let r = 1; r < rounds; r++) {
		wideSubBytes(st);
		wideShiftRows(st);
		wideMixColumns(st);
		wideAddRoundKey(st, keys, base + 32 * r);
	}
	wideSubBytes(st);
	wideShiftRows(st);
	wideAddRoundKey(st, keys, base + 32 * rounds);
}

// The wide round keys follow the fixsliced ones, 32 words per round.
function appendWideKeys(packed: Word[], words: Readonly<uint32[]>, rounds: int32, st: Wide[]): void {
	const base = 8 * (rounds + 1);
	for (let r = 0; r <= rounds; r++) {
		for (let i = 0; i < 32; i++) st[i] = laneWord(words[r * 4 + (i & 3)], words[r * 4 + (i & 3)]);
		widePack(st);
		for (let i = 0; i < 32; i++) packed[base + r * 32 + i] = st[i];
	}
}

// The key stream of the WIDE_BLOCKS counters from `batch.counter` under `nonce` into `batch.bytes`; with `hashKey`
// block 0 is the all-zero block instead.
function refillWide(keys: Readonly<Word[]>, batch: Batch, nonce: Readonly<uint8[]>, hashKey: boolean): void {
	const st = batch.wide;
	const n0 = loadLE(nonce, 0);
	const n1 = loadLE(nonce, 4);
	const n2 = loadLE(nonce, 8);
	const first = batch.counter;
	for (let p = 0; p < 8; p++) {
		const zero = hashKey && p == 0;
		st[p * 4] = laneWord(zero ? 0 : n0, n0);
		st[p * 4 + 1] = laneWord(zero ? 0 : n1, n1);
		st[p * 4 + 2] = laneWord(zero ? 0 : n2, n2);
		st[p * 4 + 3] = laneWord(zero ? 0 : swapBytes(first + (p as uint32)), swapBytes(first + ((p + 8) as uint32)));
	}
	widePack(st);
	wideEncrypt(keys, st);
	wideStore(st, batch.bytes);
	batch.end = WIDE_BLOCKS * 16;
	batch.counter += WIDE_BLOCKS as uint32;
}

function wideStore(st: Wide[], bytes: uint8[]): void {
	wideUnpack(st);
	for (let g = 0; g < WIDE_BLOCKS / 8; g++) {
		for (let i = 0; i < 32; i++) storeLE(bytes, g * 128 + i * 4, laneOf(st[i], g));
	}
}

function wideInvShiftRows(st: Wide[]): void {
	for (let i = 0; i < 32; i += 4) {
		st[i + 1] = laneRotl(st[i + 1], 8);
		st[i + 2] = laneRotl(st[i + 2], 16);
		st[i + 3] = laneRotl(st[i + 3], 24);
	}
}

function wideInvMixColumns(st: Wide[]): void {
	wideMixColumns(st);
	wideMixColumns(st);
	wideMixColumns(st);
}

function wideInvAffineGroup(st: Wide[], g: int32): void {
	const a0 = ~st[g + 28];
	const a1 = ~st[g + 24];
	const a2 = st[g + 20];
	const a3 = st[g + 16];
	const a4 = st[g + 12];
	const a5 = ~st[g + 8];
	const a6 = ~st[g + 4];
	const a7 = st[g];
	st[g] = a1 ^ a4 ^ a6;
	st[g + 4] = a0 ^ a3 ^ a5;
	st[g + 8] = a7 ^ a2 ^ a4;
	st[g + 12] = a6 ^ a1 ^ a3;
	st[g + 16] = a5 ^ a0 ^ a2;
	st[g + 20] = a4 ^ a7 ^ a1;
	st[g + 24] = a3 ^ a6 ^ a0;
	st[g + 28] = a2 ^ a5 ^ a7;
}

function wideInvSubBytes(st: Wide[]): void {
	for (let g = 0; g < 4; g++) wideInvAffineGroup(st, g);
	wideSubBytes(st);
	for (let g = 0; g < 4; g++) wideInvAffineGroup(st, g);
}

function wideDecrypt(keys: Readonly<Word[]>, st: Wide[]): void {
	const rounds = roundsOf(keys);
	const base = 8 * (rounds + 1);
	wideAddRoundKey(st, keys, base + 32 * rounds);
	for (let r = rounds - 1; r > 0; r--) {
		wideInvShiftRows(st);
		wideInvSubBytes(st);
		wideAddRoundKey(st, keys, base + 32 * r);
		wideInvMixColumns(st);
	}
	wideInvShiftRows(st);
	wideInvSubBytes(st);
	wideAddRoundKey(st, keys, base);
}

// Loads `count` blocks of `src` from `at` into the wide state, zero blocks after them.
function wideLoad(st: Wide[], src: Readonly<uint8[]>, at: int32, count: int32): void {
	for (let p = 0; p < 8; p++) {
		for (let w = 0; w < 4; w++) {
			const lo = p < count ? loadLE(src, at + p * 16 + w * 4) : 0;
			const hi = p + 8 < count ? loadLE(src, at + (p + 8) * 16 + w * 4) : 0;
			st[p * 4 + w] = laneWord(lo, hi);
		}
	}
	widePack(st);
}

const KEY_WORDS: int32 = 8 + 32;

function newWide(): Wide[] {
	return new Array<Wide>(32);
}

// The next key stream, a wide pass when at least WIDE_FROM bytes of it are `needed`.
function refill(keys: Readonly<Word[]>, batch: Batch, nonce: Readonly<uint8[]>, needed: int32, hashKey: boolean): void {
	if (needed >= WIDE_FROM) refillWide(keys, batch, nonce, hashKey);
	else refillNarrow(keys, batch, nonce, hashKey);
}

// On C a key schedule ends with the FIPS 197 round keys, two words per round key, and the round count, which the
// CPU's AES instructions run on (hw.cms); JS has no such tail.
when (c) {
	function hwTailWords(rounds: int32): int32 {
		return 2 * (rounds + 1) + 1;
	}

	function putHwKeys(packed: Word[], words: Readonly<uint32[]>, rounds: int32): void {
		const base = (rounds + 1) * KEY_WORDS;
		for (let i = 0; i < 2 * (rounds + 1); i++) packed[base + i] = (words[2 * i] as uint64) | ((words[2 * i + 1] as uint64) << 32);
		packed[base + 2 * (rounds + 1)] = rounds as uint64;
	}

	function roundsOf(keys: Readonly<Word[]>): int32 {
		return keys[keys.length - 1] as int32;
	}

	/** An output array every byte of which the caller writes before it is read, so it is not zeroed first. */
	function outputArray(size: int32): uint8[] {
		return Buffer.allocUnsafe(size);
	}
} else {
	function hwTailWords(rounds: int32): int32 {
		return 0;
	}

	function putHwKeys(packed: Word[], words: Readonly<uint32[]>, rounds: int32): void {}

	function roundsOf(keys: Readonly<Word[]>): int32 {
		return keys.length / KEY_WORDS - 1;
	}

	function outputArray(size: int32): uint8[] {
		return new Array<uint8>(size);
	}
}

function encryptState(keys: Readonly<Word[]>, st: Word[]): void {
	const rounds = roundsOf(keys);
	addRoundKey(st, keys, 0);
	let r = 1;
	while (r + 3 < rounds) {
		encryptRound(st, keys, r, 1);
		encryptRound(st, keys, r + 1, 2);
		encryptRound(st, keys, r + 2, 3);
		encryptRound(st, keys, r + 3, 0);
		r += 4;
	}
	encryptRound(st, keys, r, 1);
	if (r + 1 < rounds) {
		encryptRound(st, keys, r + 1, 2);
		encryptRound(st, keys, r + 2, 3);
	}
	if ((rounds & 3) == 2) shiftRows(st, 2);
	subBytes(st);
	addRoundKey(st, keys, rounds);
}

function decryptState(keys: Readonly<Word[]>, st: Word[]): void {
	const rounds = roundsOf(keys);
	addRoundKey(st, keys, rounds);
	invSubBytes(st);
	if ((rounds & 3) == 2) shiftRows(st, 2);
	let r = rounds - 1;
	if ((r & 3) == 3) {
		decryptRound(st, keys, r, 3);
		decryptRound(st, keys, r - 1, 2);
		r -= 2;
	}
	while (r > 1) {
		decryptRound(st, keys, r, 1);
		decryptRound(st, keys, r - 1, 0);
		decryptRound(st, keys, r - 2, 3);
		decryptRound(st, keys, r - 3, 2);
		r -= 4;
	}
	decryptRound(st, keys, 1, 1);
	addRoundKey(st, keys, 0);
}

function rotl(n: uint32, by: uint32): uint32 {
	return (n << by) | (n >> (32 - by));
}

function mul2(n: int32): int32 {
	return (n << 1) ^ (0x11b & -(n >> 7));
}

// The S-box of each byte of `n`, through the bitsliced circuit.
function subWord(n: uint32, st: Word[], block: uint8[]): uint32 {
	storeLE(block, 0, n);
	loadBlocks(st, block, 0, 1);
	subBytes(st);
	subBytesNots(st);
	storeBlocks(st, block);
	return loadLE(block, 0);
}

/** The fixsliced round keys of a 16-, 24- or 32-byte key: (rounds + 1) groups of eight words, each the round key in every block. */
export function expandKey(key: Readonly<uint8[]>): Word[] {
	if (key.length != 16 && key.length != 24 && key.length != 32) throw new Error(`aes: key must be 16, 24 or 32 bytes, got ${key.length}`);
	const nk = key.length / 4;
	const words = new Array<uint32>(key.length + 28);
	const st = new Array<Word>(8);
	const block = new Array<uint8>(BLOCKS * 16);
	for (let i = 0; i < nk; i++) words[i] = loadLE(key, i * 4);
	let rcon: int32 = 1;
	for (let i = nk; i < words.length; i++) {
		let t = words[i - 1];
		if (i % nk == 0) {
			t = subWord(rotl(t, 24), st, block) ^ (rcon as uint32);
			rcon = mul2(rcon);
		} else if (nk > 6 && i % nk == 4) {
			t = subWord(t, st, block);
		}
		words[i] = words[i - nk] ^ t;
	}
	const rounds = words.length / 4 - 1;
	const packed = new Array<Word>((rounds + 1) * KEY_WORDS + hwTailWords(rounds));
	for (let r = 0; r <= rounds; r++) {
		for (let p = 0; p < BLOCKS; p++) {
			for (let w = 0; w < 4; w++) storeLE(block, p * 16 + w * 4, words[r * 4 + w]);
		}
		loadBlocks(st, block, 0, BLOCKS);
		// Round r of the cipher leaves out r ShiftRows, which round key r undoes; the last round runs them all.
		if (r > 0 && r < rounds && (r & 3) != 0) shiftRows(st, 4 - (r & 3));
		if (r > 0) subBytesNots(st);
		for (let i = 0; i < 8; i++) packed[r * 8 + i] = st[i];
	}
	const wide = newWide();
	appendWideKeys(packed, words, rounds, wide);
	putHwKeys(packed, words, rounds);
	wipeLanes(wide);
	wipeWords(words);
	wipeLanes(st);
	wipeBytes(block);
	return packed;
}

/** The key schedule for decryption, which the fixsliced cipher shares with encryption. */
export function expandKeyDecrypt(key: Readonly<uint8[]>): Word[] {
	return expandKey(key);
}

/**
 * Blocks in flight: the fixsliced state, the input blocks and the output bytes of a pass, and where the key stream in
 * `bytes` ends and which counter comes next.
 */
class Batch {
	st: Word[] = new Array<Word>(8);
	wide = newWide();
	input: uint8[] = new Array<uint8>(BLOCKS * 16);
	bytes: uint8[] = new Array<uint8>(Math.max(BLOCKS, WIDE_BLOCKS) * 16);
	end: int32 = 0;
	counter: uint32 = 0;
}

function wipe(batch: Batch): void {
	batch.st.fill(0);
	batch.wide.fill(0);
	batch.input.fill(0);
	batch.bytes.fill(0);
}

// The key stream of the BLOCKS counters from `batch.counter` under `nonce` into `batch.bytes`; with `hashKey` block 0
// is the all-zero block instead.
function refillNarrow(keys: Readonly<Word[]>, batch: Batch, nonce: Readonly<uint8[]>, hashKey: boolean): void {
	const input = batch.input;
	for (let p = 0; p < BLOCKS; p++) {
		const zero = hashKey && p == 0;
		for (let i = 0; i < 12; i++) input[p * 16 + i] = zero ? 0 : nonce[i];
		storeLE(input, p * 16 + 12, zero ? 0 : swapBytes(batch.counter + (p as uint32)));
	}
	loadBlocks(batch.st, input, 0, BLOCKS);
	encryptState(keys, batch.st);
	storeBlocks(batch.st, batch.bytes);
	batch.end = BLOCKS * 16;
	batch.counter += BLOCKS as uint32;
}

// E(0) and E(J1) into batch.bytes[0, 32), and the key stream from counter 2 after them.
function startGcm(keys: Readonly<Word[]>, batch: Batch, nonce: Readonly<uint8[]>, length: int32): void {
	batch.counter = 0;
	refill(keys, batch, nonce, 32 + length, true);
}

// dst[dstAt, +length) = src[srcAt, +length) ^ the key stream from counter 2, which `startGcm` began at batch.bytes[32].
function ctrXor(keys: Readonly<Word[]>, batch: Batch, nonce: Readonly<uint8[]>, src: Readonly<uint8[]>, srcAt: int32, length: int32, dst: uint8[], dstAt: int32): void {
	const stream = batch.bytes;
	let streamAt = 32;
	let done = 0;
	while (done < length) {
		if (streamAt == batch.end) {
			refill(keys, batch, nonce, length - done, false);
			streamAt = 0;
		}
		const count = Math.min(batch.end - streamAt, length - done);
		for (let i = 0; i < count; i++) dst[dstAt + done + i] = src[srcAt + done + i] ^ stream[streamAt + i];
		streamAt += count;
		done += count;
	}
}

function requireNonce(nonce: Readonly<uint8[]>): void {
	if (nonce.length != 12) throw new Error(`aes-gcm: nonce must be 12 bytes, got ${nonce.length}`);
}

function requireRange(what: string, bytes: Readonly<uint8[]>, at: int32, length: int32): void {
	if (at < 0 || length < 0 || at > bytes.length - length) throw new Error(`aes-gcm: ${what} range [${at}, +${length}) is outside its ${bytes.length} bytes`);
}

// The tag over `aad` and the cipher text `text[at, +length)` into `tag[0, 16)`; `keyed` starts with E(0) and E(J1).
function gcmTag(keyed: Readonly<uint8[]>, aad: Readonly<uint8[]>, text: Readonly<uint8[]>, at: int32, length: int32, tag: uint8[]): void {
	const ghash = newGhash(keyed);
	updateGhash(ghash, aad, 0, aad.length);
	updateGhash(ghash, text, at, at + length);
	const lengths = new Array<uint8>(16);
	storeBE32(lengths, 0, (aad.length as uint32) >> 29);
	storeBE32(lengths, 4, (aad.length as uint32) << 3);
	storeBE32(lengths, 8, (length as uint32) >> 29);
	storeBE32(lengths, 12, (length as uint32) << 3);
	updateGhash(ghash, lengths, 0, 16);
	finishGhash(ghash, tag, 0);
	for (let i = 0; i < 16; i++) tag[i] ^= keyed[16 + i];
}

/**
 * AES-GCM encryption of `src[srcAt, +length)` into `dst[dstAt, +length)` (the two may be the same range) and its
 * 16-byte tag into `tag[tagAt, +16)`. The nonce must be fresh for every call under one key.
 */
export function gcmEncryptInto(xk: Readonly<Word[]>, nonce: Readonly<uint8[]>, aad: Readonly<uint8[]>, src: Readonly<uint8[]>, srcAt: int32, length: int32, dst: uint8[], dstAt: int32, tag: uint8[], tagAt: int32): void {
	requireNonce(nonce);
	requireRange("source", src, srcAt, length);
	requireRange("destination", dst, dstAt, length);
	requireRange("tag", tag, tagAt, 16);
	when (c) {
		if (aesHwAvailable()) {
			aesGcmHwSeal(xk, nonce, aad, src, srcAt, length, dst, dstAt, tag, tagAt);
			return;
		}
	}
	const batch = new Batch();
	startGcm(xk, batch, nonce, length);
	const authKey = batch.bytes.slice(0, 32);
	ctrXor(xk, batch, nonce, src, srcAt, length, dst, dstAt);
	const computed = new Array<uint8>(16);
	gcmTag(authKey, aad, dst, dstAt, length, computed);
	for (let i = 0; i < 16; i++) tag[tagAt + i] = computed[i];
	authKey.fill(0);
	wipe(batch);
}

/**
 * AES-GCM decryption of `src[srcAt, +length)` into `dst[dstAt, +length)` once the tag at `tag[tagAt, +16)` verifies;
 * false, with nothing written, when it does not.
 */
export function gcmDecryptInto(xk: Readonly<Word[]>, nonce: Readonly<uint8[]>, aad: Readonly<uint8[]>, src: Readonly<uint8[]>, srcAt: int32, length: int32, tag: Readonly<uint8[]>, tagAt: int32, dst: uint8[], dstAt: int32): boolean {
	requireNonce(nonce);
	requireRange("source", src, srcAt, length);
	requireRange("destination", dst, dstAt, length);
	requireRange("tag", tag, tagAt, 16);
	when (c) {
		if (aesHwAvailable()) return aesGcmHwOpen(xk, nonce, aad, src, srcAt, length, tag, tagAt, dst, dstAt);
	}
	const batch = new Batch();
	startGcm(xk, batch, nonce, length);
	const computed = new Array<uint8>(16);
	gcmTag(batch.bytes, aad, src, srcAt, length, computed);
	let diff: uint8 = 0;
	for (let i = 0; i < 16; i++) diff |= computed[i] ^ tag[tagAt + i];
	computed.fill(0);
	if (diff != 0) {
		wipe(batch);
		return false;
	}
	ctrXor(xk, batch, nonce, src, srcAt, length, dst, dstAt);
	wipe(batch);
	return true;
}

/** AES-GCM: `nonce(12) || cipher text || tag(16)`. The nonce must be fresh for every call under one key. */
export function gcmSealWithNonce(xk: Readonly<Word[]>, nonce: Readonly<uint8[]>, plain: Readonly<uint8[]>, aad: Readonly<uint8[]>): uint8[] {
	requireNonce(nonce);
	const size = plain.length;
	const sealed = outputArray(12 + size + 16);
	for (let i = 0; i < 12; i++) sealed[i] = nonce[i];
	gcmEncryptInto(xk, nonce, aad, plain, 0, size, sealed, 12, sealed, 12 + size);
	return sealed;
}

/** The plain text of a `nonce || cipher text || tag` blob, or null when it is shorter than 28 bytes or the tag does not verify. */
export function gcmOpen(xk: Readonly<Word[]>, sealed: Readonly<uint8[]>, aad: Readonly<uint8[]>): uint8[] | null {
	if (sealed.length < 28) return null;
	const size = sealed.length - 28;
	when (c) {
		if (aesHwAvailable()) {
			const fresh = outputArray(size);
			return aesGcmHwOpenFresh(xk, sealed[0..12], aad, sealed, 12, size, sealed, 12 + size, fresh, 0) ? fresh : null;
		}
	}
	const plain = new Array<uint8>(size);
	if (!gcmDecryptInto(xk, sealed.slice(0, 12), aad, sealed, 12, size, sealed, 12 + size, plain, 0)) return null;
	return plain;
}

function requireIv(iv: Readonly<uint8[]>): void {
	if (iv.length != 16) throw new Error(`aes-cbc: iv must be 16 bytes, got ${iv.length}`);
}

/** AES-CBC with PKCS#7 padding; `iv` is 16 bytes. */
export function cbcEncrypt(xk: Readonly<Word[]>, iv: Readonly<uint8[]>, plain: Readonly<uint8[]>): uint8[] {
	requireIv(iv);
	const size = plain.length;
	const padding = 16 - (size % 16);
	const out = outputArray(size + padding);
	when (c) {
		if (aesHwAvailable()) {
			for (let i = 0; i < size; i++) out[i] = plain[i];
			for (let i = size; i < out.length; i++) out[i] = padding as uint8;
			aesCbcHwEncrypt(xk, iv, out);
			return out;
		}
	}
	const batch = new Batch();
	const block = new Array<uint8>(16);
	for (let i = 0; i < 16; i++) block[i] = iv[i];
	for (let at = 0; at < out.length; at += 16) {
		for (let i = 0; i < 16; i++) block[i] ^= at + i < size ? plain[at + i] : (padding as uint8);
		loadBlocks(batch.st, block, 0, 1);
		encryptState(xk, batch.st);
		storeBlocks(batch.st, batch.bytes);
		for (let i = 0; i < 16; i++) {
			block[i] = batch.bytes[i];
			out[at + i] = block[i];
		}
	}
	wipe(batch);
	return out;
}

function cbcDecryptPortable(xk: Readonly<Word[]>, iv: Readonly<uint8[]>, cipher: Readonly<uint8[]>, out: uint8[]): void {
	const size = cipher.length;
	const batch = new Batch();
	let at = 0;
	while (at < size) {
		let count = Math.min(BLOCKS, (size - at) / 16);
		if ((size - at) / 16 >= WIDE_DECRYPT_FROM) {
			count = Math.min(WIDE_BLOCKS, (size - at) / 16);
			wideLoad(batch.wide, cipher, at, count);
			wideDecrypt(xk, batch.wide);
			wideStore(batch.wide, batch.bytes);
		} else {
			loadBlocks(batch.st, cipher, at, count);
			decryptState(xk, batch.st);
			storeBlocks(batch.st, batch.bytes);
		}
		for (let i = 0; i < count * 16; i++) out[at + i] = batch.bytes[i] ^ (at + i < 16 ? iv[i] : cipher[at + i - 16]);
		at += count * 16;
	}
	wipe(batch);
}

/** The plain text of an AES-CBC cipher text, or null for an empty or ragged input or bad padding; `xk` is from `expandKeyDecrypt`. */
export function cbcDecrypt(xk: Readonly<Word[]>, iv: Readonly<uint8[]>, cipher: Readonly<uint8[]>): uint8[] | null {
	requireIv(iv);
	const size = cipher.length;
	if (size == 0 || size % 16 != 0) return null;
	const out = outputArray(size);
	let decrypted = false;
	when (c) {
		if (aesHwAvailable()) {
			aesCbcHwDecrypt(xk, iv, cipher, out);
			decrypted = true;
		}
	}
	if (!decrypted) cbcDecryptPortable(xk, iv, cipher, out);
	const pad = out[size - 1] as uint32;
	let bad: uint32 = ((pad - 1) >> 8) | ((16 - pad) >> 8);
	for (let i = 0; i < 16; i++) {
		const inPadding = (0 as uint32) - (((i as uint32) - pad) >> 31);
		bad |= ((out[size - 1 - i] as uint32) ^ pad) & inPadding;
	}
	if (bad != 0) {
		out.fill(0);
		return null;
	}
	return out.slice(0, size - (pad as int32));
}
