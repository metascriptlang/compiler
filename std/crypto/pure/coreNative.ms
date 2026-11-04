/**
 * The non-algorithm half of std/crypto in MetaScript: OS random bytes, randomInt, randomUUID,
 * timingSafeEqual, hex and base64, and the hash and HMAC objects over the portable kernels.
 * Private until the public index switches to it; hashes the kernels lack are refused.
 */

import { Buffer } from "std/core/buffer";
import { Bytes } from "std/core/buffer/bytes";
import {
	encodeHex, decodeHex, encodeBase64, decodeBase64,
} from "../../core/encoding";
import { bytesOf } from "./bytes";
import { HashState } from "./state";
import { hashKind, newHash, updateHash, finishHash, hashOf } from "./hash";
import { HmacState, newHmac, updateHmac, finishHmac, hmacOf } from "./hmac";
import { Ripemd160State, newRipemd160, updateRipemd160, finishRipemd160, ripemd160Of } from "./ripemd160";
import { Sha3State, newSha3, updateSha3, finishSha3, sha3Of } from "./sha3";
import { wipeBytes } from "./secret";
import {
	CryptoError, randomFailed, invalidAlgorithm, invalidInput,
	invalidEncoding,
} from "../errors";

export type HashAlgorithm =
	| "sha256" | "sha512" | "sha384" | "sha224"
	| "sha1" | "md5" | "ripemd160"
	| "sha3-224" | "sha3-256" | "sha3-384" | "sha3-512";

when (js) {
	import { randomOctets } from "./bigint";
}

when (c) {
	@include("runtime/crypto/randomFill.h");
	extern function osRandomFill(
		buffer: Ptr<uint8>,
		length: uint64,
	): int32 from "ms_random_fill";
}

/** `size` bytes from the OS CSPRNG, or null when the source failed. */
function drawBytes(size: int32): uint8[] | null {
	when (js) {
		return randomOctets(size);
	} else {
		const out = new Array<uint8>(size);
		if (size == 0) return out;
		const span: Span<uint8> = out;
		if (osRandomFill(span as Ptr<uint8>, size as uint64) != 0) return null;
		return out;
	}
}

// ===== Random =====

const MAX_BYTES = 2147483647;
const MAX_SAFE = 9007199254740991;
const RANGE_LIMIT = 281474976710656;

export function randomBytesSync(size: number): Result<Buffer, CryptoError> {
	if (!(size >= 0) || Math.floor(size) != size || size > MAX_BYTES) {
		return Result.err(randomFailed("Random byte generation failed"));
	}
	const drawn = drawBytes(size as int32);
	if (drawn == null) {
		return Result.err(randomFailed("Random byte generation failed"));
	}
	return Result.ok(drawn as Buffer);
}

export async function randomBytes(
	size: number,
): Promise<Result<Buffer, CryptoError>> {
	return randomBytesSync(size);
}

function isSafeInteger(value: number): boolean {
	return Math.floor(value) == value && Math.abs(value) <= MAX_SAFE;
}

function drawUint64(): uint64 | null {
	when (js) {
		const drawn = drawBytes(8);
		if (drawn == null) return null;
		let x: uint64 = 0;
		for (let i = 0; i < 8; i++) x = (x << 8) | (drawn[i] as uint64);
		return x;
	} else {
		let drawn: uint8[8] = [0];
		const span: Span<uint8> = drawn;
		if (osRandomFill(span as Ptr<uint8>, 8) != 0) return null;
		let x: uint64 = 0;
		for (let i = 0; i < 8; i++) x = (x << 8) | (drawn[i] as uint64);
		return x;
	}
}

/** The high 64 bits of the 128-bit product `x * n`, from 32-bit limbs. */
function mulHigh(x: uint64, n: uint64): uint64 {
	const mask: uint64 = 0xffffffff;
	const x0 = x & mask;
	const x1 = x >> 32;
	const n0 = n & mask;
	const n1 = n >> 32;
	const p01 = x0 * n1;
	const p10 = x1 * n0;
	const mid = ((x0 * n0) >> 32) + (p01 & mask) + (p10 & mask);
	return x1 * n1 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
}

/** Lemire's debiased multiply: a uniform draw in [0, lessThan). */
function uintLessThan(lessThan: uint64): uint64 | null {
	let x = drawUint64();
	if (x == null) return null;
	if (x * lessThan < lessThan) {
		const zero: uint64 = 0;
		let t = zero - lessThan;
		if (t >= lessThan) {
			t -= lessThan;
			if (t >= lessThan) t %= lessThan;
		}
		while (x * lessThan < t) {
			x = drawUint64();
			if (x == null) return null;
		}
	}
	return mulHigh(x, lessThan);
}

export function randomIntSync(
	min: number,
	max: number,
): Result<number, CryptoError> {
	if (!isSafeInteger(min)) {
		return Result.err(invalidInput("random", "min must be a safe integer"));
	}
	if (!isSafeInteger(max)) {
		return Result.err(invalidInput("random", "max must be a safe integer"));
	}
	if (!(max > min)) {
		return Result.err(invalidInput("random", "max must be greater than min"));
	}
	const range = max - min;
	if (range >= RANGE_LIMIT) {
		return Result.err(
			invalidInput("random", "max - min must be less than 2^48"),
		);
	}
	const drawn = uintLessThan(range as uint64);
	if (drawn == null) {
		return Result.err(randomFailed("Random integer generation failed"));
	}
	return Result.ok(min + (drawn as number));
}

export async function randomInt(
	min: number,
	max: number,
): Promise<Result<number, CryptoError>> {
	return randomIntSync(min, max);
}

export function randomUUIDSync(): Result<string, CryptoError> {
	const b = drawBytes(16);
	if (b == null) return Result.err(randomFailed("UUID generation failed"));
	b[6] = (b[6] & 0x0f) | 0x40;
	b[8] = (b[8] & 0x3f) | 0x80;
	const hex = b.encodeHex();
	return Result.ok(
		`${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-` +
			`${hex.slice(16, 20)}-${hex.slice(20, 32)}`,
	);
}

export async function randomUUID(): Promise<Result<string, CryptoError>> {
	return randomUUIDSync();
}

// ===== Timing-Safe Comparison =====

/** Unequal lengths are unequal; equal lengths are compared without an early exit. */
export function timingSafeEqual(a: Bytes, b: Bytes): boolean {
	const x = bytesOf(a);
	const y = bytesOf(b);
	if (x.length != y.length) return false;
	let acc: uint8 = 0;
	for (let i = 0; i < x.length; i++) acc = acc | (x[i] ^ y[i]);
	const one: uint32 = 1;
	return ((((acc as uint32) - one) >> 8) & one) == one;
}

// ===== Extended algorithm dispatch (ripemd160, sha3-*) =====

const extKindRipemd160 = 10;
const extKindSha3_224 = 11;
const extKindSha3_256 = 12;
const extKindSha3_384 = 13;
const extKindSha3_512 = 14;

/** Kind number for the five algorithms not in hashKind; -1 if unrecognised. */
function extHashKind(algorithm: string): int32 {
	if (algorithm == "ripemd160") return extKindRipemd160;
	if (algorithm == "sha3-224") return extKindSha3_224;
	if (algorithm == "sha3-256") return extKindSha3_256;
	if (algorithm == "sha3-384") return extKindSha3_384;
	if (algorithm == "sha3-512") return extKindSha3_512;
	return -1;
}

function extSha3Bits(extKind: int32): int32 {
	if (extKind == extKindSha3_224) return 224;
	if (extKind == extKindSha3_256) return 256;
	if (extKind == extKindSha3_384) return 384;
	return 512;
}

function extBlockSize(extKind: int32): int32 {
	if (extKind == extKindRipemd160) return 64;
	return 200 - (extSha3Bits(extKind) >> 2);
}

function extDigest(extKind: int32, data: Readonly<uint8[]>): uint8[] {
	if (extKind == extKindRipemd160) return ripemd160Of(data);
	return sha3Of(extSha3Bits(extKind), data);
}

/** HMAC construction over an extended algorithm. Follows the same pad/key-hash/XOR reference as hmac.ms. */
function extHmacOf(extKind: int32, key: Readonly<uint8[]>, data: Readonly<uint8[]>): uint8[] {
	const blockSize = extBlockSize(extKind);
	const pad = new Array<uint8>(blockSize);
	if (key.length > blockSize) {
		const kh = extDigest(extKind, key);
		for (let i = 0; i < kh.length; i++) pad[i] = kh[i];
		wipeBytes(kh);
	} else {
		for (let i = 0; i < key.length; i++) pad[i] = key[i];
	}
	const opad = new Array<uint8>(blockSize);
	for (let i = 0; i < blockSize; i++) {
		opad[i] = (pad[i] ^ 0x5c) as uint8;
		pad[i] = (pad[i] ^ 0x36) as uint8;
	}
	let innerDigest: uint8[];
	if (extKind == extKindRipemd160) {
		const s = newRipemd160();
		updateRipemd160(s, pad);
		updateRipemd160(s, data);
		innerDigest = finishRipemd160(s);
	} else {
		const s = newSha3(extSha3Bits(extKind));
		updateSha3(s, pad);
		updateSha3(s, data);
		innerDigest = finishSha3(s);
	}
	wipeBytes(pad);
	let result: uint8[];
	if (extKind == extKindRipemd160) {
		const outer = newRipemd160();
		updateRipemd160(outer, opad);
		updateRipemd160(outer, innerDigest);
		result = finishRipemd160(outer);
	} else {
		const outer = newSha3(extSha3Bits(extKind));
		updateSha3(outer, opad);
		updateSha3(outer, innerDigest);
		result = finishSha3(outer);
	}
	wipeBytes(innerDigest);
	wipeBytes(opad);
	return result;
}

// ===== Hash and HMAC =====

export function digestSync(
	algorithm: HashAlgorithm,
	data: Bytes,
): Result<Buffer, CryptoError> {
	const kind = hashKind(algorithm);
	if (kind >= 0) {
		when (c) {
			if (typeof data == "string") return Result.ok(hashOf(kind, data.asBytes()) as Buffer);
			return Result.ok(hashOf(kind, data) as Buffer);
		} else {
			return Result.ok(hashOf(kind, bytesOf(data)) as Buffer);
		}
	}
	const extKind = extHashKind(algorithm);
	if (extKind < 0) return Result.err(invalidAlgorithm(algorithm));
	return Result.ok(extDigest(extKind, bytesOf(data)) as Buffer);
}

export function hmacSync(
	algorithm: HashAlgorithm,
	key: Bytes,
	data: Bytes,
): Result<Buffer, CryptoError> {
	const kind = hashKind(algorithm);
	if (kind >= 0) return Result.ok(hmacOf(kind, bytesOf(key), bytesOf(data)) as Buffer);
	const extKind = extHashKind(algorithm);
	if (extKind < 0) return Result.err(invalidAlgorithm(algorithm));
	return Result.ok(extHmacOf(extKind, bytesOf(key), bytesOf(data)) as Buffer);
}

export class Hasher {
	_state: HashState | null;
	_ripemd: Ripemd160State | null;
	_sha3: Sha3State | null;
	_extKind: int32;

	static create(algorithm: HashAlgorithm): Hasher {
		const kind = hashKind(algorithm);
		if (kind >= 0) {
			return { _state: newHash(kind), _ripemd: null, _sha3: null, _extKind: -1 };
		}
		const extKind = extHashKind(algorithm);
		if (extKind < 0) throw new Error(`createHash: could not start "${algorithm}"`);
		if (extKind == extKindRipemd160) {
			return { _state: null, _ripemd: newRipemd160(), _sha3: null, _extKind: extKind };
		}
		return { _state: null, _ripemd: null, _sha3: newSha3(extSha3Bits(extKind)), _extKind: extKind };
	}

	update(data: Bytes): Hasher {
		if (this._extKind < 0) {
			const s = this._state;
			if (s == null || s.finished) return this;
			when (c) {
				updateHash(s, typeof data == "string" ? data.asBytes() : data);
			} else {
				updateHash(s, bytesOf(data));
			}
		} else if (this._extKind == extKindRipemd160) {
			const r = this._ripemd;
			if (r == null || r.finished) return this;
			updateRipemd160(r, bytesOf(data));
		} else {
			const h3 = this._sha3;
			if (h3 == null || h3.finished) return this;
			updateSha3(h3, bytesOf(data));
		}
		return this;
	}

	digest(): Buffer {
		if (this._extKind < 0) {
			const s = this._state;
			if (s == null || s.finished) return new Array<uint8>(0) as Buffer;
			return finishHash(s) as Buffer;
		} else if (this._extKind == extKindRipemd160) {
			const r = this._ripemd;
			if (r == null || r.finished) return new Array<uint8>(0) as Buffer;
			return finishRipemd160(r) as Buffer;
		} else {
			const h3 = this._sha3;
			if (h3 == null || h3.finished) return new Array<uint8>(0) as Buffer;
			return finishSha3(h3) as Buffer;
		}
	}
}

export class Hmac {
	_state: HmacState | null;
	_ripemdInner: Ripemd160State | null;
	_sha3Inner: Sha3State | null;
	_extOpad: uint8[];
	_extKind: int32;
	_done: boolean;

	static create(algorithm: HashAlgorithm, key: Bytes): Hmac {
		const kind = hashKind(algorithm);
		if (kind >= 0) {
			return { _state: newHmac(kind, bytesOf(key)), _ripemdInner: null, _sha3Inner: null, _extOpad: [], _extKind: -1, _done: false };
		}
		const extKind = extHashKind(algorithm);
		if (extKind < 0) throw new Error(`createHmac: could not start "${algorithm}"`);
		const rawKey = bytesOf(key);
		const blockSize = extBlockSize(extKind);
		const pad = new Array<uint8>(blockSize);
		if (rawKey.length > blockSize) {
			const kh = extDigest(extKind, rawKey);
			for (let i = 0; i < kh.length; i++) pad[i] = kh[i];
			wipeBytes(kh);
		} else {
			for (let i = 0; i < rawKey.length; i++) pad[i] = rawKey[i];
		}
		const opad = new Array<uint8>(blockSize);
		for (let i = 0; i < blockSize; i++) {
			opad[i] = (pad[i] ^ 0x5c) as uint8;
			pad[i] = (pad[i] ^ 0x36) as uint8;
		}
		let ripemdInner: Ripemd160State | null = null;
		let sha3Inner: Sha3State | null = null;
		if (extKind == extKindRipemd160) {
			const inner = newRipemd160();
			updateRipemd160(inner, pad);
			ripemdInner = inner;
		} else {
			const inner = newSha3(extSha3Bits(extKind));
			updateSha3(inner, pad);
			sha3Inner = inner;
		}
		wipeBytes(pad);
		return { _state: null, _ripemdInner: ripemdInner, _sha3Inner: sha3Inner, _extOpad: opad, _extKind: extKind, _done: false };
	}

	update(data: Bytes): Hmac {
		if (!this._done) {
			if (this._extKind < 0) {
				const s = this._state;
				if (s != null) updateHmac(s, bytesOf(data));
			} else if (this._extKind == extKindRipemd160) {
				const r = this._ripemdInner;
				if (r != null) updateRipemd160(r, bytesOf(data));
			} else {
				const h3 = this._sha3Inner;
				if (h3 != null) updateSha3(h3, bytesOf(data));
			}
		}
		return this;
	}

	digest(): Buffer {
		if (this._done) return new Array<uint8>(0) as Buffer;
		this._done = true;
		if (this._extKind < 0) {
			const s = this._state;
			if (s == null) return new Array<uint8>(0) as Buffer;
			return finishHmac(s) as Buffer;
		}
		let innerDigest: uint8[];
		if (this._extKind == extKindRipemd160) {
			const r = this._ripemdInner;
			if (r == null) return new Array<uint8>(0) as Buffer;
			innerDigest = finishRipemd160(r);
			const outer = newRipemd160();
			updateRipemd160(outer, this._extOpad);
			updateRipemd160(outer, innerDigest);
			const result = finishRipemd160(outer) as Buffer;
			wipeBytes(innerDigest);
			wipeBytes(this._extOpad);
			return result;
		} else {
			const h3 = this._sha3Inner;
			if (h3 == null) return new Array<uint8>(0) as Buffer;
			innerDigest = finishSha3(h3);
			const outer = newSha3(extSha3Bits(this._extKind));
			updateSha3(outer, this._extOpad);
			updateSha3(outer, innerDigest);
			const result = finishSha3(outer) as Buffer;
			wipeBytes(innerDigest);
			wipeBytes(this._extOpad);
			return result;
		}
	}
}

export function createHash(algorithm: HashAlgorithm): Hasher {
	return Hasher.create(algorithm);
}

export function createHmac(algorithm: HashAlgorithm, key: Bytes): Hmac {
	return Hmac.create(algorithm, key);
}

/** All hash algorithms the portable kernels support. */
export function getHashes(): HashAlgorithm[] {
	const all: HashAlgorithm[] = [
		"sha256", "sha512", "sha384", "sha224", "sha1", "md5", "ripemd160",
		"sha3-256", "sha3-384", "sha3-512", "sha3-224",
	];
	return all.filter((name) => hashKind(name) >= 0 || extHashKind(name) >= 0);
}

export function isHashSupported(algorithm: string): boolean {
	return hashKind(algorithm) >= 0 || extHashKind(algorithm) >= 0;
}

/** The digest of `data` as hex, or base64 when `encoding` says so; "" for an unknown hash. */
export function encodedHash(
	algorithm: string,
	data: string,
	encoding: string,
): string {
	const kind = hashKind(algorithm);
	if (kind >= 0) {
		const digest = hashOf(kind, data.asBytes().slice(0));
		return encoding == "base64" ? digest.encodeBase64() : digest.encodeHex();
	}
	const extKind = extHashKind(algorithm);
	if (extKind < 0) return "";
	const digest = extDigest(extKind, data.asBytes().slice(0));
	return encoding == "base64" ? digest.encodeBase64() : digest.encodeHex();
}

export function base64String(data: string): string {
	return data.asBytes().encodeBase64();
}

// ===== Encoding =====

export function toHex(data: Bytes): string {
	if (typeof data == "string") return data.asBytes().encodeHex();
	return data.encodeHex();
}

export function fromHex(hex: string): Result<Buffer, CryptoError> {
	if (hex.byteLength == 0) return Result.ok(new Array<uint8>(0) as Buffer);
	const raw = hex.decodeHex();
	if (raw.length == 0) {
		return Result.err(
			invalidEncoding("fromHex", "not an even-length hexadecimal string"),
		);
	}
	return Result.ok(raw as Buffer);
}

export function toBase64(data: Bytes): string {
	if (typeof data == "string") return data.asBytes().encodeBase64();
	return data.encodeBase64();
}

export function fromBase64(b64: string): Result<Buffer, CryptoError> {
	if (b64.byteLength == 0) return Result.ok(new Array<uint8>(0) as Buffer);
	const raw = b64.decodeBase64();
	if (raw.length == 0) {
		return Result.err(
			invalidEncoding("fromBase64", "not canonical padded base64"),
		);
	}
	return Result.ok(raw as Buffer);
}
