import { HashState } from "./state";

export function initSha1(h: HashState): void {
	h.state[0] = 0x67452301;
	h.state[1] = 0xefcdab89;
	h.state[2] = 0x98badcfe;
	h.state[3] = 0x10325476;
	h.state[4] = 0xc3d2e1f0;
}

function rotl(v: uint32, c: uint32): uint32 {
	return (v << c) | (v >> (32 - c));
}

export function compressSha1(h: HashState, data: Readonly<uint8[]>, off: int32): void {
	for (let i = 0; i < 16; i++) {
		const at = off + i * 4;
		h.schedule[i] = ((data[at] as uint32) << 24) | ((data[at + 1] as uint32) << 16) | ((data[at + 2] as uint32) << 8) | (data[at + 3] as uint32);
	}
	for (let i = 16; i < 80; i++) {
		h.schedule[i] = rotl(h.schedule[i - 3] ^ h.schedule[i - 8] ^ h.schedule[i - 14] ^ h.schedule[i - 16], 1);
	}
	let a = h.state[0];
	let b = h.state[1];
	let c = h.state[2];
	let d = h.state[3];
	let e = h.state[4];
	for (let i = 0; i < 20; i++) {
		const next = rotl(a, 5) + ((b & c) ^ (~b & d)) + e + 0x5a827999 + h.schedule[i];
		e = d;
		d = c;
		c = rotl(b, 30);
		b = a;
		a = next;
	}
	for (let i = 20; i < 40; i++) {
		const next = rotl(a, 5) + (b ^ c ^ d) + e + 0x6ed9eba1 + h.schedule[i];
		e = d;
		d = c;
		c = rotl(b, 30);
		b = a;
		a = next;
	}
	for (let i = 40; i < 60; i++) {
		const next = rotl(a, 5) + ((b & c) ^ (b & d) ^ (c & d)) + e + 0x8f1bbcdc + h.schedule[i];
		e = d;
		d = c;
		c = rotl(b, 30);
		b = a;
		a = next;
	}
	for (let i = 60; i < 80; i++) {
		const next = rotl(a, 5) + (b ^ c ^ d) + e + 0xca62c1d6 + h.schedule[i];
		e = d;
		d = c;
		c = rotl(b, 30);
		b = a;
		a = next;
	}
	h.state[0] = h.state[0] + a;
	h.state[1] = h.state[1] + b;
	h.state[2] = h.state[2] + c;
	h.state[3] = h.state[3] + d;
	h.state[4] = h.state[4] + e;
}
