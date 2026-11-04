import { HashState, HashBytes, newHashState, wipeHashState, kindSha256, kindSha224, kindSha512, kindSha384, kindSha1, kindMd5 } from "./state";
import { sha2Iv } from "./sha2";
import { initSha1 } from "./sha1";
import { initMd5 } from "./md5";
import { encodeHex } from "../../core/encoding";

when (!js) {
	import { Buffer } from "std/core/buffer";
	import { sha256HwBlocks, sha512HwBlocks, pureCpuFeatures } from "./hw";
	import { compress256Words, compress512Words } from "./sha2";
	import { compressSha1Words } from "./sha1";
	import { compressMd5Words } from "./md5";
	import { hashOutputSize, stateWords } from "./state";
	import { wipeBytes, wipeWords } from "./secret";

	/** The digest array; finishHashInto writes every byte, so it is not zeroed first. */
	function digestArray(size: int32): uint8[] {
		return Buffer.allocUnsafe(size);
	}
} else {
	import { compress256, compress512 } from "./sha2";
	import { compressSha1 } from "./sha1";
	import { compressMd5 } from "./md5";

	function digestArray(size: int32): uint8[] {
		return new Array<uint8>(size);
	}
}

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

/** The initial chaining words of a hash kind into `state`. */
function initWords(kind: int32, state: Span<uint32>): void {
	if (kind == kindSha1) initSha1(state);
	else if (kind == kindMd5) initMd5(state);
	else sha2Iv(kind, state);
}

export function resetHash(h: HashState): void {
	initWords(h.kind, h.state);
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

when (!js) {
	/**
	 * Compresses `blocks` whole blocks of `data` from `off` into the chaining words `state`, on the CPU's SHA
	 * extension when it has one.
	 */
	function compressWords(kind: int32, state: Span<uint32>, data: HashBytes, off: int32, blocks: int32): void {
		if (blocks == 0) return;
		const wide = kind == kindSha512 || kind == kindSha384;
		let done = 0;
		if (kind == kindSha256 || kind == kindSha224) done = sha256HwBlocks(state, data, off, blocks) as int32;
		else if (wide) done = sha512HwBlocks(state, data, off, blocks) as int32;
		const size = wide ? 128 : 64;
		for (let i = done; i < blocks; i++) {
			const at = off + i * size;
			if (kind == kindSha256 || kind == kindSha224) compress256Words(state, data, at);
			else if (wide) compress512Words(state, data, at);
			else if (kind == kindSha1) compressSha1Words(state, data, at);
			else compressMd5Words(state, data, at);
		}
	}

	function compressRun(h: HashState, data: HashBytes, off: int32, blocks: int32): void {
		compressWords(h.kind, h.state, data, off, blocks);
	}
} else {
	function compressRun(h: HashState, data: HashBytes, off: int32, blocks: int32): void {
		for (let i = 0; i < blocks; i++) {
			const at = off + i * h.blockSize;
			if (h.kind == kindSha256 || h.kind == kindSha224) compress256(h, data, at);
			else if (h.kind == kindSha512 || h.kind == kindSha384) compress512(h, data, at);
			else if (h.kind == kindSha1) compressSha1(h, data, at);
			else compressMd5(h, data, at);
		}
	}
}

export function updateHash(h: HashState, data: HashBytes): void {
	if (h.finished) throw new Error("hash already finished");
	const size = h.blockSize;
	const end = data.length as int32;
	let at = 0;
	let filled = h.filled;
	h.length += end;
	if (filled > 0) {
		const take = end < size - filled ? end : size - filled;
		for (let i = 0; i < take; i++) h.block[filled + i] = data[i];
		filled += take;
		at = take;
		if (filled < size) {
			h.filled = filled;
			return;
		}
		compressRun(h, h.block, 0, 1);
		filled = 0;
	}
	if (at + size <= end) {
		const blocks = ((end - at) / size) as int32;
		compressRun(h, data, at, blocks);
		at += blocks * size;
	}
	while (at < end) {
		h.block[filled] = data[at];
		filled += 1;
		at += 1;
	}
	h.filled = filled;
}

/**
 * Pads the last `filled` bytes of a message of `length` bytes in `block`: 0x80, zeros, then the
 * length in bits in the last eight bytes, little-endian for MD5 and big-endian for the others. The blocks to compress.
 */
function padInto(block: Span<uint8>, filled: int32, size: int32, length: number, md5: boolean): int32 {
	const lengthBytes = size == 128 ? 16 : 8;
	block[filled] = 0x80;
	const blocks = ((filled + lengthBytes) / size) as int32 + 1;
	const end = blocks * size;
	for (let i = filled + 1; i < end - 8; i++) block[i] = 0;
	let high: uint32 = 0;
	let low: uint32 = 0;
	when (js) {
		const bits = length * 8;
		high = Math.floor(bits / 4294967296) as uint32;
		low = (bits - Math.floor(bits / 4294967296) * 4294967296) as uint32;
	} else {
		const bytes = length as uint64;
		high = (bytes >> 29) as uint32;
		low = (bytes << 3) as uint32;
	}
	const at = end - 8;
	for (let i = 0; i < 4; i++) {
		const shift = (8 * i) as uint32;
		if (md5) {
			block[at + i] = ((low >> shift) & 255) as uint8;
			block[at + 4 + i] = ((high >> shift) & 255) as uint8;
		} else {
			block[at + 7 - i] = ((low >> shift) & 255) as uint8;
			block[at + 3 - i] = ((high >> shift) & 255) as uint8;
		}
	}
	return blocks;
}

/** The first `words` chaining words as digest bytes: little-endian words for MD5, big-endian for the others. */
function writeDigest(state: Readonly<Span<uint32>>, out: uint8[], words: int32, md5: boolean): void {
	for (let w = 0; w < words; w++) {
		const word = state[w];
		if (md5) {
			out[4 * w] = (word & 255) as uint8;
			out[4 * w + 1] = ((word >> 8) & 255) as uint8;
			out[4 * w + 2] = ((word >> 16) & 255) as uint8;
			out[4 * w + 3] = (word >> 24) as uint8;
		} else {
			out[4 * w] = (word >> 24) as uint8;
			out[4 * w + 1] = ((word >> 16) & 255) as uint8;
			out[4 * w + 2] = ((word >> 8) & 255) as uint8;
			out[4 * w + 3] = (word & 255) as uint8;
		}
	}
}

/** Pads, compresses the last block(s) and writes the digest to `out`; the state is finished afterwards. */
export function finishHashInto(h: HashState, out: uint8[]): void {
	if (h.finished) throw new Error("hash already finished");
	if (out.length < h.outputSize) {
		throw new Error("hash: output is shorter than the digest");
	}
	const md5 = h.kind == kindMd5;
	const blocks = padInto(h.block, h.filled, h.blockSize, h.length, md5);
	compressRun(h, h.block, 0, blocks);
	h.filled = 0;
	h.finished = true;
	writeDigest(h.state, out, h.outputSize >> 2, md5);
}

export function finishHash(h: HashState): uint8[] {
	const out = digestArray(h.outputSize);
	finishHashInto(h, out);
	wipeHashState(h);
	return out;
}

// A one-shot digest on C keeps its chaining words and last blocks on the stack, so the only
// allocation is the digest. SHA-2 on the CPU's extension calls the kernel directly, which
// measured 7-10 ns faster at 64 B on arm64 than the shared path; with room for three blocks,
// the shared path compresses the last whole block of the input with the padding.
when (!js) {
	function digestWith(kind: int32, data: HashBytes, state: Span<uint32>, block: Span<uint8>): uint8[] {
		const md5 = kind == kindMd5;
		const size = kind == kindSha512 || kind == kindSha384 ? 128 : 64;
		initWords(kind, state);
		const length = data.length as int32;
		let direct = (length / size) as int32;
		if (direct > 0 && block.length >= 3 * size) direct -= 1;
		compressWords(kind, state, data, 0, direct);
		const rest = length - direct * size;
		for (let i = 0; i < rest; i++) block[i] = data[direct * size + i];
		const blocks = padInto(block, rest, size, length as number, md5);
		compressWords(kind, state, block, 0, blocks);
		const out = digestArray(hashOutputSize(kind));
		writeDigest(state, out, out.length >> 2, md5);
		wipeWords(state[0..stateWords(kind)]);
		wipeBytes(block[0..blocks * size]);
		return out;
	}

	function sha2HwOneShot(kind: int32, data: HashBytes): uint8[] | null {
		const wide = kind == kindSha512 || kind == kindSha384;
		if ((pureCpuFeatures() & (wide ? 2 : 1)) == 0) return null;
		const size = wide ? 128 : 64;
		let state: uint32[16] = [0];
		let block: uint8[256] = [0];
		sha2Iv(kind, state);
		const length = data.length as int32;
		const full = (length / size) as int32;
		if (full > 0) {
			if (wide) sha512HwBlocks(state, data, 0, full);
			else sha256HwBlocks(state, data, 0, full);
		}
		const rest = length - full * size;
		for (let i = 0; i < rest; i++) block[i] = data[full * size + i];
		const blocks = padInto(block, rest, size, length as number, false);
		if (wide) sha512HwBlocks(state, block, 0, blocks);
		else sha256HwBlocks(state, block, 0, blocks);
		const out = digestArray(hashOutputSize(kind));
		writeDigest(state, out, out.length >> 2, false);
		wipeWords(state[0..(wide ? 16 : 8)]);
		wipeBytes(block[0..blocks * size]);
		return out;
	}

	function oneShot(kind: int32, data: HashBytes): uint8[] {
		if (kind != kindSha1 && kind != kindMd5) {
			const out = sha2HwOneShot(kind, data);
			if (out != null) return out;
		}
		if (kind == kindSha512 || kind == kindSha384) {
			let state: uint32[16] = [0];
			let block: uint8[256] = [0];
			return digestWith(kind, data, state, block);
		}
		let state: uint32[8] = [0];
		let block: uint8[192] = [0];
		return digestWith(kind, data, state, block);
	}
}

export function hashOf(kind: int32, data: HashBytes): uint8[] {
	when (!js) {
		return oneShot(kind, data);
	} else {
		const h = newHash(kind);
		updateHash(h, data);
		return finishHash(h);
	}
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
