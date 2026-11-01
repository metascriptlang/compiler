import { HashState, kindSha256, kindSha224, kindSha512 } from "./state";

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

// 64-bit round constants as (high, low) pairs: JS has no cheap 64-bit integer.
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

function load32(data: Readonly<uint8[]>, at: int32): uint32 {
	return ((data[at] as uint32) << 24) | ((data[at + 1] as uint32) << 16) | ((data[at + 2] as uint32) << 8) | (data[at + 3] as uint32);
}

export function compress256(h: HashState, data: Readonly<uint8[]>, off: int32): void {
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

export function compress512(h: HashState, data: Readonly<uint8[]>, off: int32): void {
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
