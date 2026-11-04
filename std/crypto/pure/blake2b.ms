import { wipeBytes, wipeWords64 } from "./secret";
import { load32LE } from "./endian";
const iv: uint64[8] = [
	0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
	0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
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
	h: uint64[8];
	m: uint64[16];
	block: uint8[];
	outputSize: int32;
	filled: int32;
	length: number;
	finished: boolean;
}

/** A hash of `outputSize` bytes (1..64), keyed when `key` is not empty (1..64 bytes); the caller checks both. */
export function newBlake2b(outputSize: int32, key: Readonly<uint8[]>): Blake2bState {
	const s: Blake2bState = {
		h: [0, 0, 0, 0, 0, 0, 0, 0],
		m: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
		block: new Array<uint8>(128),
		outputSize,
		filled: 0,
		length: 0,
		finished: false,
	};
	for (let i = 0; i < 8; i++) s.h[i] = iv[i];
	s.h[0] = s.h[0] ^ ((outputSize | ((key.length as int32) << 8) | (1 << 16) | (1 << 24)) as uint64);
	if (key.length > 0) {
		for (let i = 0; i < 128; i++) s.block[i] = i < key.length ? key[i] : 0;
		s.filled = 128;
		s.length = 128;
	}
	return s;
}

function compress(s: Blake2bState, data: Readonly<uint8[]>, off: int32, isLast: boolean): void {
	for (let i = 0; i < 16; i++) s.m[i] = (load32LE(data, off + i * 8) as uint64) | ((load32LE(data, off + i * 8 + 4) as uint64) << 32);
	let v0 = s.h[0];
	let v1 = s.h[1];
	let v2 = s.h[2];
	let v3 = s.h[3];
	let v4 = s.h[4];
	let v5 = s.h[5];
	let v6 = s.h[6];
	let v7 = s.h[7];
	let v8 = iv[0];
	let v9 = iv[1];
	let v10 = iv[2];
	let v11 = iv[3];
	let v12 = iv[4];
	let v13 = iv[5];
	let v14 = iv[6];
	let v15 = iv[7];
	v12 = v12 ^ (s.length as uint64);
	if (isLast) v14 = ~v14;
	for (let r = 0; r < 12; r++) {
		const row = (r % 10) * 16;
		v0 = v0 + v4 + s.m[sigma[row + 0]];
		v12 = v12 ^ v0;
		v12 = ((v12 >> 32) | (v12 << 32));
		v8 = v8 + v12;
		v4 = v4 ^ v8;
		v4 = ((v4 >> 24) | (v4 << 40));
		v0 = v0 + v4 + s.m[sigma[row + 1]];
		v12 = v12 ^ v0;
		v12 = ((v12 >> 16) | (v12 << 48));
		v8 = v8 + v12;
		v4 = v4 ^ v8;
		v4 = ((v4 >> 63) | (v4 << 1));
		v1 = v1 + v5 + s.m[sigma[row + 2]];
		v13 = v13 ^ v1;
		v13 = ((v13 >> 32) | (v13 << 32));
		v9 = v9 + v13;
		v5 = v5 ^ v9;
		v5 = ((v5 >> 24) | (v5 << 40));
		v1 = v1 + v5 + s.m[sigma[row + 3]];
		v13 = v13 ^ v1;
		v13 = ((v13 >> 16) | (v13 << 48));
		v9 = v9 + v13;
		v5 = v5 ^ v9;
		v5 = ((v5 >> 63) | (v5 << 1));
		v2 = v2 + v6 + s.m[sigma[row + 4]];
		v14 = v14 ^ v2;
		v14 = ((v14 >> 32) | (v14 << 32));
		v10 = v10 + v14;
		v6 = v6 ^ v10;
		v6 = ((v6 >> 24) | (v6 << 40));
		v2 = v2 + v6 + s.m[sigma[row + 5]];
		v14 = v14 ^ v2;
		v14 = ((v14 >> 16) | (v14 << 48));
		v10 = v10 + v14;
		v6 = v6 ^ v10;
		v6 = ((v6 >> 63) | (v6 << 1));
		v3 = v3 + v7 + s.m[sigma[row + 6]];
		v15 = v15 ^ v3;
		v15 = ((v15 >> 32) | (v15 << 32));
		v11 = v11 + v15;
		v7 = v7 ^ v11;
		v7 = ((v7 >> 24) | (v7 << 40));
		v3 = v3 + v7 + s.m[sigma[row + 7]];
		v15 = v15 ^ v3;
		v15 = ((v15 >> 16) | (v15 << 48));
		v11 = v11 + v15;
		v7 = v7 ^ v11;
		v7 = ((v7 >> 63) | (v7 << 1));
		v0 = v0 + v5 + s.m[sigma[row + 8]];
		v15 = v15 ^ v0;
		v15 = ((v15 >> 32) | (v15 << 32));
		v10 = v10 + v15;
		v5 = v5 ^ v10;
		v5 = ((v5 >> 24) | (v5 << 40));
		v0 = v0 + v5 + s.m[sigma[row + 9]];
		v15 = v15 ^ v0;
		v15 = ((v15 >> 16) | (v15 << 48));
		v10 = v10 + v15;
		v5 = v5 ^ v10;
		v5 = ((v5 >> 63) | (v5 << 1));
		v1 = v1 + v6 + s.m[sigma[row + 10]];
		v12 = v12 ^ v1;
		v12 = ((v12 >> 32) | (v12 << 32));
		v11 = v11 + v12;
		v6 = v6 ^ v11;
		v6 = ((v6 >> 24) | (v6 << 40));
		v1 = v1 + v6 + s.m[sigma[row + 11]];
		v12 = v12 ^ v1;
		v12 = ((v12 >> 16) | (v12 << 48));
		v11 = v11 + v12;
		v6 = v6 ^ v11;
		v6 = ((v6 >> 63) | (v6 << 1));
		v2 = v2 + v7 + s.m[sigma[row + 12]];
		v13 = v13 ^ v2;
		v13 = ((v13 >> 32) | (v13 << 32));
		v8 = v8 + v13;
		v7 = v7 ^ v8;
		v7 = ((v7 >> 24) | (v7 << 40));
		v2 = v2 + v7 + s.m[sigma[row + 13]];
		v13 = v13 ^ v2;
		v13 = ((v13 >> 16) | (v13 << 48));
		v8 = v8 + v13;
		v7 = v7 ^ v8;
		v7 = ((v7 >> 63) | (v7 << 1));
		v3 = v3 + v4 + s.m[sigma[row + 14]];
		v14 = v14 ^ v3;
		v14 = ((v14 >> 32) | (v14 << 32));
		v9 = v9 + v14;
		v4 = v4 ^ v9;
		v4 = ((v4 >> 24) | (v4 << 40));
		v3 = v3 + v4 + s.m[sigma[row + 15]];
		v14 = v14 ^ v3;
		v14 = ((v14 >> 16) | (v14 << 48));
		v9 = v9 + v14;
		v4 = v4 ^ v9;
		v4 = ((v4 >> 63) | (v4 << 1));
	}
	s.h[0] = s.h[0] ^ v0 ^ v8;
	s.h[1] = s.h[1] ^ v1 ^ v9;
	s.h[2] = s.h[2] ^ v2 ^ v10;
	s.h[3] = s.h[3] ^ v3 ^ v11;
	s.h[4] = s.h[4] ^ v4 ^ v12;
	s.h[5] = s.h[5] ^ v5 ^ v13;
	s.h[6] = s.h[6] ^ v6 ^ v14;
	s.h[7] = s.h[7] ^ v7 ^ v15;
}

export function updateBlake2b(s: Blake2bState, data: Readonly<uint8[]>, off: int32, length: int32): void {
	if (s.finished) throw new Error("hash already finished");
	if (off < 0 || length < 0 || off + length > data.length) throw new Error(`updateBlake2b: range ${off}+${length} outside ${data.length} bytes`);
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
	for (let i = 0; i < s.outputSize; i++) out[outOff + i] = ((s.h[i >> 3] >> (((i & 7) * 8) as uint64)) & 255) as uint8;
	wipeBytes(s.block);
	wipeWords64(s.m);
	wipeWords64(s.h);
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
