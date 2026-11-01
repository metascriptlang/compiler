import { newGhash, updateGhash, finishGhash } from "./ghash";

/**
 * AES with 4 T-tables, in GCM (12-byte nonce) and CBC with PKCS#7. Words are little-endian packs of four
 * bytes. Not constant-time: the S-box and T-table lookups are indexed by secret bytes, so their cache timing leaks
 * the key to a local observer. Prefer the WebCrypto forms where they exist.
 */

function mul2(n: int32): int32 {
	return (n << 1) ^ (0x11b & -(n >> 7));
}

function mul(a: int32, b: int32): int32 {
	let res = 0;
	let x = a;
	for (let y = b; y > 0; y >>= 1) {
		res ^= x & -(y & 1);
		x = mul2(x);
	}
	return res;
}

function buildSbox(): uint8[] {
	const powers = new Array<int32>(256);
	let x = 1;
	for (let i = 0; i < 256; i++) {
		powers[i] = x;
		x ^= mul2(x);
	}
	const box = new Array<uint8>(256);
	box[0] = 0x63;
	for (let i = 0; i < 255; i++) {
		let v = powers[255 - i];
		v |= v << 8;
		box[powers[i]] = ((v ^ (v >> 4) ^ (v >> 5) ^ (v >> 6) ^ (v >> 7) ^ 0x63) & 0xff) as uint8;
	}
	return box;
}

function buildInverse(box: Readonly<uint8[]>): uint8[] {
	const inverse = new Array<uint8>(256);
	for (let i = 0; i < 256; i++) inverse[box[i]] = i as uint8;
	return inverse;
}

function rotl8(n: uint32): uint32 {
	return (n << 8) | (n >> 24);
}

// T0, T1, T2, T3 back to back: the combined substitution and column mix of one byte lane each.
function buildTables(box: Readonly<uint8[]>, decode: boolean): uint32[] {
	const tables = new Array<uint32>(1024);
	for (let j = 0; j < 256; j++) {
		const s = box[j] as int32;
		const t0: uint32 = decode
			? ((mul(s, 11) as uint32) << 24) | ((mul(s, 13) as uint32) << 16) | ((mul(s, 9) as uint32) << 8) | (mul(s, 14) as uint32)
			: ((mul(s, 3) as uint32) << 24) | ((s as uint32) << 16) | ((s as uint32) << 8) | (mul(s, 2) as uint32);
		const t1 = rotl8(t0);
		const t2 = rotl8(t1);
		tables[j] = t0;
		tables[256 + j] = t1;
		tables[512 + j] = t2;
		tables[768 + j] = rotl8(t2);
	}
	return tables;
}

// Each is built from a fresh table, never from another const, so each stays a const the spawn rule accepts.
const sbox: Readonly<uint8[]> = buildSbox();
const invSbox: Readonly<uint8[]> = buildInverse(buildSbox());
const encTables: Readonly<uint32[]> = buildTables(buildSbox(), false);
const decTables: Readonly<uint32[]> = buildTables(buildInverse(buildSbox()), true);

function subWord(n: uint32): uint32 {
	return (sbox[n & 0xff] as uint32) | ((sbox[(n >> 8) & 0xff] as uint32) << 8) | ((sbox[(n >> 16) & 0xff] as uint32) << 16) | ((sbox[n >> 24] as uint32) << 24);
}

function loadLE(data: Readonly<uint8[]>, at: int32): uint32 {
	return (data[at] as uint32) | ((data[at + 1] as uint32) << 8) | ((data[at + 2] as uint32) << 16) | ((data[at + 3] as uint32) << 24);
}

function storeLE(out: uint8[], at: int32, word: uint32): void {
	out[at] = (word & 0xff) as uint8;
	out[at + 1] = ((word >> 8) & 0xff) as uint8;
	out[at + 2] = ((word >> 16) & 0xff) as uint8;
	out[at + 3] = (word >> 24) as uint8;
}

function storeBE32(out: uint8[], at: int32, word: uint32): void {
	out[at] = (word >> 24) as uint8;
	out[at + 1] = ((word >> 16) & 0xff) as uint8;
	out[at + 2] = ((word >> 8) & 0xff) as uint8;
	out[at + 3] = (word & 0xff) as uint8;
}

function swapBytes(n: uint32): uint32 {
	return ((n & 0xff) << 24) | (((n >> 8) & 0xff) << 16) | (((n >> 16) & 0xff) << 8) | (n >> 24);
}

/** The encryption round keys of a 16-, 24- or 32-byte key. */
export function expandKey(key: Readonly<uint8[]>): uint32[] {
	const nk = key.length / 4;
	const xk = new Array<uint32>(key.length + 28);
	for (let i = 0; i < nk; i++) xk[i] = loadLE(key, i * 4);
	let rcon: int32 = 1;
	for (let i = nk; i < xk.length; i++) {
		let t = xk[i - 1];
		if (i % nk == 0) {
			t = subWord((t << 24) | (t >> 8)) ^ (rcon as uint32);
			rcon = mul2(rcon);
		} else if (nk > 6 && i % nk == 4) {
			t = subWord(t);
		}
		xk[i] = xk[i - nk] ^ t;
	}
	return xk;
}

/** The round keys for decryption: the encryption ones in reverse order, the middle ones through InvMixColumns. */
export function expandKeyDecrypt(key: Readonly<uint8[]>): uint32[] {
	const enc = expandKey(key);
	const n = enc.length;
	const xk = new Array<uint32>(n);
	for (let i = 0; i < n; i += 4) {
		for (let j = 0; j < 4; j++) xk[i + j] = enc[n - i - 4 + j];
	}
	for (let i = 4; i < n - 4; i++) {
		const w = subWord(xk[i]);
		xk[i] = decTables[w & 0xff] ^ decTables[256 + ((w >> 8) & 0xff)] ^ decTables[512 + ((w >> 16) & 0xff)] ^ decTables[768 + (w >> 24)];
	}
	return xk;
}

/** One block through the cipher; `out` receives the four result words. */
function encryptBlock(xk: Readonly<uint32[]>, w0: uint32, w1: uint32, w2: uint32, w3: uint32, out: uint32[]): void {
	let s0 = w0 ^ xk[0];
	let s1 = w1 ^ xk[1];
	let s2 = w2 ^ xk[2];
	let s3 = w3 ^ xk[3];
	let k = 4;
	const rounds = xk.length / 4 - 2;
	for (let i = 0; i < rounds; i++) {
		const t0 = xk[k] ^ encTables[s0 & 0xff] ^ encTables[256 + ((s1 >> 8) & 0xff)] ^ encTables[512 + ((s2 >> 16) & 0xff)] ^ encTables[768 + (s3 >> 24)];
		const t1 = xk[k + 1] ^ encTables[s1 & 0xff] ^ encTables[256 + ((s2 >> 8) & 0xff)] ^ encTables[512 + ((s3 >> 16) & 0xff)] ^ encTables[768 + (s0 >> 24)];
		const t2 = xk[k + 2] ^ encTables[s2 & 0xff] ^ encTables[256 + ((s3 >> 8) & 0xff)] ^ encTables[512 + ((s0 >> 16) & 0xff)] ^ encTables[768 + (s1 >> 24)];
		const t3 = xk[k + 3] ^ encTables[s3 & 0xff] ^ encTables[256 + ((s0 >> 8) & 0xff)] ^ encTables[512 + ((s1 >> 16) & 0xff)] ^ encTables[768 + (s2 >> 24)];
		k += 4;
		s0 = t0;
		s1 = t1;
		s2 = t2;
		s3 = t3;
	}
	out[0] = xk[k] ^ laneWord(sbox, s0, s1, s2, s3);
	out[1] = xk[k + 1] ^ laneWord(sbox, s1, s2, s3, s0);
	out[2] = xk[k + 2] ^ laneWord(sbox, s2, s3, s0, s1);
	out[3] = xk[k + 3] ^ laneWord(sbox, s3, s0, s1, s2);
}

function decryptBlock(xk: Readonly<uint32[]>, w0: uint32, w1: uint32, w2: uint32, w3: uint32, out: uint32[]): void {
	let s0 = w0 ^ xk[0];
	let s1 = w1 ^ xk[1];
	let s2 = w2 ^ xk[2];
	let s3 = w3 ^ xk[3];
	let k = 4;
	const rounds = xk.length / 4 - 2;
	for (let i = 0; i < rounds; i++) {
		const t0 = xk[k] ^ decTables[s0 & 0xff] ^ decTables[256 + ((s3 >> 8) & 0xff)] ^ decTables[512 + ((s2 >> 16) & 0xff)] ^ decTables[768 + (s1 >> 24)];
		const t1 = xk[k + 1] ^ decTables[s1 & 0xff] ^ decTables[256 + ((s0 >> 8) & 0xff)] ^ decTables[512 + ((s3 >> 16) & 0xff)] ^ decTables[768 + (s2 >> 24)];
		const t2 = xk[k + 2] ^ decTables[s2 & 0xff] ^ decTables[256 + ((s1 >> 8) & 0xff)] ^ decTables[512 + ((s0 >> 16) & 0xff)] ^ decTables[768 + (s3 >> 24)];
		const t3 = xk[k + 3] ^ decTables[s3 & 0xff] ^ decTables[256 + ((s2 >> 8) & 0xff)] ^ decTables[512 + ((s1 >> 16) & 0xff)] ^ decTables[768 + (s0 >> 24)];
		k += 4;
		s0 = t0;
		s1 = t1;
		s2 = t2;
		s3 = t3;
	}
	out[0] = xk[k] ^ laneWord(invSbox, s0, s3, s2, s1);
	out[1] = xk[k + 1] ^ laneWord(invSbox, s1, s0, s3, s2);
	out[2] = xk[k + 2] ^ laneWord(invSbox, s2, s1, s0, s3);
	out[3] = xk[k + 3] ^ laneWord(invSbox, s3, s2, s1, s0);
}

// The last round: one substituted byte lane from each argument, without the column mix.
function laneWord(box: Readonly<uint8[]>, s0: uint32, s1: uint32, s2: uint32, s3: uint32): uint32 {
	return (box[s0 & 0xff] as uint32) | ((box[(s1 >> 8) & 0xff] as uint32) << 8) | ((box[(s2 >> 16) & 0xff] as uint32) << 16) | ((box[s3 >> 24] as uint32) << 24);
}

// CTR over the last 32 bits of the counter block (SP 800-38D inc32), the counter starting at `counter`.
function ctr32Xor(xk: Readonly<uint32[]>, n0: uint32, n1: uint32, n2: uint32, counter: uint32, src: Readonly<uint8[]>, from: int32, to: int32, dst: uint8[], dstAt: int32): void {
	const block = new Array<uint32>(4);
	const stream = new Array<uint8>(16);
	let ctr = counter;
	let at = from;
	while (at < to) {
		encryptBlock(xk, n0, n1, n2, swapBytes(ctr), block);
		ctr = ctr + 1;
		for (let i = 0; i < 4; i++) storeLE(stream, i * 4, block[i]);
		const count = to - at < 16 ? to - at : 16;
		for (let i = 0; i < count; i++) dst[dstAt + at - from + i] = src[at + i] ^ stream[i];
		at += count;
	}
}

function lengthBlock(aadLength: int32, dataLength: int32): uint8[] {
	const out = new Array<uint8>(16);
	const aad = aadLength as uint32;
	const data = dataLength as uint32;
	storeBE32(out, 0, aad >> 29);
	storeBE32(out, 4, aad << 3);
	storeBE32(out, 8, data >> 29);
	storeBE32(out, 12, data << 3);
	return out;
}

/** The 16-byte tag over `sealed[12, bodyEnd)` as cipher text, with the nonce at `sealed[0, 12)`. */
function gcmTag(xk: Readonly<uint32[]>, sealed: Readonly<uint8[]>, bodyEnd: int32, aad: Readonly<uint8[]>): uint8[] {
	const block = new Array<uint32>(4);
	const authKey = new Array<uint8>(16);
	encryptBlock(xk, 0, 0, 0, 0, block);
	for (let i = 0; i < 4; i++) storeLE(authKey, i * 4, block[i]);
	const ghash = newGhash(authKey, aad.length + bodyEnd - 12);
	updateGhash(ghash, aad, 0, aad.length);
	updateGhash(ghash, sealed, 12, bodyEnd);
	updateGhash(ghash, lengthBlock(aad.length, bodyEnd - 12), 0, 16);
	const tag = new Array<uint8>(16);
	finishGhash(ghash, tag, 0);
	encryptBlock(xk, loadLE(sealed, 0), loadLE(sealed, 4), loadLE(sealed, 8), swapBytes(1), block);
	const mask = new Array<uint8>(16);
	for (let i = 0; i < 4; i++) storeLE(mask, i * 4, block[i]);
	for (let i = 0; i < 16; i++) tag[i] = tag[i] ^ mask[i];
	return tag;
}

/** AES-GCM: `nonce(12) || cipher text || tag(16)`. The nonce must be fresh for every call under one key. */
export function gcmSealWithNonce(xk: Readonly<uint32[]>, nonce: Readonly<uint8[]>, plain: Readonly<uint8[]>, aad: Readonly<uint8[]>): uint8[] {
	const size = plain.length;
	const sealed = new Array<uint8>(12 + size + 16);
	for (let i = 0; i < 12; i++) sealed[i] = nonce[i];
	ctr32Xor(xk, loadLE(nonce, 0), loadLE(nonce, 4), loadLE(nonce, 8), 2, plain, 0, size, sealed, 12);
	const tag = gcmTag(xk, sealed, 12 + size, aad);
	for (let i = 0; i < 16; i++) sealed[12 + size + i] = tag[i];
	return sealed;
}

/** The plain text of a `nonce || cipher text || tag` blob, or null when the tag does not verify; needs at least 28 bytes. */
export function gcmOpen(xk: Readonly<uint32[]>, sealed: Readonly<uint8[]>, aad: Readonly<uint8[]>): uint8[] | null {
	const end = sealed.length - 16;
	const tag = gcmTag(xk, sealed, end, aad);
	let diff: uint8 = 0;
	for (let i = 0; i < 16; i++) diff = diff | (tag[i] ^ sealed[end + i]);
	if (diff != 0) return null;
	const plain = new Array<uint8>(end - 12);
	ctr32Xor(xk, loadLE(sealed, 0), loadLE(sealed, 4), loadLE(sealed, 8), 2, sealed, 12, end, plain, 0);
	return plain;
}

/** AES-CBC with PKCS#7 padding; `iv` is 16 bytes. */
export function cbcEncrypt(xk: Readonly<uint32[]>, iv: Readonly<uint8[]>, plain: Readonly<uint8[]>): uint8[] {
	const size = plain.length;
	const padding = 16 - (size % 16);
	const out = new Array<uint8>(size + padding);
	const block = new Array<uint32>(4);
	const last = new Array<uint8>(16);
	let p0 = loadLE(iv, 0);
	let p1 = loadLE(iv, 4);
	let p2 = loadLE(iv, 8);
	let p3 = loadLE(iv, 12);
	for (let at = 0; at < size + padding; at += 16) {
		let w0: uint32;
		let w1: uint32;
		let w2: uint32;
		let w3: uint32;
		if (at + 16 <= size) {
			w0 = loadLE(plain, at);
			w1 = loadLE(plain, at + 4);
			w2 = loadLE(plain, at + 8);
			w3 = loadLE(plain, at + 12);
		} else {
			for (let i = 0; i < 16; i++) last[i] = at + i < size ? plain[at + i] : (padding as uint8);
			w0 = loadLE(last, 0);
			w1 = loadLE(last, 4);
			w2 = loadLE(last, 8);
			w3 = loadLE(last, 12);
		}
		encryptBlock(xk, w0 ^ p0, w1 ^ p1, w2 ^ p2, w3 ^ p3, block);
		p0 = block[0];
		p1 = block[1];
		p2 = block[2];
		p3 = block[3];
		for (let i = 0; i < 4; i++) storeLE(out, at + i * 4, block[i]);
	}
	return out;
}

/** The plain text of an AES-CBC cipher text, or null for an empty or ragged input or bad padding; `xk` is from `expandKeyDecrypt`. */
export function cbcDecrypt(xk: Readonly<uint32[]>, iv: Readonly<uint8[]>, cipher: Readonly<uint8[]>): uint8[] | null {
	const size = cipher.length;
	if (size == 0 || size % 16 != 0) return null;
	const out = new Array<uint8>(size);
	const block = new Array<uint32>(4);
	let p0 = loadLE(iv, 0);
	let p1 = loadLE(iv, 4);
	let p2 = loadLE(iv, 8);
	let p3 = loadLE(iv, 12);
	for (let at = 0; at < size; at += 16) {
		const c0 = loadLE(cipher, at);
		const c1 = loadLE(cipher, at + 4);
		const c2 = loadLE(cipher, at + 8);
		const c3 = loadLE(cipher, at + 12);
		decryptBlock(xk, c0, c1, c2, c3, block);
		storeLE(out, at, block[0] ^ p0);
		storeLE(out, at + 4, block[1] ^ p1);
		storeLE(out, at + 8, block[2] ^ p2);
		storeLE(out, at + 12, block[3] ^ p3);
		p0 = c0;
		p1 = c1;
		p2 = c2;
		p3 = c3;
	}
	const pad = out[size - 1] as int32;
	let valid = pad >= 1 && pad <= 16 ? 1 : 0;
	for (let i = 0; i < 16; i++) {
		if (i < pad && out[size - 1 - i] != pad) valid = 0;
	}
	if (valid == 0) return null;
	return out.slice(0, size - pad);
}
