import { InputBytes } from "./bytes";
import {
	newPoly1305,
	updatePoly1305,
	padPoly1305,
	finishPoly1305,
} from "./poly1305";
import { declassify, wipeBytes, wipeWords } from "./secret";
import { load32LE } from "./endian";

when (c) {
	import { chachaHwXor, poly1305HwAead } from "./hw";
}

/**
 * The working words of one cipher call, allocated once so no block
 * allocates.
 */
class ChaChaWork {
	key: uint32[8];
	nonce: uint32[3];
	block: uint32[16];
	authKey: uint8[];
	tag: uint8[];
}

function newWork(): ChaChaWork {
	return {
		key: [0, 0, 0, 0, 0, 0, 0, 0],
		nonce: [0, 0, 0],
		block: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
		authKey: new Array<uint8>(32),
		tag: new Array<uint8>(16),
	};
}

function rotl(x: uint32, n: uint32): uint32 {
	return (x << n) | (x >> (32 - n));
}

/**
 * The words of 32 raw key bytes, as `dst` takes them; false, with `dst`
 * untouched, when the key is not 32 bytes.
 */
export function keyWords(key: InputBytes, dst: uint32[]): boolean {
	if (key.length != 32) return false;
	for (let i = 0; i < 8; i++) dst[i] = load32LE(key, i * 4);
	return true;
}

/**
 * RFC 8439 2.3 block function over sigma | key | counter | nonce into
 * `w.block`, feed-forward included.
 */
function chachaCore(
	w: ChaChaWork,
	n0: uint32,
	n1: uint32,
	n2: uint32,
	cnt: uint32,
): void {
	const y00: uint32 = 0x61707865;
	const y01: uint32 = 0x3320646e;
	const y02: uint32 = 0x79622d32;
	const y03: uint32 = 0x6b206574;
	const y04 = w.key[0];
	const y05 = w.key[1];
	const y06 = w.key[2];
	const y07 = w.key[3];
	const y08 = w.key[4];
	const y09 = w.key[5];
	const y10 = w.key[6];
	const y11 = w.key[7];
	let x00 = y00;
	let x01 = y01;
	let x02 = y02;
	let x03 = y03;
	let x04 = y04;
	let x05 = y05;
	let x06 = y06;
	let x07 = y07;
	let x08 = y08;
	let x09 = y09;
	let x10 = y10;
	let x11 = y11;
	let x12 = cnt;
	let x13 = n0;
	let x14 = n1;
	let x15 = n2;
	for (let r = 0; r < 20; r += 2) {
		x00 = x00 + x04;
		x12 = rotl(x12 ^ x00, 16);
		x08 = x08 + x12;
		x04 = rotl(x04 ^ x08, 12);
		x00 = x00 + x04;
		x12 = rotl(x12 ^ x00, 8);
		x08 = x08 + x12;
		x04 = rotl(x04 ^ x08, 7);

		x01 = x01 + x05;

		x13 = rotl(x13 ^ x01, 16);
		x09 = x09 + x13;
		x05 = rotl(x05 ^ x09, 12);
		x01 = x01 + x05;
		x13 = rotl(x13 ^ x01, 8);
		x09 = x09 + x13;
		x05 = rotl(x05 ^ x09, 7);

		x02 = x02 + x06;

		x14 = rotl(x14 ^ x02, 16);
		x10 = x10 + x14;
		x06 = rotl(x06 ^ x10, 12);
		x02 = x02 + x06;
		x14 = rotl(x14 ^ x02, 8);
		x10 = x10 + x14;
		x06 = rotl(x06 ^ x10, 7);

		x03 = x03 + x07;

		x15 = rotl(x15 ^ x03, 16);
		x11 = x11 + x15;
		x07 = rotl(x07 ^ x11, 12);
		x03 = x03 + x07;
		x15 = rotl(x15 ^ x03, 8);
		x11 = x11 + x15;
		x07 = rotl(x07 ^ x11, 7);

		x00 = x00 + x05;

		x15 = rotl(x15 ^ x00, 16);
		x10 = x10 + x15;
		x05 = rotl(x05 ^ x10, 12);
		x00 = x00 + x05;
		x15 = rotl(x15 ^ x00, 8);
		x10 = x10 + x15;
		x05 = rotl(x05 ^ x10, 7);

		x01 = x01 + x06;

		x12 = rotl(x12 ^ x01, 16);
		x11 = x11 + x12;
		x06 = rotl(x06 ^ x11, 12);
		x01 = x01 + x06;
		x12 = rotl(x12 ^ x01, 8);
		x11 = x11 + x12;
		x06 = rotl(x06 ^ x11, 7);

		x02 = x02 + x07;

		x13 = rotl(x13 ^ x02, 16);
		x08 = x08 + x13;
		x07 = rotl(x07 ^ x08, 12);
		x02 = x02 + x07;
		x13 = rotl(x13 ^ x02, 8);
		x08 = x08 + x13;
		x07 = rotl(x07 ^ x08, 7);

		x03 = x03 + x04;

		x14 = rotl(x14 ^ x03, 16);
		x09 = x09 + x14;
		x04 = rotl(x04 ^ x09, 12);
		x03 = x03 + x04;
		x14 = rotl(x14 ^ x03, 8);
		x09 = x09 + x14;
		x04 = rotl(x04 ^ x09, 7);
	}
	w.block[0] = y00 + x00;
	w.block[1] = y01 + x01;
	w.block[2] = y02 + x02;
	w.block[3] = y03 + x03;
	w.block[4] = y04 + x04;
	w.block[5] = y05 + x05;
	w.block[6] = y06 + x06;
	w.block[7] = y07 + x07;
	w.block[8] = y08 + x08;
	w.block[9] = y09 + x09;
	w.block[10] = y10 + x10;
	w.block[11] = y11 + x11;
	w.block[12] = cnt + x12;
	w.block[13] = n0 + x13;
	w.block[14] = n1 + x14;
	w.block[15] = n2 + x15;
}

/**
 * Derives the XChaCha20 subkey from the key words and the first 16 nonce bytes
 * at `nonceOff`, into `w.key`.
 */
function hchacha(
	w: ChaChaWork,
	key: Readonly<uint32[]>,
	nonce: InputBytes,
	nonceOff: int32,
): void {
	const n0 = load32LE(nonce, nonceOff);
	const n1 = load32LE(nonce, nonceOff + 4);
	const n2 = load32LE(nonce, nonceOff + 8);
	const n3 = load32LE(nonce, nonceOff + 12);
	for (let i = 0; i < 8; i++) w.key[i] = key[i];
	chachaCore(w, n1, n2, n3, n0);
	w.key[0] = w.block[0] - 0x61707865;
	w.key[1] = w.block[1] - 0x3320646e;
	w.key[2] = w.block[2] - 0x79622d32;
	w.key[3] = w.block[3] - 0x6b206574;
	w.key[4] = w.block[12] - n0;
	w.key[5] = w.block[13] - n1;
	w.key[6] = w.block[14] - n2;
	w.key[7] = w.block[15] - n3;
}

/**
 * XORs `length` bytes of `src` at `srcOff` with the keystream of `w` from block
 * `counter` into `dst` at `dstOff`.
 */
function chachaXor(
	w: ChaChaWork,
	counter: uint32,
	src: InputBytes,
	srcOff: int32,
	dst: uint8[],
	dstOff: int32,
	length: int32,
): void {
	let done = 0;
	let cnt = counter;
	when (c) {
		done = chachaHwXor(w.key, w.nonce, counter, src, srcOff, dst, dstOff, length) as int32;
		cnt = counter + ((done >> 6) as uint32);
	}
	while (length - done >= 64) {
		chachaCore(w, w.nonce[0], w.nonce[1], w.nonce[2], cnt);
		cnt = cnt + 1;
		const from = srcOff + done;
		const to = dstOff + done;
		for (let j = 0; j < 16; j++) {
			const word = w.block[j];
			const at = 4 * j;
			dst[to + at] = src[from + at] ^ ((word & 255) as uint8);
			dst[to + at + 1] = src[from + at + 1] ^ (((word >> 8) & 255) as uint8);
			dst[to + at + 2] = src[from + at + 2] ^ (((word >> 16) & 255) as uint8);
			dst[to + at + 3] = src[from + at + 3] ^ ((word >> 24) as uint8);
		}
		done += 64;
	}
	if (done == length) return;
	chachaCore(w, w.nonce[0], w.nonce[1], w.nonce[2], cnt);
	for (let i = 0; done + i < length; i++) {
		const word = w.block[i >> 2];
		const stream = ((word >> (((i & 3) * 8) as uint32)) & 255) as uint8;
		dst[dstOff + done + i] = src[srcOff + done + i] ^ stream;
	}
}

function startCipher(
	w: ChaChaWork,
	key: Readonly<uint32[]>,
	nonce: InputBytes,
): void {
	hchacha(w, key, nonce, 0);
	w.nonce[0] = 0;
	w.nonce[1] = load32LE(nonce, 16);
	w.nonce[2] = load32LE(nonce, 20);
}

function startIetf(
	w: ChaChaWork,
	key: Readonly<uint32[]>,
	nonce: InputBytes,
): void {
	for (let i = 0; i < 8; i++) w.key[i] = key[i];
	w.nonce[0] = load32LE(nonce, 0);
	w.nonce[1] = load32LE(nonce, 4);
	w.nonce[2] = load32LE(nonce, 8);
}

/**
 * IETF ChaCha20 (RFC 8439, 12-byte nonce): XORs `src` with the keystream from
 * block `counter` into `dst` of the same length; false on a bad nonce or
 * length.
 */
export function chacha20Xor(
	key: Readonly<uint32[]>,
	nonce: InputBytes,
	counter: uint32,
	src: InputBytes,
	dst: uint8[],
): boolean {
	if (nonce.length != 12 || dst.length != src.length) return false;
	const blocks = ((src.length as int64) + 63) >> 6;
	if (blocks > 4294967296 - (counter as int64)) return false;
	const w = newWork();
	startIetf(w, key, nonce);
	chachaXor(w, counter, src, 0, dst, 0, src.length as int32);
	wipeWork(w);
	return true;
}

function putLengths(lengths: uint8[], aadLength: int64, textLength: int64): void {
	for (let i = 0; i < 8; i++) {
		lengths[i] = ((aadLength >> ((8 * i) as int64)) & 255) as uint8;
		lengths[8 + i] = ((textLength >> ((8 * i) as int64)) & 255) as uint8;
	}
}

/** Zeroes the subkey, keystream block and one-time key a call leaves behind. */
function wipeWork(w: ChaChaWork): void {
	wipeWords(w.key);
	wipeWords(w.block);
	wipeBytes(w.authKey);
	wipeBytes(w.tag);
}

/**
 * The Poly1305 tag of aad || pad || cipherText || pad || lengths over the one-
 * time key from block 0, into `w.tag`.
 */
function computeTag(
	w: ChaChaWork,
	aad: InputBytes,
	cipher: InputBytes,
	cipherOff: int32,
	cipherLength: int32,
): void {
	chachaXor(w, 0, w.authKey, 0, w.authKey, 0, 32);
	when (c) {
		if (poly1305HwAead(w.tag, w.authKey, aad, cipher, cipherOff, cipherLength)) return;
	}
	const mac = newPoly1305(w.authKey, 0);
	updatePoly1305(mac, aad, 0, aad.length as int32);
	padPoly1305(mac);
	updatePoly1305(mac, cipher, cipherOff, cipherLength);
	padPoly1305(mac);
	const lengths = new Array<uint8>(16);
	putLengths(lengths, aad.length as int64, cipherLength as int64);
	updatePoly1305(mac, lengths, 0, 16);
	finishPoly1305(mac, w.tag, 0);
}

/**
 * XChaCha20-Poly1305 seal into `out` (24 + plain length + 16 bytes), whose
 * first 24 bytes already hold the nonce: writes cipherText then the tag.
 */
export function xchachaSealInto(
	key: Readonly<uint32[]>,
	aad: InputBytes,
	plain: InputBytes,
	out: uint8[],
): boolean {
	const length = plain.length as int32;
	if (out.length != 24 + length + 16) return false;
	const w = newWork();
	startCipher(w, key, out);
	chachaXor(w, 1, plain, 0, out, 24, length);
	computeTag(w, aad, out, 24, length);
	for (let i = 0; i < 16; i++) out[24 + length + i] = w.tag[i];
	wipeWork(w);
	return true;
}

/**
 * Opens nonce || cipherText || tag into `out` (sealed length - 40); false, with
 * `out` untouched, when the tag does not match.
 */
export function xchachaOpenInto(
	key: Readonly<uint32[]>,
	aad: InputBytes,
	sealed: InputBytes,
	out: uint8[],
): boolean {
	const length = (sealed.length as int32) - 40;
	if (length < 0 || out.length != length) return false;
	const w = newWork();
	startCipher(w, key, sealed);
	computeTag(w, aad, sealed, 24, length);
	const matched = tagMatches(w, sealed, 24 + length);
	if (matched) chachaXor(w, 1, sealed, 24, out, 0, length);
	wipeWork(w);
	return matched;
}

function tagMatches(
	w: ChaChaWork,
	sealed: InputBytes,
	at: int32,
): boolean {
	let diff: uint32 = 0;
	for (let i = 0; i < 16; i++) diff =
		diff | ((w.tag[i] ^ sealed[at + i]) as uint32);
	return declassify(diff) == 0;
}

/**
 * ChaCha20-Poly1305 (RFC 8439, 12-byte nonce) seal into `out` (plain length +
 * 16): cipherText then the tag; false on a bad nonce or out length.
 */
export function chacha20Poly1305SealInto(
	key: Readonly<uint32[]>,
	nonce: InputBytes,
	aad: InputBytes,
	plain: InputBytes,
	out: uint8[],
): boolean {
	const length = plain.length as int32;
	if (nonce.length != 12 || out.length != length + 16) return false;
	const w = newWork();
	startIetf(w, key, nonce);
	chachaXor(w, 1, plain, 0, out, 0, length);
	computeTag(w, aad, out, 0, length);
	for (let i = 0; i < 16; i++) out[length + i] = w.tag[i];
	wipeWork(w);
	return true;
}

/**
 * Opens cipherText || tag into `out` (sealed length - 16); false, with `out`
 * untouched, on a bad nonce, length or tag.
 */
export function chacha20Poly1305OpenInto(
	key: Readonly<uint32[]>,
	nonce: InputBytes,
	aad: InputBytes,
	sealed: InputBytes,
	out: uint8[],
): boolean {
	const length = (sealed.length as int32) - 16;
	if (nonce.length != 12 || length < 0 || out.length != length) return false;
	const w = newWork();
	startIetf(w, key, nonce);
	computeTag(w, aad, sealed, 0, length);
	const matched = tagMatches(w, sealed, length);
	if (matched) chachaXor(w, 1, sealed, 0, out, 0, length);
	wipeWork(w);
	return matched;
}

/**
 * ChaCha20-Poly1305 seal of `buf[at, +length)` in place, its tag into
 * `buf[at + length, +16)`; false on a bad nonce or a range outside `buf`.
 */
export function chacha20Poly1305SealAt(
	key: Readonly<uint32[]>,
	nonce: InputBytes,
	aad: InputBytes,
	buf: uint8[],
	at: int32,
	length: int32,
): boolean {
	if (nonce.length != 12 || at < 0 || length < 0 || at + length + 16 > buf.length) return false;
	const w = newWork();
	startIetf(w, key, nonce);
	chachaXor(w, 1, buf, at, buf, at, length);
	computeTag(w, aad, buf, at, length);
	for (let i = 0; i < 16; i++) buf[at + length + i] = w.tag[i];
	wipeWork(w);
	return true;
}

/**
 * Opens `buf[at, +length)` in place once the tag at `buf[at + length, +16)`
 * verifies; false, with `buf` untouched, on a bad nonce, range or tag.
 */
export function chacha20Poly1305OpenAt(
	key: Readonly<uint32[]>,
	nonce: InputBytes,
	aad: InputBytes,
	buf: uint8[],
	at: int32,
	length: int32,
): boolean {
	if (nonce.length != 12 || at < 0 || length < 0 || at + length + 16 > buf.length) return false;
	const w = newWork();
	startIetf(w, key, nonce);
	computeTag(w, aad, buf, at, length);
	const matched = tagMatches(w, buf, at + length);
	if (matched) chachaXor(w, 1, buf, at, buf, at, length);
	wipeWork(w);
	return matched;
}
