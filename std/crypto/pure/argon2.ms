import { newBlake2b, updateBlake2b, finishBlake2bInto } from "./blake2b";
import { wipeBytes, wipeWords } from "./secret";

const noKey: Readonly<uint8[]> = [];
const syncPoints = 4;
const maxWords = 2147483647;

/** Scratch for one Argon2 run: the halves of the block under compression on JS, the address blocks and the byte forms the hashes read. */
class Argon2Work {
	low: uint32[128];
	high: uint32[128];
	address: uint32[];
	h0: uint8[];
	bytes: uint8[];
	word: uint8[];
	chain: uint8[];
	last: uint32[];
}

function newWork(): Argon2Work {
	return { low: [0], high: [0], address: new Array<uint32>(768), h0: new Array<uint8>(72), bytes: new Array<uint8>(1024), word: new Array<uint8>(4), chain: new Array<uint8>(64), last: new Array<uint32>(256) };
}

function put32(out: uint8[], at: int32, value: number): void {
	const v = value as uint32;
	out[at] = (v & 255) as uint8;
	out[at + 1] = ((v >> 8) & 255) as uint8;
	out[at + 2] = ((v >> 16) & 255) as uint8;
	out[at + 3] = ((v >> 24) & 255) as uint8;
}

function carry(sum: uint32, addend: uint32): uint32 {
	return sum < addend ? 1 : 0;
}

/** The high 32 bits of a * b, from 16-bit halves so no step leaves 32 bits. */
function mulHigh(a: uint32, b: uint32): uint32 {
	const a0 = a & 0xffff;
	const a1 = a >> 16;
	const b0 = b & 0xffff;
	const b1 = b >> 16;
	const lh = a0 * b1;
	const hl = a1 * b0;
	const mid = ((a0 * b0) >> 16) + (lh & 0xffff) + (hl & 0xffff);
	return a1 * b1 + (lh >> 16) + (hl >> 16) + (mid >> 16);
}

/** The BlaMka G of RFC 9106 3.6 on words a, b, c and d of the block, each held as its `w.low` and `w.high` halves. */
function mixG(w: Argon2Work, a: int32, b: int32, c: int32, d: int32): void {
	let al = w.low[a];
	let ah = w.high[a];
	let bl = w.low[b];
	let bh = w.high[b];
	let cl = w.low[c];
	let ch = w.high[c];
	let dl = w.low[d];
	let dh = w.high[d];
	{
		const ml = al * bl;
		const sum = al + bl;
		const twice = ml << 1;
		const total = sum + twice;
		ah = ah + bh + ((mulHigh(al, bl) << 1) | (ml >> 31)) + carry(sum, bl) + carry(total, twice);
		al = total;
		const xl = dl ^ al;
		dl = dh ^ ah;
		dh = xl;
	}
	{
		const ml = cl * dl;
		const sum = cl + dl;
		const twice = ml << 1;
		const total = sum + twice;
		ch = ch + dh + ((mulHigh(cl, dl) << 1) | (ml >> 31)) + carry(sum, dl) + carry(total, twice);
		cl = total;
		const xl = bl ^ cl;
		const xh = bh ^ ch;
		bh = (xh >> 24) | (xl << 8);
		bl = (xl >> 24) | (xh << 8);
	}
	{
		const ml = al * bl;
		const sum = al + bl;
		const twice = ml << 1;
		const total = sum + twice;
		ah = ah + bh + ((mulHigh(al, bl) << 1) | (ml >> 31)) + carry(sum, bl) + carry(total, twice);
		al = total;
		const xl = dl ^ al;
		const xh = dh ^ ah;
		dh = (xh >> 16) | (xl << 16);
		dl = (xl >> 16) | (xh << 16);
	}
	{
		const ml = cl * dl;
		const sum = cl + dl;
		const twice = ml << 1;
		const total = sum + twice;
		ch = ch + dh + ((mulHigh(cl, dl) << 1) | (ml >> 31)) + carry(sum, dl) + carry(total, twice);
		cl = total;
		const xl = bl ^ cl;
		const xh = bh ^ ch;
		bh = (xh << 1) | (xl >> 31);
		bl = (xl << 1) | (xh >> 31);
	}
	w.low[a] = al;
	w.high[a] = ah;
	w.low[b] = bl;
	w.high[b] = bh;
	w.low[c] = cl;
	w.high[c] = ch;
	w.low[d] = dl;
	w.high[d] = dh;
}

function permute(w: Argon2Work, i0: int32, i1: int32, i2: int32, i3: int32, i4: int32, i5: int32, i6: int32, i7: int32, i8: int32, i9: int32, i10: int32, i11: int32, i12: int32, i13: int32, i14: int32, i15: int32): void {
	mixG(w, i0, i4, i8, i12);
	mixG(w, i1, i5, i9, i13);
	mixG(w, i2, i6, i10, i14);
	mixG(w, i3, i7, i11, i15);
	mixG(w, i0, i5, i10, i15);
	mixG(w, i1, i6, i11, i12);
	mixG(w, i2, i7, i8, i13);
	mixG(w, i3, i4, i9, i14);
}

when (c) {
	function fBlaMka(x: uint64, y: uint64): uint64 {
		return x + y + 2 * (x & 0xffffffff) * (y & 0xffffffff);
	}

	function rotr64(x: uint64, n: uint64): uint64 {
		return (x >> n) | (x << (64 - n));
	}

	/** The BlaMka round of RFC 9106 3.6 over the 16 words of `t` from `at`; constant offsets let the C compiler keep them in vector registers. */
	function roundRow(t: Span<uint64>, at: int64): void {
		let v0 = t[at];
		let v1 = t[at + 1];
		let v2 = t[at + 2];
		let v3 = t[at + 3];
		let v4 = t[at + 4];
		let v5 = t[at + 5];
		let v6 = t[at + 6];
		let v7 = t[at + 7];
		let v8 = t[at + 8];
		let v9 = t[at + 9];
		let v10 = t[at + 10];
		let v11 = t[at + 11];
		let v12 = t[at + 12];
		let v13 = t[at + 13];
		let v14 = t[at + 14];
		let v15 = t[at + 15];
		v0 = fBlaMka(v0, v4);
		v12 = rotr64(v12 ^ v0, 32);
		v8 = fBlaMka(v8, v12);
		v4 = rotr64(v4 ^ v8, 24);
		v0 = fBlaMka(v0, v4);
		v12 = rotr64(v12 ^ v0, 16);
		v8 = fBlaMka(v8, v12);
		v4 = rotr64(v4 ^ v8, 63);
		v1 = fBlaMka(v1, v5);
		v13 = rotr64(v13 ^ v1, 32);
		v9 = fBlaMka(v9, v13);
		v5 = rotr64(v5 ^ v9, 24);
		v1 = fBlaMka(v1, v5);
		v13 = rotr64(v13 ^ v1, 16);
		v9 = fBlaMka(v9, v13);
		v5 = rotr64(v5 ^ v9, 63);
		v2 = fBlaMka(v2, v6);
		v14 = rotr64(v14 ^ v2, 32);
		v10 = fBlaMka(v10, v14);
		v6 = rotr64(v6 ^ v10, 24);
		v2 = fBlaMka(v2, v6);
		v14 = rotr64(v14 ^ v2, 16);
		v10 = fBlaMka(v10, v14);
		v6 = rotr64(v6 ^ v10, 63);
		v3 = fBlaMka(v3, v7);
		v15 = rotr64(v15 ^ v3, 32);
		v11 = fBlaMka(v11, v15);
		v7 = rotr64(v7 ^ v11, 24);
		v3 = fBlaMka(v3, v7);
		v15 = rotr64(v15 ^ v3, 16);
		v11 = fBlaMka(v11, v15);
		v7 = rotr64(v7 ^ v11, 63);
		v0 = fBlaMka(v0, v5);
		v15 = rotr64(v15 ^ v0, 32);
		v10 = fBlaMka(v10, v15);
		v5 = rotr64(v5 ^ v10, 24);
		v0 = fBlaMka(v0, v5);
		v15 = rotr64(v15 ^ v0, 16);
		v10 = fBlaMka(v10, v15);
		v5 = rotr64(v5 ^ v10, 63);
		v1 = fBlaMka(v1, v6);
		v12 = rotr64(v12 ^ v1, 32);
		v11 = fBlaMka(v11, v12);
		v6 = rotr64(v6 ^ v11, 24);
		v1 = fBlaMka(v1, v6);
		v12 = rotr64(v12 ^ v1, 16);
		v11 = fBlaMka(v11, v12);
		v6 = rotr64(v6 ^ v11, 63);
		v2 = fBlaMka(v2, v7);
		v13 = rotr64(v13 ^ v2, 32);
		v8 = fBlaMka(v8, v13);
		v7 = rotr64(v7 ^ v8, 24);
		v2 = fBlaMka(v2, v7);
		v13 = rotr64(v13 ^ v2, 16);
		v8 = fBlaMka(v8, v13);
		v7 = rotr64(v7 ^ v8, 63);
		v3 = fBlaMka(v3, v4);
		v14 = rotr64(v14 ^ v3, 32);
		v9 = fBlaMka(v9, v14);
		v4 = rotr64(v4 ^ v9, 24);
		v3 = fBlaMka(v3, v4);
		v14 = rotr64(v14 ^ v3, 16);
		v9 = fBlaMka(v9, v14);
		v4 = rotr64(v4 ^ v9, 63);
		t[at] = v0;
		t[at + 1] = v1;
		t[at + 2] = v2;
		t[at + 3] = v3;
		t[at + 4] = v4;
		t[at + 5] = v5;
		t[at + 6] = v6;
		t[at + 7] = v7;
		t[at + 8] = v8;
		t[at + 9] = v9;
		t[at + 10] = v10;
		t[at + 11] = v11;
		t[at + 12] = v12;
		t[at + 13] = v13;
		t[at + 14] = v14;
		t[at + 15] = v15;
	}

	/** The BlaMka G of RFC 9106 3.6 on words a, b, c and d of `t`. */
	@inline
	function mix64(t: Span<uint64>, a: int64, b: int64, c: int64, d: int64): void {
		let va = t[a];
		let vb = t[b];
		let vc = t[c];
		let vd = t[d];
		va = fBlaMka(va, vb);
		vd = rotr64(vd ^ va, 32);
		vc = fBlaMka(vc, vd);
		vb = rotr64(vb ^ vc, 24);
		va = fBlaMka(va, vb);
		vd = rotr64(vd ^ va, 16);
		vc = fBlaMka(vc, vd);
		vb = rotr64(vb ^ vc, 63);
		t[a] = va;
		t[b] = vb;
		t[c] = vc;
		t[d] = vd;
	}

	/** The compression function on native 64-bit words, for a backend where uint64 is a machine word: each (low, high) pair of `x` is read and written as one little-endian uint64. */
	function compressWide(x: Span<uint32>, xPos: int32, yPos: int32, outPos: int32, needXor: boolean): void {
		@emit(`_Static_assert(__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__, "a uint32 pair is read as one uint64");`);
		const m = (x as Ptr<uint32>) as Ptr<uint64>;
		const words = m[0..x.length / 2];
		const xAt = (xPos / 2) as int64;
		const yAt = (yPos / 2) as int64;
		const outAt = (outPos / 2) as int64;
		let t: uint64[128] = [0];
		for (let i: int64 = 0; i < 128; i++) t[i] = words[xAt + i] ^ words[yAt + i];
		for (let i: int64 = 0; i < 128; i += 16) roundRow(t, i);
		for (let i: int64 = 0; i < 32; i++) mix64(t, i, i + 32, i + 64, i + 96);
		for (let i: int64 = 0; i < 16; i += 2) {
			mix64(t, i, i + 33, i + 80, i + 113);
			mix64(t, i + 1, i + 48, i + 81, i + 96);
			mix64(t, i + 16, i + 49, i + 64, i + 97);
			mix64(t, i + 17, i + 32, i + 65, i + 112);
		}
		if (needXor) {
			for (let i: int64 = 0; i < 128; i++) words[outAt + i] = words[outAt + i] ^ t[i] ^ words[xAt + i] ^ words[yAt + i];
		} else {
			for (let i: int64 = 0; i < 128; i++) words[outAt + i] = t[i] ^ words[xAt + i] ^ words[yAt + i];
		}
	}
}

/** The compression function: out (xor-accumulated when `needXor`) from the blocks at `xPos` and `yPos` of `x`. */
function compressBlock(w: Argon2Work, x: uint32[], xPos: int32, yPos: int32, outPos: int32, needXor: boolean): void {
	when (c) {
		compressWide(x, xPos, yPos, outPos, needXor);
	} else {
		compressPairs(w, x, xPos, yPos, outPos, needXor);
	}
}

/** The compression function on (low, high) 32-bit halves, for a backend whose 64-bit integers are not machine words. */
function compressPairs(w: Argon2Work, x: uint32[], xPos: int32, yPos: int32, outPos: int32, needXor: boolean): void {
	let xi = xPos;
	let yi = yPos;
	let oi = outPos;
	for (let i = 0; i < 128; i++) {
		const low = x[xi] ^ x[yi];
		const high = x[xi + 1] ^ x[yi + 1];
		w.low[i] = low;
		w.high[i] = high;
		if (needXor) {
			x[oi] = x[oi] ^ low;
			x[oi + 1] = x[oi + 1] ^ high;
		} else {
			x[oi] = low;
			x[oi + 1] = high;
		}
		xi += 2;
		yi += 2;
		oi += 2;
	}
	for (let i = 0; i < 128; i += 16) {
		permute(w, i, i + 1, i + 2, i + 3, i + 4, i + 5, i + 6, i + 7, i + 8, i + 9, i + 10, i + 11, i + 12, i + 13, i + 14, i + 15);
	}
	for (let i = 0; i < 16; i += 2) {
		permute(w, i, i + 1, i + 16, i + 17, i + 32, i + 33, i + 48, i + 49, i + 64, i + 65, i + 80, i + 81, i + 96, i + 97, i + 112, i + 113);
	}
	oi = outPos;
	for (let i = 0; i < 128; i++) {
		x[oi] = x[oi] ^ w.low[i];
		x[oi + 1] = x[oi + 1] ^ w.high[i];
		oi += 2;
	}
}

/** The variable-length hash H' of `length` bytes of `data`, `outLength` bytes into `out` at `outOff`. */
function hPrime(w: Argon2Work, data: Readonly<uint8[]>, length: int32, outLength: int32, out: uint8[], outOff: int32): void {
	put32(w.word, 0, outLength);
	if (outLength <= 64) {
		const s = newBlake2b(outLength, noKey);
		updateBlake2b(s, w.word, 0, 4);
		updateBlake2b(s, data, 0, length);
		finishBlake2bInto(s, out, outOff);
		return;
	}
	const v = w.chain;
	const first = newBlake2b(64, noKey);
	updateBlake2b(first, w.word, 0, 4);
	updateBlake2b(first, data, 0, length);
	finishBlake2bInto(first, v, 0);
	for (let i = 0; i < 32; i++) out[outOff + i] = v[i];
	let pos = 32;
	while (outLength - pos > 64) {
		const next = newBlake2b(64, noKey);
		updateBlake2b(next, v, 0, 64);
		finishBlake2bInto(next, v, 0);
		for (let i = 0; i < 32; i++) out[outOff + pos + i] = v[i];
		pos += 32;
	}
	const last = newBlake2b(outLength - pos, noKey);
	updateBlake2b(last, v, 0, 64);
	finishBlake2bInto(last, out, outOff + pos);
}

function wordsToBytes(words: Readonly<uint32[]>, from: int32, out: uint8[]): void {
	for (let i = 0; i < 256; i++) put32(out, i * 4, words[from + i]);
}

function bytesToWords(bytes: Readonly<uint8[]>, words: uint32[], to: int32): void {
	for (let i = 0; i < 256; i++) {
		words[to + i] = (bytes[i * 4] as uint32) | ((bytes[i * 4 + 1] as uint32) << 8) | ((bytes[i * 4 + 2] as uint32) << 16) | ((bytes[i * 4 + 3] as uint32) << 24);
	}
}

/** Where block `index` of a segment may reference, as an offset into the lane (RFC 9106 3.4.1.1). */
function indexAlpha(pass: int32, slice: int32, laneLen: int32, segmentLen: int32, index: int32, randL: uint32, sameLane: boolean): int32 {
	let area: int32;
	if (pass == 0) {
		if (slice == 0) area = index - 1;
		else if (sameLane) area = slice * segmentLen + index - 1;
		else area = slice * segmentLen + (index == 0 ? -1 : 0);
	} else if (sameLane) area = laneLen - segmentLen + index - 1;
	else area = laneLen - segmentLen + (index == 0 ? -1 : 0);
	const startPos = pass != 0 && slice != syncPoints - 1 ? (slice + 1) * segmentLen : 0;
	const randHigh = mulHigh(randL, randL);
	const areaHigh = mulHigh(area as uint32, randHigh);
	return (startPos + area - 1 - (areaHigh as int32)) % laneLen;
}

/** The checks the reference makes before hashing; "" when the parameters are valid, else its message for the first one broken. */
export function argon2Problem(timeCost: number, memoryCost: number, parallelism: number, hashLen: number, saltLen: number): string {
	if (hashLen < 4) return "Output is too short";
	if (saltLen < 8) return "Salt is too short";
	if (timeCost < 1) return "Time cost is too small";
	if (parallelism < 1) return "Too few lanes";
	if (parallelism > 16777215) return "Too many lanes";
	if (memoryCost < 8 || memoryCost < 8 * parallelism) return "Memory cost is too small";
	return "";
}

/** The number of 32-bit words of memory an Argon2id run with these parameters fills. */
export function argon2Words(memoryCost: int32, parallelism: int32): number {
	return 256 * 4 * parallelism * Math.floor(memoryCost / (syncPoints * parallelism));
}

export enum Argon2Mode {
	Argon2d,
	Argon2i,
	Argon2id,
}

function modeId(mode: Argon2Mode): int32 {
	return match (mode) {
		Argon2Mode.Argon2d => 0,
		Argon2Mode.Argon2i => 1,
		Argon2Mode.Argon2id => 2,
	};
}

export function argon2ModeName(mode: Argon2Mode): string {
	return match (mode) {
		Argon2Mode.Argon2d => "argon2d",
		Argon2Mode.Argon2i => "argon2i",
		Argon2Mode.Argon2id => "argon2id",
	};
}

function modeOfName(name: string): Argon2Mode | null {
	if (name == "argon2d") return Argon2Mode.Argon2d;
	if (name == "argon2i") return Argon2Mode.Argon2i;
	if (name == "argon2id") return Argon2Mode.Argon2id;
	return null;
}

/**
 * Argon2id (RFC 9106) of `password` and `salt`, `hashLen` bytes, with no secret and no associated data.
 * `memory` is `argon2Words(memoryCost, parallelism)` words the caller allocates; the parameters were checked
 * with `argon2Problem`. `version` 0x10 overwrites on later passes, any other value (0x13) xors.
 */
export function argon2idHash(memory: uint32[], password: Readonly<uint8[]>, salt: Readonly<uint8[]>, timeCost: int32, memoryCost: int32, parallelism: int32, version: int32, hashLen: int32): uint8[] {
	return argon2Fill(memory, password, salt, noKey, noKey, Argon2Mode.Argon2id, timeCost, memoryCost, parallelism, version, hashLen);
}

/** Argon2 of any mode with the optional `secret` (keyed hashing) and associated data `ad`; memory and checks as `argon2idHash`. */
export function argon2Fill(memory: uint32[], password: Readonly<uint8[]>, salt: Readonly<uint8[]>, secret: Readonly<uint8[]>, ad: Readonly<uint8[]>, mode: Argon2Mode, timeCost: int32, memoryCost: int32, parallelism: int32, version: int32, hashLen: int32): uint8[] {
	const w = newWork();
	const typeId = modeId(mode);
	const laneLen = 4 * (Math.floor(memoryCost / (syncPoints * parallelism)) as int32);
	const memoryBlocks = laneLen * parallelism;
	const segmentLen = laneLen / syncPoints;

	const initial = newBlake2b(64, noKey);
	put32(w.word, 0, parallelism);
	updateBlake2b(initial, w.word, 0, 4);
	put32(w.word, 0, hashLen);
	updateBlake2b(initial, w.word, 0, 4);
	put32(w.word, 0, memoryCost);
	updateBlake2b(initial, w.word, 0, 4);
	put32(w.word, 0, timeCost);
	updateBlake2b(initial, w.word, 0, 4);
	put32(w.word, 0, version);
	updateBlake2b(initial, w.word, 0, 4);
	put32(w.word, 0, typeId);
	updateBlake2b(initial, w.word, 0, 4);
	put32(w.word, 0, password.length as int32);
	updateBlake2b(initial, w.word, 0, 4);
	updateBlake2b(initial, password, 0, password.length as int32);
	put32(w.word, 0, salt.length as int32);
	updateBlake2b(initial, w.word, 0, 4);
	updateBlake2b(initial, salt, 0, salt.length as int32);
	put32(w.word, 0, secret.length as int32);
	updateBlake2b(initial, w.word, 0, 4);
	updateBlake2b(initial, secret, 0, secret.length as int32);
	put32(w.word, 0, ad.length as int32);
	updateBlake2b(initial, w.word, 0, 4);
	updateBlake2b(initial, ad, 0, ad.length as int32);
	finishBlake2bInto(initial, w.h0, 0);

	for (let l = 0; l < parallelism; l++) {
		const at = 256 * laneLen * l;
		put32(w.h0, 68, l);
		put32(w.h0, 64, 0);
		hPrime(w, w.h0, 72, 1024, w.bytes, 0);
		bytesToWords(w.bytes, memory, at);
		put32(w.h0, 64, 1);
		hPrime(w, w.h0, 72, 1024, w.bytes, 0);
		bytesToWords(w.bytes, memory, at + 256);
	}

	w.address[256 + 6] = memoryBlocks as uint32;
	w.address[256 + 8] = timeCost as uint32;
	w.address[256 + 10] = typeId as uint32;
	for (let r = 0; r < timeCost; r++) {
		const needXor = r != 0 && version != 0x10;
		w.address[256 + 0] = r as uint32;
		for (let s = 0; s < syncPoints; s++) {
			w.address[256 + 4] = s as uint32;
			const dataIndependent = mode == Argon2Mode.Argon2i || (mode == Argon2Mode.Argon2id && r == 0 && s < 2);
			for (let l = 0; l < parallelism; l++) {
				w.address[256 + 2] = l as uint32;
				w.address[256 + 12] = 0;
				let startPos = 0;
				if (r == 0 && s == 0) {
					startPos = 2;
					if (dataIndependent) {
						w.address[256 + 12] = w.address[256 + 12] + 1;
						compressBlock(w, w.address, 256, 512, 0, false);
						compressBlock(w, w.address, 0, 512, 0, false);
					}
				}
				let offset = l * laneLen + s * segmentLen + startPos;
				for (let index = startPos; index < segmentLen; index++) {
					const prev = offset % laneLen != 0 ? offset - 1 : offset + laneLen - 1;
					let randL: uint32;
					let randH: uint32;
					if (dataIndependent) {
						const i128 = index % 128;
						if (i128 == 0) {
							w.address[256 + 12] = w.address[256 + 12] + 1;
							compressBlock(w, w.address, 256, 512, 0, false);
							compressBlock(w, w.address, 0, 512, 0, false);
						}
						randL = w.address[2 * i128];
						randH = w.address[2 * i128 + 1];
					} else {
						randL = memory[256 * prev];
						randH = memory[256 * prev + 1];
					}
					const refLane = r == 0 && s == 0 ? l : ((randH % (parallelism as uint32)) as int32);
					const refPos = indexAlpha(r, s, laneLen, segmentLen, index, randL, refLane == l);
					compressBlock(w, memory, 256 * prev, 256 * (laneLen * refLane + refPos), offset * 256, needXor);
					offset += 1;
				}
			}
		}
	}

	const last = w.last;
	for (let l = 0; l < parallelism; l++) {
		for (let j = 0; j < 256; j++) last[j] = last[j] ^ memory[256 * (laneLen * l + laneLen - 1) + j];
	}
	wordsToBytes(last, 0, w.bytes);
	const out = new Array<uint8>(hashLen);
	hPrime(w, w.bytes, 1024, hashLen, out, 0);
	wipeWords(memory);
	wipeWork(w);
	return out;
}

function wipeWork(w: Argon2Work): void {
	wipeWords(w.low);
	wipeWords(w.high);
	wipeWords(w.address);
	wipeBytes(w.h0);
	wipeBytes(w.bytes);
	wipeBytes(w.word);
	wipeBytes(w.chain);
	wipeWords(w.last);
}

function maskEq(x: uint32, y: uint32): uint32 {
	return (((0 - (x ^ y)) >> 8) & 0xff) ^ 0xff;
}

function maskGt(x: uint32, y: uint32): uint32 {
	return ((y - x) >> 8) & 0xff;
}

function maskGe(x: uint32, y: uint32): uint32 {
	return maskGt(y, x) ^ 0xff;
}

function sextetChar(x: uint32): uint32 {
	return (maskGt(26, x) & (x + 65))
		| (maskGe(x, 26) & maskGt(52, x) & (x + 71))
		| (maskGe(x, 52) & maskGt(62, x) & (x - 4))
		| (maskEq(x, 62) & 43)
		| (maskEq(x, 63) & 47);
}

/** The sextet of a base64 character, or 0xff for any other; `sextetChar` and this branch on no data bit. */
function charSextet(c: uint32): uint32 {
	const x = (maskGe(c, 65) & maskGe(90, c) & (c - 65))
		| (maskGe(c, 97) & maskGe(122, c) & (c - 71))
		| (maskGe(c, 48) & maskGe(57, c) & (c + 4))
		| (maskEq(c, 43) & 62)
		| (maskEq(c, 47) & 63);
	return x | (maskEq(x, 0) & (maskEq(c, 65) ^ 0xff));
}

export function base64NoPad(data: Readonly<uint8[]>): string {
	let out = "";
	let acc: uint32 = 0;
	let bits = 0;
	for (let i = 0; i < data.length; i++) {
		acc = ((acc << 8) | (data[i] as uint32)) & 0xffffff;
		bits += 8;
		while (bits >= 6) {
			bits -= 6;
			out += String.fromCharCode(sextetChar((acc >> (bits as uint32)) & 63) as int32);
		}
	}
	if (bits > 0) out += String.fromCharCode(sextetChar((acc << ((6 - bits) as uint32)) & 63) as int32);
	return out;
}

/** The bytes of unpadded standard base64, or null for another character or non-zero trailing bits, as the reference decoder refuses. */
function fromBase64NoPad(text: string): uint8[] | null {
	const out: uint8[] = [];
	let acc: uint32 = 0;
	let bits = 0;
	for (let i = 0; i < text.length; i++) {
		const code = text.charCodeAt(i);
		if (code > 127) return null;
		const sextet = charSextet(code as uint32);
		if (sextet == 0xff) return null;
		acc = ((acc << 6) | sextet) & 0xffffff;
		bits += 6;
		if (bits >= 8) {
			bits -= 8;
			out.push(((acc >> (bits as uint32)) & 255) as uint8);
		}
	}
	if (bits > 4 || (acc & (((1 << bits) - 1) as uint32)) != 0) return null;
	return out;
}

/** A decimal with no leading zero that fits 32 bits, or -1, as the reference decoder reads one. */
function minimalDecimal(text: string): number {
	if (text.length == 0 || text.length > 10) return -1;
	if (text.length > 1 && text.charCodeAt(0) == 48) return -1;
	let value = 0;
	for (let i = 0; i < text.length; i++) {
		const digit = text.charCodeAt(i) - 48;
		if (digit < 0 || digit > 9) return -1;
		value = value * 10 + digit;
	}
	return value > 4294967295 ? -1 : value;
}

export class Argon2Encoded {
	mode: Argon2Mode;
	version: number;
	memoryCost: number;
	timeCost: number;
	parallelism: number;
	salt: uint8[];
	hash: uint8[];
}

export function decodeArgon2(encoded: string): Argon2Encoded | null {
	const parts = encoded.split("$");
	const hasVersion = parts.length == 6;
	if ((!hasVersion && parts.length != 5) || parts[0] != "") return null;
	const mode = modeOfName(parts[1]);
	if (mode == null) return null;
	let version: number = 0x10;
	if (hasVersion) {
		if (!parts[2].startsWith("v=")) return null;
		version = minimalDecimal(parts[2].substring(2));
		if (version < 0) return null;
	}
	const params = parts[parts.length - 3].split(",");
	if (params.length != 3 || !params[0].startsWith("m=") || !params[1].startsWith("t=") || !params[2].startsWith("p=")) return null;
	const memoryCost = minimalDecimal(params[0].substring(2));
	const timeCost = minimalDecimal(params[1].substring(2));
	const parallelism = minimalDecimal(params[2].substring(2));
	const salt = fromBase64NoPad(parts[parts.length - 2]);
	const hash = fromBase64NoPad(parts[parts.length - 1]);
	if (memoryCost < 0 || timeCost < 0 || parallelism < 0 || salt == null || hash == null) return null;
	if (argon2Problem(timeCost, memoryCost, parallelism, hash.length, salt.length) != "") return null;
	return { mode, version, memoryCost, timeCost, parallelism, salt, hash };
}

export function decodeArgon2id(encoded: string): Argon2Encoded | null {
	const fields = decodeArgon2(encoded);
	if (fields == null || fields.mode != Argon2Mode.Argon2id) return null;
	return fields;
}

export const argon2Version: int32 = 0x13;

/** The most an untrusted encoded hash may ask of `argon2VerifyEncoded`: its m, t and p are read from the string. */
export class Argon2Bounds {
	memoryCost: number;
	timeCost: number;
	parallelism: number;
}

export function defaultArgon2Bounds(): Argon2Bounds {
	return { memoryCost: 262144, timeCost: 12, parallelism: 16 };
}

export function argon2Raw(password: Readonly<uint8[]>, salt: Readonly<uint8[]>, timeCost: int32, memoryCost: int32, parallelism: int32, hashLen: int32, mode: Argon2Mode = Argon2Mode.Argon2id, secret: Readonly<uint8[]> = noKey, ad: Readonly<uint8[]> = noKey): Result<uint8[], string> {
	const problem = argon2Problem(timeCost, memoryCost, parallelism, hashLen, salt.length);
	if (problem != "") return Result.err(problem);
	const words = argon2Words(memoryCost, parallelism);
	if (words > maxWords) return Result.err("Memory allocation error");
	const memory = new Array<uint32>(words as int32);
	return Result.ok(argon2Fill(memory, password, salt, secret, ad, mode, timeCost, memoryCost, parallelism, argon2Version, hashLen));
}

export function argon2Encode(password: Readonly<uint8[]>, salt: Readonly<uint8[]>, timeCost: int32, memoryCost: int32, parallelism: int32, hashLen: int32, mode: Argon2Mode = Argon2Mode.Argon2id): Result<string, string> {
	const raw = try argon2Raw(password, salt, timeCost, memoryCost, parallelism, hashLen, mode);
	return Result.ok("$" + argon2ModeName(mode) + "$v=" + argon2Version + "$m=" + memoryCost + ",t=" + timeCost + ",p=" + parallelism + "$" + base64NoPad(salt) + "$" + base64NoPad(raw));
}

/**
 * True only when `password` hashes to the encoded hash. False for a wrong password and for every
 * string it did not check: malformed, a version other than 0x10 or 0x13, or asking for more than `bounds`.
 */
export function argon2VerifyEncoded(encoded: string, password: Readonly<uint8[]>, bounds: Argon2Bounds = defaultArgon2Bounds()): boolean {
	const fields = decodeArgon2(encoded);
	if (fields == null || (fields.version != 0x10 && fields.version != 0x13)) return false;
	if (fields.memoryCost > bounds.memoryCost || fields.timeCost > bounds.timeCost || fields.parallelism > bounds.parallelism) return false;
	const words = argon2Words(fields.memoryCost as int32, fields.parallelism as int32);
	if (words > maxWords) return false;
	const memory = new Array<uint32>(words as int32);
	const got = argon2Fill(memory, password, fields.salt, noKey, noKey, fields.mode, fields.timeCost as int32, fields.memoryCost as int32, fields.parallelism as int32, fields.version as int32, fields.hash.length as int32);
	let diff: uint8 = 0;
	for (let i = 0; i < got.length; i++) diff |= got[i] ^ fields.hash[i];
	return diff == 0;
}
