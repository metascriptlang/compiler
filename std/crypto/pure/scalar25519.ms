/**
 * Scalars mod L = 2^252 + 27742317777372353535851937790883648493, following Zig's std.crypto scalar.zig (MIT,
 * see LICENSE.zig.MIT): the same Barrett reduction (q = x >> 248, mu = floor(2^512 / L), quotient = q * mu >> 264,
 * remainder mod 2^264, one masked subtraction of L), mul-then-add and the byte-wise canonical check. Zig keeps
 * 56-bit limbs with 128-bit products; here the limbs are 32 bits wide with 64-bit products, so the quotient
 * and remainder steps are written as schoolbook loops over limb arrays instead of Zig's unrolled code.
 */

const scalarLimbs = 8;
const orderLimbs: Readonly<uint32[]> = [
	0x5cf5d3ed, 0x5812631a, 0xa2f79cd6, 0x14def9de, 0, 0, 0, 0x10000000, 0,
];
const barrettMu: Readonly<uint32[]> = [
	0x0a2c131b, 0xed9ce5a3, 0x086329a7, 0x2106215d, 0xffffffeb, 0xffffffff, 0xffffffff, 0xffffffff, 0xf,
];
const orderBytes: Readonly<uint8[]> = [
	0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10,
];

function limbsOf(bytes: Readonly<uint8[]>, from: int32, length: int32, count: int32): uint32[] {
	const out = new Array<uint32>(count);
	for (let i = 0; i < length; i++) {
		const limb = i >> 2;
		out[limb] = out[limb] | ((bytes[from + i] as uint32) << (((i & 3) * 8) as uint32));
	}
	return out;
}

function bytesOf(limbs: Readonly<uint32[]>): uint8[] {
	const out = new Array<uint8>(32);
	for (let i = 0; i < 32; i++) out[i] = ((limbs[i >> 2] >> (((i & 3) * 8) as uint32)) & 0xff) as uint8;
	return out;
}

/** The product truncated to its low `count` limbs. */
function mulLow(a: Readonly<uint32[]>, b: Readonly<uint32[]>, count: int32): uint32[] {
	const out = new Array<uint32>(count);
	for (let i = 0; i < a.length && i < count; i++) {
		let carry: uint64 = 0;
		for (let j = 0; j < b.length && i + j < count; j++) {
			const t = (out[i + j] as uint64) + (a[i] as uint64) * (b[j] as uint64) + carry;
			out[i + j] = t as uint32;
			carry = t >> 32;
		}
		if (i + b.length < count) out[i + b.length] = carry as uint32;
	}
	return out;
}

/** `count` limbs of x >> (32 * limbShift + bitShift), bitShift in 1..31. */
function shiftRight(x: Readonly<uint32[]>, limbShift: int32, bitShift: uint32, count: int32): uint32[] {
	const out = new Array<uint32>(count);
	for (let i = 0; i < count; i++) {
		const low = limbShift + i < x.length ? x[limbShift + i] >> bitShift : 0;
		const high = limbShift + i + 1 < x.length ? x[limbShift + i + 1] << (32 - bitShift) : 0;
		out[i] = low | high;
	}
	return out;
}

/** a - b over the shorter length of a, the final borrow (0 or 1) in the returned last slot. */
function subBorrow(a: Readonly<uint32[]>, b: Readonly<uint32[]>): uint32[] {
	const out = new Array<uint32>(a.length + 1);
	let borrow: uint64 = 0;
	for (let i = 0; i < a.length; i++) {
		const t = (a[i] as uint64) + 0x100000000 - (b[i] as uint64) - borrow;
		out[i] = t as uint32;
		borrow = 1 - (t >> 32);
	}
	out[a.length] = borrow as uint32;
	return out;
}

/** The 9-limb (288-bit) value minus L when that does not borrow; the masked choice of Zig's add and reduce. */
function subtractOrderOnce(s: Readonly<uint32[]>): uint32[] {
	const t = subBorrow(s, orderLimbs);
	const mask = (t[s.length] ^ 1) * 0xffffffff;
	const out = new Array<uint32>(s.length);
	for (let i = 0; i < s.length; i++) out[i] = s[i] ^ (mask & (s[i] ^ t[i]));
	return out;
}

/** Barrett reduction of a value below 2^512 held in 16 limbs; the result is below L, in 9 limbs. */
function reduceLimbs(x: Readonly<uint32[]>): uint32[] {
	const q = shiftRight(x, 7, 24, 9);
	const qmu = mulLow(q, barrettMu, 18);
	const quotient = shiftRight(qmu, 8, 8, 9);
	const qmul = mulLow(quotient, orderLimbs, 9);
	qmul[8] = qmul[8] & 0xff;
	const r = new Array<uint32>(9);
	for (let i = 0; i < 9; i++) r[i] = x[i];
	r[8] = r[8] & 0xff;
	const s = subBorrow(r, qmul);
	s.length = 9;
	s[8] = s[8] & 0xff;
	return subtractOrderOnce(s);
}

/** The 32-byte little-endian scalar reduced mod L. */
export function scalarReduce32(s: Readonly<uint8[]>): uint8[] {
	return bytesOf(reduceLimbs(limbsOf(s, 0, 32, 16)));
}

/** The 64-byte little-endian scalar reduced mod L. */
export function scalarReduce64(s: Readonly<uint8[]>): uint8[] {
	return bytesOf(reduceLimbs(limbsOf(s, 0, 64, 16)));
}

/** a * b + c mod L for 32-byte scalars, as Zig's mulAdd: reduce each, multiply and reduce, then add. */
export function scalarMulAdd(a: Readonly<uint8[]>, b: Readonly<uint8[]>, c: Readonly<uint8[]>): uint8[] {
	const x = reduceLimbs(limbsOf(a, 0, 32, 16));
	const y = reduceLimbs(limbsOf(b, 0, 32, 16));
	const z = reduceLimbs(limbsOf(c, 0, 32, 16));
	x.length = scalarLimbs;
	y.length = scalarLimbs;
	const product = reduceLimbs(mulLow(x, y, 16));
	const sum = new Array<uint32>(9);
	let carry: uint64 = 0;
	for (let i = 0; i < 9; i++) {
		const t = (product[i] as uint64) + (z[i] as uint64) + carry;
		sum[i] = t as uint32;
		carry = t >> 32;
	}
	return bytesOf(subtractOrderOnce(sum));
}

/** Whether the 32 bytes at `from` encode a scalar below L, Zig's rejectNonCanonical without its branch. */
export function scalarIsCanonical(s: Readonly<uint8[]>, from: int32): boolean {
	let c = 0;
	let n = 1;
	for (let i = 31; i >= 0; i--) {
		const xs = s[from + i] as int32;
		const xl = orderBytes[i] as int32;
		c = c | (((xs - xl) >> 8) & n);
		n = n & ((((xs ^ xl) - 1) >> 8) & 1);
	}
	return c != 0;
}
