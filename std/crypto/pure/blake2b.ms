// 64-bit words are (low, high) uint32 pairs, as in sha2: JS has no cheap 64-bit integer.
const iv: uint32[16] = [
	0xf3bcc908, 0x6a09e667, 0x84caa73b, 0xbb67ae85, 0xfe94f82b, 0x3c6ef372, 0x5f1d36f1, 0xa54ff53a,
	0xade682d1, 0x510e527f, 0x2b3e6c1f, 0x9b05688c, 0xfb41bd6b, 0x1f83d9ab, 0x137e2179, 0x5be0cd19,
];

// The message word order of rounds 0..9; rounds 10 and 11 reuse rows 0 and 1.
const sigma: uint8[160] = [
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
	14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3,
	11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4,
	7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8,
	9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13,
	2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9,
	12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11,
	13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10,
	6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5,
	10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0,
];

/** The running state of one BLAKE2b hash, with fixed typed storage so no call allocates a table. */
export class Blake2bState {
	h: uint32[16];
	v: uint32[32];
	m: uint32[32];
	m64: uint64[16];
	block: uint8[];
	outputSize: int32;
	filled: int32;
	length: number;
	finished: boolean;
}

/** A hash of `outputSize` bytes (1..64), keyed when `key` is not empty (1..64 bytes); the caller checks both. */
export function newBlake2b(outputSize: int32, key: Readonly<uint8[]>): Blake2bState {
	const s: Blake2bState = {
		h: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
		m: [
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		],
		v: [
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		],
		m64: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
		block: new Array<uint8>(128),
		outputSize,
		filled: 0,
		length: 0,
		finished: false,
	};
	for (let i = 0; i < 16; i++) s.h[i] = iv[i];
	s.h[0] = s.h[0] ^ ((outputSize | ((key.length as int32) << 8) | (1 << 16) | (1 << 24)) as uint32);
	if (key.length > 0) {
		for (let i = 0; i < 128; i++) s.block[i] = i < key.length ? key[i] : 0;
		s.filled = 128;
		s.length = 128;
	}
	return s;
}

function load32(data: Readonly<uint8[]>, at: int32): uint32 {
	return (data[at] as uint32) | ((data[at + 1] as uint32) << 8) | ((data[at + 2] as uint32) << 16) | ((data[at + 3] as uint32) << 24);
}

when (c) {
	function compress(s: Blake2bState, data: Readonly<uint8[]>, off: int32, isLast: boolean): void {
		for (let i = 0; i < 16; i++) s.m64[i] = (load32(data, off + i * 8) as uint64) | ((load32(data, off + i * 8 + 4) as uint64) << 32);
		let v0 = (s.h[0] as uint64) | ((s.h[1] as uint64) << 32);
		let v1 = (s.h[2] as uint64) | ((s.h[3] as uint64) << 32);
		let v2 = (s.h[4] as uint64) | ((s.h[5] as uint64) << 32);
		let v3 = (s.h[6] as uint64) | ((s.h[7] as uint64) << 32);
		let v4 = (s.h[8] as uint64) | ((s.h[9] as uint64) << 32);
		let v5 = (s.h[10] as uint64) | ((s.h[11] as uint64) << 32);
		let v6 = (s.h[12] as uint64) | ((s.h[13] as uint64) << 32);
		let v7 = (s.h[14] as uint64) | ((s.h[15] as uint64) << 32);
		let v8 = (iv[0] as uint64) | ((iv[1] as uint64) << 32);
		let v9 = (iv[2] as uint64) | ((iv[3] as uint64) << 32);
		let v10 = (iv[4] as uint64) | ((iv[5] as uint64) << 32);
		let v11 = (iv[6] as uint64) | ((iv[7] as uint64) << 32);
		let v12 = (iv[8] as uint64) | ((iv[9] as uint64) << 32);
		let v13 = (iv[10] as uint64) | ((iv[11] as uint64) << 32);
		let v14 = (iv[12] as uint64) | ((iv[13] as uint64) << 32);
		let v15 = (iv[14] as uint64) | ((iv[15] as uint64) << 32);
		v12 = v12 ^ (s.length as uint64);
		if (isLast) v14 = ~v14;
		for (let r = 0; r < 12; r++) {
			const row = (r % 10) * 16;
			v0 = v0 + v4 + s.m64[sigma[row + 0]];
			v12 = v12 ^ v0;
			v12 = ((v12 >> 32) | (v12 << 32));
			v8 = v8 + v12;
			v4 = v4 ^ v8;
			v4 = ((v4 >> 24) | (v4 << 40));
			v0 = v0 + v4 + s.m64[sigma[row + 1]];
			v12 = v12 ^ v0;
			v12 = ((v12 >> 16) | (v12 << 48));
			v8 = v8 + v12;
			v4 = v4 ^ v8;
			v4 = ((v4 >> 63) | (v4 << 1));
			v1 = v1 + v5 + s.m64[sigma[row + 2]];
			v13 = v13 ^ v1;
			v13 = ((v13 >> 32) | (v13 << 32));
			v9 = v9 + v13;
			v5 = v5 ^ v9;
			v5 = ((v5 >> 24) | (v5 << 40));
			v1 = v1 + v5 + s.m64[sigma[row + 3]];
			v13 = v13 ^ v1;
			v13 = ((v13 >> 16) | (v13 << 48));
			v9 = v9 + v13;
			v5 = v5 ^ v9;
			v5 = ((v5 >> 63) | (v5 << 1));
			v2 = v2 + v6 + s.m64[sigma[row + 4]];
			v14 = v14 ^ v2;
			v14 = ((v14 >> 32) | (v14 << 32));
			v10 = v10 + v14;
			v6 = v6 ^ v10;
			v6 = ((v6 >> 24) | (v6 << 40));
			v2 = v2 + v6 + s.m64[sigma[row + 5]];
			v14 = v14 ^ v2;
			v14 = ((v14 >> 16) | (v14 << 48));
			v10 = v10 + v14;
			v6 = v6 ^ v10;
			v6 = ((v6 >> 63) | (v6 << 1));
			v3 = v3 + v7 + s.m64[sigma[row + 6]];
			v15 = v15 ^ v3;
			v15 = ((v15 >> 32) | (v15 << 32));
			v11 = v11 + v15;
			v7 = v7 ^ v11;
			v7 = ((v7 >> 24) | (v7 << 40));
			v3 = v3 + v7 + s.m64[sigma[row + 7]];
			v15 = v15 ^ v3;
			v15 = ((v15 >> 16) | (v15 << 48));
			v11 = v11 + v15;
			v7 = v7 ^ v11;
			v7 = ((v7 >> 63) | (v7 << 1));
			v0 = v0 + v5 + s.m64[sigma[row + 8]];
			v15 = v15 ^ v0;
			v15 = ((v15 >> 32) | (v15 << 32));
			v10 = v10 + v15;
			v5 = v5 ^ v10;
			v5 = ((v5 >> 24) | (v5 << 40));
			v0 = v0 + v5 + s.m64[sigma[row + 9]];
			v15 = v15 ^ v0;
			v15 = ((v15 >> 16) | (v15 << 48));
			v10 = v10 + v15;
			v5 = v5 ^ v10;
			v5 = ((v5 >> 63) | (v5 << 1));
			v1 = v1 + v6 + s.m64[sigma[row + 10]];
			v12 = v12 ^ v1;
			v12 = ((v12 >> 32) | (v12 << 32));
			v11 = v11 + v12;
			v6 = v6 ^ v11;
			v6 = ((v6 >> 24) | (v6 << 40));
			v1 = v1 + v6 + s.m64[sigma[row + 11]];
			v12 = v12 ^ v1;
			v12 = ((v12 >> 16) | (v12 << 48));
			v11 = v11 + v12;
			v6 = v6 ^ v11;
			v6 = ((v6 >> 63) | (v6 << 1));
			v2 = v2 + v7 + s.m64[sigma[row + 12]];
			v13 = v13 ^ v2;
			v13 = ((v13 >> 32) | (v13 << 32));
			v8 = v8 + v13;
			v7 = v7 ^ v8;
			v7 = ((v7 >> 24) | (v7 << 40));
			v2 = v2 + v7 + s.m64[sigma[row + 13]];
			v13 = v13 ^ v2;
			v13 = ((v13 >> 16) | (v13 << 48));
			v8 = v8 + v13;
			v7 = v7 ^ v8;
			v7 = ((v7 >> 63) | (v7 << 1));
			v3 = v3 + v4 + s.m64[sigma[row + 14]];
			v14 = v14 ^ v3;
			v14 = ((v14 >> 32) | (v14 << 32));
			v9 = v9 + v14;
			v4 = v4 ^ v9;
			v4 = ((v4 >> 24) | (v4 << 40));
			v3 = v3 + v4 + s.m64[sigma[row + 15]];
			v14 = v14 ^ v3;
			v14 = ((v14 >> 16) | (v14 << 48));
			v9 = v9 + v14;
			v4 = v4 ^ v9;
			v4 = ((v4 >> 63) | (v4 << 1));
		}
		const w0 = v0 ^ v8;
		s.h[0] = s.h[0] ^ ((w0 & 0xffffffff) as uint32);
		s.h[1] = s.h[1] ^ ((w0 >> 32) as uint32);
		const w1 = v1 ^ v9;
		s.h[2] = s.h[2] ^ ((w1 & 0xffffffff) as uint32);
		s.h[3] = s.h[3] ^ ((w1 >> 32) as uint32);
		const w2 = v2 ^ v10;
		s.h[4] = s.h[4] ^ ((w2 & 0xffffffff) as uint32);
		s.h[5] = s.h[5] ^ ((w2 >> 32) as uint32);
		const w3 = v3 ^ v11;
		s.h[6] = s.h[6] ^ ((w3 & 0xffffffff) as uint32);
		s.h[7] = s.h[7] ^ ((w3 >> 32) as uint32);
		const w4 = v4 ^ v12;
		s.h[8] = s.h[8] ^ ((w4 & 0xffffffff) as uint32);
		s.h[9] = s.h[9] ^ ((w4 >> 32) as uint32);
		const w5 = v5 ^ v13;
		s.h[10] = s.h[10] ^ ((w5 & 0xffffffff) as uint32);
		s.h[11] = s.h[11] ^ ((w5 >> 32) as uint32);
		const w6 = v6 ^ v14;
		s.h[12] = s.h[12] ^ ((w6 & 0xffffffff) as uint32);
		s.h[13] = s.h[13] ^ ((w6 >> 32) as uint32);
		const w7 = v7 ^ v15;
		s.h[14] = s.h[14] ^ ((w7 & 0xffffffff) as uint32);
		s.h[15] = s.h[15] ^ ((w7 >> 32) as uint32);
	}
}
when (!c) {
	function carry(sum: uint32, addend: uint32): uint32 {
		return sum < addend ? 1 : 0;
	}

	/** One quarter-round (both halves) on the working vector, with message words `x` and `y` read from `m`. */
	function mix(s: Blake2bState, a: int32, b: int32, c: int32, d: int32, x: int32, y: int32): void {
		let al = s.v[2 * a];
		let ah = s.v[2 * a + 1];
		let bl = s.v[2 * b];
		let bh = s.v[2 * b + 1];
		let cl = s.v[2 * c];
		let ch = s.v[2 * c + 1];
		let dl = s.v[2 * d];
		let dh = s.v[2 * d + 1];

		let sum = al + bl;
		ah = ah + bh + carry(sum, bl);
		al = sum;
		sum = al + s.m[2 * x];
		ah = ah + s.m[2 * x + 1] + carry(sum, s.m[2 * x]);
		al = sum;
		let xh = dh ^ ah;
		let xl = dl ^ al;
		dh = xl;
		dl = xh;
		sum = cl + dl;
		ch = ch + dh + carry(sum, dl);
		cl = sum;
		xh = bh ^ ch;
		xl = bl ^ cl;
		bh = (xh >> 24) | (xl << 8);
		bl = (xl >> 24) | (xh << 8);

		sum = al + bl;
		ah = ah + bh + carry(sum, bl);
		al = sum;
		sum = al + s.m[2 * y];
		ah = ah + s.m[2 * y + 1] + carry(sum, s.m[2 * y]);
		al = sum;
		xh = dh ^ ah;
		xl = dl ^ al;
		dh = (xh >> 16) | (xl << 16);
		dl = (xl >> 16) | (xh << 16);
		sum = cl + dl;
		ch = ch + dh + carry(sum, dl);
		cl = sum;
		xh = bh ^ ch;
		xl = bl ^ cl;
		bh = (xh << 1) | (xl >> 31);
		bl = (xl << 1) | (xh >> 31);

		s.v[2 * a] = al;
		s.v[2 * a + 1] = ah;
		s.v[2 * b] = bl;
		s.v[2 * b + 1] = bh;
		s.v[2 * c] = cl;
		s.v[2 * c + 1] = ch;
		s.v[2 * d] = dl;
		s.v[2 * d + 1] = dh;
	}

	function compress(s: Blake2bState, data: Readonly<uint8[]>, off: int32, isLast: boolean): void {
		for (let i = 0; i < 32; i++) s.m[i] = load32(data, off + i * 4);
		for (let i = 0; i < 16; i++) {
			s.v[i] = s.h[i];
			s.v[16 + i] = iv[i];
		}
		const high = Math.floor(s.length / 4294967296) as uint32;
		const low = (s.length - Math.floor(s.length / 4294967296) * 4294967296) as uint32;
		s.v[24] = s.v[24] ^ low;
		s.v[25] = s.v[25] ^ high;
		if (isLast) {
			s.v[28] = ~s.v[28];
			s.v[29] = ~s.v[29];
		}
		for (let r = 0; r < 12; r++) {
			const row = (r % 10) * 16;
			mix(s, 0, 4, 8, 12, sigma[row], sigma[row + 1]);
			mix(s, 1, 5, 9, 13, sigma[row + 2], sigma[row + 3]);
			mix(s, 2, 6, 10, 14, sigma[row + 4], sigma[row + 5]);
			mix(s, 3, 7, 11, 15, sigma[row + 6], sigma[row + 7]);
			mix(s, 0, 5, 10, 15, sigma[row + 8], sigma[row + 9]);
			mix(s, 1, 6, 11, 12, sigma[row + 10], sigma[row + 11]);
			mix(s, 2, 7, 8, 13, sigma[row + 12], sigma[row + 13]);
			mix(s, 3, 4, 9, 14, sigma[row + 14], sigma[row + 15]);
		}
		for (let i = 0; i < 16; i++) s.h[i] = s.h[i] ^ s.v[i] ^ s.v[16 + i];
	}
}

export function updateBlake2b(s: Blake2bState, data: Readonly<uint8[]>, off: int32, length: int32): void {
	if (s.finished) throw new Error("hash already finished");
	let at = off;
	const end = off + length;
	while (at < end) {
		if (s.filled == 128) {
			compress(s, s.block, 0, false);
			s.filled = 0;
		}
		if (s.filled == 0) {
			while (end - at > 128) {
				s.length += 128;
				compress(s, data, at, false);
				at += 128;
			}
		}
		const room = 128 - s.filled;
		const take = end - at < room ? end - at : room;
		for (let i = 0; i < take; i++) s.block[s.filled + i] = data[at + i];
		s.filled += take;
		s.length += take;
		at += take;
	}
}

/** Pads, compresses the last block and writes the digest to `out` at `outOff`; the state is finished afterwards. */
export function finishBlake2bInto(s: Blake2bState, out: uint8[], outOff: int32): void {
	if (s.finished) throw new Error("hash already finished");
	for (let i = s.filled; i < 128; i++) s.block[i] = 0;
	compress(s, s.block, 0, true);
	s.finished = true;
	for (let i = 0; i < s.outputSize; i++) out[outOff + i] = ((s.h[i >> 2] >> (((i & 3) * 8) as uint32)) & 255) as uint8;
}

export function finishBlake2b(s: Blake2bState): uint8[] {
	const out = new Array<uint8>(s.outputSize);
	finishBlake2bInto(s, out, 0);
	return out;
}

export function blake2bOf(outputSize: int32, key: Readonly<uint8[]>, data: Readonly<uint8[]>): uint8[] {
	const s = newBlake2b(outputSize, key);
	updateBlake2b(s, data, 0, data.length as int32);
	return finishBlake2b(s);
}
