import { encodeHex } from "../../core/encoding";
import { wipeBytes } from "./secret";

// Derived from Zig std.crypto keccak_p.zig + sha3.zig, commit 16d31ceed5de91b469e010b4a8d515236ad6bf14; see LICENSE.sha3.

const RC_LO: uint32[24] = [
	0x00000001, 0x00008082, 0x0000808a, 0x80008000,
	0x0000808b, 0x80000001, 0x80008081, 0x00008009,
	0x0000008a, 0x00000088, 0x80008009, 0x8000000a,
	0x8000808b, 0x0000008b, 0x00008089, 0x00008003,
	0x00008002, 0x00000080, 0x0000800a, 0x8000000a,
	0x80008081, 0x00008080, 0x80000001, 0x80008008,
];
const RC_HI: uint32[24] = [
	0x00000000, 0x00000000, 0x80000000, 0x80000000,
	0x00000000, 0x00000000, 0x80000000, 0x80000000,
	0x00000000, 0x00000000, 0x00000000, 0x00000000,
	0x00000000, 0x80000000, 0x80000000, 0x80000000,
	0x80000000, 0x80000000, 0x00000000, 0x80000000,
	0x80000000, 0x80000000, 0x00000000, 0x80000000,
];

// JS lowers every uint64 operation to BigInt; 64-bit lanes ran 30-50x slower there than (lo, hi)
// uint32 pairs, while on C they ran 3-5x faster (rtx, 2026-11-04).
when (c) {
	import { wipeWords64 } from "./secret";

	export class Sha3State {
		st: uint64[25];
		buf: uint8[144];
		rate: int32;
		bits: int32;
		filled: int32;
		finished: boolean;
	}

	function keccakF(state: Sha3State): void {
		const st = state.st;
		let a0: uint64 = st[0];
		let a1: uint64 = st[1];
		let a2: uint64 = st[2];
		let a3: uint64 = st[3];
		let a4: uint64 = st[4];
		let a5: uint64 = st[5];
		let a6: uint64 = st[6];
		let a7: uint64 = st[7];
		let a8: uint64 = st[8];
		let a9: uint64 = st[9];
		let a10: uint64 = st[10];
		let a11: uint64 = st[11];
		let a12: uint64 = st[12];
		let a13: uint64 = st[13];
		let a14: uint64 = st[14];
		let a15: uint64 = st[15];
		let a16: uint64 = st[16];
		let a17: uint64 = st[17];
		let a18: uint64 = st[18];
		let a19: uint64 = st[19];
		let a20: uint64 = st[20];
		let a21: uint64 = st[21];
		let a22: uint64 = st[22];
		let a23: uint64 = st[23];
		let a24: uint64 = st[24];
		for (let round = 0; round < 24; round++) {
			const c0 = a0 ^ a5 ^ a10 ^ a15 ^ a20;
			const c1 = a1 ^ a6 ^ a11 ^ a16 ^ a21;
			const c2 = a2 ^ a7 ^ a12 ^ a17 ^ a22;
			const c3 = a3 ^ a8 ^ a13 ^ a18 ^ a23;
			const c4 = a4 ^ a9 ^ a14 ^ a19 ^ a24;
			const d0 = c4 ^ ((c1 << 1) | (c1 >> 63));
			const d1 = c0 ^ ((c2 << 1) | (c2 >> 63));
			const d2 = c1 ^ ((c3 << 1) | (c3 >> 63));
			const d3 = c2 ^ ((c4 << 1) | (c4 >> 63));
			const d4 = c3 ^ ((c0 << 1) | (c0 >> 63));
			const t0: uint64 = a0 ^ d0;
			const t1: uint64 = a6 ^ d1;
			const t2: uint64 = a12 ^ d2;
			const t3: uint64 = a18 ^ d3;
			const t4: uint64 = a24 ^ d4;
			const t5: uint64 = a3 ^ d3;
			const t6: uint64 = a9 ^ d4;
			const t7: uint64 = a10 ^ d0;
			const t8: uint64 = a16 ^ d1;
			const t9: uint64 = a22 ^ d2;
			const t10: uint64 = a1 ^ d1;
			const t11: uint64 = a7 ^ d2;
			const t12: uint64 = a13 ^ d3;
			const t13: uint64 = a19 ^ d4;
			const t14: uint64 = a20 ^ d0;
			const t15: uint64 = a4 ^ d4;
			const t16: uint64 = a5 ^ d0;
			const t17: uint64 = a11 ^ d1;
			const t18: uint64 = a17 ^ d2;
			const t19: uint64 = a23 ^ d3;
			const t20: uint64 = a2 ^ d2;
			const t21: uint64 = a8 ^ d3;
			const t22: uint64 = a14 ^ d4;
			const t23: uint64 = a15 ^ d0;
			const t24: uint64 = a21 ^ d1;
			const b0: uint64 = t0;
			const b1: uint64 = ((t1 << 44) | (t1 >> 20));
			const b2: uint64 = ((t2 << 43) | (t2 >> 21));
			const b3: uint64 = ((t3 << 21) | (t3 >> 43));
			const b4: uint64 = ((t4 << 14) | (t4 >> 50));
			const b5: uint64 = ((t5 << 28) | (t5 >> 36));
			const b6: uint64 = ((t6 << 20) | (t6 >> 44));
			const b7: uint64 = ((t7 << 3) | (t7 >> 61));
			const b8: uint64 = ((t8 << 45) | (t8 >> 19));
			const b9: uint64 = ((t9 << 61) | (t9 >> 3));
			const b10: uint64 = ((t10 << 1) | (t10 >> 63));
			const b11: uint64 = ((t11 << 6) | (t11 >> 58));
			const b12: uint64 = ((t12 << 25) | (t12 >> 39));
			const b13: uint64 = ((t13 << 8) | (t13 >> 56));
			const b14: uint64 = ((t14 << 18) | (t14 >> 46));
			const b15: uint64 = ((t15 << 27) | (t15 >> 37));
			const b16: uint64 = ((t16 << 36) | (t16 >> 28));
			const b17: uint64 = ((t17 << 10) | (t17 >> 54));
			const b18: uint64 = ((t18 << 15) | (t18 >> 49));
			const b19: uint64 = ((t19 << 56) | (t19 >> 8));
			const b20: uint64 = ((t20 << 62) | (t20 >> 2));
			const b21: uint64 = ((t21 << 55) | (t21 >> 9));
			const b22: uint64 = ((t22 << 39) | (t22 >> 25));
			const b23: uint64 = ((t23 << 41) | (t23 >> 23));
			const b24: uint64 = ((t24 << 2) | (t24 >> 62));
			a0 = b0 ^ (~b1 & b2);
			a1 = b1 ^ (~b2 & b3);
			a2 = b2 ^ (~b3 & b4);
			a3 = b3 ^ (~b4 & b0);
			a4 = b4 ^ (~b0 & b1);
			a5 = b5 ^ (~b6 & b7);
			a6 = b6 ^ (~b7 & b8);
			a7 = b7 ^ (~b8 & b9);
			a8 = b8 ^ (~b9 & b5);
			a9 = b9 ^ (~b5 & b6);
			a10 = b10 ^ (~b11 & b12);
			a11 = b11 ^ (~b12 & b13);
			a12 = b12 ^ (~b13 & b14);
			a13 = b13 ^ (~b14 & b10);
			a14 = b14 ^ (~b10 & b11);
			a15 = b15 ^ (~b16 & b17);
			a16 = b16 ^ (~b17 & b18);
			a17 = b17 ^ (~b18 & b19);
			a18 = b18 ^ (~b19 & b15);
			a19 = b19 ^ (~b15 & b16);
			a20 = b20 ^ (~b21 & b22);
			a21 = b21 ^ (~b22 & b23);
			a22 = b22 ^ (~b23 & b24);
			a23 = b23 ^ (~b24 & b20);
			a24 = b24 ^ (~b20 & b21);
			a0 ^= ((RC_HI[round] as uint64) << 32) | (RC_LO[round] as uint64);
		}
		state.st[0] = a0;
		state.st[1] = a1;
		state.st[2] = a2;
		state.st[3] = a3;
		state.st[4] = a4;
		state.st[5] = a5;
		state.st[6] = a6;
		state.st[7] = a7;
		state.st[8] = a8;
		state.st[9] = a9;
		state.st[10] = a10;
		state.st[11] = a11;
		state.st[12] = a12;
		state.st[13] = a13;
		state.st[14] = a14;
		state.st[15] = a15;
		state.st[16] = a16;
		state.st[17] = a17;
		state.st[18] = a18;
		state.st[19] = a19;
		state.st[20] = a20;
		state.st[21] = a21;
		state.st[22] = a22;
		state.st[23] = a23;
		state.st[24] = a24;
	}


	function laneAt(data: Readonly<Span<uint8>>, at: int64): uint64 {
		return (data[at] as uint64) | ((data[at + 1] as uint64) << 8) | ((data[at + 2] as uint64) << 16) | ((data[at + 3] as uint64) << 24)
			| ((data[at + 4] as uint64) << 32) | ((data[at + 5] as uint64) << 40) | ((data[at + 6] as uint64) << 48) | ((data[at + 7] as uint64) << 56);
	}

	function addBytes(state: Sha3State, data: Readonly<Span<uint8>>, at: int64, len: int32): void {
		let i = 0;
		while (i + 8 <= len) {
			state.st[i >> 3] ^= laneAt(data, at + i);
			i += 8;
		}
		for (let k = 0; i + k < len; k++) addByte(state, data[at + i + k], i + k);
	}

	function addByte(state: Sha3State, b: uint8, offset: int32): void {
		state.st[offset >> 3] ^= (b as uint64) << (((offset & 7) * 8) as uint64);
	}

	function stateByte(state: Sha3State, i: int32): uint8 {
		return ((state.st[i >> 3] >> (((i & 7) * 8) as uint64)) & 255) as uint8;
	}

	function wipeLanes(state: Sha3State): void {
		wipeWords64(state.st);
	}

	/** The pending-input buffer, inline in the state and sized for the widest rate (SHA3-224). */
	function zeroBuffer(rate: int32): uint8[144] {
		return [0];
	}

	function zeroLanes(): uint64[25] {
		return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
	}
} else {
	import { wipeWords } from "./secret";

	export class Sha3State {
		st: uint32[50];
		buf: uint8[];
		rate: int32;
		bits: int32;
		filled: int32;
		finished: boolean;
	}

	function keccakF(state: Sha3State): void {
		const st = state.st;
		let a0l: uint32 = st[0];
		let a0h: uint32 = st[1];
		let a1l: uint32 = st[2];
		let a1h: uint32 = st[3];
		let a2l: uint32 = st[4];
		let a2h: uint32 = st[5];
		let a3l: uint32 = st[6];
		let a3h: uint32 = st[7];
		let a4l: uint32 = st[8];
		let a4h: uint32 = st[9];
		let a5l: uint32 = st[10];
		let a5h: uint32 = st[11];
		let a6l: uint32 = st[12];
		let a6h: uint32 = st[13];
		let a7l: uint32 = st[14];
		let a7h: uint32 = st[15];
		let a8l: uint32 = st[16];
		let a8h: uint32 = st[17];
		let a9l: uint32 = st[18];
		let a9h: uint32 = st[19];
		let a10l: uint32 = st[20];
		let a10h: uint32 = st[21];
		let a11l: uint32 = st[22];
		let a11h: uint32 = st[23];
		let a12l: uint32 = st[24];
		let a12h: uint32 = st[25];
		let a13l: uint32 = st[26];
		let a13h: uint32 = st[27];
		let a14l: uint32 = st[28];
		let a14h: uint32 = st[29];
		let a15l: uint32 = st[30];
		let a15h: uint32 = st[31];
		let a16l: uint32 = st[32];
		let a16h: uint32 = st[33];
		let a17l: uint32 = st[34];
		let a17h: uint32 = st[35];
		let a18l: uint32 = st[36];
		let a18h: uint32 = st[37];
		let a19l: uint32 = st[38];
		let a19h: uint32 = st[39];
		let a20l: uint32 = st[40];
		let a20h: uint32 = st[41];
		let a21l: uint32 = st[42];
		let a21h: uint32 = st[43];
		let a22l: uint32 = st[44];
		let a22h: uint32 = st[45];
		let a23l: uint32 = st[46];
		let a23h: uint32 = st[47];
		let a24l: uint32 = st[48];
		let a24h: uint32 = st[49];
		for (let round = 0; round < 24; round++) {
			const c0l = a0l ^ a5l ^ a10l ^ a15l ^ a20l;
			const c0h = a0h ^ a5h ^ a10h ^ a15h ^ a20h;
			const c1l = a1l ^ a6l ^ a11l ^ a16l ^ a21l;
			const c1h = a1h ^ a6h ^ a11h ^ a16h ^ a21h;
			const c2l = a2l ^ a7l ^ a12l ^ a17l ^ a22l;
			const c2h = a2h ^ a7h ^ a12h ^ a17h ^ a22h;
			const c3l = a3l ^ a8l ^ a13l ^ a18l ^ a23l;
			const c3h = a3h ^ a8h ^ a13h ^ a18h ^ a23h;
			const c4l = a4l ^ a9l ^ a14l ^ a19l ^ a24l;
			const c4h = a4h ^ a9h ^ a14h ^ a19h ^ a24h;
			const d0l = c4l ^ ((c1l << 1) | (c1h >> 31));
			const d0h = c4h ^ ((c1h << 1) | (c1l >> 31));
			const d1l = c0l ^ ((c2l << 1) | (c2h >> 31));
			const d1h = c0h ^ ((c2h << 1) | (c2l >> 31));
			const d2l = c1l ^ ((c3l << 1) | (c3h >> 31));
			const d2h = c1h ^ ((c3h << 1) | (c3l >> 31));
			const d3l = c2l ^ ((c4l << 1) | (c4h >> 31));
			const d3h = c2h ^ ((c4h << 1) | (c4l >> 31));
			const d4l = c3l ^ ((c0l << 1) | (c0h >> 31));
			const d4h = c3h ^ ((c0h << 1) | (c0l >> 31));
			const b0l: uint32 = (a0l ^ d0l);
			const b0h: uint32 = (a0h ^ d0h);
			const b1l: uint32 = (((a6h ^ d1h) << 12) | ((a6l ^ d1l) >> 20));
			const b1h: uint32 = (((a6l ^ d1l) << 12) | ((a6h ^ d1h) >> 20));
			const b2l: uint32 = (((a12h ^ d2h) << 11) | ((a12l ^ d2l) >> 21));
			const b2h: uint32 = (((a12l ^ d2l) << 11) | ((a12h ^ d2h) >> 21));
			const b3l: uint32 = (((a18l ^ d3l) << 21) | ((a18h ^ d3h) >> 11));
			const b3h: uint32 = (((a18h ^ d3h) << 21) | ((a18l ^ d3l) >> 11));
			const b4l: uint32 = (((a24l ^ d4l) << 14) | ((a24h ^ d4h) >> 18));
			const b4h: uint32 = (((a24h ^ d4h) << 14) | ((a24l ^ d4l) >> 18));
			const b5l: uint32 = (((a3l ^ d3l) << 28) | ((a3h ^ d3h) >> 4));
			const b5h: uint32 = (((a3h ^ d3h) << 28) | ((a3l ^ d3l) >> 4));
			const b6l: uint32 = (((a9l ^ d4l) << 20) | ((a9h ^ d4h) >> 12));
			const b6h: uint32 = (((a9h ^ d4h) << 20) | ((a9l ^ d4l) >> 12));
			const b7l: uint32 = (((a10l ^ d0l) << 3) | ((a10h ^ d0h) >> 29));
			const b7h: uint32 = (((a10h ^ d0h) << 3) | ((a10l ^ d0l) >> 29));
			const b8l: uint32 = (((a16h ^ d1h) << 13) | ((a16l ^ d1l) >> 19));
			const b8h: uint32 = (((a16l ^ d1l) << 13) | ((a16h ^ d1h) >> 19));
			const b9l: uint32 = (((a22h ^ d2h) << 29) | ((a22l ^ d2l) >> 3));
			const b9h: uint32 = (((a22l ^ d2l) << 29) | ((a22h ^ d2h) >> 3));
			const b10l: uint32 = (((a1l ^ d1l) << 1) | ((a1h ^ d1h) >> 31));
			const b10h: uint32 = (((a1h ^ d1h) << 1) | ((a1l ^ d1l) >> 31));
			const b11l: uint32 = (((a7l ^ d2l) << 6) | ((a7h ^ d2h) >> 26));
			const b11h: uint32 = (((a7h ^ d2h) << 6) | ((a7l ^ d2l) >> 26));
			const b12l: uint32 = (((a13l ^ d3l) << 25) | ((a13h ^ d3h) >> 7));
			const b12h: uint32 = (((a13h ^ d3h) << 25) | ((a13l ^ d3l) >> 7));
			const b13l: uint32 = (((a19l ^ d4l) << 8) | ((a19h ^ d4h) >> 24));
			const b13h: uint32 = (((a19h ^ d4h) << 8) | ((a19l ^ d4l) >> 24));
			const b14l: uint32 = (((a20l ^ d0l) << 18) | ((a20h ^ d0h) >> 14));
			const b14h: uint32 = (((a20h ^ d0h) << 18) | ((a20l ^ d0l) >> 14));
			const b15l: uint32 = (((a4l ^ d4l) << 27) | ((a4h ^ d4h) >> 5));
			const b15h: uint32 = (((a4h ^ d4h) << 27) | ((a4l ^ d4l) >> 5));
			const b16l: uint32 = (((a5h ^ d0h) << 4) | ((a5l ^ d0l) >> 28));
			const b16h: uint32 = (((a5l ^ d0l) << 4) | ((a5h ^ d0h) >> 28));
			const b17l: uint32 = (((a11l ^ d1l) << 10) | ((a11h ^ d1h) >> 22));
			const b17h: uint32 = (((a11h ^ d1h) << 10) | ((a11l ^ d1l) >> 22));
			const b18l: uint32 = (((a17l ^ d2l) << 15) | ((a17h ^ d2h) >> 17));
			const b18h: uint32 = (((a17h ^ d2h) << 15) | ((a17l ^ d2l) >> 17));
			const b19l: uint32 = (((a23h ^ d3h) << 24) | ((a23l ^ d3l) >> 8));
			const b19h: uint32 = (((a23l ^ d3l) << 24) | ((a23h ^ d3h) >> 8));
			const b20l: uint32 = (((a2h ^ d2h) << 30) | ((a2l ^ d2l) >> 2));
			const b20h: uint32 = (((a2l ^ d2l) << 30) | ((a2h ^ d2h) >> 2));
			const b21l: uint32 = (((a8h ^ d3h) << 23) | ((a8l ^ d3l) >> 9));
			const b21h: uint32 = (((a8l ^ d3l) << 23) | ((a8h ^ d3h) >> 9));
			const b22l: uint32 = (((a14h ^ d4h) << 7) | ((a14l ^ d4l) >> 25));
			const b22h: uint32 = (((a14l ^ d4l) << 7) | ((a14h ^ d4h) >> 25));
			const b23l: uint32 = (((a15h ^ d0h) << 9) | ((a15l ^ d0l) >> 23));
			const b23h: uint32 = (((a15l ^ d0l) << 9) | ((a15h ^ d0h) >> 23));
			const b24l: uint32 = (((a21l ^ d1l) << 2) | ((a21h ^ d1h) >> 30));
			const b24h: uint32 = (((a21h ^ d1h) << 2) | ((a21l ^ d1l) >> 30));
			a0l = b0l ^ (~b1l & b2l);
			a0h = b0h ^ (~b1h & b2h);
			a1l = b1l ^ (~b2l & b3l);
			a1h = b1h ^ (~b2h & b3h);
			a2l = b2l ^ (~b3l & b4l);
			a2h = b2h ^ (~b3h & b4h);
			a3l = b3l ^ (~b4l & b0l);
			a3h = b3h ^ (~b4h & b0h);
			a4l = b4l ^ (~b0l & b1l);
			a4h = b4h ^ (~b0h & b1h);
			a5l = b5l ^ (~b6l & b7l);
			a5h = b5h ^ (~b6h & b7h);
			a6l = b6l ^ (~b7l & b8l);
			a6h = b6h ^ (~b7h & b8h);
			a7l = b7l ^ (~b8l & b9l);
			a7h = b7h ^ (~b8h & b9h);
			a8l = b8l ^ (~b9l & b5l);
			a8h = b8h ^ (~b9h & b5h);
			a9l = b9l ^ (~b5l & b6l);
			a9h = b9h ^ (~b5h & b6h);
			a10l = b10l ^ (~b11l & b12l);
			a10h = b10h ^ (~b11h & b12h);
			a11l = b11l ^ (~b12l & b13l);
			a11h = b11h ^ (~b12h & b13h);
			a12l = b12l ^ (~b13l & b14l);
			a12h = b12h ^ (~b13h & b14h);
			a13l = b13l ^ (~b14l & b10l);
			a13h = b13h ^ (~b14h & b10h);
			a14l = b14l ^ (~b10l & b11l);
			a14h = b14h ^ (~b10h & b11h);
			a15l = b15l ^ (~b16l & b17l);
			a15h = b15h ^ (~b16h & b17h);
			a16l = b16l ^ (~b17l & b18l);
			a16h = b16h ^ (~b17h & b18h);
			a17l = b17l ^ (~b18l & b19l);
			a17h = b17h ^ (~b18h & b19h);
			a18l = b18l ^ (~b19l & b15l);
			a18h = b18h ^ (~b19h & b15h);
			a19l = b19l ^ (~b15l & b16l);
			a19h = b19h ^ (~b15h & b16h);
			a20l = b20l ^ (~b21l & b22l);
			a20h = b20h ^ (~b21h & b22h);
			a21l = b21l ^ (~b22l & b23l);
			a21h = b21h ^ (~b22h & b23h);
			a22l = b22l ^ (~b23l & b24l);
			a22h = b22h ^ (~b23h & b24h);
			a23l = b23l ^ (~b24l & b20l);
			a23h = b23h ^ (~b24h & b20h);
			a24l = b24l ^ (~b20l & b21l);
			a24h = b24h ^ (~b20h & b21h);
			a0l ^= RC_LO[round];
			a0h ^= RC_HI[round];
		}
		state.st[0] = a0l;
		state.st[1] = a0h;
		state.st[2] = a1l;
		state.st[3] = a1h;
		state.st[4] = a2l;
		state.st[5] = a2h;
		state.st[6] = a3l;
		state.st[7] = a3h;
		state.st[8] = a4l;
		state.st[9] = a4h;
		state.st[10] = a5l;
		state.st[11] = a5h;
		state.st[12] = a6l;
		state.st[13] = a6h;
		state.st[14] = a7l;
		state.st[15] = a7h;
		state.st[16] = a8l;
		state.st[17] = a8h;
		state.st[18] = a9l;
		state.st[19] = a9h;
		state.st[20] = a10l;
		state.st[21] = a10h;
		state.st[22] = a11l;
		state.st[23] = a11h;
		state.st[24] = a12l;
		state.st[25] = a12h;
		state.st[26] = a13l;
		state.st[27] = a13h;
		state.st[28] = a14l;
		state.st[29] = a14h;
		state.st[30] = a15l;
		state.st[31] = a15h;
		state.st[32] = a16l;
		state.st[33] = a16h;
		state.st[34] = a17l;
		state.st[35] = a17h;
		state.st[36] = a18l;
		state.st[37] = a18h;
		state.st[38] = a19l;
		state.st[39] = a19h;
		state.st[40] = a20l;
		state.st[41] = a20h;
		state.st[42] = a21l;
		state.st[43] = a21h;
		state.st[44] = a22l;
		state.st[45] = a22h;
		state.st[46] = a23l;
		state.st[47] = a23h;
		state.st[48] = a24l;
		state.st[49] = a24h;
	}


	function addBytes(state: Sha3State, data: Readonly<Span<uint8>>, at: int64, len: int32): void {
		const base = at as number;
		let i = 0;
		while (i + 4 <= len) {
			const j = base + i;
			state.st[i >> 2] ^= (data[j] as uint32) | ((data[j + 1] as uint32) << 8) | ((data[j + 2] as uint32) << 16) | ((data[j + 3] as uint32) << 24);
			i += 4;
		}
		for (let k = 0; i + k < len; k++) addByte(state, data[base + i + k], i + k);
	}

	function addByte(state: Sha3State, b: uint8, offset: int32): void {
		state.st[offset >> 2] ^= (b as uint32) << (((offset & 3) * 8) as uint32);
	}

	function stateByte(state: Sha3State, i: int32): uint8 {
		return ((state.st[i >> 2] >> (((i & 3) * 8) as uint32)) & 255) as uint8;
	}

	function wipeLanes(state: Sha3State): void {
		wipeWords(state.st);
	}

	function zeroBuffer(rate: int32): uint8[] {
		return new Array<uint8>(rate);
	}

	function zeroLanes(): uint32[50] {
		return [
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
		];
	}
}

/** Returns a new SHA3 state for the given output size (224, 256, 384 or 512 bits). */
export function newSha3(bits: int32): Sha3State {
	if (bits != 224 && bits != 256 && bits != 384 && bits != 512) throw new Error("SHA3: unsupported output size");
	const rate = 200 - (bits >> 2);
	return {
		st: zeroLanes(),
		buf: zeroBuffer(rate),
		rate,
		bits,
		filled: 0,
		finished: false,
	};
}

/** Absorb data into the sponge. Throws if called after finishSha3. */
export function updateSha3(state: Sha3State, data: Readonly<Span<uint8>>): void {
	if (state.finished) throw new Error("SHA3: already finished");
	const n: int64 = data.length;
	const rate = state.rate;
	let i: int64 = 0;
	if (state.filled > 0) {
		const room = rate - state.filled;
		const take = n < room ? n as int32 : room;
		for (let j = 0; j < take; j++) state.buf[state.filled + j] = data[j];
		state.filled += take;
		if (take == n) return;
		if (state.filled == rate) {
			addBytes(state, state.buf, 0, rate);
			keccakF(state);
			state.filled = 0;
		}
		i = take;
	}
	while (n - i > rate) {
		addBytes(state, data, i, rate);
		keccakF(state);
		i += rate;
	}
	const left = (n - i) as int32;
	for (let j = 0; j < left; j++) state.buf[j] = data[i + j];
	state.filled = left;
}

/** Pad, permute, and return the digest bytes; the state is wiped afterwards. Throws if called more than once. */
export function finishSha3(state: Sha3State): uint8[] {
	const out = new Array<uint8>(state.bits >> 3);
	finishSha3Into(state, out);
	return out;
}

/** Pad, permute, and write the `bits / 8` digest bytes to `out`; the state is wiped afterwards. */
export function finishSha3Into(state: Sha3State, out: Span<uint8>): void {
	if (state.finished) throw new Error("SHA3: already finished");
	const rate = state.rate;
	addBytes(state, state.buf, 0, state.filled);
	if (state.filled == rate) {
		keccakF(state);
		state.filled = 0;
	}
	addByte(state, 0x06, state.filled);
	addByte(state, 0x80, rate - 1);
	keccakF(state);
	state.finished = true;
	for (let i = 0; i < state.bits >> 3; i++) out[i] = stateByte(state, i);
	wipeLanes(state);
	wipeBytes(state.buf);
	state.filled = 0;
}

/** Hash data in one call. */
export function sha3Of(bits: int32, data: Readonly<Span<uint8>>): uint8[] {
	const state = newSha3(bits);
	updateSha3(state, data);
	return finishSha3(state);
}

function hex(bytes: Readonly<uint8[]>): string {
	return bytes.encodeHex();
}

const longMsg = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu";

test "sha3-224 NIST vectors" {
	assert hex(sha3Of(224, "".asBytes().slice(0))) == "6b4e03423667dbb73b6e15454f0eb1abd4597f9a1b078e3f5b5a6bc7";
	assert hex(sha3Of(224, "abc".asBytes().slice(0))) == "e642824c3f8cf24ad09234ee7d3c766fc9a3a5168d0c94ad73b46fdf";
	assert hex(sha3Of(224, longMsg.asBytes().slice(0))) == "543e6868e1666c1a643630df77367ae5a62a85070a51c14cbf665cbc";
}

test "sha3-256 NIST vectors" {
	assert hex(sha3Of(256, "".asBytes().slice(0))) == "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a";
	assert hex(sha3Of(256, "abc".asBytes().slice(0))) == "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532";
	assert hex(sha3Of(256, longMsg.asBytes().slice(0))) == "916f6061fe879741ca6469b43971dfdb28b1a32dc36cb3254e812be27aad1d18";
}

test "sha3-384 NIST vectors" {
	assert hex(sha3Of(384, "".asBytes().slice(0))) == "0c63a75b845e4f7d01107d852e4c2485c51a50aaaa94fc61995e71bbee983a2ac3713831264adb47fb6bd1e058d5f004";
	assert hex(sha3Of(384, "abc".asBytes().slice(0))) == "ec01498288516fc926459f58e2c6ad8df9b473cb0fc08c2596da7cf0e49be4b298d88cea927ac7f539f1edf228376d25";
	assert hex(sha3Of(384, longMsg.asBytes().slice(0))) == "79407d3b5916b59c3e30b09822974791c313fb9ecc849e406f23592d04f625dc8c709b98b43b3852b337216179aa7fc7";
}

test "sha3-512 NIST vectors" {
	assert hex(sha3Of(512, "".asBytes().slice(0))) == "a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26";
	assert hex(sha3Of(512, "abc".asBytes().slice(0))) == "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0";
	assert hex(sha3Of(512, longMsg.asBytes().slice(0))) == "afebb2ef542e6579c50cad06d2e578f9f8dd6881d7dc824d26360feebf18a4fa73e3261122948efcfd492e74e82e2189ed0fb440d187f382270cb455f21dd185";
}

test "sha3-256 split update matches single call" {
	const s = newSha3(256);
	updateSha3(s, "a".asBytes().slice(0));
	updateSha3(s, "bc".asBytes().slice(0));
	assert hex(finishSha3(s)) == "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532";
}

test "sha3-256 rate-boundary flush" {
	const all = new Array<uint8>(137);
	const ref = sha3Of(256, all);
	const s = newSha3(256);
	updateSha3(s, new Array<uint8>(136));
	updateSha3(s, new Array<uint8>(1));
	assert hex(finishSha3(s)) == hex(ref);
}

test "sha3-512 split update" {
	const s = newSha3(512);
	updateSha3(s, "a".asBytes().slice(0));
	updateSha3(s, "bc".asBytes().slice(0));
	assert hex(finishSha3(s)) == "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0";
}

test "sha3 rejects unsupported output sizes" {
	for (const bits of [0, 128, 225, 1024]) {
		let threw = false;
		try {
			newSha3(bits);
		} catch (e) {
			threw = true;
		}
		assert threw;
	}
}

test "sha3 update after finish throws even for empty input" {
	const s = newSha3(256);
	finishSha3(s);
	let threw = false;
	try {
		updateSha3(s, []);
	} catch (e) {
		threw = true;
	}
	assert threw;
}

test "sha3 finish wipes the sponge state and buffer" {
	const s = newSha3(256);
	updateSha3(s, "abc".asBytes().slice(0));
	finishSha3(s);
	for (let i = 0; i < s.st.length; i++) assert s.st[i] == 0;
	for (let i = 0; i < s.buf.length; i++) assert s.buf[i] == 0;
}

test "sha3 finish after finish throws" {
	const s = newSha3(512);
	finishSha3(s);
	let threw = false;
	try {
		finishSha3(s);
	} catch (e) {
		threw = true;
	}
	assert threw;
}

test "sha3-256 zero input rate boundaries match reference" {
	assert hex(sha3Of(256, new Array<uint8>(135))) == "7d080d7ba978a75c8a7d1f9be566c859084509c9c2b4928435c225d5777d98e3";
	assert hex(sha3Of(256, new Array<uint8>(136))) == "e772c9cf9eb9c991cdfcf125001b454fdbc0a95f188d1b4c844aa032ad6e075e";
	assert hex(sha3Of(256, new Array<uint8>(137))) == "9ed57188470a83b758cd71c00c6cc3beb984b36a6c35864b4e53017b24cf5699";
}

test "sha3-512 zero input rate boundaries match reference" {
	assert hex(sha3Of(512, new Array<uint8>(71))) == "cd87417194c917561a59c7f2eb4b95145971e32e8e4ef3b23b0f190bfd29e3692cc7975275750a27df95d5c6a99b7a341e1b8a38a750a51aca5b77bae41fbbfc";
	assert hex(sha3Of(512, new Array<uint8>(72))) == "f8d76fdd8a082a67eaab47b5518ac486cb9a90dcb9f3c9efcfd86d5c8b3f1831601d3c8435f84b9e56da91283d5b98040e6e7b2c8dd9aa5bd4ebdf1823a7cf29";
	assert hex(sha3Of(512, new Array<uint8>(73))) == "4ed8ba5741d94caef309c190bc13d18eb0f16942ebea76dcf0c6db1a35311fc04611313ea7d0ff2228a131cd68a84b3872c93d75700601107b6addeaffaa7a90";
}

test "sha3-224 zero input rate boundaries match reference" {
	assert hex(sha3Of(224, new Array<uint8>(143))) == "b6b709fdb9852b8c7439a33595d42dba2940f44c10c3ce09f8b6a87a";
	assert hex(sha3Of(224, new Array<uint8>(144))) == "f2b8486fceee2c6a11a604ce4efe217da854829c2c2dcc9a23758b4d";
	assert hex(sha3Of(224, new Array<uint8>(145))) == "361ca40de495e03bd091694f1d1372851105046a1bf6d59fafe7d668";
}

test "sha3-384 zero input rate boundaries match reference" {
	assert hex(sha3Of(384, new Array<uint8>(103))) == "11c556552dda63418669716bad02e4125f4973f3ceea99ee50b6ff117e9f7a3fed0360abb5eff4ac8e954205c01981d2";
	assert hex(sha3Of(384, new Array<uint8>(104))) == "aaed6beb61b1f9a9b469d38a27a35edde7f676f4603e67f5424c7588043b869ebbfcfc3ecee2ae6f5ecfaf7f706c49e3";
	assert hex(sha3Of(384, new Array<uint8>(105))) == "7db7a10350831a0b3c8c94a138a301858dd8c6d589cd1b47f6720f9243162f952161ae945ec8cf7a838d02cfbcc762ee";
}

function counting(n: int32): uint8[] {
	const out = new Array<uint8>(n);
	for (let i = 0; i < n; i++) out[i] = (i & 255) as uint8;
	return out;
}

function splitHex(bits: int32, data: Readonly<uint8[]>, cut: int32): string {
	const s = newSha3(bits);
	updateSha3(s, data.slice(0, cut));
	updateSha3(s, data.slice(cut));
	return hex(finishSha3(s));
}

function byteByByteHex(bits: int32, data: Readonly<uint8[]>): string {
	const s = newSha3(bits);
	const n = data.length as int32;
	for (let i = 0; i < n; i++) updateSha3(s, data.slice(i, i + 1));
	return hex(finishSha3(s));
}

test "sha3 multi-block input split at every rate edge matches reference" {
	const data = counting(500);
	const sizes: int32[] = [224, 256, 384, 512];
	const want = [
		"eb7d43dfd550ee5aff6159b3ccaee0715c9c36bbce1822ad7e26702e",
		"0f96259f82fb8c30d3d702e8a89a475d2e96690a5ee9892a48351864fb492aa5",
		"88587b396e4297ab27908fb4741a3259372e6dd8fa62b22912d0c60afc4eb89cfd6a7baa7f8690f6be874140b1d52713",
		"5c371829f774959d04ac4b4e49557e4355427407ca960a3acc9643bb5b13cb692bbe281f3f4137784551092b4613e016a4f1ff2714f8f67f97d11e3233a9b662",
	];
	for (let k = 0; k < 4; k++) {
		const bits = sizes[k];
		const rate = 200 - (bits >> 2);
		assert hex(sha3Of(bits, data)) == want[k];
		const cuts: int32[] = [0, 1, rate - 1, rate, rate + 1, 2 * rate, 499, 500];
		for (const cut of cuts) assert splitHex(bits, data, cut) == want[k];
		assert byteByByteHex(bits, data) == want[k];
	}
}

test "sha3-256 of a million a fed in uneven chunks" {
	const s = newSha3(256);
	const big = new Array<uint8>(1000);
	for (let i = 0; i < 1000; i++) big[i] = 97;
	const odd = new Array<uint8>(7);
	for (let i = 0; i < 7; i++) odd[i] = 97;
	for (let i = 0; i < 500; i++) updateSha3(s, big);
	for (let i = 0; i < 71428; i++) updateSha3(s, odd);
	for (let i = 0; i < 4; i++) updateSha3(s, odd.slice(0, 1));
	assert hex(finishSha3(s)) == "5c8875ae474a3634ba4fd55ec85bffd661f32aca75c6d699d0cdcb6c115891c1";
}
