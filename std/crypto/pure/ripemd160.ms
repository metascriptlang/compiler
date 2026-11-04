// Derived from @noble/hashes 1.8.0, MIT, Paul Miller (https://paulmillr.com).
// Reference: tools/solana/node_modules/@noble/hashes/src/legacy.ts, RIPEMD160.
// Algorithm: https://homes.esat.kuleuven.be/~bosselae/ripemd160.html
// Licence: std/crypto/pure/LICENSE.ripemd160

import { encodeHex } from "../../core/encoding";

export class Ripemd160State {
	h: uint32[5];
	block: uint8[];
	filled: int32;
	lengthLow: uint32;
	lengthHigh: uint32;
	finished: boolean;
}

export function newRipemd160(): Ripemd160State {
	return {
		h: [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0],
		block: new Array<uint8>(64),
		filled: 0,
		lengthLow: 0,
		lengthHigh: 0,
		finished: false,
	};
}

function compress(s: Ripemd160State, data: Readonly<uint8[]>, off: int32): void {
	const w0 = (data[off + 0] as uint32) | ((data[off + 1] as uint32) << 8) | ((data[off + 2] as uint32) << 16) | ((data[off + 3] as uint32) << 24);
	const w1 = (data[off + 4] as uint32) | ((data[off + 5] as uint32) << 8) | ((data[off + 6] as uint32) << 16) | ((data[off + 7] as uint32) << 24);
	const w2 = (data[off + 8] as uint32) | ((data[off + 9] as uint32) << 8) | ((data[off + 10] as uint32) << 16) | ((data[off + 11] as uint32) << 24);
	const w3 = (data[off + 12] as uint32) | ((data[off + 13] as uint32) << 8) | ((data[off + 14] as uint32) << 16) | ((data[off + 15] as uint32) << 24);
	const w4 = (data[off + 16] as uint32) | ((data[off + 17] as uint32) << 8) | ((data[off + 18] as uint32) << 16) | ((data[off + 19] as uint32) << 24);
	const w5 = (data[off + 20] as uint32) | ((data[off + 21] as uint32) << 8) | ((data[off + 22] as uint32) << 16) | ((data[off + 23] as uint32) << 24);
	const w6 = (data[off + 24] as uint32) | ((data[off + 25] as uint32) << 8) | ((data[off + 26] as uint32) << 16) | ((data[off + 27] as uint32) << 24);
	const w7 = (data[off + 28] as uint32) | ((data[off + 29] as uint32) << 8) | ((data[off + 30] as uint32) << 16) | ((data[off + 31] as uint32) << 24);
	const w8 = (data[off + 32] as uint32) | ((data[off + 33] as uint32) << 8) | ((data[off + 34] as uint32) << 16) | ((data[off + 35] as uint32) << 24);
	const w9 = (data[off + 36] as uint32) | ((data[off + 37] as uint32) << 8) | ((data[off + 38] as uint32) << 16) | ((data[off + 39] as uint32) << 24);
	const w10 = (data[off + 40] as uint32) | ((data[off + 41] as uint32) << 8) | ((data[off + 42] as uint32) << 16) | ((data[off + 43] as uint32) << 24);
	const w11 = (data[off + 44] as uint32) | ((data[off + 45] as uint32) << 8) | ((data[off + 46] as uint32) << 16) | ((data[off + 47] as uint32) << 24);
	const w12 = (data[off + 48] as uint32) | ((data[off + 49] as uint32) << 8) | ((data[off + 50] as uint32) << 16) | ((data[off + 51] as uint32) << 24);
	const w13 = (data[off + 52] as uint32) | ((data[off + 53] as uint32) << 8) | ((data[off + 54] as uint32) << 16) | ((data[off + 55] as uint32) << 24);
	const w14 = (data[off + 56] as uint32) | ((data[off + 57] as uint32) << 8) | ((data[off + 58] as uint32) << 16) | ((data[off + 59] as uint32) << 24);
	const w15 = (data[off + 60] as uint32) | ((data[off + 61] as uint32) << 8) | ((data[off + 62] as uint32) << 16) | ((data[off + 63] as uint32) << 24);
	let al = s.h[0];
	let bl = s.h[1];
	let cl = s.h[2];
	let dl = s.h[3];
	let el = s.h[4];
	let ar = s.h[0];
	let br = s.h[1];
	let cr = s.h[2];
	let dr = s.h[3];
	let er = s.h[4];
	{
		const t = al + (bl ^ cl ^ dl) + w0;
		al = ((t << 11) | (t >> 21)) + el;
	}
	cl = (cl << 10) | (cl >> 22);
	{
		const t = ar + (br ^ (cr | ~dr)) + w5 + 0x50a28be6;
		ar = ((t << 8) | (t >> 24)) + er;
	}
	cr = (cr << 10) | (cr >> 22);
	{
		const t = el + (al ^ bl ^ cl) + w1;
		el = ((t << 14) | (t >> 18)) + dl;
	}
	bl = (bl << 10) | (bl >> 22);
	{
		const t = er + (ar ^ (br | ~cr)) + w14 + 0x50a28be6;
		er = ((t << 9) | (t >> 23)) + dr;
	}
	br = (br << 10) | (br >> 22);
	{
		const t = dl + (el ^ al ^ bl) + w2;
		dl = ((t << 15) | (t >> 17)) + cl;
	}
	al = (al << 10) | (al >> 22);
	{
		const t = dr + (er ^ (ar | ~br)) + w7 + 0x50a28be6;
		dr = ((t << 9) | (t >> 23)) + cr;
	}
	ar = (ar << 10) | (ar >> 22);
	{
		const t = cl + (dl ^ el ^ al) + w3;
		cl = ((t << 12) | (t >> 20)) + bl;
	}
	el = (el << 10) | (el >> 22);
	{
		const t = cr + (dr ^ (er | ~ar)) + w0 + 0x50a28be6;
		cr = ((t << 11) | (t >> 21)) + br;
	}
	er = (er << 10) | (er >> 22);
	{
		const t = bl + (cl ^ dl ^ el) + w4;
		bl = ((t << 5) | (t >> 27)) + al;
	}
	dl = (dl << 10) | (dl >> 22);
	{
		const t = br + (cr ^ (dr | ~er)) + w9 + 0x50a28be6;
		br = ((t << 13) | (t >> 19)) + ar;
	}
	dr = (dr << 10) | (dr >> 22);
	{
		const t = al + (bl ^ cl ^ dl) + w5;
		al = ((t << 8) | (t >> 24)) + el;
	}
	cl = (cl << 10) | (cl >> 22);
	{
		const t = ar + (br ^ (cr | ~dr)) + w2 + 0x50a28be6;
		ar = ((t << 15) | (t >> 17)) + er;
	}
	cr = (cr << 10) | (cr >> 22);
	{
		const t = el + (al ^ bl ^ cl) + w6;
		el = ((t << 7) | (t >> 25)) + dl;
	}
	bl = (bl << 10) | (bl >> 22);
	{
		const t = er + (ar ^ (br | ~cr)) + w11 + 0x50a28be6;
		er = ((t << 15) | (t >> 17)) + dr;
	}
	br = (br << 10) | (br >> 22);
	{
		const t = dl + (el ^ al ^ bl) + w7;
		dl = ((t << 9) | (t >> 23)) + cl;
	}
	al = (al << 10) | (al >> 22);
	{
		const t = dr + (er ^ (ar | ~br)) + w4 + 0x50a28be6;
		dr = ((t << 5) | (t >> 27)) + cr;
	}
	ar = (ar << 10) | (ar >> 22);
	{
		const t = cl + (dl ^ el ^ al) + w8;
		cl = ((t << 11) | (t >> 21)) + bl;
	}
	el = (el << 10) | (el >> 22);
	{
		const t = cr + (dr ^ (er | ~ar)) + w13 + 0x50a28be6;
		cr = ((t << 7) | (t >> 25)) + br;
	}
	er = (er << 10) | (er >> 22);
	{
		const t = bl + (cl ^ dl ^ el) + w9;
		bl = ((t << 13) | (t >> 19)) + al;
	}
	dl = (dl << 10) | (dl >> 22);
	{
		const t = br + (cr ^ (dr | ~er)) + w6 + 0x50a28be6;
		br = ((t << 7) | (t >> 25)) + ar;
	}
	dr = (dr << 10) | (dr >> 22);
	{
		const t = al + (bl ^ cl ^ dl) + w10;
		al = ((t << 14) | (t >> 18)) + el;
	}
	cl = (cl << 10) | (cl >> 22);
	{
		const t = ar + (br ^ (cr | ~dr)) + w15 + 0x50a28be6;
		ar = ((t << 8) | (t >> 24)) + er;
	}
	cr = (cr << 10) | (cr >> 22);
	{
		const t = el + (al ^ bl ^ cl) + w11;
		el = ((t << 15) | (t >> 17)) + dl;
	}
	bl = (bl << 10) | (bl >> 22);
	{
		const t = er + (ar ^ (br | ~cr)) + w8 + 0x50a28be6;
		er = ((t << 11) | (t >> 21)) + dr;
	}
	br = (br << 10) | (br >> 22);
	{
		const t = dl + (el ^ al ^ bl) + w12;
		dl = ((t << 6) | (t >> 26)) + cl;
	}
	al = (al << 10) | (al >> 22);
	{
		const t = dr + (er ^ (ar | ~br)) + w1 + 0x50a28be6;
		dr = ((t << 14) | (t >> 18)) + cr;
	}
	ar = (ar << 10) | (ar >> 22);
	{
		const t = cl + (dl ^ el ^ al) + w13;
		cl = ((t << 7) | (t >> 25)) + bl;
	}
	el = (el << 10) | (el >> 22);
	{
		const t = cr + (dr ^ (er | ~ar)) + w10 + 0x50a28be6;
		cr = ((t << 14) | (t >> 18)) + br;
	}
	er = (er << 10) | (er >> 22);
	{
		const t = bl + (cl ^ dl ^ el) + w14;
		bl = ((t << 9) | (t >> 23)) + al;
	}
	dl = (dl << 10) | (dl >> 22);
	{
		const t = br + (cr ^ (dr | ~er)) + w3 + 0x50a28be6;
		br = ((t << 12) | (t >> 20)) + ar;
	}
	dr = (dr << 10) | (dr >> 22);
	{
		const t = al + (bl ^ cl ^ dl) + w15;
		al = ((t << 8) | (t >> 24)) + el;
	}
	cl = (cl << 10) | (cl >> 22);
	{
		const t = ar + (br ^ (cr | ~dr)) + w12 + 0x50a28be6;
		ar = ((t << 6) | (t >> 26)) + er;
	}
	cr = (cr << 10) | (cr >> 22);
	{
		const t = el + ((al & bl) | (~al & cl)) + w7 + 0x5a827999;
		el = ((t << 7) | (t >> 25)) + dl;
	}
	bl = (bl << 10) | (bl >> 22);
	{
		const t = er + ((ar & cr) | (br & ~cr)) + w6 + 0x5c4dd124;
		er = ((t << 9) | (t >> 23)) + dr;
	}
	br = (br << 10) | (br >> 22);
	{
		const t = dl + ((el & al) | (~el & bl)) + w4 + 0x5a827999;
		dl = ((t << 6) | (t >> 26)) + cl;
	}
	al = (al << 10) | (al >> 22);
	{
		const t = dr + ((er & br) | (ar & ~br)) + w11 + 0x5c4dd124;
		dr = ((t << 13) | (t >> 19)) + cr;
	}
	ar = (ar << 10) | (ar >> 22);
	{
		const t = cl + ((dl & el) | (~dl & al)) + w13 + 0x5a827999;
		cl = ((t << 8) | (t >> 24)) + bl;
	}
	el = (el << 10) | (el >> 22);
	{
		const t = cr + ((dr & ar) | (er & ~ar)) + w3 + 0x5c4dd124;
		cr = ((t << 15) | (t >> 17)) + br;
	}
	er = (er << 10) | (er >> 22);
	{
		const t = bl + ((cl & dl) | (~cl & el)) + w1 + 0x5a827999;
		bl = ((t << 13) | (t >> 19)) + al;
	}
	dl = (dl << 10) | (dl >> 22);
	{
		const t = br + ((cr & er) | (dr & ~er)) + w7 + 0x5c4dd124;
		br = ((t << 7) | (t >> 25)) + ar;
	}
	dr = (dr << 10) | (dr >> 22);
	{
		const t = al + ((bl & cl) | (~bl & dl)) + w10 + 0x5a827999;
		al = ((t << 11) | (t >> 21)) + el;
	}
	cl = (cl << 10) | (cl >> 22);
	{
		const t = ar + ((br & dr) | (cr & ~dr)) + w0 + 0x5c4dd124;
		ar = ((t << 12) | (t >> 20)) + er;
	}
	cr = (cr << 10) | (cr >> 22);
	{
		const t = el + ((al & bl) | (~al & cl)) + w6 + 0x5a827999;
		el = ((t << 9) | (t >> 23)) + dl;
	}
	bl = (bl << 10) | (bl >> 22);
	{
		const t = er + ((ar & cr) | (br & ~cr)) + w13 + 0x5c4dd124;
		er = ((t << 8) | (t >> 24)) + dr;
	}
	br = (br << 10) | (br >> 22);
	{
		const t = dl + ((el & al) | (~el & bl)) + w15 + 0x5a827999;
		dl = ((t << 7) | (t >> 25)) + cl;
	}
	al = (al << 10) | (al >> 22);
	{
		const t = dr + ((er & br) | (ar & ~br)) + w5 + 0x5c4dd124;
		dr = ((t << 9) | (t >> 23)) + cr;
	}
	ar = (ar << 10) | (ar >> 22);
	{
		const t = cl + ((dl & el) | (~dl & al)) + w3 + 0x5a827999;
		cl = ((t << 15) | (t >> 17)) + bl;
	}
	el = (el << 10) | (el >> 22);
	{
		const t = cr + ((dr & ar) | (er & ~ar)) + w10 + 0x5c4dd124;
		cr = ((t << 11) | (t >> 21)) + br;
	}
	er = (er << 10) | (er >> 22);
	{
		const t = bl + ((cl & dl) | (~cl & el)) + w12 + 0x5a827999;
		bl = ((t << 7) | (t >> 25)) + al;
	}
	dl = (dl << 10) | (dl >> 22);
	{
		const t = br + ((cr & er) | (dr & ~er)) + w14 + 0x5c4dd124;
		br = ((t << 7) | (t >> 25)) + ar;
	}
	dr = (dr << 10) | (dr >> 22);
	{
		const t = al + ((bl & cl) | (~bl & dl)) + w0 + 0x5a827999;
		al = ((t << 12) | (t >> 20)) + el;
	}
	cl = (cl << 10) | (cl >> 22);
	{
		const t = ar + ((br & dr) | (cr & ~dr)) + w15 + 0x5c4dd124;
		ar = ((t << 7) | (t >> 25)) + er;
	}
	cr = (cr << 10) | (cr >> 22);
	{
		const t = el + ((al & bl) | (~al & cl)) + w9 + 0x5a827999;
		el = ((t << 15) | (t >> 17)) + dl;
	}
	bl = (bl << 10) | (bl >> 22);
	{
		const t = er + ((ar & cr) | (br & ~cr)) + w8 + 0x5c4dd124;
		er = ((t << 12) | (t >> 20)) + dr;
	}
	br = (br << 10) | (br >> 22);
	{
		const t = dl + ((el & al) | (~el & bl)) + w5 + 0x5a827999;
		dl = ((t << 9) | (t >> 23)) + cl;
	}
	al = (al << 10) | (al >> 22);
	{
		const t = dr + ((er & br) | (ar & ~br)) + w12 + 0x5c4dd124;
		dr = ((t << 7) | (t >> 25)) + cr;
	}
	ar = (ar << 10) | (ar >> 22);
	{
		const t = cl + ((dl & el) | (~dl & al)) + w2 + 0x5a827999;
		cl = ((t << 11) | (t >> 21)) + bl;
	}
	el = (el << 10) | (el >> 22);
	{
		const t = cr + ((dr & ar) | (er & ~ar)) + w4 + 0x5c4dd124;
		cr = ((t << 6) | (t >> 26)) + br;
	}
	er = (er << 10) | (er >> 22);
	{
		const t = bl + ((cl & dl) | (~cl & el)) + w14 + 0x5a827999;
		bl = ((t << 7) | (t >> 25)) + al;
	}
	dl = (dl << 10) | (dl >> 22);
	{
		const t = br + ((cr & er) | (dr & ~er)) + w9 + 0x5c4dd124;
		br = ((t << 15) | (t >> 17)) + ar;
	}
	dr = (dr << 10) | (dr >> 22);
	{
		const t = al + ((bl & cl) | (~bl & dl)) + w11 + 0x5a827999;
		al = ((t << 13) | (t >> 19)) + el;
	}
	cl = (cl << 10) | (cl >> 22);
	{
		const t = ar + ((br & dr) | (cr & ~dr)) + w1 + 0x5c4dd124;
		ar = ((t << 13) | (t >> 19)) + er;
	}
	cr = (cr << 10) | (cr >> 22);
	{
		const t = el + ((al & bl) | (~al & cl)) + w8 + 0x5a827999;
		el = ((t << 12) | (t >> 20)) + dl;
	}
	bl = (bl << 10) | (bl >> 22);
	{
		const t = er + ((ar & cr) | (br & ~cr)) + w2 + 0x5c4dd124;
		er = ((t << 11) | (t >> 21)) + dr;
	}
	br = (br << 10) | (br >> 22);
	{
		const t = dl + ((el | ~al) ^ bl) + w3 + 0x6ed9eba1;
		dl = ((t << 11) | (t >> 21)) + cl;
	}
	al = (al << 10) | (al >> 22);
	{
		const t = dr + ((er | ~ar) ^ br) + w15 + 0x6d703ef3;
		dr = ((t << 9) | (t >> 23)) + cr;
	}
	ar = (ar << 10) | (ar >> 22);
	{
		const t = cl + ((dl | ~el) ^ al) + w10 + 0x6ed9eba1;
		cl = ((t << 13) | (t >> 19)) + bl;
	}
	el = (el << 10) | (el >> 22);
	{
		const t = cr + ((dr | ~er) ^ ar) + w5 + 0x6d703ef3;
		cr = ((t << 7) | (t >> 25)) + br;
	}
	er = (er << 10) | (er >> 22);
	{
		const t = bl + ((cl | ~dl) ^ el) + w14 + 0x6ed9eba1;
		bl = ((t << 6) | (t >> 26)) + al;
	}
	dl = (dl << 10) | (dl >> 22);
	{
		const t = br + ((cr | ~dr) ^ er) + w1 + 0x6d703ef3;
		br = ((t << 15) | (t >> 17)) + ar;
	}
	dr = (dr << 10) | (dr >> 22);
	{
		const t = al + ((bl | ~cl) ^ dl) + w4 + 0x6ed9eba1;
		al = ((t << 7) | (t >> 25)) + el;
	}
	cl = (cl << 10) | (cl >> 22);
	{
		const t = ar + ((br | ~cr) ^ dr) + w3 + 0x6d703ef3;
		ar = ((t << 11) | (t >> 21)) + er;
	}
	cr = (cr << 10) | (cr >> 22);
	{
		const t = el + ((al | ~bl) ^ cl) + w9 + 0x6ed9eba1;
		el = ((t << 14) | (t >> 18)) + dl;
	}
	bl = (bl << 10) | (bl >> 22);
	{
		const t = er + ((ar | ~br) ^ cr) + w7 + 0x6d703ef3;
		er = ((t << 8) | (t >> 24)) + dr;
	}
	br = (br << 10) | (br >> 22);
	{
		const t = dl + ((el | ~al) ^ bl) + w15 + 0x6ed9eba1;
		dl = ((t << 9) | (t >> 23)) + cl;
	}
	al = (al << 10) | (al >> 22);
	{
		const t = dr + ((er | ~ar) ^ br) + w14 + 0x6d703ef3;
		dr = ((t << 6) | (t >> 26)) + cr;
	}
	ar = (ar << 10) | (ar >> 22);
	{
		const t = cl + ((dl | ~el) ^ al) + w8 + 0x6ed9eba1;
		cl = ((t << 13) | (t >> 19)) + bl;
	}
	el = (el << 10) | (el >> 22);
	{
		const t = cr + ((dr | ~er) ^ ar) + w6 + 0x6d703ef3;
		cr = ((t << 6) | (t >> 26)) + br;
	}
	er = (er << 10) | (er >> 22);
	{
		const t = bl + ((cl | ~dl) ^ el) + w1 + 0x6ed9eba1;
		bl = ((t << 15) | (t >> 17)) + al;
	}
	dl = (dl << 10) | (dl >> 22);
	{
		const t = br + ((cr | ~dr) ^ er) + w9 + 0x6d703ef3;
		br = ((t << 14) | (t >> 18)) + ar;
	}
	dr = (dr << 10) | (dr >> 22);
	{
		const t = al + ((bl | ~cl) ^ dl) + w2 + 0x6ed9eba1;
		al = ((t << 14) | (t >> 18)) + el;
	}
	cl = (cl << 10) | (cl >> 22);
	{
		const t = ar + ((br | ~cr) ^ dr) + w11 + 0x6d703ef3;
		ar = ((t << 12) | (t >> 20)) + er;
	}
	cr = (cr << 10) | (cr >> 22);
	{
		const t = el + ((al | ~bl) ^ cl) + w7 + 0x6ed9eba1;
		el = ((t << 8) | (t >> 24)) + dl;
	}
	bl = (bl << 10) | (bl >> 22);
	{
		const t = er + ((ar | ~br) ^ cr) + w8 + 0x6d703ef3;
		er = ((t << 13) | (t >> 19)) + dr;
	}
	br = (br << 10) | (br >> 22);
	{
		const t = dl + ((el | ~al) ^ bl) + w0 + 0x6ed9eba1;
		dl = ((t << 13) | (t >> 19)) + cl;
	}
	al = (al << 10) | (al >> 22);
	{
		const t = dr + ((er | ~ar) ^ br) + w12 + 0x6d703ef3;
		dr = ((t << 5) | (t >> 27)) + cr;
	}
	ar = (ar << 10) | (ar >> 22);
	{
		const t = cl + ((dl | ~el) ^ al) + w6 + 0x6ed9eba1;
		cl = ((t << 6) | (t >> 26)) + bl;
	}
	el = (el << 10) | (el >> 22);
	{
		const t = cr + ((dr | ~er) ^ ar) + w2 + 0x6d703ef3;
		cr = ((t << 14) | (t >> 18)) + br;
	}
	er = (er << 10) | (er >> 22);
	{
		const t = bl + ((cl | ~dl) ^ el) + w13 + 0x6ed9eba1;
		bl = ((t << 5) | (t >> 27)) + al;
	}
	dl = (dl << 10) | (dl >> 22);
	{
		const t = br + ((cr | ~dr) ^ er) + w10 + 0x6d703ef3;
		br = ((t << 13) | (t >> 19)) + ar;
	}
	dr = (dr << 10) | (dr >> 22);
	{
		const t = al + ((bl | ~cl) ^ dl) + w11 + 0x6ed9eba1;
		al = ((t << 12) | (t >> 20)) + el;
	}
	cl = (cl << 10) | (cl >> 22);
	{
		const t = ar + ((br | ~cr) ^ dr) + w0 + 0x6d703ef3;
		ar = ((t << 13) | (t >> 19)) + er;
	}
	cr = (cr << 10) | (cr >> 22);
	{
		const t = el + ((al | ~bl) ^ cl) + w5 + 0x6ed9eba1;
		el = ((t << 7) | (t >> 25)) + dl;
	}
	bl = (bl << 10) | (bl >> 22);
	{
		const t = er + ((ar | ~br) ^ cr) + w4 + 0x6d703ef3;
		er = ((t << 7) | (t >> 25)) + dr;
	}
	br = (br << 10) | (br >> 22);
	{
		const t = dl + ((el | ~al) ^ bl) + w12 + 0x6ed9eba1;
		dl = ((t << 5) | (t >> 27)) + cl;
	}
	al = (al << 10) | (al >> 22);
	{
		const t = dr + ((er | ~ar) ^ br) + w13 + 0x6d703ef3;
		dr = ((t << 5) | (t >> 27)) + cr;
	}
	ar = (ar << 10) | (ar >> 22);
	{
		const t = cl + ((dl & al) | (el & ~al)) + w1 + 0x8f1bbcdc;
		cl = ((t << 11) | (t >> 21)) + bl;
	}
	el = (el << 10) | (el >> 22);
	{
		const t = cr + ((dr & er) | (~dr & ar)) + w8 + 0x7a6d76e9;
		cr = ((t << 15) | (t >> 17)) + br;
	}
	er = (er << 10) | (er >> 22);
	{
		const t = bl + ((cl & el) | (dl & ~el)) + w9 + 0x8f1bbcdc;
		bl = ((t << 12) | (t >> 20)) + al;
	}
	dl = (dl << 10) | (dl >> 22);
	{
		const t = br + ((cr & dr) | (~cr & er)) + w6 + 0x7a6d76e9;
		br = ((t << 5) | (t >> 27)) + ar;
	}
	dr = (dr << 10) | (dr >> 22);
	{
		const t = al + ((bl & dl) | (cl & ~dl)) + w11 + 0x8f1bbcdc;
		al = ((t << 14) | (t >> 18)) + el;
	}
	cl = (cl << 10) | (cl >> 22);
	{
		const t = ar + ((br & cr) | (~br & dr)) + w4 + 0x7a6d76e9;
		ar = ((t << 8) | (t >> 24)) + er;
	}
	cr = (cr << 10) | (cr >> 22);
	{
		const t = el + ((al & cl) | (bl & ~cl)) + w10 + 0x8f1bbcdc;
		el = ((t << 15) | (t >> 17)) + dl;
	}
	bl = (bl << 10) | (bl >> 22);
	{
		const t = er + ((ar & br) | (~ar & cr)) + w1 + 0x7a6d76e9;
		er = ((t << 11) | (t >> 21)) + dr;
	}
	br = (br << 10) | (br >> 22);
	{
		const t = dl + ((el & bl) | (al & ~bl)) + w0 + 0x8f1bbcdc;
		dl = ((t << 14) | (t >> 18)) + cl;
	}
	al = (al << 10) | (al >> 22);
	{
		const t = dr + ((er & ar) | (~er & br)) + w3 + 0x7a6d76e9;
		dr = ((t << 14) | (t >> 18)) + cr;
	}
	ar = (ar << 10) | (ar >> 22);
	{
		const t = cl + ((dl & al) | (el & ~al)) + w8 + 0x8f1bbcdc;
		cl = ((t << 15) | (t >> 17)) + bl;
	}
	el = (el << 10) | (el >> 22);
	{
		const t = cr + ((dr & er) | (~dr & ar)) + w11 + 0x7a6d76e9;
		cr = ((t << 14) | (t >> 18)) + br;
	}
	er = (er << 10) | (er >> 22);
	{
		const t = bl + ((cl & el) | (dl & ~el)) + w12 + 0x8f1bbcdc;
		bl = ((t << 9) | (t >> 23)) + al;
	}
	dl = (dl << 10) | (dl >> 22);
	{
		const t = br + ((cr & dr) | (~cr & er)) + w15 + 0x7a6d76e9;
		br = ((t << 6) | (t >> 26)) + ar;
	}
	dr = (dr << 10) | (dr >> 22);
	{
		const t = al + ((bl & dl) | (cl & ~dl)) + w4 + 0x8f1bbcdc;
		al = ((t << 8) | (t >> 24)) + el;
	}
	cl = (cl << 10) | (cl >> 22);
	{
		const t = ar + ((br & cr) | (~br & dr)) + w0 + 0x7a6d76e9;
		ar = ((t << 14) | (t >> 18)) + er;
	}
	cr = (cr << 10) | (cr >> 22);
	{
		const t = el + ((al & cl) | (bl & ~cl)) + w13 + 0x8f1bbcdc;
		el = ((t << 9) | (t >> 23)) + dl;
	}
	bl = (bl << 10) | (bl >> 22);
	{
		const t = er + ((ar & br) | (~ar & cr)) + w5 + 0x7a6d76e9;
		er = ((t << 6) | (t >> 26)) + dr;
	}
	br = (br << 10) | (br >> 22);
	{
		const t = dl + ((el & bl) | (al & ~bl)) + w3 + 0x8f1bbcdc;
		dl = ((t << 14) | (t >> 18)) + cl;
	}
	al = (al << 10) | (al >> 22);
	{
		const t = dr + ((er & ar) | (~er & br)) + w12 + 0x7a6d76e9;
		dr = ((t << 9) | (t >> 23)) + cr;
	}
	ar = (ar << 10) | (ar >> 22);
	{
		const t = cl + ((dl & al) | (el & ~al)) + w7 + 0x8f1bbcdc;
		cl = ((t << 5) | (t >> 27)) + bl;
	}
	el = (el << 10) | (el >> 22);
	{
		const t = cr + ((dr & er) | (~dr & ar)) + w2 + 0x7a6d76e9;
		cr = ((t << 12) | (t >> 20)) + br;
	}
	er = (er << 10) | (er >> 22);
	{
		const t = bl + ((cl & el) | (dl & ~el)) + w15 + 0x8f1bbcdc;
		bl = ((t << 6) | (t >> 26)) + al;
	}
	dl = (dl << 10) | (dl >> 22);
	{
		const t = br + ((cr & dr) | (~cr & er)) + w13 + 0x7a6d76e9;
		br = ((t << 9) | (t >> 23)) + ar;
	}
	dr = (dr << 10) | (dr >> 22);
	{
		const t = al + ((bl & dl) | (cl & ~dl)) + w14 + 0x8f1bbcdc;
		al = ((t << 8) | (t >> 24)) + el;
	}
	cl = (cl << 10) | (cl >> 22);
	{
		const t = ar + ((br & cr) | (~br & dr)) + w9 + 0x7a6d76e9;
		ar = ((t << 12) | (t >> 20)) + er;
	}
	cr = (cr << 10) | (cr >> 22);
	{
		const t = el + ((al & cl) | (bl & ~cl)) + w5 + 0x8f1bbcdc;
		el = ((t << 6) | (t >> 26)) + dl;
	}
	bl = (bl << 10) | (bl >> 22);
	{
		const t = er + ((ar & br) | (~ar & cr)) + w7 + 0x7a6d76e9;
		er = ((t << 5) | (t >> 27)) + dr;
	}
	br = (br << 10) | (br >> 22);
	{
		const t = dl + ((el & bl) | (al & ~bl)) + w6 + 0x8f1bbcdc;
		dl = ((t << 5) | (t >> 27)) + cl;
	}
	al = (al << 10) | (al >> 22);
	{
		const t = dr + ((er & ar) | (~er & br)) + w10 + 0x7a6d76e9;
		dr = ((t << 15) | (t >> 17)) + cr;
	}
	ar = (ar << 10) | (ar >> 22);
	{
		const t = cl + ((dl & al) | (el & ~al)) + w2 + 0x8f1bbcdc;
		cl = ((t << 12) | (t >> 20)) + bl;
	}
	el = (el << 10) | (el >> 22);
	{
		const t = cr + ((dr & er) | (~dr & ar)) + w14 + 0x7a6d76e9;
		cr = ((t << 8) | (t >> 24)) + br;
	}
	er = (er << 10) | (er >> 22);
	{
		const t = bl + (cl ^ (dl | ~el)) + w4 + 0xa953fd4e;
		bl = ((t << 9) | (t >> 23)) + al;
	}
	dl = (dl << 10) | (dl >> 22);
	{
		const t = br + (cr ^ dr ^ er) + w12;
		br = ((t << 8) | (t >> 24)) + ar;
	}
	dr = (dr << 10) | (dr >> 22);
	{
		const t = al + (bl ^ (cl | ~dl)) + w0 + 0xa953fd4e;
		al = ((t << 15) | (t >> 17)) + el;
	}
	cl = (cl << 10) | (cl >> 22);
	{
		const t = ar + (br ^ cr ^ dr) + w15;
		ar = ((t << 5) | (t >> 27)) + er;
	}
	cr = (cr << 10) | (cr >> 22);
	{
		const t = el + (al ^ (bl | ~cl)) + w5 + 0xa953fd4e;
		el = ((t << 5) | (t >> 27)) + dl;
	}
	bl = (bl << 10) | (bl >> 22);
	{
		const t = er + (ar ^ br ^ cr) + w10;
		er = ((t << 12) | (t >> 20)) + dr;
	}
	br = (br << 10) | (br >> 22);
	{
		const t = dl + (el ^ (al | ~bl)) + w9 + 0xa953fd4e;
		dl = ((t << 11) | (t >> 21)) + cl;
	}
	al = (al << 10) | (al >> 22);
	{
		const t = dr + (er ^ ar ^ br) + w4;
		dr = ((t << 9) | (t >> 23)) + cr;
	}
	ar = (ar << 10) | (ar >> 22);
	{
		const t = cl + (dl ^ (el | ~al)) + w7 + 0xa953fd4e;
		cl = ((t << 6) | (t >> 26)) + bl;
	}
	el = (el << 10) | (el >> 22);
	{
		const t = cr + (dr ^ er ^ ar) + w1;
		cr = ((t << 12) | (t >> 20)) + br;
	}
	er = (er << 10) | (er >> 22);
	{
		const t = bl + (cl ^ (dl | ~el)) + w12 + 0xa953fd4e;
		bl = ((t << 8) | (t >> 24)) + al;
	}
	dl = (dl << 10) | (dl >> 22);
	{
		const t = br + (cr ^ dr ^ er) + w5;
		br = ((t << 5) | (t >> 27)) + ar;
	}
	dr = (dr << 10) | (dr >> 22);
	{
		const t = al + (bl ^ (cl | ~dl)) + w2 + 0xa953fd4e;
		al = ((t << 13) | (t >> 19)) + el;
	}
	cl = (cl << 10) | (cl >> 22);
	{
		const t = ar + (br ^ cr ^ dr) + w8;
		ar = ((t << 14) | (t >> 18)) + er;
	}
	cr = (cr << 10) | (cr >> 22);
	{
		const t = el + (al ^ (bl | ~cl)) + w10 + 0xa953fd4e;
		el = ((t << 12) | (t >> 20)) + dl;
	}
	bl = (bl << 10) | (bl >> 22);
	{
		const t = er + (ar ^ br ^ cr) + w7;
		er = ((t << 6) | (t >> 26)) + dr;
	}
	br = (br << 10) | (br >> 22);
	{
		const t = dl + (el ^ (al | ~bl)) + w14 + 0xa953fd4e;
		dl = ((t << 5) | (t >> 27)) + cl;
	}
	al = (al << 10) | (al >> 22);
	{
		const t = dr + (er ^ ar ^ br) + w6;
		dr = ((t << 8) | (t >> 24)) + cr;
	}
	ar = (ar << 10) | (ar >> 22);
	{
		const t = cl + (dl ^ (el | ~al)) + w1 + 0xa953fd4e;
		cl = ((t << 12) | (t >> 20)) + bl;
	}
	el = (el << 10) | (el >> 22);
	{
		const t = cr + (dr ^ er ^ ar) + w2;
		cr = ((t << 13) | (t >> 19)) + br;
	}
	er = (er << 10) | (er >> 22);
	{
		const t = bl + (cl ^ (dl | ~el)) + w3 + 0xa953fd4e;
		bl = ((t << 13) | (t >> 19)) + al;
	}
	dl = (dl << 10) | (dl >> 22);
	{
		const t = br + (cr ^ dr ^ er) + w13;
		br = ((t << 6) | (t >> 26)) + ar;
	}
	dr = (dr << 10) | (dr >> 22);
	{
		const t = al + (bl ^ (cl | ~dl)) + w8 + 0xa953fd4e;
		al = ((t << 14) | (t >> 18)) + el;
	}
	cl = (cl << 10) | (cl >> 22);
	{
		const t = ar + (br ^ cr ^ dr) + w14;
		ar = ((t << 5) | (t >> 27)) + er;
	}
	cr = (cr << 10) | (cr >> 22);
	{
		const t = el + (al ^ (bl | ~cl)) + w11 + 0xa953fd4e;
		el = ((t << 11) | (t >> 21)) + dl;
	}
	bl = (bl << 10) | (bl >> 22);
	{
		const t = er + (ar ^ br ^ cr) + w0;
		er = ((t << 15) | (t >> 17)) + dr;
	}
	br = (br << 10) | (br >> 22);
	{
		const t = dl + (el ^ (al | ~bl)) + w6 + 0xa953fd4e;
		dl = ((t << 8) | (t >> 24)) + cl;
	}
	al = (al << 10) | (al >> 22);
	{
		const t = dr + (er ^ ar ^ br) + w3;
		dr = ((t << 13) | (t >> 19)) + cr;
	}
	ar = (ar << 10) | (ar >> 22);
	{
		const t = cl + (dl ^ (el | ~al)) + w15 + 0xa953fd4e;
		cl = ((t << 5) | (t >> 27)) + bl;
	}
	el = (el << 10) | (el >> 22);
	{
		const t = cr + (dr ^ er ^ ar) + w9;
		cr = ((t << 11) | (t >> 21)) + br;
	}
	er = (er << 10) | (er >> 22);
	{
		const t = bl + (cl ^ (dl | ~el)) + w13 + 0xa953fd4e;
		bl = ((t << 6) | (t >> 26)) + al;
	}
	dl = (dl << 10) | (dl >> 22);
	{
		const t = br + (cr ^ dr ^ er) + w11;
		br = ((t << 11) | (t >> 21)) + ar;
	}
	dr = (dr << 10) | (dr >> 22);
	const t = s.h[1] + cl + dr;
	s.h[1] = s.h[2] + dl + er;
	s.h[2] = s.h[3] + el + ar;
	s.h[3] = s.h[4] + al + br;
	s.h[4] = s.h[0] + bl + cr;
	s.h[0] = t;
}

export function updateRipemd160(s: Ripemd160State, data: Readonly<uint8[]>): void {
	if (s.finished) throw new Error("ripemd160: already finished");
	const end = data.length as int32;
	let at = 0;
	const low = s.lengthLow + (end as uint32);
	if (low < s.lengthLow) s.lengthHigh += 1;
	s.lengthLow = low;
	if (s.filled > 0) {
		while (at < end && s.filled < 64) {
			s.block[s.filled] = data[at];
			s.filled += 1;
			at += 1;
		}
		if (s.filled < 64) return;
		compress(s, s.block, 0);
		s.filled = 0;
	}
	while (at + 64 <= end) {
		compress(s, data, at);
		at += 64;
	}
	while (at < end) {
		s.block[s.filled] = data[at];
		s.filled += 1;
		at += 1;
	}
}

export function finishRipemd160(s: Ripemd160State): uint8[] {
	if (s.finished) throw new Error("ripemd160: already finished");
	s.block[s.filled] = 0x80;
	s.filled += 1;
	if (s.filled > 56) {
		while (s.filled < 64) {
			s.block[s.filled] = 0;
			s.filled += 1;
		}
		compress(s, s.block, 0);
		s.filled = 0;
	}
	while (s.filled < 56) {
		s.block[s.filled] = 0;
		s.filled += 1;
	}
	const low = s.lengthLow << 3;
	const high = (s.lengthHigh << 3) | (s.lengthLow >> 29);
	for (let i = 0; i < 4; i++) {
		const shift = (8 * i) as uint32;
		s.block[56 + i] = ((low >> shift) & 255) as uint8;
		s.block[60 + i] = ((high >> shift) & 255) as uint8;
	}
	compress(s, s.block, 0);
	s.block.fill(0);
	s.finished = true;
	const out = new Array<uint8>(20);
	for (let i = 0; i < 5; i++) {
		const word = s.h[i];
		out[4 * i + 0] = (word & 255) as uint8;
		out[4 * i + 1] = ((word >> 8) & 255) as uint8;
		out[4 * i + 2] = ((word >> 16) & 255) as uint8;
		out[4 * i + 3] = ((word >> 24) & 255) as uint8;
	}
	return out;
}

export function ripemd160Of(data: Readonly<uint8[]>): uint8[] {
	const s = newRipemd160();
	updateRipemd160(s, data);
	return finishRipemd160(s);
}

function hashStr(text: string): string {
	return ripemd160Of(text.asBytes().slice(0)).encodeHex();
}

test "ripemd160 empty" {
	assert hashStr("") == "9c1185a5c5e9fc54612808977ee8f548b2258d31";
}

test "ripemd160 abc" {
	assert hashStr("abc") == "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc";
}

test "ripemd160 message digest" {
	assert hashStr("message digest") == "5d0689ef49d2fae572b881b123a85ffa21595f36";
}

test "ripemd160 lowercase alphabet" {
	assert hashStr("abcdefghijklmnopqrstuvwxyz") == "f71c27109c692c1b56bbdceb5b9d2865b3708dbc";
}

test "ripemd160 padding boundary 56 bytes forces second block" {
	assert hashStr("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") == "12a053384a9c0c88e405a06c27dcf49ada62eb2b";
}

test "ripemd160 62-byte alphanumeric" {
	assert hashStr("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") == "b0e20b6e3116640286ed3a87a5713079b21f5189";
}

test "ripemd160 multiblock 80-byte decimal string" {
	assert hashStr("12345678901234567890123456789012345678901234567890123456789012345678901234567890") == "9b752e45573d4b39f4dbd3323cab82bf63326bfb";
}

test "ripemd160 split feed matches single" {
	const s = newRipemd160();
	updateRipemd160(s, "a".asBytes().slice(0));
	updateRipemd160(s, "bc".asBytes().slice(0));
	assert finishRipemd160(s).encodeHex() == "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc";
}

test "ripemd160 update after finish throws" {
	const s = newRipemd160();
	finishRipemd160(s);
	let threw = false;
	try {
		updateRipemd160(s, []);
	} catch (e) {
		threw = true;
	}
	assert threw;
}

test "ripemd160 finish wipes the buffered tail" {
	const s = newRipemd160();
	updateRipemd160(s, "secret".asBytes().slice(0));
	finishRipemd160(s);
	for (const b of s.block) assert b == 0;
}

test "ripemd160 finish after finish throws" {
	const s = newRipemd160();
	finishRipemd160(s);
	let threw = false;
	try {
		finishRipemd160(s);
	} catch (e) {
		threw = true;
	}
	assert threw;
}

function repeatA(n: int32): uint8[] {
	const data = new Array<uint8>(n);
	for (let i = 0; i < n; i++) data[i] = 0x61;
	return data;
}

function hashRepeatA(n: int32): string {
	return ripemd160Of(repeatA(n)).encodeHex();
}

test "ripemd160 a" {
	assert hashStr("a") == "0bdc9d2d256b3ee9daae347be6f4dc835a467ffe";
}

test "ripemd160 padding boundaries 55 56 64" {
	assert hashRepeatA(55) == "0d8a8c9063a48576a7c97e9f95253a6e53ff6765";
	assert hashRepeatA(56) == "e72334b46c83cc70bef979e15453706c95b888be";
	assert hashRepeatA(64) == "9dfb7d374ad924f3f88de96291c33e9abed53e32";
}

test "ripemd160 million a" {
	assert hashRepeatA(1000000) == "52783243c1697bdbe16d37f97f68f08325dc1528";
}

test "ripemd160 byte counter carries into the high word" {
	const s = newRipemd160();
	s.lengthLow = 0xffffffc0;
	updateRipemd160(s, repeatA(64));
	assert s.lengthLow == 0;
	assert s.lengthHigh == 1;
}

test "ripemd160 streaming split across blocks" {
	const text = "12345678901234567890123456789012345678901234567890123456789012345678901234567890".asBytes().slice(0);
	for (const cut of [1, 7, 63, 64, 65, 79]) {
		const s = newRipemd160();
		updateRipemd160(s, text.slice(0, cut));
		updateRipemd160(s, text.slice(cut));
		assert finishRipemd160(s).encodeHex() == "9b752e45573d4b39f4dbd3323cab82bf63326bfb";
	}
}
