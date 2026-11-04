import { HashState, kindSha256, kindSha224, kindSha512 } from "./state";
import { load32BE } from "./endian";

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

export function compress256(h: HashState, data: Readonly<uint8[]>, off: int32): void {
	let w: uint32[64] = [];
	for (let i = 0; i < 16; i++) w[i] = load32(data, off + i * 4);
	for (let i = 16; i < 64; i++) {
		const w15 = w[i - 15];
		const w2 = w[i - 2];
		const s0 = rotr(w15, 7) ^ rotr(w15, 18) ^ (w15 >> 3);
		const s1 = rotr(w2, 17) ^ rotr(w2, 19) ^ (w2 >> 10);
		w[i] = s1 + w[i - 7] + s0 + w[i - 16];
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
		const t1 = hh + sigma1 + ((e & f) ^ (~e & g)) + k256[i] + w[i];
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

function rotr64(v: uint64, c: uint64): uint64 {
	return (v >> c) | (v << (64 - c));
}

function k64(i: int32): uint64 {
	return ((k512[i * 2] as uint64) << 32) | (k512[i * 2 + 1] as uint64);
}

export function compress512(h: HashState, data: Readonly<uint8[]>, off: int32): void {
	let w: uint64[80] = [];
	for (let i = 0; i < 16; i++) {
		w[i] = ((load32(data, off + i * 8) as uint64) << 32) | (load32(data, off + i * 8 + 4) as uint64);
	}
	for (let i = 16; i < 80; i++) {
		const w15 = w[i - 15];
		const w2 = w[i - 2];
		const s0 = rotr64(w15, 1) ^ rotr64(w15, 8) ^ (w15 >> 7);
		const s1 = rotr64(w2, 19) ^ rotr64(w2, 61) ^ (w2 >> 6);
		w[i] = s1 + w[i - 7] + s0 + w[i - 16];
	}
	let v: uint64[8] = [];
	for (let i = 0; i < 8; i++) v[i] = ((h.state[i * 2] as uint64) << 32) | (h.state[i * 2 + 1] as uint64);
	let a = v[0];
	let b = v[1];
	let c = v[2];
	let d = v[3];
	let e = v[4];
	let f = v[5];
	let g = v[6];
	let hh = v[7];
	for (let i = 0; i < 80; i++) {
		const sigma1 = rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41);
		const t1 = hh + sigma1 + ((e & f) ^ (~e & g)) + k64(i) + w[i];
		const sigma0 = rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39);
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
	v[0] = v[0] + a;
	v[1] = v[1] + b;
	v[2] = v[2] + c;
	v[3] = v[3] + d;
	v[4] = v[4] + e;
	v[5] = v[5] + f;
	v[6] = v[6] + g;
	v[7] = v[7] + hh;
	for (let i = 0; i < 8; i++) {
		h.state[i * 2] = (v[i] >> 32) as uint32;
		h.state[i * 2 + 1] = (v[i] & 0xffffffff) as uint32;
	}
}

export function compress512(st: HashState, data: Readonly<uint8[]>, off: int32): void {
	when (js) {
		compress512Split(st, data, off);
	} else {
		compress512Wide(st, data, off);
	}
}
