import { newPoly1305, updatePoly1305, padPoly1305, finishPoly1305 } from "./poly1305";

/** The working words of one XChaCha20-Poly1305 call, allocated once so no block allocates. */
class ChaChaWork {
	key: uint32[8];
	nonce: uint32[3];
	block: uint32[16];
	authKey: uint8[];
	tag: uint8[];
	lengths: uint8[];
}

function newWork(): ChaChaWork {
	return {
		key: [0, 0, 0, 0, 0, 0, 0, 0],
		nonce: [0, 0, 0],
		block: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
		authKey: new Array<uint8>(32),
		tag: new Array<uint8>(16),
		lengths: new Array<uint8>(16),
	};
}

function load32(data: Readonly<uint8[]>, at: int32): uint32 {
	return (data[at] as uint32) | ((data[at + 1] as uint32) << 8) | ((data[at + 2] as uint32) << 16) | ((data[at + 3] as uint32) << 24);
}

function rotl(x: uint32, n: uint32): uint32 {
	return (x << n) | (x >> (32 - n));
}

/** The words of 32 raw key bytes, as `dst` takes them. */
export function keyWords(key: Readonly<uint8[]>, dst: uint32[]): void {
	for (let i = 0; i < 8; i++) dst[i] = load32(key, i * 4);
}

/** RFC 8439 2.3 block function: sigma | key | counter | nonce into `out`; `hchacha` reads the state before its feed-forward. */
function chachaCore(w: ChaChaWork, n0: uint32, n1: uint32, n2: uint32, cnt: uint32): void {
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
		x00 = x00 + x04; x12 = rotl(x12 ^ x00, 16);
		x08 = x08 + x12; x04 = rotl(x04 ^ x08, 12);
		x00 = x00 + x04; x12 = rotl(x12 ^ x00, 8);
		x08 = x08 + x12; x04 = rotl(x04 ^ x08, 7);

		x01 = x01 + x05; x13 = rotl(x13 ^ x01, 16);
		x09 = x09 + x13; x05 = rotl(x05 ^ x09, 12);
		x01 = x01 + x05; x13 = rotl(x13 ^ x01, 8);
		x09 = x09 + x13; x05 = rotl(x05 ^ x09, 7);

		x02 = x02 + x06; x14 = rotl(x14 ^ x02, 16);
		x10 = x10 + x14; x06 = rotl(x06 ^ x10, 12);
		x02 = x02 + x06; x14 = rotl(x14 ^ x02, 8);
		x10 = x10 + x14; x06 = rotl(x06 ^ x10, 7);

		x03 = x03 + x07; x15 = rotl(x15 ^ x03, 16);
		x11 = x11 + x15; x07 = rotl(x07 ^ x11, 12);
		x03 = x03 + x07; x15 = rotl(x15 ^ x03, 8);
		x11 = x11 + x15; x07 = rotl(x07 ^ x11, 7);

		x00 = x00 + x05; x15 = rotl(x15 ^ x00, 16);
		x10 = x10 + x15; x05 = rotl(x05 ^ x10, 12);
		x00 = x00 + x05; x15 = rotl(x15 ^ x00, 8);
		x10 = x10 + x15; x05 = rotl(x05 ^ x10, 7);

		x01 = x01 + x06; x12 = rotl(x12 ^ x01, 16);
		x11 = x11 + x12; x06 = rotl(x06 ^ x11, 12);
		x01 = x01 + x06; x12 = rotl(x12 ^ x01, 8);
		x11 = x11 + x12; x06 = rotl(x06 ^ x11, 7);

		x02 = x02 + x07; x13 = rotl(x13 ^ x02, 16);
		x08 = x08 + x13; x07 = rotl(x07 ^ x08, 12);
		x02 = x02 + x07; x13 = rotl(x13 ^ x02, 8);
		x08 = x08 + x13; x07 = rotl(x07 ^ x08, 7);

		x03 = x03 + x04; x14 = rotl(x14 ^ x03, 16);
		x09 = x09 + x14; x04 = rotl(x04 ^ x09, 12);
		x03 = x03 + x04; x14 = rotl(x14 ^ x03, 8);
		x09 = x09 + x14; x04 = rotl(x04 ^ x09, 7);
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

/** Derives the XChaCha20 subkey from the key words and the first 16 nonce bytes at `nonceOff`, into `w.key`. */
function hchacha(w: ChaChaWork, key: Readonly<uint32[]>, nonce: Readonly<uint8[]>, nonceOff: int32): void {
	const n0 = load32(nonce, nonceOff);
	const n1 = load32(nonce, nonceOff + 4);
	const n2 = load32(nonce, nonceOff + 8);
	const n3 = load32(nonce, nonceOff + 12);
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

/** XORs `length` bytes of `src` at `srcOff` with the keystream of `w` from block `counter` into `dst` at `dstOff`. */
function chachaXor(w: ChaChaWork, counter: uint32, src: Readonly<uint8[]>, srcOff: int32, dst: uint8[], dstOff: int32, length: int32): void {
	let done = 0;
	let cnt = counter;
	while (done < length) {
		chachaCore(w, w.nonce[0], w.nonce[1], w.nonce[2], cnt);
		cnt = cnt + 1;
		const take = length - done < 64 ? length - done : 64;
		for (let i = 0; i < take; i++) {
			const word = w.block[i >> 2];
			const stream = ((word >> (((i & 3) * 8) as uint32)) & 255) as uint8;
			dst[dstOff + done + i] = src[srcOff + done + i] ^ stream;
		}
		done += take;
	}
}

function startCipher(w: ChaChaWork, key: Readonly<uint32[]>, nonce: Readonly<uint8[]>): void {
	hchacha(w, key, nonce, 0);
	w.nonce[0] = 0;
	w.nonce[1] = load32(nonce, 16);
	w.nonce[2] = load32(nonce, 20);
}

function putLengths(w: ChaChaWork, aadLength: int32, textLength: int32): void {
	for (let i = 0; i < 4; i++) {
		w.lengths[i] = ((aadLength >> (8 * i)) & 255) as uint8;
		w.lengths[8 + i] = ((textLength >> (8 * i)) & 255) as uint8;
	}
}

/** The Poly1305 tag of aad || pad || cipherText || pad || lengths over the one-time key from block 0, into `w.tag`. */
function computeTag(w: ChaChaWork, aad: Readonly<uint8[]>, cipher: Readonly<uint8[]>, cipherOff: int32, cipherLength: int32): void {
	chachaXor(w, 0, w.authKey, 0, w.authKey, 0, 32);
	const mac = newPoly1305(w.authKey, 0);
	updatePoly1305(mac, aad, 0, aad.length as int32);
	padPoly1305(mac);
	updatePoly1305(mac, cipher, cipherOff, cipherLength);
	padPoly1305(mac);
	putLengths(w, aad.length as int32, cipherLength);
	updatePoly1305(mac, w.lengths, 0, 16);
	finishPoly1305(mac, w.tag, 0);
}

/**
 * XChaCha20-Poly1305 seal into `out` (24 + plain length + 16 bytes), whose first 24 bytes already hold
 * the nonce: writes cipherText then the tag after it.
 */
export function xchachaSealInto(key: Readonly<uint32[]>, aad: Readonly<uint8[]>, plain: Readonly<uint8[]>, out: uint8[]): void {
	const w = newWork();
	const length = plain.length as int32;
	startCipher(w, key, out);
	chachaXor(w, 1, plain, 0, out, 24, length);
	computeTag(w, aad, out, 24, length);
	for (let i = 0; i < 16; i++) out[24 + length + i] = w.tag[i];
}

/** Opens nonce || cipherText || tag into `out` (sealed length - 40); false, with `out` untouched, when the tag does not match. */
export function xchachaOpenInto(key: Readonly<uint32[]>, aad: Readonly<uint8[]>, sealed: Readonly<uint8[]>, out: uint8[]): boolean {
	const w = newWork();
	const length = (sealed.length as int32) - 40;
	startCipher(w, key, sealed);
	computeTag(w, aad, sealed, 24, length);
	let diff: uint32 = 0;
	for (let i = 0; i < 16; i++) diff = diff | ((w.tag[i] ^ sealed[24 + length + i]) as uint32);
	if (diff != 0) return false;
	chachaXor(w, 1, sealed, 24, out, 0, length);
	return true;
}
