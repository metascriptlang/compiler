import { HashState, HashBytes } from "./state";

export function initMd5(state: Span<uint32>): void {
	state[0] = 0x67452301;
	state[1] = 0xefcdab89;
	state[2] = 0x98badcfe;
	state[3] = 0x10325476;
}

function rotl(v: uint32, c: uint32): uint32 {
	return (v << c) | (v >> (32 - c));
}

when (!js) {
	export function compressMd5Words(state: Span<uint32>, data: HashBytes, off: int32): void {
		const w0: uint32 = (data[off + 0] as uint32) | ((data[off + 1] as uint32) << 8) | ((data[off + 2] as uint32) << 16) | ((data[off + 3] as uint32) << 24);
		const w1: uint32 = (data[off + 4] as uint32) | ((data[off + 5] as uint32) << 8) | ((data[off + 6] as uint32) << 16) | ((data[off + 7] as uint32) << 24);
		const w2: uint32 = (data[off + 8] as uint32) | ((data[off + 9] as uint32) << 8) | ((data[off + 10] as uint32) << 16) | ((data[off + 11] as uint32) << 24);
		const w3: uint32 = (data[off + 12] as uint32) | ((data[off + 13] as uint32) << 8) | ((data[off + 14] as uint32) << 16) | ((data[off + 15] as uint32) << 24);
		const w4: uint32 = (data[off + 16] as uint32) | ((data[off + 17] as uint32) << 8) | ((data[off + 18] as uint32) << 16) | ((data[off + 19] as uint32) << 24);
		const w5: uint32 = (data[off + 20] as uint32) | ((data[off + 21] as uint32) << 8) | ((data[off + 22] as uint32) << 16) | ((data[off + 23] as uint32) << 24);
		const w6: uint32 = (data[off + 24] as uint32) | ((data[off + 25] as uint32) << 8) | ((data[off + 26] as uint32) << 16) | ((data[off + 27] as uint32) << 24);
		const w7: uint32 = (data[off + 28] as uint32) | ((data[off + 29] as uint32) << 8) | ((data[off + 30] as uint32) << 16) | ((data[off + 31] as uint32) << 24);
		const w8: uint32 = (data[off + 32] as uint32) | ((data[off + 33] as uint32) << 8) | ((data[off + 34] as uint32) << 16) | ((data[off + 35] as uint32) << 24);
		const w9: uint32 = (data[off + 36] as uint32) | ((data[off + 37] as uint32) << 8) | ((data[off + 38] as uint32) << 16) | ((data[off + 39] as uint32) << 24);
		const w10: uint32 = (data[off + 40] as uint32) | ((data[off + 41] as uint32) << 8) | ((data[off + 42] as uint32) << 16) | ((data[off + 43] as uint32) << 24);
		const w11: uint32 = (data[off + 44] as uint32) | ((data[off + 45] as uint32) << 8) | ((data[off + 46] as uint32) << 16) | ((data[off + 47] as uint32) << 24);
		const w12: uint32 = (data[off + 48] as uint32) | ((data[off + 49] as uint32) << 8) | ((data[off + 50] as uint32) << 16) | ((data[off + 51] as uint32) << 24);
		const w13: uint32 = (data[off + 52] as uint32) | ((data[off + 53] as uint32) << 8) | ((data[off + 54] as uint32) << 16) | ((data[off + 55] as uint32) << 24);
		const w14: uint32 = (data[off + 56] as uint32) | ((data[off + 57] as uint32) << 8) | ((data[off + 58] as uint32) << 16) | ((data[off + 59] as uint32) << 24);
		const w15: uint32 = (data[off + 60] as uint32) | ((data[off + 61] as uint32) << 8) | ((data[off + 62] as uint32) << 16) | ((data[off + 63] as uint32) << 24);
		let v0 = state[0];
		let v1 = state[1];
		let v2 = state[2];
		let v3 = state[3];
		v0 = v1 + rotl(v0 + ((v1 & v2) | (~v1 & v3)) + 0xd76aa478 + w0, 7);
		v3 = v0 + rotl(v3 + ((v0 & v1) | (~v0 & v2)) + 0xe8c7b756 + w1, 12);
		v2 = v3 + rotl(v2 + ((v3 & v0) | (~v3 & v1)) + 0x242070db + w2, 17);
		v1 = v2 + rotl(v1 + ((v2 & v3) | (~v2 & v0)) + 0xc1bdceee + w3, 22);
		v0 = v1 + rotl(v0 + ((v1 & v2) | (~v1 & v3)) + 0xf57c0faf + w4, 7);
		v3 = v0 + rotl(v3 + ((v0 & v1) | (~v0 & v2)) + 0x4787c62a + w5, 12);
		v2 = v3 + rotl(v2 + ((v3 & v0) | (~v3 & v1)) + 0xa8304613 + w6, 17);
		v1 = v2 + rotl(v1 + ((v2 & v3) | (~v2 & v0)) + 0xfd469501 + w7, 22);
		v0 = v1 + rotl(v0 + ((v1 & v2) | (~v1 & v3)) + 0x698098d8 + w8, 7);
		v3 = v0 + rotl(v3 + ((v0 & v1) | (~v0 & v2)) + 0x8b44f7af + w9, 12);
		v2 = v3 + rotl(v2 + ((v3 & v0) | (~v3 & v1)) + 0xffff5bb1 + w10, 17);
		v1 = v2 + rotl(v1 + ((v2 & v3) | (~v2 & v0)) + 0x895cd7be + w11, 22);
		v0 = v1 + rotl(v0 + ((v1 & v2) | (~v1 & v3)) + 0x6b901122 + w12, 7);
		v3 = v0 + rotl(v3 + ((v0 & v1) | (~v0 & v2)) + 0xfd987193 + w13, 12);
		v2 = v3 + rotl(v2 + ((v3 & v0) | (~v3 & v1)) + 0xa679438e + w14, 17);
		v1 = v2 + rotl(v1 + ((v2 & v3) | (~v2 & v0)) + 0x49b40821 + w15, 22);
		v0 = v1 + rotl(v0 + ((v3 & v1) | (~v3 & v2)) + 0xf61e2562 + w1, 5);
		v3 = v0 + rotl(v3 + ((v2 & v0) | (~v2 & v1)) + 0xc040b340 + w6, 9);
		v2 = v3 + rotl(v2 + ((v1 & v3) | (~v1 & v0)) + 0x265e5a51 + w11, 14);
		v1 = v2 + rotl(v1 + ((v0 & v2) | (~v0 & v3)) + 0xe9b6c7aa + w0, 20);
		v0 = v1 + rotl(v0 + ((v3 & v1) | (~v3 & v2)) + 0xd62f105d + w5, 5);
		v3 = v0 + rotl(v3 + ((v2 & v0) | (~v2 & v1)) + 0x02441453 + w10, 9);
		v2 = v3 + rotl(v2 + ((v1 & v3) | (~v1 & v0)) + 0xd8a1e681 + w15, 14);
		v1 = v2 + rotl(v1 + ((v0 & v2) | (~v0 & v3)) + 0xe7d3fbc8 + w4, 20);
		v0 = v1 + rotl(v0 + ((v3 & v1) | (~v3 & v2)) + 0x21e1cde6 + w9, 5);
		v3 = v0 + rotl(v3 + ((v2 & v0) | (~v2 & v1)) + 0xc33707d6 + w14, 9);
		v2 = v3 + rotl(v2 + ((v1 & v3) | (~v1 & v0)) + 0xf4d50d87 + w3, 14);
		v1 = v2 + rotl(v1 + ((v0 & v2) | (~v0 & v3)) + 0x455a14ed + w8, 20);
		v0 = v1 + rotl(v0 + ((v3 & v1) | (~v3 & v2)) + 0xa9e3e905 + w13, 5);
		v3 = v0 + rotl(v3 + ((v2 & v0) | (~v2 & v1)) + 0xfcefa3f8 + w2, 9);
		v2 = v3 + rotl(v2 + ((v1 & v3) | (~v1 & v0)) + 0x676f02d9 + w7, 14);
		v1 = v2 + rotl(v1 + ((v0 & v2) | (~v0 & v3)) + 0x8d2a4c8a + w12, 20);
		v0 = v1 + rotl(v0 + (v1 ^ v2 ^ v3) + 0xfffa3942 + w5, 4);
		v3 = v0 + rotl(v3 + (v0 ^ v1 ^ v2) + 0x8771f681 + w8, 11);
		v2 = v3 + rotl(v2 + (v3 ^ v0 ^ v1) + 0x6d9d6122 + w11, 16);
		v1 = v2 + rotl(v1 + (v2 ^ v3 ^ v0) + 0xfde5380c + w14, 23);
		v0 = v1 + rotl(v0 + (v1 ^ v2 ^ v3) + 0xa4beea44 + w1, 4);
		v3 = v0 + rotl(v3 + (v0 ^ v1 ^ v2) + 0x4bdecfa9 + w4, 11);
		v2 = v3 + rotl(v2 + (v3 ^ v0 ^ v1) + 0xf6bb4b60 + w7, 16);
		v1 = v2 + rotl(v1 + (v2 ^ v3 ^ v0) + 0xbebfbc70 + w10, 23);
		v0 = v1 + rotl(v0 + (v1 ^ v2 ^ v3) + 0x289b7ec6 + w13, 4);
		v3 = v0 + rotl(v3 + (v0 ^ v1 ^ v2) + 0xeaa127fa + w0, 11);
		v2 = v3 + rotl(v2 + (v3 ^ v0 ^ v1) + 0xd4ef3085 + w3, 16);
		v1 = v2 + rotl(v1 + (v2 ^ v3 ^ v0) + 0x04881d05 + w6, 23);
		v0 = v1 + rotl(v0 + (v1 ^ v2 ^ v3) + 0xd9d4d039 + w9, 4);
		v3 = v0 + rotl(v3 + (v0 ^ v1 ^ v2) + 0xe6db99e5 + w12, 11);
		v2 = v3 + rotl(v2 + (v3 ^ v0 ^ v1) + 0x1fa27cf8 + w15, 16);
		v1 = v2 + rotl(v1 + (v2 ^ v3 ^ v0) + 0xc4ac5665 + w2, 23);
		v0 = v1 + rotl(v0 + (v2 ^ (v1 | ~v3)) + 0xf4292244 + w0, 6);
		v3 = v0 + rotl(v3 + (v1 ^ (v0 | ~v2)) + 0x432aff97 + w7, 10);
		v2 = v3 + rotl(v2 + (v0 ^ (v3 | ~v1)) + 0xab9423a7 + w14, 15);
		v1 = v2 + rotl(v1 + (v3 ^ (v2 | ~v0)) + 0xfc93a039 + w5, 21);
		v0 = v1 + rotl(v0 + (v2 ^ (v1 | ~v3)) + 0x655b59c3 + w12, 6);
		v3 = v0 + rotl(v3 + (v1 ^ (v0 | ~v2)) + 0x8f0ccc92 + w3, 10);
		v2 = v3 + rotl(v2 + (v0 ^ (v3 | ~v1)) + 0xffeff47d + w10, 15);
		v1 = v2 + rotl(v1 + (v3 ^ (v2 | ~v0)) + 0x85845dd1 + w1, 21);
		v0 = v1 + rotl(v0 + (v2 ^ (v1 | ~v3)) + 0x6fa87e4f + w8, 6);
		v3 = v0 + rotl(v3 + (v1 ^ (v0 | ~v2)) + 0xfe2ce6e0 + w15, 10);
		v2 = v3 + rotl(v2 + (v0 ^ (v3 | ~v1)) + 0xa3014314 + w6, 15);
		v1 = v2 + rotl(v1 + (v3 ^ (v2 | ~v0)) + 0x4e0811a1 + w13, 21);
		v0 = v1 + rotl(v0 + (v2 ^ (v1 | ~v3)) + 0xf7537e82 + w4, 6);
		v3 = v0 + rotl(v3 + (v1 ^ (v0 | ~v2)) + 0xbd3af235 + w11, 10);
		v2 = v3 + rotl(v2 + (v0 ^ (v3 | ~v1)) + 0x2ad7d2bb + w2, 15);
		v1 = v2 + rotl(v1 + (v3 ^ (v2 | ~v0)) + 0xeb86d391 + w9, 21);
		state[0] = state[0] + v0;
		state[1] = state[1] + v1;
		state[2] = state[2] + v2;
		state[3] = state[3] + v3;
	}
}

when (js) {
	const k: uint32[64] = [
		0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a,
		0xa8304613, 0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
		0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340,
		0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
		0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8,
		0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
		0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
		0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
		0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92,
		0xffeff47d, 0x85845dd1, 0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
		0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
	];

	const shifts: uint32[64] = [
		7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
		5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
		4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
		6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
	];

	function compressMd5Block(h: HashState, data: HashBytes, off: int32): void {
		for (let i = 0; i < 16; i++) {
			const at = off + i * 4;
			h.schedule[i] = (data[at] as uint32) | ((data[at + 1] as uint32) << 8) | ((data[at + 2] as uint32) << 16) | ((data[at + 3] as uint32) << 24);
		}
		let a = h.state[0];
		let b = h.state[1];
		let c = h.state[2];
		let d = h.state[3];
		for (let i = 0; i < 16; i++) {
			const next = b + rotl(a + ((b & c) | (~b & d)) + k[i] + h.schedule[i], shifts[i]);
			a = d;
			d = c;
			c = b;
			b = next;
		}
		for (let i = 16; i < 32; i++) {
			const next = b + rotl(a + ((d & b) | (~d & c)) + k[i] + h.schedule[(5 * i + 1) & 15], shifts[i]);
			a = d;
			d = c;
			c = b;
			b = next;
		}
		for (let i = 32; i < 48; i++) {
			const next = b + rotl(a + (b ^ c ^ d) + k[i] + h.schedule[(3 * i + 5) & 15], shifts[i]);
			a = d;
			d = c;
			c = b;
			b = next;
		}
		for (let i = 48; i < 64; i++) {
			const next = b + rotl(a + (c ^ (b | ~d)) + k[i] + h.schedule[(7 * i) & 15], shifts[i]);
			a = d;
			d = c;
			c = b;
			b = next;
		}
		h.state[0] = h.state[0] + a;
		h.state[1] = h.state[1] + b;
		h.state[2] = h.state[2] + c;
		h.state[3] = h.state[3] + d;
	}
}

export function compressMd5(h: HashState, data: HashBytes, off: int32): void {
	when (!js) {
		compressMd5Words(h.state, data, off);
	} else {
		compressMd5Block(h, data, off);
	}
}
