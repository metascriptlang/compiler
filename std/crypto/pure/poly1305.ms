import { wipeBytes, wipeWords } from "./secret";
import { load32LE } from "./endian";
/**
 * The running state of one Poly1305 MAC: 32-bit limbs with 64-bit products,
 * fixed storage so no call allocates.
 */
export class Poly1305State {
	r: uint32[4];
	pad: uint32[4];
	h: uint32[5];
	block: uint8[];
	filled: int32;
}

export function newPoly1305(
	key: Readonly<uint8[]>,
	keyOff: int32,
): Poly1305State {
	return {
		r: [
			load32LE(key, keyOff) & 0x0fffffff,
			load32LE(key, keyOff + 4) & 0x0ffffffc,
			load32LE(key, keyOff + 8) & 0x0ffffffc,
			load32LE(key, keyOff + 12) & 0x0ffffffc,
		],
		pad: [
			load32LE(key, keyOff + 16),
			load32LE(key, keyOff + 20),
			load32LE(key, keyOff + 24),
			load32LE(key, keyOff + 28),
		],
		h: [0, 0, 0, 0, 0],
		block: new Array<uint8>(16),
		filled: 0,
	};
}

/**
 * Absorbs `blocks` 16-byte blocks of `data` from `off`; `hibit` is 1 for a full
 * block and 0 for the padded last one.
 */
function absorb(
	s: Poly1305State,
	data: Readonly<uint8[]>,
	off: int32,
	blocks: int32,
	hibit: uint32,
): void {
	const r0 = s.r[0] as uint64;
	const r1 = s.r[1] as uint64;
	const r2 = s.r[2] as uint64;
	const r3 = s.r[3] as uint64;
	const rr0 = ((s.r[0] >> 2) * 5) as uint64;
	const rr1 = ((s.r[1] >> 2) + s.r[1]) as uint64;
	const rr2 = ((s.r[2] >> 2) + s.r[2]) as uint64;
	const rr3 = ((s.r[3] >> 2) + s.r[3]) as uint64;
	const rr4 = s.r[0] & 3;
	let h0 = s.h[0];
	let h1 = s.h[1];
	let h2 = s.h[2];
	let h3 = s.h[3];
	let h4 = s.h[4];
	let at = off;
	for (let b = 0; b < blocks; b++) {
		const s0 = (h0 as uint64) + (load32LE(data, at) as uint64);
		const s1 = (h1 as uint64) + (load32LE(data, at + 4) as uint64);
		const s2 = (h2 as uint64) + (load32LE(data, at + 8) as uint64);
		const s3 = (h3 as uint64) + (load32LE(data, at + 12) as uint64);
		const s4 = h4 + hibit;
		at += 16;

		const x0 = s0 * r0 + s1 * rr3 + s2 * rr2 + s3 * rr1 + (s4 as uint64) * rr0;
		const x1 = s0 * r1 + s1 * r0 + s2 * rr3 + s3 * rr2 + (s4 as uint64) * rr1;
		const x2 = s0 * r2 + s1 * r1 + s2 * r0 + s3 * rr3 + (s4 as uint64) * rr2;
		const x3 = s0 * r3 + s1 * r2 + s2 * r1 + s3 * r0 + (s4 as uint64) * rr3;
		const x4 = s4 * rr4;

		const u5 = x4 + ((x3 >> 32) as uint32);
		const u0 = (((u5 >> 2) * 5) as uint64) + (x0 & 0xffffffff);
		const u1 = (u0 >> 32) + (x1 & 0xffffffff) + (x0 >> 32);
		const u2 = (u1 >> 32) + (x2 & 0xffffffff) + (x1 >> 32);
		const u3 = (u2 >> 32) + (x3 & 0xffffffff) + (x2 >> 32);
		const u4 = ((u3 >> 32) as uint32) + (u5 & 3);

		h0 = (u0 & 0xffffffff) as uint32;
		h1 = (u1 & 0xffffffff) as uint32;
		h2 = (u2 & 0xffffffff) as uint32;
		h3 = (u3 & 0xffffffff) as uint32;
		h4 = u4;
	}
	s.h[0] = h0;
	s.h[1] = h1;
	s.h[2] = h2;
	s.h[3] = h3;
	s.h[4] = h4;
}

export function updatePoly1305(
	s: Poly1305State,
	data: Readonly<uint8[]>,
	off: int32,
	length: int32,
): void {
	let at = off;
	const end = off + length;
	if (s.filled > 0) {
		while (at < end && s.filled < 16) {
			s.block[s.filled] = data[at];
			s.filled += 1;
			at += 1;
		}
		if (s.filled < 16) return;
		absorb(s, s.block, 0, 1, 1);
		s.filled = 0;
	}
	const blocks = (end - at) >> 4;
	absorb(s, data, at, blocks, 1);
	at += blocks << 4;
	while (at < end) {
		s.block[s.filled] = data[at];
		s.filled += 1;
		at += 1;
	}
}

/**
 * Zero-fills the buffered partial block to 16 bytes and absorbs it, as AEAD
 * padding does.
 */
export function padPoly1305(s: Poly1305State): void {
	if (s.filled == 0) return;
	for (let i = s.filled; i < 16; i++) s.block[i] = 0;
	absorb(s, s.block, 0, 1, 1);
	s.filled = 0;
}

/** Writes the 16-byte tag to `out` at `outOff` and wipes the state. */
export function finishPoly1305(
	s: Poly1305State,
	out: uint8[],
	outOff: int32,
): void {
	if (s.filled > 0) {
		s.block[s.filled] = 1;
		for (let i = s.filled + 1; i < 16; i++) s.block[i] = 0;
		absorb(s, s.block, 0, 1, 0);
	}
	let c: uint64 = 5;
	for (let i = 0; i < 4; i++) {
		c += s.h[i] as uint64;
		c = c >> 32;
	}
	c += s.h[4] as uint64;
	c = (c >> 2) * 5;
	for (let i = 0; i < 4; i++) {
		c += (s.h[i] as uint64) + (s.pad[i] as uint64);
		const word = (c & 0xffffffff) as uint32;
		out[outOff + 4 * i] = (word & 255) as uint8;
		out[outOff + 4 * i + 1] = ((word >> 8) & 255) as uint8;
		out[outOff + 4 * i + 2] = ((word >> 16) & 255) as uint8;
		out[outOff + 4 * i + 3] = (word >> 24) as uint8;
		c = c >> 32;
	}
	wipeWords(s.r);
	wipeWords(s.pad);
	wipeWords(s.h);
	wipeBytes(s.block);
	s.filled = 0;
}
