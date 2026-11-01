import { newBlake2b, updateBlake2b, finishBlake2bInto } from "./blake2b";

const noKey: Readonly<uint8[]> = [];
const syncPoints = 4;

/** Scratch for one Argon2 run: the block under compression, the address blocks and the byte forms the hashes read. */
class Argon2Work {
	buf: uint32[256];
	address: uint32[];
	h0: uint8[];
	bytes: uint8[];
	word: uint8[];
}

function newWork(): Argon2Work {
	return { buf: [0], address: new Array<uint32>(768), h0: new Array<uint8>(72), bytes: new Array<uint8>(1024), word: new Array<uint8>(4) };
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

/** w.buf[a] = w.buf[a] + w.buf[b] + 2 * low32(w.buf[a]) * low32(w.buf[b]) on 64-bit words stored as (low, high) pairs. */
function blamka(w: Argon2Work, a: int32, b: int32): void {
	const al = w.buf[2 * a];
	const bl = w.buf[2 * b];
	const ml = al * bl;
	const mh = mulHigh(al, bl);
	const rl = al + bl;
	const doubled = ml << 1;
	const sum = rl + doubled;
	w.buf[2 * a + 1] = w.buf[2 * a + 1] + w.buf[2 * b + 1] + ((mh << 1) | (ml >> 31)) + carry(rl, bl) + carry(sum, doubled);
	w.buf[2 * a] = sum;
}

function rotr32(w: Argon2Work, d: int32, a: int32): void {
	const xh = w.buf[2 * d + 1] ^ w.buf[2 * a + 1];
	const xl = w.buf[2 * d] ^ w.buf[2 * a];
	w.buf[2 * d] = xh;
	w.buf[2 * d + 1] = xl;
}

function rotr24(w: Argon2Work, b: int32, c: int32): void {
	const xh = w.buf[2 * b + 1] ^ w.buf[2 * c + 1];
	const xl = w.buf[2 * b] ^ w.buf[2 * c];
	w.buf[2 * b + 1] = (xh >> 24) | (xl << 8);
	w.buf[2 * b] = (xl >> 24) | (xh << 8);
}

function rotr16(w: Argon2Work, d: int32, a: int32): void {
	const xh = w.buf[2 * d + 1] ^ w.buf[2 * a + 1];
	const xl = w.buf[2 * d] ^ w.buf[2 * a];
	w.buf[2 * d + 1] = (xh >> 16) | (xl << 16);
	w.buf[2 * d] = (xl >> 16) | (xh << 16);
}

function rotr63(w: Argon2Work, b: int32, c: int32): void {
	const xh = w.buf[2 * b + 1] ^ w.buf[2 * c + 1];
	const xl = w.buf[2 * b] ^ w.buf[2 * c];
	w.buf[2 * b + 1] = (xh << 1) | (xl >> 31);
	w.buf[2 * b] = (xl << 1) | (xh >> 31);
}

function mixG(w: Argon2Work, a: int32, b: int32, c: int32, d: int32): void {
	blamka(w, a, b);
	rotr32(w, d, a);
	blamka(w, c, d);
	rotr24(w, b, c);
	blamka(w, a, b);
	rotr16(w, d, a);
	blamka(w, c, d);
	rotr63(w, b, c);
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

/** The compression function: out (xor-accumulated when `needXor`) from the blocks at `xPos` and `yPos` of `x`. */
function compressBlock(w: Argon2Work, x: uint32[], xPos: int32, yPos: int32, outPos: int32, needXor: boolean): void {
	if (needXor) {
		for (let i = 0; i < 256; i++) {
			const r = x[xPos + i] ^ x[yPos + i];
			w.buf[i] = r;
			x[outPos + i] = x[outPos + i] ^ r;
		}
	} else {
		for (let i = 0; i < 256; i++) {
			const r = x[xPos + i] ^ x[yPos + i];
			w.buf[i] = r;
			x[outPos + i] = r;
		}
	}
	for (let i = 0; i < 128; i += 16) {
		permute(w, i, i + 1, i + 2, i + 3, i + 4, i + 5, i + 6, i + 7, i + 8, i + 9, i + 10, i + 11, i + 12, i + 13, i + 14, i + 15);
	}
	for (let i = 0; i < 16; i += 2) {
		permute(w, i, i + 1, i + 16, i + 17, i + 32, i + 33, i + 48, i + 49, i + 64, i + 65, i + 80, i + 81, i + 96, i + 97, i + 112, i + 113);
	}
	for (let i = 0; i < 256; i++) x[outPos + i] = x[outPos + i] ^ w.buf[i];
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
	const v = new Array<uint8>(64);
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

/**
 * Argon2id (RFC 9106) of `password` and `salt`, `hashLen` bytes, with no secret and no associated data.
 * `memory` is `argon2Words(memoryCost, parallelism)` words the caller allocates; the parameters were checked
 * with `argon2Problem`. `version` 0x10 overwrites on later passes, any other value (0x13) xors.
 */
export function argon2idHash(memory: uint32[], password: Readonly<uint8[]>, salt: Readonly<uint8[]>, timeCost: int32, memoryCost: int32, parallelism: int32, version: int32, hashLen: int32): uint8[] {
	const w = newWork();
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
	put32(w.word, 0, 2);
	updateBlake2b(initial, w.word, 0, 4);
	put32(w.word, 0, password.length as int32);
	updateBlake2b(initial, w.word, 0, 4);
	updateBlake2b(initial, password, 0, password.length as int32);
	put32(w.word, 0, salt.length as int32);
	updateBlake2b(initial, w.word, 0, 4);
	updateBlake2b(initial, salt, 0, salt.length as int32);
	put32(w.word, 0, 0);
	updateBlake2b(initial, w.word, 0, 4);
	updateBlake2b(initial, w.word, 0, 4);
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
	w.address[256 + 10] = 2;
	for (let r = 0; r < timeCost; r++) {
		const needXor = r != 0 && version != 0x10;
		w.address[256 + 0] = r as uint32;
		for (let s = 0; s < syncPoints; s++) {
			w.address[256 + 4] = s as uint32;
			const dataIndependent = r == 0 && s < 2;
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

	const last = new Array<uint32>(256);
	for (let l = 0; l < parallelism; l++) {
		for (let j = 0; j < 256; j++) last[j] = last[j] ^ memory[256 * (laneLen * l + laneLen - 1) + j];
	}
	wordsToBytes(last, 0, w.bytes);
	const out = new Array<uint8>(hashLen);
	hPrime(w, w.bytes, 1024, hashLen, out, 0);
	return out;
}

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/** Standard base64 without padding, as the encoded hash string carries salt and hash. */
export function base64NoPad(data: Readonly<uint8[]>): string {
	let out = "";
	let acc: uint32 = 0;
	let bits = 0;
	for (let i = 0; i < data.length; i++) {
		acc = ((acc << 8) | (data[i] as uint32)) & 0xffffff;
		bits += 8;
		while (bits >= 6) {
			bits -= 6;
			out += alphabet[((acc >> (bits as uint32)) & 63) as int32];
		}
	}
	if (bits > 0) out += alphabet[((acc << ((6 - bits) as uint32)) & 63) as int32];
	return out;
}

/** The bytes of unpadded standard base64, or null for another character or non-zero trailing bits, as the reference decoder refuses. */
function fromBase64NoPad(text: string): uint8[] | null {
	const out: uint8[] = [];
	let acc: uint32 = 0;
	let bits = 0;
	for (let i = 0; i < text.length; i++) {
		const index = alphabet.indexOf(text[i]);
		if (index < 0) return null;
		acc = ((acc << 6) | (index as uint32)) & 0xffffff;
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

/** The fields of `$argon2id[$v=V]$m=M,t=T,p=P$salt$hash`. */
export class Argon2Encoded {
	version: number;
	memoryCost: number;
	timeCost: number;
	parallelism: number;
	salt: uint8[];
	hash: uint8[];
}

/** The fields of an argon2id encoding, or null for any string the reference decoder or its input checks refuse. */
export function decodeArgon2id(encoded: string): Argon2Encoded | null {
	const parts = encoded.split("$");
	const hasVersion = parts.length == 6;
	if ((!hasVersion && parts.length != 5) || parts[0] != "" || parts[1] != "argon2id") return null;
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
	return { version, memoryCost, timeCost, parallelism, salt, hash };
}
