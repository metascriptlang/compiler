import { HashState, HashBytes, kindSha256, kindSha224, kindSha512 } from "./state";

const k256: uint32[64] = [
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const k512: uint32[160] = [
	0x428a2f98, 0xd728ae22, 0x71374491, 0x23ef65cd, 0xb5c0fbcf, 0xec4d3b2f,
	0xe9b5dba5, 0x8189dbbc, 0x3956c25b, 0xf348b538, 0x59f111f1, 0xb605d019,
	0x923f82a4, 0xaf194f9b, 0xab1c5ed5, 0xda6d8118, 0xd807aa98, 0xa3030242,
	0x12835b01, 0x45706fbe, 0x243185be, 0x4ee4b28c, 0x550c7dc3, 0xd5ffb4e2,
	0x72be5d74, 0xf27b896f, 0x80deb1fe, 0x3b1696b1, 0x9bdc06a7, 0x25c71235,
	0xc19bf174, 0xcf692694, 0xe49b69c1, 0x9ef14ad2, 0xefbe4786, 0x384f25e3,
	0x0fc19dc6, 0x8b8cd5b5, 0x240ca1cc, 0x77ac9c65, 0x2de92c6f, 0x592b0275,
	0x4a7484aa, 0x6ea6e483, 0x5cb0a9dc, 0xbd41fbd4, 0x76f988da, 0x831153b5,
	0x983e5152, 0xee66dfab, 0xa831c66d, 0x2db43210, 0xb00327c8, 0x98fb213f,
	0xbf597fc7, 0xbeef0ee4, 0xc6e00bf3, 0x3da88fc2, 0xd5a79147, 0x930aa725,
	0x06ca6351, 0xe003826f, 0x14292967, 0x0a0e6e70, 0x27b70a85, 0x46d22ffc,
	0x2e1b2138, 0x5c26c926, 0x4d2c6dfc, 0x5ac42aed, 0x53380d13, 0x9d95b3df,
	0x650a7354, 0x8baf63de, 0x766a0abb, 0x3c77b2a8, 0x81c2c92e, 0x47edaee6,
	0x92722c85, 0x1482353b, 0xa2bfe8a1, 0x4cf10364, 0xa81a664b, 0xbc423001,
	0xc24b8b70, 0xd0f89791, 0xc76c51a3, 0x0654be30, 0xd192e819, 0xd6ef5218,
	0xd6990624, 0x5565a910, 0xf40e3585, 0x5771202a, 0x106aa070, 0x32bbd1b8,
	0x19a4c116, 0xb8d2d0c8, 0x1e376c08, 0x5141ab53, 0x2748774c, 0xdf8eeb99,
	0x34b0bcb5, 0xe19b48a8, 0x391c0cb3, 0xc5c95a63, 0x4ed8aa4a, 0xe3418acb,
	0x5b9cca4f, 0x7763e373, 0x682e6ff3, 0xd6b2b8a3, 0x748f82ee, 0x5defb2fc,
	0x78a5636f, 0x43172f60, 0x84c87814, 0xa1f0ab72, 0x8cc70208, 0x1a6439ec,
	0x90befffa, 0x23631e28, 0xa4506ceb, 0xde82bde9, 0xbef9a3f7, 0xb2c67915,
	0xc67178f2, 0xe372532b, 0xca273ece, 0xea26619c, 0xd186b8c7, 0x21c0c207,
	0xeada7dd6, 0xcde0eb1e, 0xf57d4f7f, 0xee6ed178, 0x06f067aa, 0x72176fba,
	0x0a637dc5, 0xa2c898a6, 0x113f9804, 0xbef90dae, 0x1b710b35, 0x131c471b,
	0x28db77f5, 0x23047d84, 0x32caab7b, 0x40c72493, 0x3c9ebe0a, 0x15c9bebc,
	0x431d67c4, 0x9c100d4c, 0x4cc5d4be, 0xcb3e42b6, 0x597f299c, 0xfc657e2a,
	0x5fcb6fab, 0x3ad6faec, 0x6c44198c, 0x4a475817,
];

const iv224: uint32[8] = [0xc1059ed8, 0x367cd507, 0x3070dd17, 0xf70e5939, 0xffc00b31, 0x68581511, 0x64f98fa7, 0xbefa4fa4];
const iv256: uint32[8] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
const iv384: uint32[16] = [
	0xcbbb9d5d, 0xc1059ed8, 0x629a292a, 0x367cd507, 0x9159015a, 0x3070dd17, 0x152fecd8, 0xf70e5939,
	0x67332667, 0xffc00b31, 0x8eb44a87, 0x68581511, 0xdb0c2e0d, 0x64f98fa7, 0x47b5481d, 0xbefa4fa4,
];
const iv512: uint32[16] = [
	0x6a09e667, 0xf3bcc908, 0xbb67ae85, 0x84caa73b, 0x3c6ef372, 0xfe94f82b, 0xa54ff53a, 0x5f1d36f1,
	0x510e527f, 0xade682d1, 0x9b05688c, 0x2b3e6c1f, 0x1f83d9ab, 0xfb41bd6b, 0x5be0cd19, 0x137e2179,
];

/** The initial chaining words of a SHA-2 kind into `state`: eight for SHA-224/256, sixteen (high word first) for SHA-384/512. */
export function sha2Iv(kind: int32, state: Span<uint32>): void {
	if (kind == kindSha256) {
		for (let i = 0; i < 8; i++) state[i] = iv256[i];
	} else if (kind == kindSha224) {
		for (let i = 0; i < 8; i++) state[i] = iv224[i];
	} else if (kind == kindSha512) {
		for (let i = 0; i < 16; i++) state[i] = iv512[i];
	} else {
		for (let i = 0; i < 16; i++) state[i] = iv384[i];
	}
}

export function initSha2(h: HashState): void {
	if (h.kind == kindSha256) {
		for (let i = 0; i < 8; i++) h.state[i] = iv256[i];
	} else if (h.kind == kindSha224) {
		for (let i = 0; i < 8; i++) h.state[i] = iv224[i];
	} else if (h.kind == kindSha512) {
		for (let i = 0; i < 16; i++) h.state[i] = iv512[i];
	} else {
		for (let i = 0; i < 16; i++) h.state[i] = iv384[i];
	}
}

function rotr(v: uint32, c: uint32): uint32 {
	return (v >> c) | (v << (32 - c));
}

function compress256Unrolled(st: HashState, data: Readonly<uint8[]>, off: int32): void {
	let w0: uint32 = load32BE(data, off + 0);
	let w1: uint32 = load32BE(data, off + 4);
	let w2: uint32 = load32BE(data, off + 8);
	let w3: uint32 = load32BE(data, off + 12);
	let w4: uint32 = load32BE(data, off + 16);
	let w5: uint32 = load32BE(data, off + 20);
	let w6: uint32 = load32BE(data, off + 24);
	let w7: uint32 = load32BE(data, off + 28);
	let w8: uint32 = load32BE(data, off + 32);
	let w9: uint32 = load32BE(data, off + 36);
	let w10: uint32 = load32BE(data, off + 40);
	let w11: uint32 = load32BE(data, off + 44);
	let w12: uint32 = load32BE(data, off + 48);
	let w13: uint32 = load32BE(data, off + 52);
	let w14: uint32 = load32BE(data, off + 56);
	let w15: uint32 = load32BE(data, off + 60);
	let a: uint32 = st.state[0];
	let b: uint32 = st.state[1];
	let c: uint32 = st.state[2];
	let d: uint32 = st.state[3];
	let e: uint32 = st.state[4];
	let f: uint32 = st.state[5];
	let g: uint32 = st.state[6];
	let h: uint32 = st.state[7];
	let t: uint32 = 0;
	t = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k256[0] + w0;
	d = d + t;
	h = t + (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
	t = g + (rotr(d, 6) ^ rotr(d, 11) ^ rotr(d, 25)) + ((d & e) ^ (~d & f)) + k256[1] + w1;
	c = c + t;
	g = t + (rotr(h, 2) ^ rotr(h, 13) ^ rotr(h, 22)) + ((h & a) ^ (h & b) ^ (a & b));
	t = f + (rotr(c, 6) ^ rotr(c, 11) ^ rotr(c, 25)) + ((c & d) ^ (~c & e)) + k256[2] + w2;
	b = b + t;
	f = t + (rotr(g, 2) ^ rotr(g, 13) ^ rotr(g, 22)) + ((g & h) ^ (g & a) ^ (h & a));
	t = e + (rotr(b, 6) ^ rotr(b, 11) ^ rotr(b, 25)) + ((b & c) ^ (~b & d)) + k256[3] + w3;
	a = a + t;
	e = t + (rotr(f, 2) ^ rotr(f, 13) ^ rotr(f, 22)) + ((f & g) ^ (f & h) ^ (g & h));
	t = d + (rotr(a, 6) ^ rotr(a, 11) ^ rotr(a, 25)) + ((a & b) ^ (~a & c)) + k256[4] + w4;
	h = h + t;
	d = t + (rotr(e, 2) ^ rotr(e, 13) ^ rotr(e, 22)) + ((e & f) ^ (e & g) ^ (f & g));
	t = c + (rotr(h, 6) ^ rotr(h, 11) ^ rotr(h, 25)) + ((h & a) ^ (~h & b)) + k256[5] + w5;
	g = g + t;
	c = t + (rotr(d, 2) ^ rotr(d, 13) ^ rotr(d, 22)) + ((d & e) ^ (d & f) ^ (e & f));
	t = b + (rotr(g, 6) ^ rotr(g, 11) ^ rotr(g, 25)) + ((g & h) ^ (~g & a)) + k256[6] + w6;
	f = f + t;
	b = t + (rotr(c, 2) ^ rotr(c, 13) ^ rotr(c, 22)) + ((c & d) ^ (c & e) ^ (d & e));
	t = a + (rotr(f, 6) ^ rotr(f, 11) ^ rotr(f, 25)) + ((f & g) ^ (~f & h)) + k256[7] + w7;
	e = e + t;
	a = t + (rotr(b, 2) ^ rotr(b, 13) ^ rotr(b, 22)) + ((b & c) ^ (b & d) ^ (c & d));
	t = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k256[8] + w8;
	d = d + t;
	h = t + (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
	t = g + (rotr(d, 6) ^ rotr(d, 11) ^ rotr(d, 25)) + ((d & e) ^ (~d & f)) + k256[9] + w9;
	c = c + t;
	g = t + (rotr(h, 2) ^ rotr(h, 13) ^ rotr(h, 22)) + ((h & a) ^ (h & b) ^ (a & b));
	t = f + (rotr(c, 6) ^ rotr(c, 11) ^ rotr(c, 25)) + ((c & d) ^ (~c & e)) + k256[10] + w10;
	b = b + t;
	f = t + (rotr(g, 2) ^ rotr(g, 13) ^ rotr(g, 22)) + ((g & h) ^ (g & a) ^ (h & a));
	t = e + (rotr(b, 6) ^ rotr(b, 11) ^ rotr(b, 25)) + ((b & c) ^ (~b & d)) + k256[11] + w11;
	a = a + t;
	e = t + (rotr(f, 2) ^ rotr(f, 13) ^ rotr(f, 22)) + ((f & g) ^ (f & h) ^ (g & h));
	t = d + (rotr(a, 6) ^ rotr(a, 11) ^ rotr(a, 25)) + ((a & b) ^ (~a & c)) + k256[12] + w12;
	h = h + t;
	d = t + (rotr(e, 2) ^ rotr(e, 13) ^ rotr(e, 22)) + ((e & f) ^ (e & g) ^ (f & g));
	t = c + (rotr(h, 6) ^ rotr(h, 11) ^ rotr(h, 25)) + ((h & a) ^ (~h & b)) + k256[13] + w13;
	g = g + t;
	c = t + (rotr(d, 2) ^ rotr(d, 13) ^ rotr(d, 22)) + ((d & e) ^ (d & f) ^ (e & f));
	t = b + (rotr(g, 6) ^ rotr(g, 11) ^ rotr(g, 25)) + ((g & h) ^ (~g & a)) + k256[14] + w14;
	f = f + t;
	b = t + (rotr(c, 2) ^ rotr(c, 13) ^ rotr(c, 22)) + ((c & d) ^ (c & e) ^ (d & e));
	t = a + (rotr(f, 6) ^ rotr(f, 11) ^ rotr(f, 25)) + ((f & g) ^ (~f & h)) + k256[15] + w15;
	e = e + t;
	a = t + (rotr(b, 2) ^ rotr(b, 13) ^ rotr(b, 22)) + ((b & c) ^ (b & d) ^ (c & d));
	w0 = w0 + (rotr(w14, 17) ^ rotr(w14, 19) ^ (w14 >> 10)) + w9 + (rotr(w1, 7) ^ rotr(w1, 18) ^ (w1 >> 3));
	t = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k256[16] + w0;
	d = d + t;
	h = t + (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
	w1 = w1 + (rotr(w15, 17) ^ rotr(w15, 19) ^ (w15 >> 10)) + w10 + (rotr(w2, 7) ^ rotr(w2, 18) ^ (w2 >> 3));
	t = g + (rotr(d, 6) ^ rotr(d, 11) ^ rotr(d, 25)) + ((d & e) ^ (~d & f)) + k256[17] + w1;
	c = c + t;
	g = t + (rotr(h, 2) ^ rotr(h, 13) ^ rotr(h, 22)) + ((h & a) ^ (h & b) ^ (a & b));
	w2 = w2 + (rotr(w0, 17) ^ rotr(w0, 19) ^ (w0 >> 10)) + w11 + (rotr(w3, 7) ^ rotr(w3, 18) ^ (w3 >> 3));
	t = f + (rotr(c, 6) ^ rotr(c, 11) ^ rotr(c, 25)) + ((c & d) ^ (~c & e)) + k256[18] + w2;
	b = b + t;
	f = t + (rotr(g, 2) ^ rotr(g, 13) ^ rotr(g, 22)) + ((g & h) ^ (g & a) ^ (h & a));
	w3 = w3 + (rotr(w1, 17) ^ rotr(w1, 19) ^ (w1 >> 10)) + w12 + (rotr(w4, 7) ^ rotr(w4, 18) ^ (w4 >> 3));
	t = e + (rotr(b, 6) ^ rotr(b, 11) ^ rotr(b, 25)) + ((b & c) ^ (~b & d)) + k256[19] + w3;
	a = a + t;
	e = t + (rotr(f, 2) ^ rotr(f, 13) ^ rotr(f, 22)) + ((f & g) ^ (f & h) ^ (g & h));
	w4 = w4 + (rotr(w2, 17) ^ rotr(w2, 19) ^ (w2 >> 10)) + w13 + (rotr(w5, 7) ^ rotr(w5, 18) ^ (w5 >> 3));
	t = d + (rotr(a, 6) ^ rotr(a, 11) ^ rotr(a, 25)) + ((a & b) ^ (~a & c)) + k256[20] + w4;
	h = h + t;
	d = t + (rotr(e, 2) ^ rotr(e, 13) ^ rotr(e, 22)) + ((e & f) ^ (e & g) ^ (f & g));
	w5 = w5 + (rotr(w3, 17) ^ rotr(w3, 19) ^ (w3 >> 10)) + w14 + (rotr(w6, 7) ^ rotr(w6, 18) ^ (w6 >> 3));
	t = c + (rotr(h, 6) ^ rotr(h, 11) ^ rotr(h, 25)) + ((h & a) ^ (~h & b)) + k256[21] + w5;
	g = g + t;
	c = t + (rotr(d, 2) ^ rotr(d, 13) ^ rotr(d, 22)) + ((d & e) ^ (d & f) ^ (e & f));
	w6 = w6 + (rotr(w4, 17) ^ rotr(w4, 19) ^ (w4 >> 10)) + w15 + (rotr(w7, 7) ^ rotr(w7, 18) ^ (w7 >> 3));
	t = b + (rotr(g, 6) ^ rotr(g, 11) ^ rotr(g, 25)) + ((g & h) ^ (~g & a)) + k256[22] + w6;
	f = f + t;
	b = t + (rotr(c, 2) ^ rotr(c, 13) ^ rotr(c, 22)) + ((c & d) ^ (c & e) ^ (d & e));
	w7 = w7 + (rotr(w5, 17) ^ rotr(w5, 19) ^ (w5 >> 10)) + w0 + (rotr(w8, 7) ^ rotr(w8, 18) ^ (w8 >> 3));
	t = a + (rotr(f, 6) ^ rotr(f, 11) ^ rotr(f, 25)) + ((f & g) ^ (~f & h)) + k256[23] + w7;
	e = e + t;
	a = t + (rotr(b, 2) ^ rotr(b, 13) ^ rotr(b, 22)) + ((b & c) ^ (b & d) ^ (c & d));
	w8 = w8 + (rotr(w6, 17) ^ rotr(w6, 19) ^ (w6 >> 10)) + w1 + (rotr(w9, 7) ^ rotr(w9, 18) ^ (w9 >> 3));
	t = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k256[24] + w8;
	d = d + t;
	h = t + (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
	w9 = w9 + (rotr(w7, 17) ^ rotr(w7, 19) ^ (w7 >> 10)) + w2 + (rotr(w10, 7) ^ rotr(w10, 18) ^ (w10 >> 3));
	t = g + (rotr(d, 6) ^ rotr(d, 11) ^ rotr(d, 25)) + ((d & e) ^ (~d & f)) + k256[25] + w9;
	c = c + t;
	g = t + (rotr(h, 2) ^ rotr(h, 13) ^ rotr(h, 22)) + ((h & a) ^ (h & b) ^ (a & b));
	w10 = w10 + (rotr(w8, 17) ^ rotr(w8, 19) ^ (w8 >> 10)) + w3 + (rotr(w11, 7) ^ rotr(w11, 18) ^ (w11 >> 3));
	t = f + (rotr(c, 6) ^ rotr(c, 11) ^ rotr(c, 25)) + ((c & d) ^ (~c & e)) + k256[26] + w10;
	b = b + t;
	f = t + (rotr(g, 2) ^ rotr(g, 13) ^ rotr(g, 22)) + ((g & h) ^ (g & a) ^ (h & a));
	w11 = w11 + (rotr(w9, 17) ^ rotr(w9, 19) ^ (w9 >> 10)) + w4 + (rotr(w12, 7) ^ rotr(w12, 18) ^ (w12 >> 3));
	t = e + (rotr(b, 6) ^ rotr(b, 11) ^ rotr(b, 25)) + ((b & c) ^ (~b & d)) + k256[27] + w11;
	a = a + t;
	e = t + (rotr(f, 2) ^ rotr(f, 13) ^ rotr(f, 22)) + ((f & g) ^ (f & h) ^ (g & h));
	w12 = w12 + (rotr(w10, 17) ^ rotr(w10, 19) ^ (w10 >> 10)) + w5 + (rotr(w13, 7) ^ rotr(w13, 18) ^ (w13 >> 3));
	t = d + (rotr(a, 6) ^ rotr(a, 11) ^ rotr(a, 25)) + ((a & b) ^ (~a & c)) + k256[28] + w12;
	h = h + t;
	d = t + (rotr(e, 2) ^ rotr(e, 13) ^ rotr(e, 22)) + ((e & f) ^ (e & g) ^ (f & g));
	w13 = w13 + (rotr(w11, 17) ^ rotr(w11, 19) ^ (w11 >> 10)) + w6 + (rotr(w14, 7) ^ rotr(w14, 18) ^ (w14 >> 3));
	t = c + (rotr(h, 6) ^ rotr(h, 11) ^ rotr(h, 25)) + ((h & a) ^ (~h & b)) + k256[29] + w13;
	g = g + t;
	c = t + (rotr(d, 2) ^ rotr(d, 13) ^ rotr(d, 22)) + ((d & e) ^ (d & f) ^ (e & f));
	w14 = w14 + (rotr(w12, 17) ^ rotr(w12, 19) ^ (w12 >> 10)) + w7 + (rotr(w15, 7) ^ rotr(w15, 18) ^ (w15 >> 3));
	t = b + (rotr(g, 6) ^ rotr(g, 11) ^ rotr(g, 25)) + ((g & h) ^ (~g & a)) + k256[30] + w14;
	f = f + t;
	b = t + (rotr(c, 2) ^ rotr(c, 13) ^ rotr(c, 22)) + ((c & d) ^ (c & e) ^ (d & e));
	w15 = w15 + (rotr(w13, 17) ^ rotr(w13, 19) ^ (w13 >> 10)) + w8 + (rotr(w0, 7) ^ rotr(w0, 18) ^ (w0 >> 3));
	t = a + (rotr(f, 6) ^ rotr(f, 11) ^ rotr(f, 25)) + ((f & g) ^ (~f & h)) + k256[31] + w15;
	e = e + t;
	a = t + (rotr(b, 2) ^ rotr(b, 13) ^ rotr(b, 22)) + ((b & c) ^ (b & d) ^ (c & d));
	w0 = w0 + (rotr(w14, 17) ^ rotr(w14, 19) ^ (w14 >> 10)) + w9 + (rotr(w1, 7) ^ rotr(w1, 18) ^ (w1 >> 3));
	t = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k256[32] + w0;
	d = d + t;
	h = t + (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
	w1 = w1 + (rotr(w15, 17) ^ rotr(w15, 19) ^ (w15 >> 10)) + w10 + (rotr(w2, 7) ^ rotr(w2, 18) ^ (w2 >> 3));
	t = g + (rotr(d, 6) ^ rotr(d, 11) ^ rotr(d, 25)) + ((d & e) ^ (~d & f)) + k256[33] + w1;
	c = c + t;
	g = t + (rotr(h, 2) ^ rotr(h, 13) ^ rotr(h, 22)) + ((h & a) ^ (h & b) ^ (a & b));
	w2 = w2 + (rotr(w0, 17) ^ rotr(w0, 19) ^ (w0 >> 10)) + w11 + (rotr(w3, 7) ^ rotr(w3, 18) ^ (w3 >> 3));
	t = f + (rotr(c, 6) ^ rotr(c, 11) ^ rotr(c, 25)) + ((c & d) ^ (~c & e)) + k256[34] + w2;
	b = b + t;
	f = t + (rotr(g, 2) ^ rotr(g, 13) ^ rotr(g, 22)) + ((g & h) ^ (g & a) ^ (h & a));
	w3 = w3 + (rotr(w1, 17) ^ rotr(w1, 19) ^ (w1 >> 10)) + w12 + (rotr(w4, 7) ^ rotr(w4, 18) ^ (w4 >> 3));
	t = e + (rotr(b, 6) ^ rotr(b, 11) ^ rotr(b, 25)) + ((b & c) ^ (~b & d)) + k256[35] + w3;
	a = a + t;
	e = t + (rotr(f, 2) ^ rotr(f, 13) ^ rotr(f, 22)) + ((f & g) ^ (f & h) ^ (g & h));
	w4 = w4 + (rotr(w2, 17) ^ rotr(w2, 19) ^ (w2 >> 10)) + w13 + (rotr(w5, 7) ^ rotr(w5, 18) ^ (w5 >> 3));
	t = d + (rotr(a, 6) ^ rotr(a, 11) ^ rotr(a, 25)) + ((a & b) ^ (~a & c)) + k256[36] + w4;
	h = h + t;
	d = t + (rotr(e, 2) ^ rotr(e, 13) ^ rotr(e, 22)) + ((e & f) ^ (e & g) ^ (f & g));
	w5 = w5 + (rotr(w3, 17) ^ rotr(w3, 19) ^ (w3 >> 10)) + w14 + (rotr(w6, 7) ^ rotr(w6, 18) ^ (w6 >> 3));
	t = c + (rotr(h, 6) ^ rotr(h, 11) ^ rotr(h, 25)) + ((h & a) ^ (~h & b)) + k256[37] + w5;
	g = g + t;
	c = t + (rotr(d, 2) ^ rotr(d, 13) ^ rotr(d, 22)) + ((d & e) ^ (d & f) ^ (e & f));
	w6 = w6 + (rotr(w4, 17) ^ rotr(w4, 19) ^ (w4 >> 10)) + w15 + (rotr(w7, 7) ^ rotr(w7, 18) ^ (w7 >> 3));
	t = b + (rotr(g, 6) ^ rotr(g, 11) ^ rotr(g, 25)) + ((g & h) ^ (~g & a)) + k256[38] + w6;
	f = f + t;
	b = t + (rotr(c, 2) ^ rotr(c, 13) ^ rotr(c, 22)) + ((c & d) ^ (c & e) ^ (d & e));
	w7 = w7 + (rotr(w5, 17) ^ rotr(w5, 19) ^ (w5 >> 10)) + w0 + (rotr(w8, 7) ^ rotr(w8, 18) ^ (w8 >> 3));
	t = a + (rotr(f, 6) ^ rotr(f, 11) ^ rotr(f, 25)) + ((f & g) ^ (~f & h)) + k256[39] + w7;
	e = e + t;
	a = t + (rotr(b, 2) ^ rotr(b, 13) ^ rotr(b, 22)) + ((b & c) ^ (b & d) ^ (c & d));
	w8 = w8 + (rotr(w6, 17) ^ rotr(w6, 19) ^ (w6 >> 10)) + w1 + (rotr(w9, 7) ^ rotr(w9, 18) ^ (w9 >> 3));
	t = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k256[40] + w8;
	d = d + t;
	h = t + (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
	w9 = w9 + (rotr(w7, 17) ^ rotr(w7, 19) ^ (w7 >> 10)) + w2 + (rotr(w10, 7) ^ rotr(w10, 18) ^ (w10 >> 3));
	t = g + (rotr(d, 6) ^ rotr(d, 11) ^ rotr(d, 25)) + ((d & e) ^ (~d & f)) + k256[41] + w9;
	c = c + t;
	g = t + (rotr(h, 2) ^ rotr(h, 13) ^ rotr(h, 22)) + ((h & a) ^ (h & b) ^ (a & b));
	w10 = w10 + (rotr(w8, 17) ^ rotr(w8, 19) ^ (w8 >> 10)) + w3 + (rotr(w11, 7) ^ rotr(w11, 18) ^ (w11 >> 3));
	t = f + (rotr(c, 6) ^ rotr(c, 11) ^ rotr(c, 25)) + ((c & d) ^ (~c & e)) + k256[42] + w10;
	b = b + t;
	f = t + (rotr(g, 2) ^ rotr(g, 13) ^ rotr(g, 22)) + ((g & h) ^ (g & a) ^ (h & a));
	w11 = w11 + (rotr(w9, 17) ^ rotr(w9, 19) ^ (w9 >> 10)) + w4 + (rotr(w12, 7) ^ rotr(w12, 18) ^ (w12 >> 3));
	t = e + (rotr(b, 6) ^ rotr(b, 11) ^ rotr(b, 25)) + ((b & c) ^ (~b & d)) + k256[43] + w11;
	a = a + t;
	e = t + (rotr(f, 2) ^ rotr(f, 13) ^ rotr(f, 22)) + ((f & g) ^ (f & h) ^ (g & h));
	w12 = w12 + (rotr(w10, 17) ^ rotr(w10, 19) ^ (w10 >> 10)) + w5 + (rotr(w13, 7) ^ rotr(w13, 18) ^ (w13 >> 3));
	t = d + (rotr(a, 6) ^ rotr(a, 11) ^ rotr(a, 25)) + ((a & b) ^ (~a & c)) + k256[44] + w12;
	h = h + t;
	d = t + (rotr(e, 2) ^ rotr(e, 13) ^ rotr(e, 22)) + ((e & f) ^ (e & g) ^ (f & g));
	w13 = w13 + (rotr(w11, 17) ^ rotr(w11, 19) ^ (w11 >> 10)) + w6 + (rotr(w14, 7) ^ rotr(w14, 18) ^ (w14 >> 3));
	t = c + (rotr(h, 6) ^ rotr(h, 11) ^ rotr(h, 25)) + ((h & a) ^ (~h & b)) + k256[45] + w13;
	g = g + t;
	c = t + (rotr(d, 2) ^ rotr(d, 13) ^ rotr(d, 22)) + ((d & e) ^ (d & f) ^ (e & f));
	w14 = w14 + (rotr(w12, 17) ^ rotr(w12, 19) ^ (w12 >> 10)) + w7 + (rotr(w15, 7) ^ rotr(w15, 18) ^ (w15 >> 3));
	t = b + (rotr(g, 6) ^ rotr(g, 11) ^ rotr(g, 25)) + ((g & h) ^ (~g & a)) + k256[46] + w14;
	f = f + t;
	b = t + (rotr(c, 2) ^ rotr(c, 13) ^ rotr(c, 22)) + ((c & d) ^ (c & e) ^ (d & e));
	w15 = w15 + (rotr(w13, 17) ^ rotr(w13, 19) ^ (w13 >> 10)) + w8 + (rotr(w0, 7) ^ rotr(w0, 18) ^ (w0 >> 3));
	t = a + (rotr(f, 6) ^ rotr(f, 11) ^ rotr(f, 25)) + ((f & g) ^ (~f & h)) + k256[47] + w15;
	e = e + t;
	a = t + (rotr(b, 2) ^ rotr(b, 13) ^ rotr(b, 22)) + ((b & c) ^ (b & d) ^ (c & d));
	w0 = w0 + (rotr(w14, 17) ^ rotr(w14, 19) ^ (w14 >> 10)) + w9 + (rotr(w1, 7) ^ rotr(w1, 18) ^ (w1 >> 3));
	t = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k256[48] + w0;
	d = d + t;
	h = t + (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
	w1 = w1 + (rotr(w15, 17) ^ rotr(w15, 19) ^ (w15 >> 10)) + w10 + (rotr(w2, 7) ^ rotr(w2, 18) ^ (w2 >> 3));
	t = g + (rotr(d, 6) ^ rotr(d, 11) ^ rotr(d, 25)) + ((d & e) ^ (~d & f)) + k256[49] + w1;
	c = c + t;
	g = t + (rotr(h, 2) ^ rotr(h, 13) ^ rotr(h, 22)) + ((h & a) ^ (h & b) ^ (a & b));
	w2 = w2 + (rotr(w0, 17) ^ rotr(w0, 19) ^ (w0 >> 10)) + w11 + (rotr(w3, 7) ^ rotr(w3, 18) ^ (w3 >> 3));
	t = f + (rotr(c, 6) ^ rotr(c, 11) ^ rotr(c, 25)) + ((c & d) ^ (~c & e)) + k256[50] + w2;
	b = b + t;
	f = t + (rotr(g, 2) ^ rotr(g, 13) ^ rotr(g, 22)) + ((g & h) ^ (g & a) ^ (h & a));
	w3 = w3 + (rotr(w1, 17) ^ rotr(w1, 19) ^ (w1 >> 10)) + w12 + (rotr(w4, 7) ^ rotr(w4, 18) ^ (w4 >> 3));
	t = e + (rotr(b, 6) ^ rotr(b, 11) ^ rotr(b, 25)) + ((b & c) ^ (~b & d)) + k256[51] + w3;
	a = a + t;
	e = t + (rotr(f, 2) ^ rotr(f, 13) ^ rotr(f, 22)) + ((f & g) ^ (f & h) ^ (g & h));
	w4 = w4 + (rotr(w2, 17) ^ rotr(w2, 19) ^ (w2 >> 10)) + w13 + (rotr(w5, 7) ^ rotr(w5, 18) ^ (w5 >> 3));
	t = d + (rotr(a, 6) ^ rotr(a, 11) ^ rotr(a, 25)) + ((a & b) ^ (~a & c)) + k256[52] + w4;
	h = h + t;
	d = t + (rotr(e, 2) ^ rotr(e, 13) ^ rotr(e, 22)) + ((e & f) ^ (e & g) ^ (f & g));
	w5 = w5 + (rotr(w3, 17) ^ rotr(w3, 19) ^ (w3 >> 10)) + w14 + (rotr(w6, 7) ^ rotr(w6, 18) ^ (w6 >> 3));
	t = c + (rotr(h, 6) ^ rotr(h, 11) ^ rotr(h, 25)) + ((h & a) ^ (~h & b)) + k256[53] + w5;
	g = g + t;
	c = t + (rotr(d, 2) ^ rotr(d, 13) ^ rotr(d, 22)) + ((d & e) ^ (d & f) ^ (e & f));
	w6 = w6 + (rotr(w4, 17) ^ rotr(w4, 19) ^ (w4 >> 10)) + w15 + (rotr(w7, 7) ^ rotr(w7, 18) ^ (w7 >> 3));
	t = b + (rotr(g, 6) ^ rotr(g, 11) ^ rotr(g, 25)) + ((g & h) ^ (~g & a)) + k256[54] + w6;
	f = f + t;
	b = t + (rotr(c, 2) ^ rotr(c, 13) ^ rotr(c, 22)) + ((c & d) ^ (c & e) ^ (d & e));
	w7 = w7 + (rotr(w5, 17) ^ rotr(w5, 19) ^ (w5 >> 10)) + w0 + (rotr(w8, 7) ^ rotr(w8, 18) ^ (w8 >> 3));
	t = a + (rotr(f, 6) ^ rotr(f, 11) ^ rotr(f, 25)) + ((f & g) ^ (~f & h)) + k256[55] + w7;
	e = e + t;
	a = t + (rotr(b, 2) ^ rotr(b, 13) ^ rotr(b, 22)) + ((b & c) ^ (b & d) ^ (c & d));
	w8 = w8 + (rotr(w6, 17) ^ rotr(w6, 19) ^ (w6 >> 10)) + w1 + (rotr(w9, 7) ^ rotr(w9, 18) ^ (w9 >> 3));
	t = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k256[56] + w8;
	d = d + t;
	h = t + (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
	w9 = w9 + (rotr(w7, 17) ^ rotr(w7, 19) ^ (w7 >> 10)) + w2 + (rotr(w10, 7) ^ rotr(w10, 18) ^ (w10 >> 3));
	t = g + (rotr(d, 6) ^ rotr(d, 11) ^ rotr(d, 25)) + ((d & e) ^ (~d & f)) + k256[57] + w9;
	c = c + t;
	g = t + (rotr(h, 2) ^ rotr(h, 13) ^ rotr(h, 22)) + ((h & a) ^ (h & b) ^ (a & b));
	w10 = w10 + (rotr(w8, 17) ^ rotr(w8, 19) ^ (w8 >> 10)) + w3 + (rotr(w11, 7) ^ rotr(w11, 18) ^ (w11 >> 3));
	t = f + (rotr(c, 6) ^ rotr(c, 11) ^ rotr(c, 25)) + ((c & d) ^ (~c & e)) + k256[58] + w10;
	b = b + t;
	f = t + (rotr(g, 2) ^ rotr(g, 13) ^ rotr(g, 22)) + ((g & h) ^ (g & a) ^ (h & a));
	w11 = w11 + (rotr(w9, 17) ^ rotr(w9, 19) ^ (w9 >> 10)) + w4 + (rotr(w12, 7) ^ rotr(w12, 18) ^ (w12 >> 3));
	t = e + (rotr(b, 6) ^ rotr(b, 11) ^ rotr(b, 25)) + ((b & c) ^ (~b & d)) + k256[59] + w11;
	a = a + t;
	e = t + (rotr(f, 2) ^ rotr(f, 13) ^ rotr(f, 22)) + ((f & g) ^ (f & h) ^ (g & h));
	w12 = w12 + (rotr(w10, 17) ^ rotr(w10, 19) ^ (w10 >> 10)) + w5 + (rotr(w13, 7) ^ rotr(w13, 18) ^ (w13 >> 3));
	t = d + (rotr(a, 6) ^ rotr(a, 11) ^ rotr(a, 25)) + ((a & b) ^ (~a & c)) + k256[60] + w12;
	h = h + t;
	d = t + (rotr(e, 2) ^ rotr(e, 13) ^ rotr(e, 22)) + ((e & f) ^ (e & g) ^ (f & g));
	w13 = w13 + (rotr(w11, 17) ^ rotr(w11, 19) ^ (w11 >> 10)) + w6 + (rotr(w14, 7) ^ rotr(w14, 18) ^ (w14 >> 3));
	t = c + (rotr(h, 6) ^ rotr(h, 11) ^ rotr(h, 25)) + ((h & a) ^ (~h & b)) + k256[61] + w13;
	g = g + t;
	c = t + (rotr(d, 2) ^ rotr(d, 13) ^ rotr(d, 22)) + ((d & e) ^ (d & f) ^ (e & f));
	w14 = w14 + (rotr(w12, 17) ^ rotr(w12, 19) ^ (w12 >> 10)) + w7 + (rotr(w15, 7) ^ rotr(w15, 18) ^ (w15 >> 3));
	t = b + (rotr(g, 6) ^ rotr(g, 11) ^ rotr(g, 25)) + ((g & h) ^ (~g & a)) + k256[62] + w14;
	f = f + t;
	b = t + (rotr(c, 2) ^ rotr(c, 13) ^ rotr(c, 22)) + ((c & d) ^ (c & e) ^ (d & e));
	w15 = w15 + (rotr(w13, 17) ^ rotr(w13, 19) ^ (w13 >> 10)) + w8 + (rotr(w0, 7) ^ rotr(w0, 18) ^ (w0 >> 3));
	t = a + (rotr(f, 6) ^ rotr(f, 11) ^ rotr(f, 25)) + ((f & g) ^ (~f & h)) + k256[63] + w15;
	e = e + t;
	a = t + (rotr(b, 2) ^ rotr(b, 13) ^ rotr(b, 22)) + ((b & c) ^ (b & d) ^ (c & d));
	st.state[0] = st.state[0] + a;
	st.state[1] = st.state[1] + b;
	st.state[2] = st.state[2] + c;
	st.state[3] = st.state[3] + d;
	st.state[4] = st.state[4] + e;
	st.state[5] = st.state[5] + f;
	st.state[6] = st.state[6] + g;
	st.state[7] = st.state[7] + h;
}

when (!js) {
	@inline
	function wordBE(data: HashBytes, at: int32): uint32 {
		return ((data[at] as uint32) << 24) | ((data[at + 1] as uint32) << 16) | ((data[at + 2] as uint32) << 8) | (data[at + 3] as uint32);
	}

	function compress256Block(st: HashState, data: HashBytes, off: int32): void {
		let w0: uint32 = wordBE(data, off + 0);
		let w1: uint32 = wordBE(data, off + 4);
		let w2: uint32 = wordBE(data, off + 8);
		let w3: uint32 = wordBE(data, off + 12);
		let w4: uint32 = wordBE(data, off + 16);
		let w5: uint32 = wordBE(data, off + 20);
		let w6: uint32 = wordBE(data, off + 24);
		let w7: uint32 = wordBE(data, off + 28);
		let w8: uint32 = wordBE(data, off + 32);
		let w9: uint32 = wordBE(data, off + 36);
		let w10: uint32 = wordBE(data, off + 40);
		let w11: uint32 = wordBE(data, off + 44);
		let w12: uint32 = wordBE(data, off + 48);
		let w13: uint32 = wordBE(data, off + 52);
		let w14: uint32 = wordBE(data, off + 56);
		let w15: uint32 = wordBE(data, off + 60);
		let a: uint32 = st.state[0];
		let b: uint32 = st.state[1];
		let c: uint32 = st.state[2];
		let d: uint32 = st.state[3];
		let e: uint32 = st.state[4];
		let f: uint32 = st.state[5];
		let g: uint32 = st.state[6];
		let h: uint32 = st.state[7];
		let t: uint32 = 0;
		t = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k256[0] + w0;
		d = d + t;
		h = t + (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
		t = g + (rotr(d, 6) ^ rotr(d, 11) ^ rotr(d, 25)) + ((d & e) ^ (~d & f)) + k256[1] + w1;
		c = c + t;
		g = t + (rotr(h, 2) ^ rotr(h, 13) ^ rotr(h, 22)) + ((h & a) ^ (h & b) ^ (a & b));
		t = f + (rotr(c, 6) ^ rotr(c, 11) ^ rotr(c, 25)) + ((c & d) ^ (~c & e)) + k256[2] + w2;
		b = b + t;
		f = t + (rotr(g, 2) ^ rotr(g, 13) ^ rotr(g, 22)) + ((g & h) ^ (g & a) ^ (h & a));
		t = e + (rotr(b, 6) ^ rotr(b, 11) ^ rotr(b, 25)) + ((b & c) ^ (~b & d)) + k256[3] + w3;
		a = a + t;
		e = t + (rotr(f, 2) ^ rotr(f, 13) ^ rotr(f, 22)) + ((f & g) ^ (f & h) ^ (g & h));
		t = d + (rotr(a, 6) ^ rotr(a, 11) ^ rotr(a, 25)) + ((a & b) ^ (~a & c)) + k256[4] + w4;
		h = h + t;
		d = t + (rotr(e, 2) ^ rotr(e, 13) ^ rotr(e, 22)) + ((e & f) ^ (e & g) ^ (f & g));
		t = c + (rotr(h, 6) ^ rotr(h, 11) ^ rotr(h, 25)) + ((h & a) ^ (~h & b)) + k256[5] + w5;
		g = g + t;
		c = t + (rotr(d, 2) ^ rotr(d, 13) ^ rotr(d, 22)) + ((d & e) ^ (d & f) ^ (e & f));
		t = b + (rotr(g, 6) ^ rotr(g, 11) ^ rotr(g, 25)) + ((g & h) ^ (~g & a)) + k256[6] + w6;
		f = f + t;
		b = t + (rotr(c, 2) ^ rotr(c, 13) ^ rotr(c, 22)) + ((c & d) ^ (c & e) ^ (d & e));
		t = a + (rotr(f, 6) ^ rotr(f, 11) ^ rotr(f, 25)) + ((f & g) ^ (~f & h)) + k256[7] + w7;
		e = e + t;
		a = t + (rotr(b, 2) ^ rotr(b, 13) ^ rotr(b, 22)) + ((b & c) ^ (b & d) ^ (c & d));
		t = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k256[8] + w8;
		d = d + t;
		h = t + (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
		t = g + (rotr(d, 6) ^ rotr(d, 11) ^ rotr(d, 25)) + ((d & e) ^ (~d & f)) + k256[9] + w9;
		c = c + t;
		g = t + (rotr(h, 2) ^ rotr(h, 13) ^ rotr(h, 22)) + ((h & a) ^ (h & b) ^ (a & b));
		t = f + (rotr(c, 6) ^ rotr(c, 11) ^ rotr(c, 25)) + ((c & d) ^ (~c & e)) + k256[10] + w10;
		b = b + t;
		f = t + (rotr(g, 2) ^ rotr(g, 13) ^ rotr(g, 22)) + ((g & h) ^ (g & a) ^ (h & a));
		t = e + (rotr(b, 6) ^ rotr(b, 11) ^ rotr(b, 25)) + ((b & c) ^ (~b & d)) + k256[11] + w11;
		a = a + t;
		e = t + (rotr(f, 2) ^ rotr(f, 13) ^ rotr(f, 22)) + ((f & g) ^ (f & h) ^ (g & h));
		t = d + (rotr(a, 6) ^ rotr(a, 11) ^ rotr(a, 25)) + ((a & b) ^ (~a & c)) + k256[12] + w12;
		h = h + t;
		d = t + (rotr(e, 2) ^ rotr(e, 13) ^ rotr(e, 22)) + ((e & f) ^ (e & g) ^ (f & g));
		t = c + (rotr(h, 6) ^ rotr(h, 11) ^ rotr(h, 25)) + ((h & a) ^ (~h & b)) + k256[13] + w13;
		g = g + t;
		c = t + (rotr(d, 2) ^ rotr(d, 13) ^ rotr(d, 22)) + ((d & e) ^ (d & f) ^ (e & f));
		t = b + (rotr(g, 6) ^ rotr(g, 11) ^ rotr(g, 25)) + ((g & h) ^ (~g & a)) + k256[14] + w14;
		f = f + t;
		b = t + (rotr(c, 2) ^ rotr(c, 13) ^ rotr(c, 22)) + ((c & d) ^ (c & e) ^ (d & e));
		t = a + (rotr(f, 6) ^ rotr(f, 11) ^ rotr(f, 25)) + ((f & g) ^ (~f & h)) + k256[15] + w15;
		e = e + t;
		a = t + (rotr(b, 2) ^ rotr(b, 13) ^ rotr(b, 22)) + ((b & c) ^ (b & d) ^ (c & d));
		w0 = w0 + (rotr(w14, 17) ^ rotr(w14, 19) ^ (w14 >> 10)) + w9 + (rotr(w1, 7) ^ rotr(w1, 18) ^ (w1 >> 3));
		t = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k256[16] + w0;
		d = d + t;
		h = t + (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
		w1 = w1 + (rotr(w15, 17) ^ rotr(w15, 19) ^ (w15 >> 10)) + w10 + (rotr(w2, 7) ^ rotr(w2, 18) ^ (w2 >> 3));
		t = g + (rotr(d, 6) ^ rotr(d, 11) ^ rotr(d, 25)) + ((d & e) ^ (~d & f)) + k256[17] + w1;
		c = c + t;
		g = t + (rotr(h, 2) ^ rotr(h, 13) ^ rotr(h, 22)) + ((h & a) ^ (h & b) ^ (a & b));
		w2 = w2 + (rotr(w0, 17) ^ rotr(w0, 19) ^ (w0 >> 10)) + w11 + (rotr(w3, 7) ^ rotr(w3, 18) ^ (w3 >> 3));
		t = f + (rotr(c, 6) ^ rotr(c, 11) ^ rotr(c, 25)) + ((c & d) ^ (~c & e)) + k256[18] + w2;
		b = b + t;
		f = t + (rotr(g, 2) ^ rotr(g, 13) ^ rotr(g, 22)) + ((g & h) ^ (g & a) ^ (h & a));
		w3 = w3 + (rotr(w1, 17) ^ rotr(w1, 19) ^ (w1 >> 10)) + w12 + (rotr(w4, 7) ^ rotr(w4, 18) ^ (w4 >> 3));
		t = e + (rotr(b, 6) ^ rotr(b, 11) ^ rotr(b, 25)) + ((b & c) ^ (~b & d)) + k256[19] + w3;
		a = a + t;
		e = t + (rotr(f, 2) ^ rotr(f, 13) ^ rotr(f, 22)) + ((f & g) ^ (f & h) ^ (g & h));
		w4 = w4 + (rotr(w2, 17) ^ rotr(w2, 19) ^ (w2 >> 10)) + w13 + (rotr(w5, 7) ^ rotr(w5, 18) ^ (w5 >> 3));
		t = d + (rotr(a, 6) ^ rotr(a, 11) ^ rotr(a, 25)) + ((a & b) ^ (~a & c)) + k256[20] + w4;
		h = h + t;
		d = t + (rotr(e, 2) ^ rotr(e, 13) ^ rotr(e, 22)) + ((e & f) ^ (e & g) ^ (f & g));
		w5 = w5 + (rotr(w3, 17) ^ rotr(w3, 19) ^ (w3 >> 10)) + w14 + (rotr(w6, 7) ^ rotr(w6, 18) ^ (w6 >> 3));
		t = c + (rotr(h, 6) ^ rotr(h, 11) ^ rotr(h, 25)) + ((h & a) ^ (~h & b)) + k256[21] + w5;
		g = g + t;
		c = t + (rotr(d, 2) ^ rotr(d, 13) ^ rotr(d, 22)) + ((d & e) ^ (d & f) ^ (e & f));
		w6 = w6 + (rotr(w4, 17) ^ rotr(w4, 19) ^ (w4 >> 10)) + w15 + (rotr(w7, 7) ^ rotr(w7, 18) ^ (w7 >> 3));
		t = b + (rotr(g, 6) ^ rotr(g, 11) ^ rotr(g, 25)) + ((g & h) ^ (~g & a)) + k256[22] + w6;
		f = f + t;
		b = t + (rotr(c, 2) ^ rotr(c, 13) ^ rotr(c, 22)) + ((c & d) ^ (c & e) ^ (d & e));
		w7 = w7 + (rotr(w5, 17) ^ rotr(w5, 19) ^ (w5 >> 10)) + w0 + (rotr(w8, 7) ^ rotr(w8, 18) ^ (w8 >> 3));
		t = a + (rotr(f, 6) ^ rotr(f, 11) ^ rotr(f, 25)) + ((f & g) ^ (~f & h)) + k256[23] + w7;
		e = e + t;
		a = t + (rotr(b, 2) ^ rotr(b, 13) ^ rotr(b, 22)) + ((b & c) ^ (b & d) ^ (c & d));
		w8 = w8 + (rotr(w6, 17) ^ rotr(w6, 19) ^ (w6 >> 10)) + w1 + (rotr(w9, 7) ^ rotr(w9, 18) ^ (w9 >> 3));
		t = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k256[24] + w8;
		d = d + t;
		h = t + (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
		w9 = w9 + (rotr(w7, 17) ^ rotr(w7, 19) ^ (w7 >> 10)) + w2 + (rotr(w10, 7) ^ rotr(w10, 18) ^ (w10 >> 3));
		t = g + (rotr(d, 6) ^ rotr(d, 11) ^ rotr(d, 25)) + ((d & e) ^ (~d & f)) + k256[25] + w9;
		c = c + t;
		g = t + (rotr(h, 2) ^ rotr(h, 13) ^ rotr(h, 22)) + ((h & a) ^ (h & b) ^ (a & b));
		w10 = w10 + (rotr(w8, 17) ^ rotr(w8, 19) ^ (w8 >> 10)) + w3 + (rotr(w11, 7) ^ rotr(w11, 18) ^ (w11 >> 3));
		t = f + (rotr(c, 6) ^ rotr(c, 11) ^ rotr(c, 25)) + ((c & d) ^ (~c & e)) + k256[26] + w10;
		b = b + t;
		f = t + (rotr(g, 2) ^ rotr(g, 13) ^ rotr(g, 22)) + ((g & h) ^ (g & a) ^ (h & a));
		w11 = w11 + (rotr(w9, 17) ^ rotr(w9, 19) ^ (w9 >> 10)) + w4 + (rotr(w12, 7) ^ rotr(w12, 18) ^ (w12 >> 3));
		t = e + (rotr(b, 6) ^ rotr(b, 11) ^ rotr(b, 25)) + ((b & c) ^ (~b & d)) + k256[27] + w11;
		a = a + t;
		e = t + (rotr(f, 2) ^ rotr(f, 13) ^ rotr(f, 22)) + ((f & g) ^ (f & h) ^ (g & h));
		w12 = w12 + (rotr(w10, 17) ^ rotr(w10, 19) ^ (w10 >> 10)) + w5 + (rotr(w13, 7) ^ rotr(w13, 18) ^ (w13 >> 3));
		t = d + (rotr(a, 6) ^ rotr(a, 11) ^ rotr(a, 25)) + ((a & b) ^ (~a & c)) + k256[28] + w12;
		h = h + t;
		d = t + (rotr(e, 2) ^ rotr(e, 13) ^ rotr(e, 22)) + ((e & f) ^ (e & g) ^ (f & g));
		w13 = w13 + (rotr(w11, 17) ^ rotr(w11, 19) ^ (w11 >> 10)) + w6 + (rotr(w14, 7) ^ rotr(w14, 18) ^ (w14 >> 3));
		t = c + (rotr(h, 6) ^ rotr(h, 11) ^ rotr(h, 25)) + ((h & a) ^ (~h & b)) + k256[29] + w13;
		g = g + t;
		c = t + (rotr(d, 2) ^ rotr(d, 13) ^ rotr(d, 22)) + ((d & e) ^ (d & f) ^ (e & f));
		w14 = w14 + (rotr(w12, 17) ^ rotr(w12, 19) ^ (w12 >> 10)) + w7 + (rotr(w15, 7) ^ rotr(w15, 18) ^ (w15 >> 3));
		t = b + (rotr(g, 6) ^ rotr(g, 11) ^ rotr(g, 25)) + ((g & h) ^ (~g & a)) + k256[30] + w14;
		f = f + t;
		b = t + (rotr(c, 2) ^ rotr(c, 13) ^ rotr(c, 22)) + ((c & d) ^ (c & e) ^ (d & e));
		w15 = w15 + (rotr(w13, 17) ^ rotr(w13, 19) ^ (w13 >> 10)) + w8 + (rotr(w0, 7) ^ rotr(w0, 18) ^ (w0 >> 3));
		t = a + (rotr(f, 6) ^ rotr(f, 11) ^ rotr(f, 25)) + ((f & g) ^ (~f & h)) + k256[31] + w15;
		e = e + t;
		a = t + (rotr(b, 2) ^ rotr(b, 13) ^ rotr(b, 22)) + ((b & c) ^ (b & d) ^ (c & d));
		w0 = w0 + (rotr(w14, 17) ^ rotr(w14, 19) ^ (w14 >> 10)) + w9 + (rotr(w1, 7) ^ rotr(w1, 18) ^ (w1 >> 3));
		t = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k256[32] + w0;
		d = d + t;
		h = t + (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
		w1 = w1 + (rotr(w15, 17) ^ rotr(w15, 19) ^ (w15 >> 10)) + w10 + (rotr(w2, 7) ^ rotr(w2, 18) ^ (w2 >> 3));
		t = g + (rotr(d, 6) ^ rotr(d, 11) ^ rotr(d, 25)) + ((d & e) ^ (~d & f)) + k256[33] + w1;
		c = c + t;
		g = t + (rotr(h, 2) ^ rotr(h, 13) ^ rotr(h, 22)) + ((h & a) ^ (h & b) ^ (a & b));
		w2 = w2 + (rotr(w0, 17) ^ rotr(w0, 19) ^ (w0 >> 10)) + w11 + (rotr(w3, 7) ^ rotr(w3, 18) ^ (w3 >> 3));
		t = f + (rotr(c, 6) ^ rotr(c, 11) ^ rotr(c, 25)) + ((c & d) ^ (~c & e)) + k256[34] + w2;
		b = b + t;
		f = t + (rotr(g, 2) ^ rotr(g, 13) ^ rotr(g, 22)) + ((g & h) ^ (g & a) ^ (h & a));
		w3 = w3 + (rotr(w1, 17) ^ rotr(w1, 19) ^ (w1 >> 10)) + w12 + (rotr(w4, 7) ^ rotr(w4, 18) ^ (w4 >> 3));
		t = e + (rotr(b, 6) ^ rotr(b, 11) ^ rotr(b, 25)) + ((b & c) ^ (~b & d)) + k256[35] + w3;
		a = a + t;
		e = t + (rotr(f, 2) ^ rotr(f, 13) ^ rotr(f, 22)) + ((f & g) ^ (f & h) ^ (g & h));
		w4 = w4 + (rotr(w2, 17) ^ rotr(w2, 19) ^ (w2 >> 10)) + w13 + (rotr(w5, 7) ^ rotr(w5, 18) ^ (w5 >> 3));
		t = d + (rotr(a, 6) ^ rotr(a, 11) ^ rotr(a, 25)) + ((a & b) ^ (~a & c)) + k256[36] + w4;
		h = h + t;
		d = t + (rotr(e, 2) ^ rotr(e, 13) ^ rotr(e, 22)) + ((e & f) ^ (e & g) ^ (f & g));
		w5 = w5 + (rotr(w3, 17) ^ rotr(w3, 19) ^ (w3 >> 10)) + w14 + (rotr(w6, 7) ^ rotr(w6, 18) ^ (w6 >> 3));
		t = c + (rotr(h, 6) ^ rotr(h, 11) ^ rotr(h, 25)) + ((h & a) ^ (~h & b)) + k256[37] + w5;
		g = g + t;
		c = t + (rotr(d, 2) ^ rotr(d, 13) ^ rotr(d, 22)) + ((d & e) ^ (d & f) ^ (e & f));
		w6 = w6 + (rotr(w4, 17) ^ rotr(w4, 19) ^ (w4 >> 10)) + w15 + (rotr(w7, 7) ^ rotr(w7, 18) ^ (w7 >> 3));
		t = b + (rotr(g, 6) ^ rotr(g, 11) ^ rotr(g, 25)) + ((g & h) ^ (~g & a)) + k256[38] + w6;
		f = f + t;
		b = t + (rotr(c, 2) ^ rotr(c, 13) ^ rotr(c, 22)) + ((c & d) ^ (c & e) ^ (d & e));
		w7 = w7 + (rotr(w5, 17) ^ rotr(w5, 19) ^ (w5 >> 10)) + w0 + (rotr(w8, 7) ^ rotr(w8, 18) ^ (w8 >> 3));
		t = a + (rotr(f, 6) ^ rotr(f, 11) ^ rotr(f, 25)) + ((f & g) ^ (~f & h)) + k256[39] + w7;
		e = e + t;
		a = t + (rotr(b, 2) ^ rotr(b, 13) ^ rotr(b, 22)) + ((b & c) ^ (b & d) ^ (c & d));
		w8 = w8 + (rotr(w6, 17) ^ rotr(w6, 19) ^ (w6 >> 10)) + w1 + (rotr(w9, 7) ^ rotr(w9, 18) ^ (w9 >> 3));
		t = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k256[40] + w8;
		d = d + t;
		h = t + (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
		w9 = w9 + (rotr(w7, 17) ^ rotr(w7, 19) ^ (w7 >> 10)) + w2 + (rotr(w10, 7) ^ rotr(w10, 18) ^ (w10 >> 3));
		t = g + (rotr(d, 6) ^ rotr(d, 11) ^ rotr(d, 25)) + ((d & e) ^ (~d & f)) + k256[41] + w9;
		c = c + t;
		g = t + (rotr(h, 2) ^ rotr(h, 13) ^ rotr(h, 22)) + ((h & a) ^ (h & b) ^ (a & b));
		w10 = w10 + (rotr(w8, 17) ^ rotr(w8, 19) ^ (w8 >> 10)) + w3 + (rotr(w11, 7) ^ rotr(w11, 18) ^ (w11 >> 3));
		t = f + (rotr(c, 6) ^ rotr(c, 11) ^ rotr(c, 25)) + ((c & d) ^ (~c & e)) + k256[42] + w10;
		b = b + t;
		f = t + (rotr(g, 2) ^ rotr(g, 13) ^ rotr(g, 22)) + ((g & h) ^ (g & a) ^ (h & a));
		w11 = w11 + (rotr(w9, 17) ^ rotr(w9, 19) ^ (w9 >> 10)) + w4 + (rotr(w12, 7) ^ rotr(w12, 18) ^ (w12 >> 3));
		t = e + (rotr(b, 6) ^ rotr(b, 11) ^ rotr(b, 25)) + ((b & c) ^ (~b & d)) + k256[43] + w11;
		a = a + t;
		e = t + (rotr(f, 2) ^ rotr(f, 13) ^ rotr(f, 22)) + ((f & g) ^ (f & h) ^ (g & h));
		w12 = w12 + (rotr(w10, 17) ^ rotr(w10, 19) ^ (w10 >> 10)) + w5 + (rotr(w13, 7) ^ rotr(w13, 18) ^ (w13 >> 3));
		t = d + (rotr(a, 6) ^ rotr(a, 11) ^ rotr(a, 25)) + ((a & b) ^ (~a & c)) + k256[44] + w12;
		h = h + t;
		d = t + (rotr(e, 2) ^ rotr(e, 13) ^ rotr(e, 22)) + ((e & f) ^ (e & g) ^ (f & g));
		w13 = w13 + (rotr(w11, 17) ^ rotr(w11, 19) ^ (w11 >> 10)) + w6 + (rotr(w14, 7) ^ rotr(w14, 18) ^ (w14 >> 3));
		t = c + (rotr(h, 6) ^ rotr(h, 11) ^ rotr(h, 25)) + ((h & a) ^ (~h & b)) + k256[45] + w13;
		g = g + t;
		c = t + (rotr(d, 2) ^ rotr(d, 13) ^ rotr(d, 22)) + ((d & e) ^ (d & f) ^ (e & f));
		w14 = w14 + (rotr(w12, 17) ^ rotr(w12, 19) ^ (w12 >> 10)) + w7 + (rotr(w15, 7) ^ rotr(w15, 18) ^ (w15 >> 3));
		t = b + (rotr(g, 6) ^ rotr(g, 11) ^ rotr(g, 25)) + ((g & h) ^ (~g & a)) + k256[46] + w14;
		f = f + t;
		b = t + (rotr(c, 2) ^ rotr(c, 13) ^ rotr(c, 22)) + ((c & d) ^ (c & e) ^ (d & e));
		w15 = w15 + (rotr(w13, 17) ^ rotr(w13, 19) ^ (w13 >> 10)) + w8 + (rotr(w0, 7) ^ rotr(w0, 18) ^ (w0 >> 3));
		t = a + (rotr(f, 6) ^ rotr(f, 11) ^ rotr(f, 25)) + ((f & g) ^ (~f & h)) + k256[47] + w15;
		e = e + t;
		a = t + (rotr(b, 2) ^ rotr(b, 13) ^ rotr(b, 22)) + ((b & c) ^ (b & d) ^ (c & d));
		w0 = w0 + (rotr(w14, 17) ^ rotr(w14, 19) ^ (w14 >> 10)) + w9 + (rotr(w1, 7) ^ rotr(w1, 18) ^ (w1 >> 3));
		t = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k256[48] + w0;
		d = d + t;
		h = t + (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
		w1 = w1 + (rotr(w15, 17) ^ rotr(w15, 19) ^ (w15 >> 10)) + w10 + (rotr(w2, 7) ^ rotr(w2, 18) ^ (w2 >> 3));
		t = g + (rotr(d, 6) ^ rotr(d, 11) ^ rotr(d, 25)) + ((d & e) ^ (~d & f)) + k256[49] + w1;
		c = c + t;
		g = t + (rotr(h, 2) ^ rotr(h, 13) ^ rotr(h, 22)) + ((h & a) ^ (h & b) ^ (a & b));
		w2 = w2 + (rotr(w0, 17) ^ rotr(w0, 19) ^ (w0 >> 10)) + w11 + (rotr(w3, 7) ^ rotr(w3, 18) ^ (w3 >> 3));
		t = f + (rotr(c, 6) ^ rotr(c, 11) ^ rotr(c, 25)) + ((c & d) ^ (~c & e)) + k256[50] + w2;
		b = b + t;
		f = t + (rotr(g, 2) ^ rotr(g, 13) ^ rotr(g, 22)) + ((g & h) ^ (g & a) ^ (h & a));
		w3 = w3 + (rotr(w1, 17) ^ rotr(w1, 19) ^ (w1 >> 10)) + w12 + (rotr(w4, 7) ^ rotr(w4, 18) ^ (w4 >> 3));
		t = e + (rotr(b, 6) ^ rotr(b, 11) ^ rotr(b, 25)) + ((b & c) ^ (~b & d)) + k256[51] + w3;
		a = a + t;
		e = t + (rotr(f, 2) ^ rotr(f, 13) ^ rotr(f, 22)) + ((f & g) ^ (f & h) ^ (g & h));
		w4 = w4 + (rotr(w2, 17) ^ rotr(w2, 19) ^ (w2 >> 10)) + w13 + (rotr(w5, 7) ^ rotr(w5, 18) ^ (w5 >> 3));
		t = d + (rotr(a, 6) ^ rotr(a, 11) ^ rotr(a, 25)) + ((a & b) ^ (~a & c)) + k256[52] + w4;
		h = h + t;
		d = t + (rotr(e, 2) ^ rotr(e, 13) ^ rotr(e, 22)) + ((e & f) ^ (e & g) ^ (f & g));
		w5 = w5 + (rotr(w3, 17) ^ rotr(w3, 19) ^ (w3 >> 10)) + w14 + (rotr(w6, 7) ^ rotr(w6, 18) ^ (w6 >> 3));
		t = c + (rotr(h, 6) ^ rotr(h, 11) ^ rotr(h, 25)) + ((h & a) ^ (~h & b)) + k256[53] + w5;
		g = g + t;
		c = t + (rotr(d, 2) ^ rotr(d, 13) ^ rotr(d, 22)) + ((d & e) ^ (d & f) ^ (e & f));
		w6 = w6 + (rotr(w4, 17) ^ rotr(w4, 19) ^ (w4 >> 10)) + w15 + (rotr(w7, 7) ^ rotr(w7, 18) ^ (w7 >> 3));
		t = b + (rotr(g, 6) ^ rotr(g, 11) ^ rotr(g, 25)) + ((g & h) ^ (~g & a)) + k256[54] + w6;
		f = f + t;
		b = t + (rotr(c, 2) ^ rotr(c, 13) ^ rotr(c, 22)) + ((c & d) ^ (c & e) ^ (d & e));
		w7 = w7 + (rotr(w5, 17) ^ rotr(w5, 19) ^ (w5 >> 10)) + w0 + (rotr(w8, 7) ^ rotr(w8, 18) ^ (w8 >> 3));
		t = a + (rotr(f, 6) ^ rotr(f, 11) ^ rotr(f, 25)) + ((f & g) ^ (~f & h)) + k256[55] + w7;
		e = e + t;
		a = t + (rotr(b, 2) ^ rotr(b, 13) ^ rotr(b, 22)) + ((b & c) ^ (b & d) ^ (c & d));
		w8 = w8 + (rotr(w6, 17) ^ rotr(w6, 19) ^ (w6 >> 10)) + w1 + (rotr(w9, 7) ^ rotr(w9, 18) ^ (w9 >> 3));
		t = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k256[56] + w8;
		d = d + t;
		h = t + (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
		w9 = w9 + (rotr(w7, 17) ^ rotr(w7, 19) ^ (w7 >> 10)) + w2 + (rotr(w10, 7) ^ rotr(w10, 18) ^ (w10 >> 3));
		t = g + (rotr(d, 6) ^ rotr(d, 11) ^ rotr(d, 25)) + ((d & e) ^ (~d & f)) + k256[57] + w9;
		c = c + t;
		g = t + (rotr(h, 2) ^ rotr(h, 13) ^ rotr(h, 22)) + ((h & a) ^ (h & b) ^ (a & b));
		w10 = w10 + (rotr(w8, 17) ^ rotr(w8, 19) ^ (w8 >> 10)) + w3 + (rotr(w11, 7) ^ rotr(w11, 18) ^ (w11 >> 3));
		t = f + (rotr(c, 6) ^ rotr(c, 11) ^ rotr(c, 25)) + ((c & d) ^ (~c & e)) + k256[58] + w10;
		b = b + t;
		f = t + (rotr(g, 2) ^ rotr(g, 13) ^ rotr(g, 22)) + ((g & h) ^ (g & a) ^ (h & a));
		w11 = w11 + (rotr(w9, 17) ^ rotr(w9, 19) ^ (w9 >> 10)) + w4 + (rotr(w12, 7) ^ rotr(w12, 18) ^ (w12 >> 3));
		t = e + (rotr(b, 6) ^ rotr(b, 11) ^ rotr(b, 25)) + ((b & c) ^ (~b & d)) + k256[59] + w11;
		a = a + t;
		e = t + (rotr(f, 2) ^ rotr(f, 13) ^ rotr(f, 22)) + ((f & g) ^ (f & h) ^ (g & h));
		w12 = w12 + (rotr(w10, 17) ^ rotr(w10, 19) ^ (w10 >> 10)) + w5 + (rotr(w13, 7) ^ rotr(w13, 18) ^ (w13 >> 3));
		t = d + (rotr(a, 6) ^ rotr(a, 11) ^ rotr(a, 25)) + ((a & b) ^ (~a & c)) + k256[60] + w12;
		h = h + t;
		d = t + (rotr(e, 2) ^ rotr(e, 13) ^ rotr(e, 22)) + ((e & f) ^ (e & g) ^ (f & g));
		w13 = w13 + (rotr(w11, 17) ^ rotr(w11, 19) ^ (w11 >> 10)) + w6 + (rotr(w14, 7) ^ rotr(w14, 18) ^ (w14 >> 3));
		t = c + (rotr(h, 6) ^ rotr(h, 11) ^ rotr(h, 25)) + ((h & a) ^ (~h & b)) + k256[61] + w13;
		g = g + t;
		c = t + (rotr(d, 2) ^ rotr(d, 13) ^ rotr(d, 22)) + ((d & e) ^ (d & f) ^ (e & f));
		w14 = w14 + (rotr(w12, 17) ^ rotr(w12, 19) ^ (w12 >> 10)) + w7 + (rotr(w15, 7) ^ rotr(w15, 18) ^ (w15 >> 3));
		t = b + (rotr(g, 6) ^ rotr(g, 11) ^ rotr(g, 25)) + ((g & h) ^ (~g & a)) + k256[62] + w14;
		f = f + t;
		b = t + (rotr(c, 2) ^ rotr(c, 13) ^ rotr(c, 22)) + ((c & d) ^ (c & e) ^ (d & e));
		w15 = w15 + (rotr(w13, 17) ^ rotr(w13, 19) ^ (w13 >> 10)) + w8 + (rotr(w0, 7) ^ rotr(w0, 18) ^ (w0 >> 3));
		t = a + (rotr(f, 6) ^ rotr(f, 11) ^ rotr(f, 25)) + ((f & g) ^ (~f & h)) + k256[63] + w15;
		e = e + t;
		a = t + (rotr(b, 2) ^ rotr(b, 13) ^ rotr(b, 22)) + ((b & c) ^ (b & d) ^ (c & d));
		st.state[0] = st.state[0] + a;
		st.state[1] = st.state[1] + b;
		st.state[2] = st.state[2] + c;
		st.state[3] = st.state[3] + d;
		st.state[4] = st.state[4] + e;
		st.state[5] = st.state[5] + f;
		st.state[6] = st.state[6] + g;
		st.state[7] = st.state[7] + h;
	}

	function rotr64(v: uint64, c: uint64): uint64 {
		return (v >> c) | (v << (64 - c));
	}

	function compress512Block(st: HashState, data: HashBytes, off: int32): void {
		let w0: uint64 = ((wordBE(data, off + 0) as uint64) << 32) | (wordBE(data, off + 4) as uint64);
		let w1: uint64 = ((wordBE(data, off + 8) as uint64) << 32) | (wordBE(data, off + 12) as uint64);
		let w2: uint64 = ((wordBE(data, off + 16) as uint64) << 32) | (wordBE(data, off + 20) as uint64);
		let w3: uint64 = ((wordBE(data, off + 24) as uint64) << 32) | (wordBE(data, off + 28) as uint64);
		let w4: uint64 = ((wordBE(data, off + 32) as uint64) << 32) | (wordBE(data, off + 36) as uint64);
		let w5: uint64 = ((wordBE(data, off + 40) as uint64) << 32) | (wordBE(data, off + 44) as uint64);
		let w6: uint64 = ((wordBE(data, off + 48) as uint64) << 32) | (wordBE(data, off + 52) as uint64);
		let w7: uint64 = ((wordBE(data, off + 56) as uint64) << 32) | (wordBE(data, off + 60) as uint64);
		let w8: uint64 = ((wordBE(data, off + 64) as uint64) << 32) | (wordBE(data, off + 68) as uint64);
		let w9: uint64 = ((wordBE(data, off + 72) as uint64) << 32) | (wordBE(data, off + 76) as uint64);
		let w10: uint64 = ((wordBE(data, off + 80) as uint64) << 32) | (wordBE(data, off + 84) as uint64);
		let w11: uint64 = ((wordBE(data, off + 88) as uint64) << 32) | (wordBE(data, off + 92) as uint64);
		let w12: uint64 = ((wordBE(data, off + 96) as uint64) << 32) | (wordBE(data, off + 100) as uint64);
		let w13: uint64 = ((wordBE(data, off + 104) as uint64) << 32) | (wordBE(data, off + 108) as uint64);
		let w14: uint64 = ((wordBE(data, off + 112) as uint64) << 32) | (wordBE(data, off + 116) as uint64);
		let w15: uint64 = ((wordBE(data, off + 120) as uint64) << 32) | (wordBE(data, off + 124) as uint64);
		let a: uint64 = ((st.state[0] as uint64) << 32) | (st.state[1] as uint64);
		let b: uint64 = ((st.state[2] as uint64) << 32) | (st.state[3] as uint64);
		let c: uint64 = ((st.state[4] as uint64) << 32) | (st.state[5] as uint64);
		let d: uint64 = ((st.state[6] as uint64) << 32) | (st.state[7] as uint64);
		let e: uint64 = ((st.state[8] as uint64) << 32) | (st.state[9] as uint64);
		let f: uint64 = ((st.state[10] as uint64) << 32) | (st.state[11] as uint64);
		let g: uint64 = ((st.state[12] as uint64) << 32) | (st.state[13] as uint64);
		let h: uint64 = ((st.state[14] as uint64) << 32) | (st.state[15] as uint64);
		let t: uint64 = 0;
		t = h + (rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)) + (g ^ (e & (f ^ g))) + 0x428a2f98d728ae22 + w0;
		d = d + t;
		h = t + (rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)) + ((a & (b | c)) | (b & c));
		t = g + (rotr64(d, 14) ^ rotr64(d, 18) ^ rotr64(d, 41)) + (f ^ (d & (e ^ f))) + 0x7137449123ef65cd + w1;
		c = c + t;
		g = t + (rotr64(h, 28) ^ rotr64(h, 34) ^ rotr64(h, 39)) + ((h & (a | b)) | (a & b));
		t = f + (rotr64(c, 14) ^ rotr64(c, 18) ^ rotr64(c, 41)) + (e ^ (c & (d ^ e))) + 0xb5c0fbcfec4d3b2f + w2;
		b = b + t;
		f = t + (rotr64(g, 28) ^ rotr64(g, 34) ^ rotr64(g, 39)) + ((g & (h | a)) | (h & a));
		t = e + (rotr64(b, 14) ^ rotr64(b, 18) ^ rotr64(b, 41)) + (d ^ (b & (c ^ d))) + 0xe9b5dba58189dbbc + w3;
		a = a + t;
		e = t + (rotr64(f, 28) ^ rotr64(f, 34) ^ rotr64(f, 39)) + ((f & (g | h)) | (g & h));
		t = d + (rotr64(a, 14) ^ rotr64(a, 18) ^ rotr64(a, 41)) + (c ^ (a & (b ^ c))) + 0x3956c25bf348b538 + w4;
		h = h + t;
		d = t + (rotr64(e, 28) ^ rotr64(e, 34) ^ rotr64(e, 39)) + ((e & (f | g)) | (f & g));
		t = c + (rotr64(h, 14) ^ rotr64(h, 18) ^ rotr64(h, 41)) + (b ^ (h & (a ^ b))) + 0x59f111f1b605d019 + w5;
		g = g + t;
		c = t + (rotr64(d, 28) ^ rotr64(d, 34) ^ rotr64(d, 39)) + ((d & (e | f)) | (e & f));
		t = b + (rotr64(g, 14) ^ rotr64(g, 18) ^ rotr64(g, 41)) + (a ^ (g & (h ^ a))) + 0x923f82a4af194f9b + w6;
		f = f + t;
		b = t + (rotr64(c, 28) ^ rotr64(c, 34) ^ rotr64(c, 39)) + ((c & (d | e)) | (d & e));
		t = a + (rotr64(f, 14) ^ rotr64(f, 18) ^ rotr64(f, 41)) + (h ^ (f & (g ^ h))) + 0xab1c5ed5da6d8118 + w7;
		e = e + t;
		a = t + (rotr64(b, 28) ^ rotr64(b, 34) ^ rotr64(b, 39)) + ((b & (c | d)) | (c & d));
		t = h + (rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)) + (g ^ (e & (f ^ g))) + 0xd807aa98a3030242 + w8;
		d = d + t;
		h = t + (rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)) + ((a & (b | c)) | (b & c));
		t = g + (rotr64(d, 14) ^ rotr64(d, 18) ^ rotr64(d, 41)) + (f ^ (d & (e ^ f))) + 0x12835b0145706fbe + w9;
		c = c + t;
		g = t + (rotr64(h, 28) ^ rotr64(h, 34) ^ rotr64(h, 39)) + ((h & (a | b)) | (a & b));
		t = f + (rotr64(c, 14) ^ rotr64(c, 18) ^ rotr64(c, 41)) + (e ^ (c & (d ^ e))) + 0x243185be4ee4b28c + w10;
		b = b + t;
		f = t + (rotr64(g, 28) ^ rotr64(g, 34) ^ rotr64(g, 39)) + ((g & (h | a)) | (h & a));
		t = e + (rotr64(b, 14) ^ rotr64(b, 18) ^ rotr64(b, 41)) + (d ^ (b & (c ^ d))) + 0x550c7dc3d5ffb4e2 + w11;
		a = a + t;
		e = t + (rotr64(f, 28) ^ rotr64(f, 34) ^ rotr64(f, 39)) + ((f & (g | h)) | (g & h));
		t = d + (rotr64(a, 14) ^ rotr64(a, 18) ^ rotr64(a, 41)) + (c ^ (a & (b ^ c))) + 0x72be5d74f27b896f + w12;
		h = h + t;
		d = t + (rotr64(e, 28) ^ rotr64(e, 34) ^ rotr64(e, 39)) + ((e & (f | g)) | (f & g));
		t = c + (rotr64(h, 14) ^ rotr64(h, 18) ^ rotr64(h, 41)) + (b ^ (h & (a ^ b))) + 0x80deb1fe3b1696b1 + w13;
		g = g + t;
		c = t + (rotr64(d, 28) ^ rotr64(d, 34) ^ rotr64(d, 39)) + ((d & (e | f)) | (e & f));
		t = b + (rotr64(g, 14) ^ rotr64(g, 18) ^ rotr64(g, 41)) + (a ^ (g & (h ^ a))) + 0x9bdc06a725c71235 + w14;
		f = f + t;
		b = t + (rotr64(c, 28) ^ rotr64(c, 34) ^ rotr64(c, 39)) + ((c & (d | e)) | (d & e));
		t = a + (rotr64(f, 14) ^ rotr64(f, 18) ^ rotr64(f, 41)) + (h ^ (f & (g ^ h))) + 0xc19bf174cf692694 + w15;
		e = e + t;
		a = t + (rotr64(b, 28) ^ rotr64(b, 34) ^ rotr64(b, 39)) + ((b & (c | d)) | (c & d));
		w0 = w0 + (rotr64(w14, 19) ^ rotr64(w14, 61) ^ (w14 >> 6)) + w9 + (rotr64(w1, 1) ^ rotr64(w1, 8) ^ (w1 >> 7));
		t = h + (rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)) + (g ^ (e & (f ^ g))) + 0xe49b69c19ef14ad2 + w0;
		d = d + t;
		h = t + (rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)) + ((a & (b | c)) | (b & c));
		w1 = w1 + (rotr64(w15, 19) ^ rotr64(w15, 61) ^ (w15 >> 6)) + w10 + (rotr64(w2, 1) ^ rotr64(w2, 8) ^ (w2 >> 7));
		t = g + (rotr64(d, 14) ^ rotr64(d, 18) ^ rotr64(d, 41)) + (f ^ (d & (e ^ f))) + 0xefbe4786384f25e3 + w1;
		c = c + t;
		g = t + (rotr64(h, 28) ^ rotr64(h, 34) ^ rotr64(h, 39)) + ((h & (a | b)) | (a & b));
		w2 = w2 + (rotr64(w0, 19) ^ rotr64(w0, 61) ^ (w0 >> 6)) + w11 + (rotr64(w3, 1) ^ rotr64(w3, 8) ^ (w3 >> 7));
		t = f + (rotr64(c, 14) ^ rotr64(c, 18) ^ rotr64(c, 41)) + (e ^ (c & (d ^ e))) + 0x0fc19dc68b8cd5b5 + w2;
		b = b + t;
		f = t + (rotr64(g, 28) ^ rotr64(g, 34) ^ rotr64(g, 39)) + ((g & (h | a)) | (h & a));
		w3 = w3 + (rotr64(w1, 19) ^ rotr64(w1, 61) ^ (w1 >> 6)) + w12 + (rotr64(w4, 1) ^ rotr64(w4, 8) ^ (w4 >> 7));
		t = e + (rotr64(b, 14) ^ rotr64(b, 18) ^ rotr64(b, 41)) + (d ^ (b & (c ^ d))) + 0x240ca1cc77ac9c65 + w3;
		a = a + t;
		e = t + (rotr64(f, 28) ^ rotr64(f, 34) ^ rotr64(f, 39)) + ((f & (g | h)) | (g & h));
		w4 = w4 + (rotr64(w2, 19) ^ rotr64(w2, 61) ^ (w2 >> 6)) + w13 + (rotr64(w5, 1) ^ rotr64(w5, 8) ^ (w5 >> 7));
		t = d + (rotr64(a, 14) ^ rotr64(a, 18) ^ rotr64(a, 41)) + (c ^ (a & (b ^ c))) + 0x2de92c6f592b0275 + w4;
		h = h + t;
		d = t + (rotr64(e, 28) ^ rotr64(e, 34) ^ rotr64(e, 39)) + ((e & (f | g)) | (f & g));
		w5 = w5 + (rotr64(w3, 19) ^ rotr64(w3, 61) ^ (w3 >> 6)) + w14 + (rotr64(w6, 1) ^ rotr64(w6, 8) ^ (w6 >> 7));
		t = c + (rotr64(h, 14) ^ rotr64(h, 18) ^ rotr64(h, 41)) + (b ^ (h & (a ^ b))) + 0x4a7484aa6ea6e483 + w5;
		g = g + t;
		c = t + (rotr64(d, 28) ^ rotr64(d, 34) ^ rotr64(d, 39)) + ((d & (e | f)) | (e & f));
		w6 = w6 + (rotr64(w4, 19) ^ rotr64(w4, 61) ^ (w4 >> 6)) + w15 + (rotr64(w7, 1) ^ rotr64(w7, 8) ^ (w7 >> 7));
		t = b + (rotr64(g, 14) ^ rotr64(g, 18) ^ rotr64(g, 41)) + (a ^ (g & (h ^ a))) + 0x5cb0a9dcbd41fbd4 + w6;
		f = f + t;
		b = t + (rotr64(c, 28) ^ rotr64(c, 34) ^ rotr64(c, 39)) + ((c & (d | e)) | (d & e));
		w7 = w7 + (rotr64(w5, 19) ^ rotr64(w5, 61) ^ (w5 >> 6)) + w0 + (rotr64(w8, 1) ^ rotr64(w8, 8) ^ (w8 >> 7));
		t = a + (rotr64(f, 14) ^ rotr64(f, 18) ^ rotr64(f, 41)) + (h ^ (f & (g ^ h))) + 0x76f988da831153b5 + w7;
		e = e + t;
		a = t + (rotr64(b, 28) ^ rotr64(b, 34) ^ rotr64(b, 39)) + ((b & (c | d)) | (c & d));
		w8 = w8 + (rotr64(w6, 19) ^ rotr64(w6, 61) ^ (w6 >> 6)) + w1 + (rotr64(w9, 1) ^ rotr64(w9, 8) ^ (w9 >> 7));
		t = h + (rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)) + (g ^ (e & (f ^ g))) + 0x983e5152ee66dfab + w8;
		d = d + t;
		h = t + (rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)) + ((a & (b | c)) | (b & c));
		w9 = w9 + (rotr64(w7, 19) ^ rotr64(w7, 61) ^ (w7 >> 6)) + w2 + (rotr64(w10, 1) ^ rotr64(w10, 8) ^ (w10 >> 7));
		t = g + (rotr64(d, 14) ^ rotr64(d, 18) ^ rotr64(d, 41)) + (f ^ (d & (e ^ f))) + 0xa831c66d2db43210 + w9;
		c = c + t;
		g = t + (rotr64(h, 28) ^ rotr64(h, 34) ^ rotr64(h, 39)) + ((h & (a | b)) | (a & b));
		w10 = w10 + (rotr64(w8, 19) ^ rotr64(w8, 61) ^ (w8 >> 6)) + w3 + (rotr64(w11, 1) ^ rotr64(w11, 8) ^ (w11 >> 7));
		t = f + (rotr64(c, 14) ^ rotr64(c, 18) ^ rotr64(c, 41)) + (e ^ (c & (d ^ e))) + 0xb00327c898fb213f + w10;
		b = b + t;
		f = t + (rotr64(g, 28) ^ rotr64(g, 34) ^ rotr64(g, 39)) + ((g & (h | a)) | (h & a));
		w11 = w11 + (rotr64(w9, 19) ^ rotr64(w9, 61) ^ (w9 >> 6)) + w4 + (rotr64(w12, 1) ^ rotr64(w12, 8) ^ (w12 >> 7));
		t = e + (rotr64(b, 14) ^ rotr64(b, 18) ^ rotr64(b, 41)) + (d ^ (b & (c ^ d))) + 0xbf597fc7beef0ee4 + w11;
		a = a + t;
		e = t + (rotr64(f, 28) ^ rotr64(f, 34) ^ rotr64(f, 39)) + ((f & (g | h)) | (g & h));
		w12 = w12 + (rotr64(w10, 19) ^ rotr64(w10, 61) ^ (w10 >> 6)) + w5 + (rotr64(w13, 1) ^ rotr64(w13, 8) ^ (w13 >> 7));
		t = d + (rotr64(a, 14) ^ rotr64(a, 18) ^ rotr64(a, 41)) + (c ^ (a & (b ^ c))) + 0xc6e00bf33da88fc2 + w12;
		h = h + t;
		d = t + (rotr64(e, 28) ^ rotr64(e, 34) ^ rotr64(e, 39)) + ((e & (f | g)) | (f & g));
		w13 = w13 + (rotr64(w11, 19) ^ rotr64(w11, 61) ^ (w11 >> 6)) + w6 + (rotr64(w14, 1) ^ rotr64(w14, 8) ^ (w14 >> 7));
		t = c + (rotr64(h, 14) ^ rotr64(h, 18) ^ rotr64(h, 41)) + (b ^ (h & (a ^ b))) + 0xd5a79147930aa725 + w13;
		g = g + t;
		c = t + (rotr64(d, 28) ^ rotr64(d, 34) ^ rotr64(d, 39)) + ((d & (e | f)) | (e & f));
		w14 = w14 + (rotr64(w12, 19) ^ rotr64(w12, 61) ^ (w12 >> 6)) + w7 + (rotr64(w15, 1) ^ rotr64(w15, 8) ^ (w15 >> 7));
		t = b + (rotr64(g, 14) ^ rotr64(g, 18) ^ rotr64(g, 41)) + (a ^ (g & (h ^ a))) + 0x06ca6351e003826f + w14;
		f = f + t;
		b = t + (rotr64(c, 28) ^ rotr64(c, 34) ^ rotr64(c, 39)) + ((c & (d | e)) | (d & e));
		w15 = w15 + (rotr64(w13, 19) ^ rotr64(w13, 61) ^ (w13 >> 6)) + w8 + (rotr64(w0, 1) ^ rotr64(w0, 8) ^ (w0 >> 7));
		t = a + (rotr64(f, 14) ^ rotr64(f, 18) ^ rotr64(f, 41)) + (h ^ (f & (g ^ h))) + 0x142929670a0e6e70 + w15;
		e = e + t;
		a = t + (rotr64(b, 28) ^ rotr64(b, 34) ^ rotr64(b, 39)) + ((b & (c | d)) | (c & d));
		w0 = w0 + (rotr64(w14, 19) ^ rotr64(w14, 61) ^ (w14 >> 6)) + w9 + (rotr64(w1, 1) ^ rotr64(w1, 8) ^ (w1 >> 7));
		t = h + (rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)) + (g ^ (e & (f ^ g))) + 0x27b70a8546d22ffc + w0;
		d = d + t;
		h = t + (rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)) + ((a & (b | c)) | (b & c));
		w1 = w1 + (rotr64(w15, 19) ^ rotr64(w15, 61) ^ (w15 >> 6)) + w10 + (rotr64(w2, 1) ^ rotr64(w2, 8) ^ (w2 >> 7));
		t = g + (rotr64(d, 14) ^ rotr64(d, 18) ^ rotr64(d, 41)) + (f ^ (d & (e ^ f))) + 0x2e1b21385c26c926 + w1;
		c = c + t;
		g = t + (rotr64(h, 28) ^ rotr64(h, 34) ^ rotr64(h, 39)) + ((h & (a | b)) | (a & b));
		w2 = w2 + (rotr64(w0, 19) ^ rotr64(w0, 61) ^ (w0 >> 6)) + w11 + (rotr64(w3, 1) ^ rotr64(w3, 8) ^ (w3 >> 7));
		t = f + (rotr64(c, 14) ^ rotr64(c, 18) ^ rotr64(c, 41)) + (e ^ (c & (d ^ e))) + 0x4d2c6dfc5ac42aed + w2;
		b = b + t;
		f = t + (rotr64(g, 28) ^ rotr64(g, 34) ^ rotr64(g, 39)) + ((g & (h | a)) | (h & a));
		w3 = w3 + (rotr64(w1, 19) ^ rotr64(w1, 61) ^ (w1 >> 6)) + w12 + (rotr64(w4, 1) ^ rotr64(w4, 8) ^ (w4 >> 7));
		t = e + (rotr64(b, 14) ^ rotr64(b, 18) ^ rotr64(b, 41)) + (d ^ (b & (c ^ d))) + 0x53380d139d95b3df + w3;
		a = a + t;
		e = t + (rotr64(f, 28) ^ rotr64(f, 34) ^ rotr64(f, 39)) + ((f & (g | h)) | (g & h));
		w4 = w4 + (rotr64(w2, 19) ^ rotr64(w2, 61) ^ (w2 >> 6)) + w13 + (rotr64(w5, 1) ^ rotr64(w5, 8) ^ (w5 >> 7));
		t = d + (rotr64(a, 14) ^ rotr64(a, 18) ^ rotr64(a, 41)) + (c ^ (a & (b ^ c))) + 0x650a73548baf63de + w4;
		h = h + t;
		d = t + (rotr64(e, 28) ^ rotr64(e, 34) ^ rotr64(e, 39)) + ((e & (f | g)) | (f & g));
		w5 = w5 + (rotr64(w3, 19) ^ rotr64(w3, 61) ^ (w3 >> 6)) + w14 + (rotr64(w6, 1) ^ rotr64(w6, 8) ^ (w6 >> 7));
		t = c + (rotr64(h, 14) ^ rotr64(h, 18) ^ rotr64(h, 41)) + (b ^ (h & (a ^ b))) + 0x766a0abb3c77b2a8 + w5;
		g = g + t;
		c = t + (rotr64(d, 28) ^ rotr64(d, 34) ^ rotr64(d, 39)) + ((d & (e | f)) | (e & f));
		w6 = w6 + (rotr64(w4, 19) ^ rotr64(w4, 61) ^ (w4 >> 6)) + w15 + (rotr64(w7, 1) ^ rotr64(w7, 8) ^ (w7 >> 7));
		t = b + (rotr64(g, 14) ^ rotr64(g, 18) ^ rotr64(g, 41)) + (a ^ (g & (h ^ a))) + 0x81c2c92e47edaee6 + w6;
		f = f + t;
		b = t + (rotr64(c, 28) ^ rotr64(c, 34) ^ rotr64(c, 39)) + ((c & (d | e)) | (d & e));
		w7 = w7 + (rotr64(w5, 19) ^ rotr64(w5, 61) ^ (w5 >> 6)) + w0 + (rotr64(w8, 1) ^ rotr64(w8, 8) ^ (w8 >> 7));
		t = a + (rotr64(f, 14) ^ rotr64(f, 18) ^ rotr64(f, 41)) + (h ^ (f & (g ^ h))) + 0x92722c851482353b + w7;
		e = e + t;
		a = t + (rotr64(b, 28) ^ rotr64(b, 34) ^ rotr64(b, 39)) + ((b & (c | d)) | (c & d));
		w8 = w8 + (rotr64(w6, 19) ^ rotr64(w6, 61) ^ (w6 >> 6)) + w1 + (rotr64(w9, 1) ^ rotr64(w9, 8) ^ (w9 >> 7));
		t = h + (rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)) + (g ^ (e & (f ^ g))) + 0xa2bfe8a14cf10364 + w8;
		d = d + t;
		h = t + (rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)) + ((a & (b | c)) | (b & c));
		w9 = w9 + (rotr64(w7, 19) ^ rotr64(w7, 61) ^ (w7 >> 6)) + w2 + (rotr64(w10, 1) ^ rotr64(w10, 8) ^ (w10 >> 7));
		t = g + (rotr64(d, 14) ^ rotr64(d, 18) ^ rotr64(d, 41)) + (f ^ (d & (e ^ f))) + 0xa81a664bbc423001 + w9;
		c = c + t;
		g = t + (rotr64(h, 28) ^ rotr64(h, 34) ^ rotr64(h, 39)) + ((h & (a | b)) | (a & b));
		w10 = w10 + (rotr64(w8, 19) ^ rotr64(w8, 61) ^ (w8 >> 6)) + w3 + (rotr64(w11, 1) ^ rotr64(w11, 8) ^ (w11 >> 7));
		t = f + (rotr64(c, 14) ^ rotr64(c, 18) ^ rotr64(c, 41)) + (e ^ (c & (d ^ e))) + 0xc24b8b70d0f89791 + w10;
		b = b + t;
		f = t + (rotr64(g, 28) ^ rotr64(g, 34) ^ rotr64(g, 39)) + ((g & (h | a)) | (h & a));
		w11 = w11 + (rotr64(w9, 19) ^ rotr64(w9, 61) ^ (w9 >> 6)) + w4 + (rotr64(w12, 1) ^ rotr64(w12, 8) ^ (w12 >> 7));
		t = e + (rotr64(b, 14) ^ rotr64(b, 18) ^ rotr64(b, 41)) + (d ^ (b & (c ^ d))) + 0xc76c51a30654be30 + w11;
		a = a + t;
		e = t + (rotr64(f, 28) ^ rotr64(f, 34) ^ rotr64(f, 39)) + ((f & (g | h)) | (g & h));
		w12 = w12 + (rotr64(w10, 19) ^ rotr64(w10, 61) ^ (w10 >> 6)) + w5 + (rotr64(w13, 1) ^ rotr64(w13, 8) ^ (w13 >> 7));
		t = d + (rotr64(a, 14) ^ rotr64(a, 18) ^ rotr64(a, 41)) + (c ^ (a & (b ^ c))) + 0xd192e819d6ef5218 + w12;
		h = h + t;
		d = t + (rotr64(e, 28) ^ rotr64(e, 34) ^ rotr64(e, 39)) + ((e & (f | g)) | (f & g));
		w13 = w13 + (rotr64(w11, 19) ^ rotr64(w11, 61) ^ (w11 >> 6)) + w6 + (rotr64(w14, 1) ^ rotr64(w14, 8) ^ (w14 >> 7));
		t = c + (rotr64(h, 14) ^ rotr64(h, 18) ^ rotr64(h, 41)) + (b ^ (h & (a ^ b))) + 0xd69906245565a910 + w13;
		g = g + t;
		c = t + (rotr64(d, 28) ^ rotr64(d, 34) ^ rotr64(d, 39)) + ((d & (e | f)) | (e & f));
		w14 = w14 + (rotr64(w12, 19) ^ rotr64(w12, 61) ^ (w12 >> 6)) + w7 + (rotr64(w15, 1) ^ rotr64(w15, 8) ^ (w15 >> 7));
		t = b + (rotr64(g, 14) ^ rotr64(g, 18) ^ rotr64(g, 41)) + (a ^ (g & (h ^ a))) + 0xf40e35855771202a + w14;
		f = f + t;
		b = t + (rotr64(c, 28) ^ rotr64(c, 34) ^ rotr64(c, 39)) + ((c & (d | e)) | (d & e));
		w15 = w15 + (rotr64(w13, 19) ^ rotr64(w13, 61) ^ (w13 >> 6)) + w8 + (rotr64(w0, 1) ^ rotr64(w0, 8) ^ (w0 >> 7));
		t = a + (rotr64(f, 14) ^ rotr64(f, 18) ^ rotr64(f, 41)) + (h ^ (f & (g ^ h))) + 0x106aa07032bbd1b8 + w15;
		e = e + t;
		a = t + (rotr64(b, 28) ^ rotr64(b, 34) ^ rotr64(b, 39)) + ((b & (c | d)) | (c & d));
		w0 = w0 + (rotr64(w14, 19) ^ rotr64(w14, 61) ^ (w14 >> 6)) + w9 + (rotr64(w1, 1) ^ rotr64(w1, 8) ^ (w1 >> 7));
		t = h + (rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)) + (g ^ (e & (f ^ g))) + 0x19a4c116b8d2d0c8 + w0;
		d = d + t;
		h = t + (rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)) + ((a & (b | c)) | (b & c));
		w1 = w1 + (rotr64(w15, 19) ^ rotr64(w15, 61) ^ (w15 >> 6)) + w10 + (rotr64(w2, 1) ^ rotr64(w2, 8) ^ (w2 >> 7));
		t = g + (rotr64(d, 14) ^ rotr64(d, 18) ^ rotr64(d, 41)) + (f ^ (d & (e ^ f))) + 0x1e376c085141ab53 + w1;
		c = c + t;
		g = t + (rotr64(h, 28) ^ rotr64(h, 34) ^ rotr64(h, 39)) + ((h & (a | b)) | (a & b));
		w2 = w2 + (rotr64(w0, 19) ^ rotr64(w0, 61) ^ (w0 >> 6)) + w11 + (rotr64(w3, 1) ^ rotr64(w3, 8) ^ (w3 >> 7));
		t = f + (rotr64(c, 14) ^ rotr64(c, 18) ^ rotr64(c, 41)) + (e ^ (c & (d ^ e))) + 0x2748774cdf8eeb99 + w2;
		b = b + t;
		f = t + (rotr64(g, 28) ^ rotr64(g, 34) ^ rotr64(g, 39)) + ((g & (h | a)) | (h & a));
		w3 = w3 + (rotr64(w1, 19) ^ rotr64(w1, 61) ^ (w1 >> 6)) + w12 + (rotr64(w4, 1) ^ rotr64(w4, 8) ^ (w4 >> 7));
		t = e + (rotr64(b, 14) ^ rotr64(b, 18) ^ rotr64(b, 41)) + (d ^ (b & (c ^ d))) + 0x34b0bcb5e19b48a8 + w3;
		a = a + t;
		e = t + (rotr64(f, 28) ^ rotr64(f, 34) ^ rotr64(f, 39)) + ((f & (g | h)) | (g & h));
		w4 = w4 + (rotr64(w2, 19) ^ rotr64(w2, 61) ^ (w2 >> 6)) + w13 + (rotr64(w5, 1) ^ rotr64(w5, 8) ^ (w5 >> 7));
		t = d + (rotr64(a, 14) ^ rotr64(a, 18) ^ rotr64(a, 41)) + (c ^ (a & (b ^ c))) + 0x391c0cb3c5c95a63 + w4;
		h = h + t;
		d = t + (rotr64(e, 28) ^ rotr64(e, 34) ^ rotr64(e, 39)) + ((e & (f | g)) | (f & g));
		w5 = w5 + (rotr64(w3, 19) ^ rotr64(w3, 61) ^ (w3 >> 6)) + w14 + (rotr64(w6, 1) ^ rotr64(w6, 8) ^ (w6 >> 7));
		t = c + (rotr64(h, 14) ^ rotr64(h, 18) ^ rotr64(h, 41)) + (b ^ (h & (a ^ b))) + 0x4ed8aa4ae3418acb + w5;
		g = g + t;
		c = t + (rotr64(d, 28) ^ rotr64(d, 34) ^ rotr64(d, 39)) + ((d & (e | f)) | (e & f));
		w6 = w6 + (rotr64(w4, 19) ^ rotr64(w4, 61) ^ (w4 >> 6)) + w15 + (rotr64(w7, 1) ^ rotr64(w7, 8) ^ (w7 >> 7));
		t = b + (rotr64(g, 14) ^ rotr64(g, 18) ^ rotr64(g, 41)) + (a ^ (g & (h ^ a))) + 0x5b9cca4f7763e373 + w6;
		f = f + t;
		b = t + (rotr64(c, 28) ^ rotr64(c, 34) ^ rotr64(c, 39)) + ((c & (d | e)) | (d & e));
		w7 = w7 + (rotr64(w5, 19) ^ rotr64(w5, 61) ^ (w5 >> 6)) + w0 + (rotr64(w8, 1) ^ rotr64(w8, 8) ^ (w8 >> 7));
		t = a + (rotr64(f, 14) ^ rotr64(f, 18) ^ rotr64(f, 41)) + (h ^ (f & (g ^ h))) + 0x682e6ff3d6b2b8a3 + w7;
		e = e + t;
		a = t + (rotr64(b, 28) ^ rotr64(b, 34) ^ rotr64(b, 39)) + ((b & (c | d)) | (c & d));
		w8 = w8 + (rotr64(w6, 19) ^ rotr64(w6, 61) ^ (w6 >> 6)) + w1 + (rotr64(w9, 1) ^ rotr64(w9, 8) ^ (w9 >> 7));
		t = h + (rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)) + (g ^ (e & (f ^ g))) + 0x748f82ee5defb2fc + w8;
		d = d + t;
		h = t + (rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)) + ((a & (b | c)) | (b & c));
		w9 = w9 + (rotr64(w7, 19) ^ rotr64(w7, 61) ^ (w7 >> 6)) + w2 + (rotr64(w10, 1) ^ rotr64(w10, 8) ^ (w10 >> 7));
		t = g + (rotr64(d, 14) ^ rotr64(d, 18) ^ rotr64(d, 41)) + (f ^ (d & (e ^ f))) + 0x78a5636f43172f60 + w9;
		c = c + t;
		g = t + (rotr64(h, 28) ^ rotr64(h, 34) ^ rotr64(h, 39)) + ((h & (a | b)) | (a & b));
		w10 = w10 + (rotr64(w8, 19) ^ rotr64(w8, 61) ^ (w8 >> 6)) + w3 + (rotr64(w11, 1) ^ rotr64(w11, 8) ^ (w11 >> 7));
		t = f + (rotr64(c, 14) ^ rotr64(c, 18) ^ rotr64(c, 41)) + (e ^ (c & (d ^ e))) + 0x84c87814a1f0ab72 + w10;
		b = b + t;
		f = t + (rotr64(g, 28) ^ rotr64(g, 34) ^ rotr64(g, 39)) + ((g & (h | a)) | (h & a));
		w11 = w11 + (rotr64(w9, 19) ^ rotr64(w9, 61) ^ (w9 >> 6)) + w4 + (rotr64(w12, 1) ^ rotr64(w12, 8) ^ (w12 >> 7));
		t = e + (rotr64(b, 14) ^ rotr64(b, 18) ^ rotr64(b, 41)) + (d ^ (b & (c ^ d))) + 0x8cc702081a6439ec + w11;
		a = a + t;
		e = t + (rotr64(f, 28) ^ rotr64(f, 34) ^ rotr64(f, 39)) + ((f & (g | h)) | (g & h));
		w12 = w12 + (rotr64(w10, 19) ^ rotr64(w10, 61) ^ (w10 >> 6)) + w5 + (rotr64(w13, 1) ^ rotr64(w13, 8) ^ (w13 >> 7));
		t = d + (rotr64(a, 14) ^ rotr64(a, 18) ^ rotr64(a, 41)) + (c ^ (a & (b ^ c))) + 0x90befffa23631e28 + w12;
		h = h + t;
		d = t + (rotr64(e, 28) ^ rotr64(e, 34) ^ rotr64(e, 39)) + ((e & (f | g)) | (f & g));
		w13 = w13 + (rotr64(w11, 19) ^ rotr64(w11, 61) ^ (w11 >> 6)) + w6 + (rotr64(w14, 1) ^ rotr64(w14, 8) ^ (w14 >> 7));
		t = c + (rotr64(h, 14) ^ rotr64(h, 18) ^ rotr64(h, 41)) + (b ^ (h & (a ^ b))) + 0xa4506cebde82bde9 + w13;
		g = g + t;
		c = t + (rotr64(d, 28) ^ rotr64(d, 34) ^ rotr64(d, 39)) + ((d & (e | f)) | (e & f));
		w14 = w14 + (rotr64(w12, 19) ^ rotr64(w12, 61) ^ (w12 >> 6)) + w7 + (rotr64(w15, 1) ^ rotr64(w15, 8) ^ (w15 >> 7));
		t = b + (rotr64(g, 14) ^ rotr64(g, 18) ^ rotr64(g, 41)) + (a ^ (g & (h ^ a))) + 0xbef9a3f7b2c67915 + w14;
		f = f + t;
		b = t + (rotr64(c, 28) ^ rotr64(c, 34) ^ rotr64(c, 39)) + ((c & (d | e)) | (d & e));
		w15 = w15 + (rotr64(w13, 19) ^ rotr64(w13, 61) ^ (w13 >> 6)) + w8 + (rotr64(w0, 1) ^ rotr64(w0, 8) ^ (w0 >> 7));
		t = a + (rotr64(f, 14) ^ rotr64(f, 18) ^ rotr64(f, 41)) + (h ^ (f & (g ^ h))) + 0xc67178f2e372532b + w15;
		e = e + t;
		a = t + (rotr64(b, 28) ^ rotr64(b, 34) ^ rotr64(b, 39)) + ((b & (c | d)) | (c & d));
		w0 = w0 + (rotr64(w14, 19) ^ rotr64(w14, 61) ^ (w14 >> 6)) + w9 + (rotr64(w1, 1) ^ rotr64(w1, 8) ^ (w1 >> 7));
		t = h + (rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)) + (g ^ (e & (f ^ g))) + 0xca273eceea26619c + w0;
		d = d + t;
		h = t + (rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)) + ((a & (b | c)) | (b & c));
		w1 = w1 + (rotr64(w15, 19) ^ rotr64(w15, 61) ^ (w15 >> 6)) + w10 + (rotr64(w2, 1) ^ rotr64(w2, 8) ^ (w2 >> 7));
		t = g + (rotr64(d, 14) ^ rotr64(d, 18) ^ rotr64(d, 41)) + (f ^ (d & (e ^ f))) + 0xd186b8c721c0c207 + w1;
		c = c + t;
		g = t + (rotr64(h, 28) ^ rotr64(h, 34) ^ rotr64(h, 39)) + ((h & (a | b)) | (a & b));
		w2 = w2 + (rotr64(w0, 19) ^ rotr64(w0, 61) ^ (w0 >> 6)) + w11 + (rotr64(w3, 1) ^ rotr64(w3, 8) ^ (w3 >> 7));
		t = f + (rotr64(c, 14) ^ rotr64(c, 18) ^ rotr64(c, 41)) + (e ^ (c & (d ^ e))) + 0xeada7dd6cde0eb1e + w2;
		b = b + t;
		f = t + (rotr64(g, 28) ^ rotr64(g, 34) ^ rotr64(g, 39)) + ((g & (h | a)) | (h & a));
		w3 = w3 + (rotr64(w1, 19) ^ rotr64(w1, 61) ^ (w1 >> 6)) + w12 + (rotr64(w4, 1) ^ rotr64(w4, 8) ^ (w4 >> 7));
		t = e + (rotr64(b, 14) ^ rotr64(b, 18) ^ rotr64(b, 41)) + (d ^ (b & (c ^ d))) + 0xf57d4f7fee6ed178 + w3;
		a = a + t;
		e = t + (rotr64(f, 28) ^ rotr64(f, 34) ^ rotr64(f, 39)) + ((f & (g | h)) | (g & h));
		w4 = w4 + (rotr64(w2, 19) ^ rotr64(w2, 61) ^ (w2 >> 6)) + w13 + (rotr64(w5, 1) ^ rotr64(w5, 8) ^ (w5 >> 7));
		t = d + (rotr64(a, 14) ^ rotr64(a, 18) ^ rotr64(a, 41)) + (c ^ (a & (b ^ c))) + 0x06f067aa72176fba + w4;
		h = h + t;
		d = t + (rotr64(e, 28) ^ rotr64(e, 34) ^ rotr64(e, 39)) + ((e & (f | g)) | (f & g));
		w5 = w5 + (rotr64(w3, 19) ^ rotr64(w3, 61) ^ (w3 >> 6)) + w14 + (rotr64(w6, 1) ^ rotr64(w6, 8) ^ (w6 >> 7));
		t = c + (rotr64(h, 14) ^ rotr64(h, 18) ^ rotr64(h, 41)) + (b ^ (h & (a ^ b))) + 0x0a637dc5a2c898a6 + w5;
		g = g + t;
		c = t + (rotr64(d, 28) ^ rotr64(d, 34) ^ rotr64(d, 39)) + ((d & (e | f)) | (e & f));
		w6 = w6 + (rotr64(w4, 19) ^ rotr64(w4, 61) ^ (w4 >> 6)) + w15 + (rotr64(w7, 1) ^ rotr64(w7, 8) ^ (w7 >> 7));
		t = b + (rotr64(g, 14) ^ rotr64(g, 18) ^ rotr64(g, 41)) + (a ^ (g & (h ^ a))) + 0x113f9804bef90dae + w6;
		f = f + t;
		b = t + (rotr64(c, 28) ^ rotr64(c, 34) ^ rotr64(c, 39)) + ((c & (d | e)) | (d & e));
		w7 = w7 + (rotr64(w5, 19) ^ rotr64(w5, 61) ^ (w5 >> 6)) + w0 + (rotr64(w8, 1) ^ rotr64(w8, 8) ^ (w8 >> 7));
		t = a + (rotr64(f, 14) ^ rotr64(f, 18) ^ rotr64(f, 41)) + (h ^ (f & (g ^ h))) + 0x1b710b35131c471b + w7;
		e = e + t;
		a = t + (rotr64(b, 28) ^ rotr64(b, 34) ^ rotr64(b, 39)) + ((b & (c | d)) | (c & d));
		w8 = w8 + (rotr64(w6, 19) ^ rotr64(w6, 61) ^ (w6 >> 6)) + w1 + (rotr64(w9, 1) ^ rotr64(w9, 8) ^ (w9 >> 7));
		t = h + (rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41)) + (g ^ (e & (f ^ g))) + 0x28db77f523047d84 + w8;
		d = d + t;
		h = t + (rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39)) + ((a & (b | c)) | (b & c));
		w9 = w9 + (rotr64(w7, 19) ^ rotr64(w7, 61) ^ (w7 >> 6)) + w2 + (rotr64(w10, 1) ^ rotr64(w10, 8) ^ (w10 >> 7));
		t = g + (rotr64(d, 14) ^ rotr64(d, 18) ^ rotr64(d, 41)) + (f ^ (d & (e ^ f))) + 0x32caab7b40c72493 + w9;
		c = c + t;
		g = t + (rotr64(h, 28) ^ rotr64(h, 34) ^ rotr64(h, 39)) + ((h & (a | b)) | (a & b));
		w10 = w10 + (rotr64(w8, 19) ^ rotr64(w8, 61) ^ (w8 >> 6)) + w3 + (rotr64(w11, 1) ^ rotr64(w11, 8) ^ (w11 >> 7));
		t = f + (rotr64(c, 14) ^ rotr64(c, 18) ^ rotr64(c, 41)) + (e ^ (c & (d ^ e))) + 0x3c9ebe0a15c9bebc + w10;
		b = b + t;
		f = t + (rotr64(g, 28) ^ rotr64(g, 34) ^ rotr64(g, 39)) + ((g & (h | a)) | (h & a));
		w11 = w11 + (rotr64(w9, 19) ^ rotr64(w9, 61) ^ (w9 >> 6)) + w4 + (rotr64(w12, 1) ^ rotr64(w12, 8) ^ (w12 >> 7));
		t = e + (rotr64(b, 14) ^ rotr64(b, 18) ^ rotr64(b, 41)) + (d ^ (b & (c ^ d))) + 0x431d67c49c100d4c + w11;
		a = a + t;
		e = t + (rotr64(f, 28) ^ rotr64(f, 34) ^ rotr64(f, 39)) + ((f & (g | h)) | (g & h));
		w12 = w12 + (rotr64(w10, 19) ^ rotr64(w10, 61) ^ (w10 >> 6)) + w5 + (rotr64(w13, 1) ^ rotr64(w13, 8) ^ (w13 >> 7));
		t = d + (rotr64(a, 14) ^ rotr64(a, 18) ^ rotr64(a, 41)) + (c ^ (a & (b ^ c))) + 0x4cc5d4becb3e42b6 + w12;
		h = h + t;
		d = t + (rotr64(e, 28) ^ rotr64(e, 34) ^ rotr64(e, 39)) + ((e & (f | g)) | (f & g));
		w13 = w13 + (rotr64(w11, 19) ^ rotr64(w11, 61) ^ (w11 >> 6)) + w6 + (rotr64(w14, 1) ^ rotr64(w14, 8) ^ (w14 >> 7));
		t = c + (rotr64(h, 14) ^ rotr64(h, 18) ^ rotr64(h, 41)) + (b ^ (h & (a ^ b))) + 0x597f299cfc657e2a + w13;
		g = g + t;
		c = t + (rotr64(d, 28) ^ rotr64(d, 34) ^ rotr64(d, 39)) + ((d & (e | f)) | (e & f));
		w14 = w14 + (rotr64(w12, 19) ^ rotr64(w12, 61) ^ (w12 >> 6)) + w7 + (rotr64(w15, 1) ^ rotr64(w15, 8) ^ (w15 >> 7));
		t = b + (rotr64(g, 14) ^ rotr64(g, 18) ^ rotr64(g, 41)) + (a ^ (g & (h ^ a))) + 0x5fcb6fab3ad6faec + w14;
		f = f + t;
		b = t + (rotr64(c, 28) ^ rotr64(c, 34) ^ rotr64(c, 39)) + ((c & (d | e)) | (d & e));
		w15 = w15 + (rotr64(w13, 19) ^ rotr64(w13, 61) ^ (w13 >> 6)) + w8 + (rotr64(w0, 1) ^ rotr64(w0, 8) ^ (w0 >> 7));
		t = a + (rotr64(f, 14) ^ rotr64(f, 18) ^ rotr64(f, 41)) + (h ^ (f & (g ^ h))) + 0x6c44198c4a475817 + w15;
		e = e + t;
		a = t + (rotr64(b, 28) ^ rotr64(b, 34) ^ rotr64(b, 39)) + ((b & (c | d)) | (c & d));
		const sa = (((st.state[0] as uint64) << 32) | (st.state[1] as uint64)) + a;
		st.state[0] = (sa >> 32) as uint32;
		st.state[1] = (sa & 0xffffffff) as uint32;
		const sb = (((st.state[2] as uint64) << 32) | (st.state[3] as uint64)) + b;
		st.state[2] = (sb >> 32) as uint32;
		st.state[3] = (sb & 0xffffffff) as uint32;
		const sc = (((st.state[4] as uint64) << 32) | (st.state[5] as uint64)) + c;
		st.state[4] = (sc >> 32) as uint32;
		st.state[5] = (sc & 0xffffffff) as uint32;
		const sd = (((st.state[6] as uint64) << 32) | (st.state[7] as uint64)) + d;
		st.state[6] = (sd >> 32) as uint32;
		st.state[7] = (sd & 0xffffffff) as uint32;
		const se = (((st.state[8] as uint64) << 32) | (st.state[9] as uint64)) + e;
		st.state[8] = (se >> 32) as uint32;
		st.state[9] = (se & 0xffffffff) as uint32;
		const sf = (((st.state[10] as uint64) << 32) | (st.state[11] as uint64)) + f;
		st.state[10] = (sf >> 32) as uint32;
		st.state[11] = (sf & 0xffffffff) as uint32;
		const sg = (((st.state[12] as uint64) << 32) | (st.state[13] as uint64)) + g;
		st.state[12] = (sg >> 32) as uint32;
		st.state[13] = (sg & 0xffffffff) as uint32;
		const sh = (((st.state[14] as uint64) << 32) | (st.state[15] as uint64)) + h;
		st.state[14] = (sh >> 32) as uint32;
		st.state[15] = (sh & 0xffffffff) as uint32;
	}
}

when (js) {
	import { load32BE } from "./endian";

	function compress256Block(h: HashState, data: Readonly<uint8[]>, off: int32): void {
		for (let i = 0; i < 16; i++) h.schedule[i] = load32(data, off + i * 4);
		for (let i = 16; i < 64; i++) {
			const w15 = h.schedule[i - 15];
			const w2 = h.schedule[i - 2];
			const s0 = rotr(w15, 7) ^ rotr(w15, 18) ^ (w15 >> 3);
			const s1 = rotr(w2, 17) ^ rotr(w2, 19) ^ (w2 >> 10);
			h.schedule[i] = s1 + h.schedule[i - 7] + s0 + h.schedule[i - 16];
		}
		let a = h.state[0];
		let b = h.state[1];
		let c = h.state[2];
		let d = h.state[3];
		let e = h.state[4];
		let f = h.state[5];
		let g = h.state[6];
		let hh = h.state[7];
		for (let i = 0; i < 64; i++) {
			const sigma1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
			const t1 = hh + sigma1 + ((e & f) ^ (~e & g)) + k256[i] + h.schedule[i];
			const sigma0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
			const t2 = sigma0 + ((a & b) ^ (a & c) ^ (b & c));
			hh = g;
			g = f;
			f = e;
			e = d + t1;
			d = c;
			c = b;
			b = a;
			a = t1 + t2;
		}
		h.state[0] = h.state[0] + a;
		h.state[1] = h.state[1] + b;
		h.state[2] = h.state[2] + c;
		h.state[3] = h.state[3] + d;
		h.state[4] = h.state[4] + e;
		h.state[5] = h.state[5] + f;
		h.state[6] = h.state[6] + g;
		h.state[7] = h.state[7] + hh;
	}

	// A 64-bit word is two uint32 halves; each helper returns the high or the low half of one operation.
	function rotrHigh(hi: uint32, lo: uint32, n: uint32): uint32 {
		if (n < 32) return (hi >> n) | (lo << (32 - n));
		if (n == 32) return lo;
		return (lo >> (n - 32)) | (hi << (64 - n));
	}

	function rotrLow(hi: uint32, lo: uint32, n: uint32): uint32 {
		if (n < 32) return (hi << (32 - n)) | (lo >> n);
		if (n == 32) return hi;
		return (hi >> (n - 32)) | (lo << (64 - n));
	}

	function shrLow(hi: uint32, lo: uint32, n: uint32): uint32 {
		return (hi << (32 - n)) | (lo >> n);
	}

	function carry(sum: uint32, addend: uint32): uint32 {
		return sum < addend ? 1 : 0;
	}

	function compress512Block(h: HashState, data: Readonly<uint8[]>, off: int32): void {
		for (let i = 0; i < 32; i++) h.schedule[i] = load32(data, off + i * 4);
		for (let i = 16; i < 80; i++) {
			const w15h = h.schedule[(i - 15) * 2];
			const w15l = h.schedule[(i - 15) * 2 + 1];
			const s0h = rotrHigh(w15h, w15l, 1) ^ rotrHigh(w15h, w15l, 8) ^ (w15h >> 7);
			const s0l = rotrLow(w15h, w15l, 1) ^ rotrLow(w15h, w15l, 8) ^ shrLow(w15h, w15l, 7);
			const w2h = h.schedule[(i - 2) * 2];
			const w2l = h.schedule[(i - 2) * 2 + 1];
			const s1h = rotrHigh(w2h, w2l, 19) ^ rotrHigh(w2h, w2l, 61) ^ (w2h >> 6);
			const s1l = rotrLow(w2h, w2l, 19) ^ rotrLow(w2h, w2l, 61) ^ shrLow(w2h, w2l, 6);
			let lo = s0l + s1l;
			let hi = s0h + s1h + carry(lo, s0l);
			const x7l = h.schedule[(i - 7) * 2 + 1];
			const l7 = lo + x7l;
			hi = hi + h.schedule[(i - 7) * 2] + carry(l7, lo);
			lo = l7;
			const x16l = h.schedule[(i - 16) * 2 + 1];
			const l16 = lo + x16l;
			hi = hi + h.schedule[(i - 16) * 2] + carry(l16, lo);
			h.schedule[i * 2] = hi;
			h.schedule[i * 2 + 1] = l16;
		}
		let ah = h.state[0];
		let al = h.state[1];
		let bh = h.state[2];
		let bl = h.state[3];
		let ch = h.state[4];
		let cl = h.state[5];
		let dh = h.state[6];
		let dl = h.state[7];
		let eh = h.state[8];
		let el = h.state[9];
		let fh = h.state[10];
		let fl = h.state[11];
		let gh = h.state[12];
		let gl = h.state[13];
		let hh = h.state[14];
		let hl = h.state[15];
		for (let i = 0; i < 80; i++) {
			const s1h = rotrHigh(eh, el, 14) ^ rotrHigh(eh, el, 18) ^ rotrHigh(eh, el, 41);
			const s1l = rotrLow(eh, el, 14) ^ rotrLow(eh, el, 18) ^ rotrLow(eh, el, 41);
			const chooseh = (eh & fh) ^ (~eh & gh);
			const choosel = (el & fl) ^ (~el & gl);
			// t1 = hh + s1 + choose + k + w, accumulated one 64-bit addend at a time
			let t1l = hl + s1l;
			let t1h = hh + s1h + carry(t1l, hl);
			let next = t1l + choosel;
			t1h = t1h + chooseh + carry(next, t1l);
			t1l = next;
			next = t1l + k512[i * 2 + 1];
			t1h = t1h + k512[i * 2] + carry(next, t1l);
			t1l = next;
			next = t1l + h.schedule[i * 2 + 1];
			t1h = t1h + h.schedule[i * 2] + carry(next, t1l);
			t1l = next;
			const s0h = rotrHigh(ah, al, 28) ^ rotrHigh(ah, al, 34) ^ rotrHigh(ah, al, 39);
			const s0l = rotrLow(ah, al, 28) ^ rotrLow(ah, al, 34) ^ rotrLow(ah, al, 39);
			const majh = (ah & bh) ^ (ah & ch) ^ (bh & ch);
			const majl = (al & bl) ^ (al & cl) ^ (bl & cl);
			hh = gh;
			hl = gl;
			gh = fh;
			gl = fl;
			fh = eh;
			fl = el;
			const newEl = dl + t1l;
			eh = dh + t1h + carry(newEl, dl);
			el = newEl;
			dh = ch;
			dl = cl;
			ch = bh;
			cl = bl;
			bh = ah;
			bl = al;
			let t2l = s0l + majl;
			const t2h = s0h + majh + carry(t2l, s0l);
			const newAl = t1l + t2l;
			ah = t1h + t2h + carry(newAl, t1l);
			al = newAl;
		}
		let sum = h.state[1] + al;
		h.state[0] = h.state[0] + ah + carry(sum, al);
		h.state[1] = sum;
		sum = h.state[3] + bl;
		h.state[2] = h.state[2] + bh + carry(sum, bl);
		h.state[3] = sum;
		sum = h.state[5] + cl;
		h.state[4] = h.state[4] + ch + carry(sum, cl);
		h.state[5] = sum;
		sum = h.state[7] + dl;
		h.state[6] = h.state[6] + dh + carry(sum, dl);
		h.state[7] = sum;
		sum = h.state[9] + el;
		h.state[8] = h.state[8] + eh + carry(sum, el);
		h.state[9] = sum;
		sum = h.state[11] + fl;
		h.state[10] = h.state[10] + fh + carry(sum, fl);
		h.state[11] = sum;
		sum = h.state[13] + gl;
		h.state[12] = h.state[12] + gh + carry(sum, gl);
		h.state[13] = sum;
		sum = h.state[15] + hl;
		h.state[14] = h.state[14] + hh + carry(sum, hl);
		h.state[15] = sum;
	}
}

export function compress256(h: HashState, data: HashBytes, off: int32): void {
	compress256Block(h, data, off);
}

export function compress512(h: HashState, data: HashBytes, off: int32): void {
	compress512Block(h, data, off);
}
