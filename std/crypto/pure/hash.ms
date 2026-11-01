import { HashState, newHashState, kindSha256, kindSha224, kindSha512, kindSha384, kindSha1, kindMd5 } from "./state";
import { initSha2, compress256, compress512 } from "./sha2";
import { initSha1, compressSha1 } from "./sha1";
import { initMd5, compressMd5 } from "./md5";
import { encodeHex } from "../../core/encoding";

/** The kind number of a hash name, or -1 when the portable code has no such hash. */
export function hashKind(algorithm: string): int32 {
	if (algorithm == "sha256") return kindSha256;
	if (algorithm == "sha224") return kindSha224;
	if (algorithm == "sha512") return kindSha512;
	if (algorithm == "sha384") return kindSha384;
	if (algorithm == "sha1") return kindSha1;
	if (algorithm == "md5") return kindMd5;
	return -1;
}

export function resetHash(h: HashState): void {
	if (h.kind == kindSha1) initSha1(h);
	else if (h.kind == kindMd5) initMd5(h);
	else initSha2(h);
	h.filled = 0;
	h.length = 0;
	h.finished = false;
}

export function newHash(kind: int32): HashState {
	const h = newHashState(kind);
	resetHash(h);
	return h;
}

export function copyHash(from: Readonly<HashState>, to: HashState): void {
	for (let i = 0; i < 16; i++) to.state[i] = from.state[i];
	for (let i = 0; i < from.filled; i++) to.block[i] = from.block[i];
	to.filled = from.filled;
	to.length = from.length;
	to.finished = from.finished;
}

function compressBlock(h: HashState, data: Readonly<uint8[]>, off: int32): void {
	if (h.kind == kindSha256 || h.kind == kindSha224) compress256(h, data, off);
	else if (h.kind == kindSha512 || h.kind == kindSha384) compress512(h, data, off);
	else if (h.kind == kindSha1) compressSha1(h, data, off);
	else compressMd5(h, data, off);
}

export function updateHash(h: HashState, data: Readonly<uint8[]>): void {
	if (h.finished) throw new Error("hash already finished");
	const size = h.blockSize;
	const end = data.length as int32;
	let at = 0;
	h.length += end;
	if (h.filled > 0) {
		while (at < end && h.filled < size) {
			h.block[h.filled] = data[at];
			h.filled += 1;
			at += 1;
		}
		if (h.filled < size) return;
		compressBlock(h, h.block, 0);
		h.filled = 0;
	}
	while (at + size <= end) {
		compressBlock(h, data, at);
		at += size;
	}
	while (at < end) {
		h.block[h.filled] = data[at];
		h.filled += 1;
		at += 1;
	}
}

function putLength(h: HashState, at: int32): void {
	const bits = h.length * 8;
	const high = Math.floor(bits / 4294967296) as uint32;
	const low = (bits - Math.floor(bits / 4294967296) * 4294967296) as uint32;
	for (let i = 0; i < 4; i++) {
		const shift = (8 * i) as uint32;
		if (h.kind == kindMd5) {
			h.block[at + i] = ((low >> shift) & 255) as uint8;
			h.block[at + 4 + i] = ((high >> shift) & 255) as uint8;
		} else {
			h.block[at + 7 - i] = ((low >> shift) & 255) as uint8;
			h.block[at + 3 - i] = ((high >> shift) & 255) as uint8;
		}
	}
}

/** Pads, compresses the last block(s) and writes the digest to `out`; the state is finished afterwards. */
export function finishHashInto(h: HashState, out: uint8[]): void {
	if (h.finished) throw new Error("hash already finished");
	const size = h.blockSize;
	const lengthBytes = size == 128 ? 16 : 8;
	h.block[h.filled] = 0x80;
	h.filled += 1;
	if (h.filled > size - lengthBytes) {
		while (h.filled < size) {
			h.block[h.filled] = 0;
			h.filled += 1;
		}
		compressBlock(h, h.block, 0);
		h.filled = 0;
	}
	while (h.filled < size) {
		h.block[h.filled] = 0;
		h.filled += 1;
	}
	putLength(h, size - 8);
	compressBlock(h, h.block, 0);
	h.finished = true;
	for (let i = 0; i < h.outputSize; i++) {
		const word = h.state[i >> 2];
		const shift = (h.kind == kindMd5 ? (i & 3) * 8 : 24 - (i & 3) * 8) as uint32;
		out[i] = ((word >> shift) & 255) as uint8;
	}
}

export function finishHash(h: HashState): uint8[] {
	const out = new Array<uint8>(h.outputSize);
	finishHashInto(h, out);
	return out;
}

export function hashOf(kind: int32, data: Readonly<uint8[]>): uint8[] {
	const h = newHash(kind);
	updateHash(h, data);
	return finishHash(h);
}

function hex(kind: int32, text: string): string {
	return hashOf(kind, text.asBytes().slice(0)).encodeHex();
}

const longText = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu";

test "sha256 vectors" {
	assert hex(kindSha256, "") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
	assert hex(kindSha256, "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
	assert hex(kindSha256, "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1";
}

test "sha224 vectors" {
	assert hex(kindSha224, "abc") == "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7";
}

test "sha512 vectors" {
	assert hex(kindSha512, "") == "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e";
	assert hex(kindSha512, "abc") == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f";
	assert hex(kindSha512, longText) == "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909";
}

test "sha384 vectors" {
	assert hex(kindSha384, "abc") == "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7";
	assert hex(kindSha384, longText) == "09330c33f71147e83d192fc782cd1b4753111b173b3b05d22fa08086e3b0f712fcc7c71a557e2db966c3e9fa91746039";
}

test "sha1 vectors" {
	assert hex(kindSha1, "") == "da39a3ee5e6b4b0d3255bfef95601890afd80709";
	assert hex(kindSha1, "abc") == "a9993e364706816aba3e25717850c26c9cd0d89d";
	assert hex(kindSha1, "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") == "84983e441c3bd26ebaae4aa1f95129e5e54670f1";
}

test "md5 vectors" {
	assert hex(kindMd5, "") == "d41d8cd98f00b204e9800998ecf8427e";
	assert hex(kindMd5, "abc") == "900150983cd24fb0d6963f7d28e17f72";
	assert hex(kindMd5, "12345678901234567890123456789012345678901234567890123456789012345678901234567890") == "57edf4a22be3c955ac49da2e2107b67a";
}

test "a million a fed in uneven chunks gives the NIST sha256" {
	const h = newHash(kindSha256);
	const big = new Array<uint8>(1000);
	for (let i = 0; i < 1000; i++) big[i] = 97;
	const odd = new Array<uint8>(7);
	for (let i = 0; i < 7; i++) odd[i] = 97;
	for (let i = 0; i < 500; i++) updateHash(h, big);
	for (let i = 0; i < 71428; i++) updateHash(h, odd);
	for (let i = 0; i < 4; i++) updateHash(h, odd.slice(0, 1));
	assert finishHash(h).encodeHex() == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0";
}
