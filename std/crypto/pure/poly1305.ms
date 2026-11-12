import { InputBytes } from "./bytes";
import { wipeBytes, wipeWords } from "./secret";
when (!js) {
	import { load32LE } from "./endian";
}
when (js) {
	// Derived from @noble/ciphers 2.4.0 `_poly1305.ts`, MIT, Paul Miller (https://paulmillr.com). Licence: std/crypto/pure/LICENSE.poly1305
	// Ten 13-bit limbs, so every product and sum stays below 2^32 in uint32 arithmetic.
	export class Poly1305State {
		r: uint32[10];
		pad: uint32[8];
		h: uint32[10];
		block: uint8[];
		filled: int32;
	}

	function load16LE(data: InputBytes, at: int32): uint32 {
		return (data[at] as uint32) | ((data[at + 1] as uint32) << 8);
	}
} else {
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
}

export function newPoly1305(
	key: InputBytes,
	keyOff: int32,
): Poly1305State {
	when (js) {
		const t0 = load16LE(key, keyOff);
		const t1 = load16LE(key, keyOff + 2);
		const t2 = load16LE(key, keyOff + 4);
		const t3 = load16LE(key, keyOff + 6);
		const t4 = load16LE(key, keyOff + 8);
		const t5 = load16LE(key, keyOff + 10);
		const t6 = load16LE(key, keyOff + 12);
		const t7 = load16LE(key, keyOff + 14);
		const s: Poly1305State = {
			r: [
				t0 & 0x1fff,
				((t0 >> 13) | (t1 << 3)) & 0x1fff,
				((t1 >> 10) | (t2 << 6)) & 0x1f03,
				((t2 >> 7) | (t3 << 9)) & 0x1fff,
				((t3 >> 4) | (t4 << 12)) & 0x00ff,
				(t4 >> 1) & 0x1ffe,
				((t4 >> 14) | (t5 << 2)) & 0x1fff,
				((t5 >> 11) | (t6 << 5)) & 0x1f81,
				((t6 >> 8) | (t7 << 8)) & 0x1fff,
				(t7 >> 5) & 0x007f,
			],
			pad: [0, 0, 0, 0, 0, 0, 0, 0],
			h: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
			block: new Array<uint8>(16),
			filled: 0,
		};
		for (let i = 0; i < 8; i++) s.pad[i] = load16LE(key, keyOff + 16 + 2 * i);
		return s;
	} else {
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
}

/**
 * Absorbs `blocks` 16-byte blocks of `data` from `off`; `hibit` is 1 for a full
 * block and 0 for the padded last one.
 */
function absorb(
	s: Poly1305State,
	data: InputBytes,
	off: int32,
	blocks: int32,
	hibit: uint32,
): void {
	when (js) {
		const r0 = s.r[0];
		const r1 = s.r[1];
		const r2 = s.r[2];
		const r3 = s.r[3];
		const r4 = s.r[4];
		const r5 = s.r[5];
		const r6 = s.r[6];
		const r7 = s.r[7];
		const r8 = s.r[8];
		const r9 = s.r[9];
		const r15 = 5 * r1;
		const r25 = 5 * r2;
		const r35 = 5 * r3;
		const r45 = 5 * r4;
		const r55 = 5 * r5;
		const r65 = 5 * r6;
		const r75 = 5 * r7;
		const r85 = 5 * r8;
		const r95 = 5 * r9;
		const high = hibit << 11;
		let h0 = s.h[0];
		let h1 = s.h[1];
		let h2 = s.h[2];
		let h3 = s.h[3];
		let h4 = s.h[4];
		let h5 = s.h[5];
		let h6 = s.h[6];
		let h7 = s.h[7];
		let h8 = s.h[8];
		let h9 = s.h[9];
		let at = off;
		for (let b = 0; b < blocks; b++) {
			const t0 = load16LE(data, at);
			const t1 = load16LE(data, at + 2);
			const t2 = load16LE(data, at + 4);
			const t3 = load16LE(data, at + 6);
			const t4 = load16LE(data, at + 8);
			const t5 = load16LE(data, at + 10);
			const t6 = load16LE(data, at + 12);
			const t7 = load16LE(data, at + 14);
			at += 16;
			h0 += t0 & 0x1fff;
			h1 += ((t0 >> 13) | (t1 << 3)) & 0x1fff;
			h2 += ((t1 >> 10) | (t2 << 6)) & 0x1fff;
			h3 += ((t2 >> 7) | (t3 << 9)) & 0x1fff;
			h4 += ((t3 >> 4) | (t4 << 12)) & 0x1fff;
			h5 += (t4 >> 1) & 0x1fff;
			h6 += ((t4 >> 14) | (t5 << 2)) & 0x1fff;
			h7 += ((t5 >> 11) | (t6 << 5)) & 0x1fff;
			h8 += ((t6 >> 8) | (t7 << 8)) & 0x1fff;
			h9 += (t7 >> 5) | high;

			let d0 = h0 * r0 + h1 * r95 + h2 * r85 + h3 * r75 + h4 * r65;
			let c = d0 >> 13;
			d0 &= 0x1fff;
			d0 += h5 * r55 + h6 * r45 + h7 * r35 + h8 * r25 + h9 * r15;
			c += d0 >> 13;
			d0 &= 0x1fff;

			let d1 = c + h0 * r1 + h1 * r0 + h2 * r95 + h3 * r85 + h4 * r75;
			c = d1 >> 13;
			d1 &= 0x1fff;
			d1 += h5 * r65 + h6 * r55 + h7 * r45 + h8 * r35 + h9 * r25;
			c += d1 >> 13;
			d1 &= 0x1fff;

			let d2 = c + h0 * r2 + h1 * r1 + h2 * r0 + h3 * r95 + h4 * r85;
			c = d2 >> 13;
			d2 &= 0x1fff;
			d2 += h5 * r75 + h6 * r65 + h7 * r55 + h8 * r45 + h9 * r35;
			c += d2 >> 13;
			d2 &= 0x1fff;

			let d3 = c + h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * r95;
			c = d3 >> 13;
			d3 &= 0x1fff;
			d3 += h5 * r85 + h6 * r75 + h7 * r65 + h8 * r55 + h9 * r45;
			c += d3 >> 13;
			d3 &= 0x1fff;

			let d4 = c + h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0;
			c = d4 >> 13;
			d4 &= 0x1fff;
			d4 += h5 * r95 + h6 * r85 + h7 * r75 + h8 * r65 + h9 * r55;
			c += d4 >> 13;
			d4 &= 0x1fff;

			let d5 = c + h0 * r5 + h1 * r4 + h2 * r3 + h3 * r2 + h4 * r1;
			c = d5 >> 13;
			d5 &= 0x1fff;
			d5 += h5 * r0 + h6 * r95 + h7 * r85 + h8 * r75 + h9 * r65;
			c += d5 >> 13;
			d5 &= 0x1fff;

			let d6 = c + h0 * r6 + h1 * r5 + h2 * r4 + h3 * r3 + h4 * r2;
			c = d6 >> 13;
			d6 &= 0x1fff;
			d6 += h5 * r1 + h6 * r0 + h7 * r95 + h8 * r85 + h9 * r75;
			c += d6 >> 13;
			d6 &= 0x1fff;

			let d7 = c + h0 * r7 + h1 * r6 + h2 * r5 + h3 * r4 + h4 * r3;
			c = d7 >> 13;
			d7 &= 0x1fff;
			d7 += h5 * r2 + h6 * r1 + h7 * r0 + h8 * r95 + h9 * r85;
			c += d7 >> 13;
			d7 &= 0x1fff;

			let d8 = c + h0 * r8 + h1 * r7 + h2 * r6 + h3 * r5 + h4 * r4;
			c = d8 >> 13;
			d8 &= 0x1fff;
			d8 += h5 * r3 + h6 * r2 + h7 * r1 + h8 * r0 + h9 * r95;
			c += d8 >> 13;
			d8 &= 0x1fff;

			let d9 = c + h0 * r9 + h1 * r8 + h2 * r7 + h3 * r6 + h4 * r5;
			c = d9 >> 13;
			d9 &= 0x1fff;
			d9 += h5 * r4 + h6 * r3 + h7 * r2 + h8 * r1 + h9 * r0;
			c += d9 >> 13;
			d9 &= 0x1fff;

			c = (c << 2) + c + d0;
			h0 = c & 0x1fff;
			h1 = d1 + (c >> 13);
			h2 = d2;
			h3 = d3;
			h4 = d4;
			h5 = d5;
			h6 = d6;
			h7 = d7;
			h8 = d8;
			h9 = d9;
		}
		s.h[0] = h0;
		s.h[1] = h1;
		s.h[2] = h2;
		s.h[3] = h3;
		s.h[4] = h4;
		s.h[5] = h5;
		s.h[6] = h6;
		s.h[7] = h7;
		s.h[8] = h8;
		s.h[9] = h9;
	} else {
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
}

/** Writes the 16-byte tag to `out` at `outOff` and wipes the state. */
export function finishPoly1305(
	s: Poly1305State,
	out: uint8[],
	outOff: int32,
): void {
	when (js) {
		if (s.filled > 0) {
			s.block[s.filled] = 1;
			for (let i = s.filled + 1; i < 16; i++) s.block[i] = 0;
			absorb(s, s.block, 0, 1, 0);
		}
		let c = s.h[1] >> 13;
		s.h[1] &= 0x1fff;
		for (let i = 2; i < 10; i++) {
			s.h[i] += c;
			c = s.h[i] >> 13;
			s.h[i] &= 0x1fff;
		}
		s.h[0] += c * 5;
		c = s.h[0] >> 13;
		s.h[0] &= 0x1fff;
		s.h[1] += c;
		c = s.h[1] >> 13;
		s.h[1] &= 0x1fff;
		s.h[2] += c;
		let g: uint32[10] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
		g[0] = s.h[0] + 5;
		c = g[0] >> 13;
		g[0] &= 0x1fff;
		for (let i = 1; i < 10; i++) {
			g[i] = s.h[i] + c;
			c = g[i] >> 13;
			g[i] &= 0x1fff;
		}
		g[9] -= 1 << 13;
		let mask = (c ^ 1) - 1;
		for (let i = 0; i < 10; i++) g[i] &= mask;
		mask = ~mask;
		for (let i = 0; i < 10; i++) s.h[i] = (s.h[i] & mask) | g[i];
		s.h[0] = (s.h[0] | (s.h[1] << 13)) & 0xffff;
		s.h[1] = ((s.h[1] >> 3) | (s.h[2] << 10)) & 0xffff;
		s.h[2] = ((s.h[2] >> 6) | (s.h[3] << 7)) & 0xffff;
		s.h[3] = ((s.h[3] >> 9) | (s.h[4] << 4)) & 0xffff;
		s.h[4] = ((s.h[4] >> 12) | (s.h[5] << 1) | (s.h[6] << 14)) & 0xffff;
		s.h[5] = ((s.h[6] >> 2) | (s.h[7] << 11)) & 0xffff;
		s.h[6] = ((s.h[7] >> 5) | (s.h[8] << 8)) & 0xffff;
		s.h[7] = ((s.h[8] >> 8) | (s.h[9] << 5)) & 0xffff;
		let f = s.h[0] + s.pad[0];
		for (let i = 0; i < 8; i++) {
			if (i > 0) f = s.h[i] + s.pad[i] + (f >> 16);
			out[outOff + 2 * i] = (f & 255) as uint8;
			out[outOff + 2 * i + 1] = ((f >> 8) & 255) as uint8;
		}
		wipeWords(g);
		wipeWords(s.r);
		wipeWords(s.pad);
		wipeWords(s.h);
		wipeBytes(s.block);
		s.filled = 0;
	} else {
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
}

export function updatePoly1305(
	s: Poly1305State,
	data: InputBytes,
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
