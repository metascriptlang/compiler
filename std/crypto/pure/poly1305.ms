/** The running state of one Poly1305 MAC (13-bit limbs), with fixed typed storage so no call allocates. */
export class Poly1305State {
	r: uint32[10];
	h: uint32[10];
	g: uint32[10];
	pad: uint32[8];
	block: uint8[];
	filled: int32;
}

function load16(data: Readonly<uint8[]>, at: int32): uint32 {
	return (data[at] as uint32) | ((data[at + 1] as uint32) << 8);
}

export function newPoly1305(key: Readonly<uint8[]>, keyOff: int32): Poly1305State {
	const t0 = load16(key, keyOff);
	const t1 = load16(key, keyOff + 2);
	const t2 = load16(key, keyOff + 4);
	const t3 = load16(key, keyOff + 6);
	const t4 = load16(key, keyOff + 8);
	const t5 = load16(key, keyOff + 10);
	const t6 = load16(key, keyOff + 12);
	const t7 = load16(key, keyOff + 14);
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
		h: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
		g: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
		pad: [0, 0, 0, 0, 0, 0, 0, 0],
		block: new Array<uint8>(16),
		filled: 0,
	};
	for (let i = 0; i < 8; i++) s.pad[i] = load16(key, keyOff + 16 + 2 * i);
	return s;
}

function process(s: Poly1305State, data: Readonly<uint8[]>, off: int32, hibit: uint32): void {
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
	const t0 = load16(data, off);
	const t1 = load16(data, off + 2);
	const t2 = load16(data, off + 4);
	const t3 = load16(data, off + 6);
	const t4 = load16(data, off + 8);
	const t5 = load16(data, off + 10);
	const t6 = load16(data, off + 12);
	const t7 = load16(data, off + 14);

	const h0 = s.h[0] + (t0 & 0x1fff);
	const h1 = s.h[1] + (((t0 >> 13) | (t1 << 3)) & 0x1fff);
	const h2 = s.h[2] + (((t1 >> 10) | (t2 << 6)) & 0x1fff);
	const h3 = s.h[3] + (((t2 >> 7) | (t3 << 9)) & 0x1fff);
	const h4 = s.h[4] + (((t3 >> 4) | (t4 << 12)) & 0x1fff);
	const h5 = s.h[5] + ((t4 >> 1) & 0x1fff);
	const h6 = s.h[6] + (((t4 >> 14) | (t5 << 2)) & 0x1fff);
	const h7 = s.h[7] + (((t5 >> 11) | (t6 << 5)) & 0x1fff);
	const h8 = s.h[8] + (((t6 >> 8) | (t7 << 8)) & 0x1fff);
	const h9 = s.h[9] + ((t7 >> 5) | hibit);

	let c: uint32 = 0;

	let d0 = c + h0 * r0 + h1 * (5 * r9) + h2 * (5 * r8) + h3 * (5 * r7) + h4 * (5 * r6);
	c = d0 >> 13;
	d0 = d0 & 0x1fff;
	d0 = d0 + h5 * (5 * r5) + h6 * (5 * r4) + h7 * (5 * r3) + h8 * (5 * r2) + h9 * (5 * r1);
	c = c + (d0 >> 13);
	d0 = d0 & 0x1fff;

	let d1 = c + h0 * r1 + h1 * r0 + h2 * (5 * r9) + h3 * (5 * r8) + h4 * (5 * r7);
	c = d1 >> 13;
	d1 = d1 & 0x1fff;
	d1 = d1 + h5 * (5 * r6) + h6 * (5 * r5) + h7 * (5 * r4) + h8 * (5 * r3) + h9 * (5 * r2);
	c = c + (d1 >> 13);
	d1 = d1 & 0x1fff;

	let d2 = c + h0 * r2 + h1 * r1 + h2 * r0 + h3 * (5 * r9) + h4 * (5 * r8);
	c = d2 >> 13;
	d2 = d2 & 0x1fff;
	d2 = d2 + h5 * (5 * r7) + h6 * (5 * r6) + h7 * (5 * r5) + h8 * (5 * r4) + h9 * (5 * r3);
	c = c + (d2 >> 13);
	d2 = d2 & 0x1fff;

	let d3 = c + h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * (5 * r9);
	c = d3 >> 13;
	d3 = d3 & 0x1fff;
	d3 = d3 + h5 * (5 * r8) + h6 * (5 * r7) + h7 * (5 * r6) + h8 * (5 * r5) + h9 * (5 * r4);
	c = c + (d3 >> 13);
	d3 = d3 & 0x1fff;

	let d4 = c + h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0;
	c = d4 >> 13;
	d4 = d4 & 0x1fff;
	d4 = d4 + h5 * (5 * r9) + h6 * (5 * r8) + h7 * (5 * r7) + h8 * (5 * r6) + h9 * (5 * r5);
	c = c + (d4 >> 13);
	d4 = d4 & 0x1fff;

	let d5 = c + h0 * r5 + h1 * r4 + h2 * r3 + h3 * r2 + h4 * r1;
	c = d5 >> 13;
	d5 = d5 & 0x1fff;
	d5 = d5 + h5 * r0 + h6 * (5 * r9) + h7 * (5 * r8) + h8 * (5 * r7) + h9 * (5 * r6);
	c = c + (d5 >> 13);
	d5 = d5 & 0x1fff;

	let d6 = c + h0 * r6 + h1 * r5 + h2 * r4 + h3 * r3 + h4 * r2;
	c = d6 >> 13;
	d6 = d6 & 0x1fff;
	d6 = d6 + h5 * r1 + h6 * r0 + h7 * (5 * r9) + h8 * (5 * r8) + h9 * (5 * r7);
	c = c + (d6 >> 13);
	d6 = d6 & 0x1fff;

	let d7 = c + h0 * r7 + h1 * r6 + h2 * r5 + h3 * r4 + h4 * r3;
	c = d7 >> 13;
	d7 = d7 & 0x1fff;
	d7 = d7 + h5 * r2 + h6 * r1 + h7 * r0 + h8 * (5 * r9) + h9 * (5 * r8);
	c = c + (d7 >> 13);
	d7 = d7 & 0x1fff;

	let d8 = c + h0 * r8 + h1 * r7 + h2 * r6 + h3 * r5 + h4 * r4;
	c = d8 >> 13;
	d8 = d8 & 0x1fff;
	d8 = d8 + h5 * r3 + h6 * r2 + h7 * r1 + h8 * r0 + h9 * (5 * r9);
	c = c + (d8 >> 13);
	d8 = d8 & 0x1fff;

	let d9 = c + h0 * r9 + h1 * r8 + h2 * r7 + h3 * r6 + h4 * r5;
	c = d9 >> 13;
	d9 = d9 & 0x1fff;
	d9 = d9 + h5 * r4 + h6 * r3 + h7 * r2 + h8 * r1 + h9 * r0;
	c = c + (d9 >> 13);
	d9 = d9 & 0x1fff;

	c = (c << 2) + c;
	c = c + d0;
	d0 = c & 0x1fff;
	c = c >> 13;
	d1 = d1 + c;

	s.h[0] = d0;
	s.h[1] = d1;
	s.h[2] = d2;
	s.h[3] = d3;
	s.h[4] = d4;
	s.h[5] = d5;
	s.h[6] = d6;
	s.h[7] = d7;
	s.h[8] = d8;
	s.h[9] = d9;
}

export function updatePoly1305(s: Poly1305State, data: Readonly<uint8[]>, off: int32, length: int32): void {
	let at = off;
	const end = off + length;
	if (s.filled > 0) {
		while (at < end && s.filled < 16) {
			s.block[s.filled] = data[at];
			s.filled += 1;
			at += 1;
		}
		if (s.filled < 16) return;
		process(s, s.block, 0, 1 << 11);
		s.filled = 0;
	}
	while (at + 16 <= end) {
		process(s, data, at, 1 << 11);
		at += 16;
	}
	while (at < end) {
		s.block[s.filled] = data[at];
		s.filled += 1;
		at += 1;
	}
}

/** Zero-fills the buffered partial block to 16 bytes and processes it, as AEAD padding does. */
export function padPoly1305(s: Poly1305State): void {
	if (s.filled == 0) return;
	while (s.filled < 16) {
		s.block[s.filled] = 0;
		s.filled += 1;
	}
	process(s, s.block, 0, 1 << 11);
	s.filled = 0;
}

/** Writes the 16-byte tag to `out` at `outOff`. */
export function finishPoly1305(s: Poly1305State, out: uint8[], outOff: int32): void {
	if (s.filled > 0) {
		s.block[s.filled] = 1;
		s.filled += 1;
		while (s.filled < 16) {
			s.block[s.filled] = 0;
			s.filled += 1;
		}
		process(s, s.block, 0, 0);
	}
	let c: uint32 = s.h[1] >> 13;
	s.h[1] = s.h[1] & 0x1fff;
	for (let i = 2; i < 10; i++) {
		s.h[i] = s.h[i] + c;
		c = s.h[i] >> 13;
		s.h[i] = s.h[i] & 0x1fff;
	}
	s.h[0] = s.h[0] + c * 5;
	c = s.h[0] >> 13;
	s.h[0] = s.h[0] & 0x1fff;
	s.h[1] = s.h[1] + c;
	c = s.h[1] >> 13;
	s.h[1] = s.h[1] & 0x1fff;
	s.h[2] = s.h[2] + c;

	s.g[0] = s.h[0] + 5;
	c = s.g[0] >> 13;
	s.g[0] = s.g[0] & 0x1fff;
	for (let i = 1; i < 10; i++) {
		s.g[i] = s.h[i] + c;
		c = s.g[i] >> 13;
		s.g[i] = s.g[i] & 0x1fff;
	}
	s.g[9] = s.g[9] - (1 << 13);

	let mask: uint32 = (c ^ 1) - 1;
	for (let i = 0; i < 10; i++) s.g[i] = s.g[i] & mask;
	mask = ~mask;
	for (let i = 0; i < 10; i++) s.h[i] = (s.h[i] & mask) | s.g[i];
	s.h[0] = (s.h[0] | (s.h[1] << 13)) & 0xffff;
	s.h[1] = ((s.h[1] >> 3) | (s.h[2] << 10)) & 0xffff;
	s.h[2] = ((s.h[2] >> 6) | (s.h[3] << 7)) & 0xffff;
	s.h[3] = ((s.h[3] >> 9) | (s.h[4] << 4)) & 0xffff;
	s.h[4] = ((s.h[4] >> 12) | (s.h[5] << 1) | (s.h[6] << 14)) & 0xffff;
	s.h[5] = ((s.h[6] >> 2) | (s.h[7] << 11)) & 0xffff;
	s.h[6] = ((s.h[7] >> 5) | (s.h[8] << 8)) & 0xffff;
	s.h[7] = ((s.h[8] >> 8) | (s.h[9] << 5)) & 0xffff;

	let f: uint32 = s.h[0] + s.pad[0];
	s.h[0] = f & 0xffff;
	for (let i = 1; i < 8; i++) {
		f = s.h[i] + s.pad[i] + (f >> 16);
		s.h[i] = f & 0xffff;
	}
	for (let i = 0; i < 8; i++) {
		out[outOff + 2 * i] = (s.h[i] & 255) as uint8;
		out[outOff + 2 * i + 1] = (s.h[i] >> 8) as uint8;
	}
}
