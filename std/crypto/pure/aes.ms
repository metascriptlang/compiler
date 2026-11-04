import { newGhash, updateGhash, finishGhash, storeBE32 } from "./ghash";

/**
 * AES-128/192/256 in GCM (12-byte nonce) and CBC with PKCS#7, bitsliced: blocks run eight per 32-bit lane as 32 words
 * (blocks `8g .. 8g + 7` in lane `g`; sixteen blocks in uint64 words for bulk work on C, eight in uint32 words for short
 * and serial work and everything on JS, where a uint64 is a BigInt), so the cipher reads no table indexed by the key
 * or the data. The key schedule reads its S-box
 * through a masked select over both 128-byte halves. A key schedule is the packed round keys, the same words for both
 * directions.
 */

function mul2(n: int32): int32 {
	return (n << 1) ^ (0x11b & -(n >> 7));
}

function buildSbox(): uint8[] {
	const powers = new Array<int32>(256);
	let x = 1;
	for (let i = 0; i < 256; i++) {
		powers[i] = x;
		x ^= mul2(x);
	}
	const box = new Array<uint8>(256);
	box[0] = 0x63;
	for (let i = 0; i < 255; i++) {
		let v = powers[255 - i];
		v |= v << 8;
		box[powers[i]] = ((v ^ (v >> 4) ^ (v >> 5) ^ (v >> 6) ^ (v >> 7) ^ 0x63) & 0xff) as uint8;
	}
	return box;
}

const keySbox: Readonly<uint8[]> = buildSbox();

function sboxByte(n: uint32): uint32 {
	const low = keySbox[n & 0x7f] as uint32;
	const high = keySbox[0x80 | (n & 0x7f)] as uint32;
	const mask = (0 as uint32) - (n >> 7);
	return (high & mask) | (low & ~mask);
}

function subWord(n: uint32): uint32 {
	return sboxByte(n & 0xff) | (sboxByte((n >> 8) & 0xff) << 8) | (sboxByte((n >> 16) & 0xff) << 16) | (sboxByte(n >> 24) << 24);
}

function rotl(n: uint32, by: uint32): uint32 {
	return (n << by) | (n >> (32 - by));
}

// The lane helpers of a bitsliced word: a uint32 holds one 32-bit lane (eight blocks), a uint64 two (sixteen blocks).
// The kernels below are generic over the word, so each width gets its own monomorphized copy.

function lanesOf(like: uint32): int32 {
	return 1;
}

function splatLike(x: uint32, like: uint32): uint32 {
	return x;
}

function laneWord(lo: uint32, hi: uint32, like: uint32): uint32 {
	return lo;
}

function laneOf(w: uint32, g: int32): uint32 {
	return w;
}

function laneRotl(x: uint32, by: uint32): uint32 {
	return rotl(x, by);
}

when (c) {
	/** The word of the bulk path: two lanes, sixteen blocks per pass. A one-lane uint32 pass runs the short and serial work. */
	type Word = uint64;

	function lanesOf(like: uint64): int32 {
		return 2;
	}

	function splatLike(x: uint32, like: uint64): uint64 {
		return (x as uint64) | ((x as uint64) << 32);
	}

	function laneWord(lo: uint32, hi: uint32, like: uint64): uint64 {
		return (lo as uint64) | ((hi as uint64) << 32);
	}

	function laneOf(w: uint64, g: int32): uint32 {
		return ((w >> ((32 * g) as uint64)) & 0xffffffff) as uint32;
	}

	function laneRotl(x: uint64, by: uint64): uint64 {
		const low = splatLike(((1 as uint32) << (by as uint32)) - 1, x);
		return ((x << by) & ~low) | ((x >> (32 - by)) & low);
	}
} else {
	/** On JS a uint64 is a BigInt, so every pass is the one-lane uint32 word. */
	type Word = uint32;
}

const NBLOCKS: int32 = 8 * lanesOf(0 as Word);

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

function sbox<W>(u: W[], at: int32): void {
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

function mixColumns<W>(st: W[]): void {
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

function subBytes<W>(st: W[]): void {
	sbox(st, 0);
	sbox(st, 1);
	sbox(st, 2);
	sbox(st, 3);
}

function shiftRows<W>(st: W[]): void {
	for (let i = 0; i < 32; i += 4) {
		st[i + 1] = laneRotl(st[i + 1], 24);
		st[i + 2] = laneRotl(st[i + 2], 16);
		st[i + 3] = laneRotl(st[i + 3], 8);
	}
}

function invShiftRows<W>(st: W[]): void {
	for (let i = 0; i < 32; i += 4) {
		st[i + 1] = laneRotl(st[i + 1], 8);
		st[i + 2] = laneRotl(st[i + 2], 16);
		st[i + 3] = laneRotl(st[i + 3], 24);
	}
}

// MixColumns has order four, so its inverse is three applications.
function invMixColumns<W>(st: W[]): void {
	mixColumns(st);
	mixColumns(st);
	mixColumns(st);
}

function invAffineGroup<W>(st: W[], g: int32): void {
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

function invSubBytes<W>(st: W[]): void {
	for (let g = 0; g < 4; g++) invAffineGroup(st, g);
	subBytes(st);
	for (let g = 0; g < 4; g++) invAffineGroup(st, g);
}

// The round keys are packed as the wide word; a narrow pass takes their low lane.
function addRoundKey<W, K>(st: W[], keys: Readonly<K[]>, round: int32): void {
	const at = round * 32;
	for (let i = 0; i < 32; i++) st[i] ^= keys[at + i] as W;
}

function swapMove<W>(st: W[], a: int32, b: int32, mask: uint32, n: W): void {
	const tmp = (st[b] ^ (st[a] >> n)) & splatLike(mask, st[a]);
	st[b] ^= tmp;
	st[a] ^= tmp << n;
}

function transposeBits<W>(st: W[]): void {
	for (let k = 0; k < 4; k++) {
		swapMove(st, k + 4, k, 0x55555555, 1);
		swapMove(st, k + 12, k + 8, 0x55555555, 1);
		swapMove(st, k + 20, k + 16, 0x55555555, 1);
		swapMove(st, k + 28, k + 24, 0x55555555, 1);
		swapMove(st, k + 8, k, 0x33333333, 2);
		swapMove(st, k + 12, k + 4, 0x33333333, 2);
		swapMove(st, k + 24, k + 16, 0x33333333, 2);
		swapMove(st, k + 28, k + 20, 0x33333333, 2);
		swapMove(st, k + 16, k, 0x0f0f0f0f, 4);
		swapMove(st, k + 20, k + 4, 0x0f0f0f0f, 4);
		swapMove(st, k + 24, k + 8, 0x0f0f0f0f, 4);
		swapMove(st, k + 28, k + 12, 0x0f0f0f0f, 4);
	}
}

function packState<W>(st: W[]): void {
	for (let i = 0; i < 32; i += 4) {
		swapMove(st, i, i + 1, 0x00ff00ff, 8);
		swapMove(st, i + 2, i + 3, 0x00ff00ff, 8);
		swapMove(st, i, i + 2, 0x0000ffff, 16);
		swapMove(st, i + 1, i + 3, 0x0000ffff, 16);
	}
	transposeBits(st);
}

function unpackState<W>(st: W[]): void {
	transposeBits(st);
	for (let i = 0; i < 32; i += 4) {
		swapMove(st, i, i + 2, 0x0000ffff, 16);
		swapMove(st, i + 1, i + 3, 0x0000ffff, 16);
		swapMove(st, i, i + 1, 0x00ff00ff, 8);
		swapMove(st, i + 2, i + 3, 0x00ff00ff, 8);
	}
}

function encryptState<W, K>(keys: Readonly<K[]>, st: W[]): void {
	const rounds = keys.length / 32 - 1;
	addRoundKey(st, keys, 0);
	for (let r = 1; r < rounds; r++) {
		subBytes(st);
		shiftRows(st);
		mixColumns(st);
		addRoundKey(st, keys, r);
	}
	subBytes(st);
	shiftRows(st);
	addRoundKey(st, keys, rounds);
}

function decryptState<W, K>(keys: Readonly<K[]>, st: W[]): void {
	const rounds = keys.length / 32 - 1;
	addRoundKey(st, keys, rounds);
	for (let r = rounds - 1; r > 0; r--) {
		invShiftRows(st);
		invSubBytes(st);
		addRoundKey(st, keys, r);
		invMixColumns(st);
	}
	invShiftRows(st);
	invSubBytes(st);
	addRoundKey(st, keys, 0);
}

/** The packed round keys of a 16-, 24- or 32-byte key: (rounds + 1) groups of 32 words, each the round key in every block. */
export function expandKey(key: Readonly<uint8[]>): Word[] {
	if (key.length != 16 && key.length != 24 && key.length != 32) throw new Error(`aes: key must be 16, 24 or 32 bytes, got ${key.length}`);
	const nk = key.length / 4;
	const words = new Array<uint32>(key.length + 28);
	for (let i = 0; i < nk; i++) words[i] = loadLE(key, i * 4);
	let rcon: int32 = 1;
	for (let i = nk; i < words.length; i++) {
		let t = words[i - 1];
		if (i % nk == 0) {
			t = subWord(rotl(t, 24)) ^ (rcon as uint32);
			rcon = mul2(rcon);
		} else if (nk > 6 && i % nk == 4) {
			t = subWord(t);
		}
		words[i] = words[i - nk] ^ t;
	}
	const roundKeys = words.length / 4;
	const packed = new Array<Word>(roundKeys * 32);
	const st = new Array<uint32>(32);
	const wide = 0 as Word;
	for (let r = 0; r < roundKeys; r++) {
		for (let i = 0; i < 32; i++) st[i] = words[r * 4 + (i & 3)];
		packState(st);
		for (let i = 0; i < 32; i++) packed[r * 32 + i] = splatLike(st[i], wide);
	}
	words.fill(0);
	st.fill(0);
	return packed;
}

/** The key schedule for decryption, which the bitsliced cipher shares with encryption. */
export function expandKeyDecrypt(key: Readonly<uint8[]>): Word[] {
	return expandKey(key);
}

/**
 * Blocks in flight: the wide and the narrow bitsliced state, their bytes, and where the key stream in `bytes` ends
 * and which counter comes next.
 */
class Batch {
	wide: Word[] = new Array<Word>(32);
	narrow: uint32[] = new Array<uint32>(32);
	bytes: uint8[] = new Array<uint8>(NBLOCKS * 16);
	end: int32 = 0;
	counter: uint32 = 0;
}

function wipe(batch: Batch): void {
	batch.wide.fill(0);
	batch.narrow.fill(0);
	batch.bytes.fill(0);
}

// Loads `count` blocks of `src` from `at` into the state, zero blocks after them.
function loadBlocks<W>(st: W[], src: Readonly<uint8[]>, at: int32, count: int32): void {
	for (let p = 0; p < 8; p++) {
		for (let w = 0; w < 4; w++) {
			const lo = p < count ? loadLE(src, at + p * 16 + w * 4) : 0;
			const hi = p + 8 < count ? loadLE(src, at + (p + 8) * 16 + w * 4) : 0;
			st[p * 4 + w] = laneWord(lo, hi, st[0]);
		}
	}
	packState(st);
}

function storeBlocks<W>(st: W[], bytes: uint8[]): void {
	unpackState(st);
	const lanes = lanesOf(st[0]);
	for (let g = 0; g < lanes; g++) {
		for (let i = 0; i < 32; i++) storeLE(bytes, g * 128 + i * 4, laneOf(st[i], g));
	}
}

// The key stream of the `8 * lanes` counters from `first` under `nonce` into `bytes`; with `hashKey` block 0 is the
// all-zero block instead.
function counterBlocks<W, K>(keys: Readonly<K[]>, st: W[], bytes: uint8[], nonce: Readonly<uint8[]>, first: uint32, hashKey: boolean): void {
	const n0 = loadLE(nonce, 0);
	const n1 = loadLE(nonce, 4);
	const n2 = loadLE(nonce, 8);
	for (let p = 0; p < 8; p++) {
		const zero = hashKey && p == 0;
		st[p * 4] = laneWord(zero ? 0 : n0, n0, st[0]);
		st[p * 4 + 1] = laneWord(zero ? 0 : n1, n1, st[0]);
		st[p * 4 + 2] = laneWord(zero ? 0 : n2, n2, st[0]);
		st[p * 4 + 3] = laneWord(zero ? 0 : swapBytes(first + (p as uint32)), swapBytes(first + ((p + 8) as uint32)), st[0]);
	}
	packState(st);
	encryptState(keys, st);
	storeBlocks(st, bytes);
}

// The next key stream into `batch.bytes[0, batch.end)`, from `batch.counter`: a narrow pass when `needed` bytes fit
// in eight blocks, a wide one otherwise.
function refill(keys: Readonly<Word[]>, batch: Batch, nonce: Readonly<uint8[]>, needed: int32, hashKey: boolean): void {
	if (needed <= 128) {
		counterBlocks(keys, batch.narrow, batch.bytes, nonce, batch.counter, hashKey);
		batch.end = 128;
		batch.counter += 8;
	} else {
		counterBlocks(keys, batch.wide, batch.bytes, nonce, batch.counter, hashKey);
		batch.end = NBLOCKS * 16;
		batch.counter += NBLOCKS as uint32;
	}
}

// E(0) and E(J1) into batch.bytes[0, 32), and the key stream from counter 2 after them, sized for `length` bytes.
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
	const sealed = new Array<uint8>(12 + size + 16);
	for (let i = 0; i < 12; i++) sealed[i] = nonce[i];
	gcmEncryptInto(xk, nonce, aad, plain, 0, size, sealed, 12, sealed, 12 + size);
	return sealed;
}

/** The plain text of a `nonce || cipher text || tag` blob, or null when it is shorter than 28 bytes or the tag does not verify. */
export function gcmOpen(xk: Readonly<Word[]>, sealed: Readonly<uint8[]>, aad: Readonly<uint8[]>): uint8[] | null {
	if (sealed.length < 28) return null;
	const size = sealed.length - 28;
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
	const out = new Array<uint8>(size + padding);
	const batch = new Batch();
	const block = new Array<uint8>(16);
	for (let i = 0; i < 16; i++) block[i] = iv[i];
	for (let at = 0; at < out.length; at += 16) {
		for (let i = 0; i < 16; i++) block[i] ^= at + i < size ? plain[at + i] : (padding as uint8);
		loadBlocks(batch.narrow, block, 0, 1);
		encryptState(xk, batch.narrow);
		storeBlocks(batch.narrow, batch.bytes);
		for (let i = 0; i < 16; i++) {
			block[i] = batch.bytes[i];
			out[at + i] = block[i];
		}
	}
	wipe(batch);
	return out;
}

/** The plain text of an AES-CBC cipher text, or null for an empty or ragged input or bad padding; `xk` is from `expandKeyDecrypt`. */
export function cbcDecrypt(xk: Readonly<Word[]>, iv: Readonly<uint8[]>, cipher: Readonly<uint8[]>): uint8[] | null {
	requireIv(iv);
	const size = cipher.length;
	if (size == 0 || size % 16 != 0) return null;
	const out = new Array<uint8>(size);
	const batch = new Batch();
	for (let at = 0; at < size; at += NBLOCKS * 16) {
		const count = Math.min(NBLOCKS, (size - at) / 16);
		if (count <= 8) {
			loadBlocks(batch.narrow, cipher, at, count);
			decryptState(xk, batch.narrow);
			storeBlocks(batch.narrow, batch.bytes);
		} else {
			loadBlocks(batch.wide, cipher, at, count);
			decryptState(xk, batch.wide);
			storeBlocks(batch.wide, batch.bytes);
		}
		for (let i = 0; i < count * 16; i++) out[at + i] = batch.bytes[i] ^ (at + i < 16 ? iv[i] : cipher[at + i - 16]);
	}
	wipe(batch);
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
