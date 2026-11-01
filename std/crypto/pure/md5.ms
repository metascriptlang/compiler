import { HashState } from "./state";

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

export function initMd5(h: HashState): void {
	h.state[0] = 0x67452301;
	h.state[1] = 0xefcdab89;
	h.state[2] = 0x98badcfe;
	h.state[3] = 0x10325476;
}

function rotl(v: uint32, c: uint32): uint32 {
	return (v << c) | (v >> (32 - c));
}

export function compressMd5(h: HashState, data: Readonly<uint8[]>, off: int32): void {
	for (let i = 0; i < 16; i++) {
		const at = off + i * 4;
		h.schedule[i] = (data[at] as uint32) | ((data[at + 1] as uint32) << 8) | ((data[at + 2] as uint32) << 16) | ((data[at + 3] as uint32) << 24);
	}
	let a = h.state[0];
	let b = h.state[1];
	let c = h.state[2];
	let d = h.state[3];
	for (let i = 0; i < 64; i++) {
		let mix: uint32 = 0;
		let word = i;
		if (i < 16) {
			mix = (b & c) | (~b & d);
		} else if (i < 32) {
			mix = (d & b) | (~d & c);
			word = (5 * i + 1) & 15;
		} else if (i < 48) {
			mix = b ^ c ^ d;
			word = (3 * i + 5) & 15;
		} else {
			mix = c ^ (b | ~d);
			word = (7 * i) & 15;
		}
		const next = b + rotl(a + mix + k[i] + h.schedule[word], shifts[i]);
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
