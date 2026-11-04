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
import { randomOctets } from "./bigint";
import {
	CryptoError, randomFailed, invalidAlgorithm, invalidInput,
	invalidEncoding,
} from "../errors";

export type HashAlgorithm =
	| "sha256" | "sha512" | "sha384" | "sha224"
	| "sha1" | "md5" | "ripemd160"
	| "sha3-224" | "sha3-256" | "sha3-384" | "sha3-512";

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
	const drawn = drawBytes(8);
	if (drawn == null) return null;
	let x: uint64 = 0;
	for (let i = 0; i < 8; i++) x = (x << 8) | (drawn[i] as uint64);
	return x;
}

/** The high and low 64-bit halves of `x * n`, from 32-bit limbs. */
function mulWide(x: uint64, n: uint64): uint64[] {
	const mask: uint64 = 0xffffffff;
	const x0 = x & mask;
	const x1 = x >> 32;
	const n0 = n & mask;
	const n1 = n >> 32;
	const p00 = x0 * n0;
	const p01 = x0 * n1;
	const p10 = x1 * n0;
	const p11 = x1 * n1;
	const mid = (p00 >> 32) + (p01 & mask) + (p10 & mask);
	const high = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
	const low = (mid << 32) | (p00 & mask);
	return [high, low];
}

/** Lemire's debiased multiply: a uniform draw in [0, lessThan). */
function uintLessThan(lessThan: uint64): uint64 | null {
	const first = drawUint64();
	if (first == null) return null;
	let m = mulWide(first, lessThan);
	if (m[1] < lessThan) {
		const zero: uint64 = 0;
		let t = zero - lessThan;
		if (t >= lessThan) {
			t -= lessThan;
			if (t >= lessThan) t %= lessThan;
		}
		while (m[1] < t) {
			const next = drawUint64();
			if (next == null) return null;
			m = mulWide(next, lessThan);
		}
	}
	return m[0];
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

// ===== Hash and HMAC =====

export function digestSync(
	algorithm: HashAlgorithm,
	data: Bytes,
): Result<Buffer, CryptoError> {
	const kind = hashKind(algorithm);
	if (kind < 0) return Result.err(invalidAlgorithm(algorithm));
	return Result.ok(hashOf(kind, bytesOf(data)) as Buffer);
}

export function hmacSync(
	algorithm: HashAlgorithm,
	key: Bytes,
	data: Bytes,
): Result<Buffer, CryptoError> {
	const kind = hashKind(algorithm);
	if (kind < 0) return Result.err(invalidAlgorithm(algorithm));
	return Result.ok(hmacOf(kind, bytesOf(key), bytesOf(data)) as Buffer);
}

export class Hasher {
	_state: HashState;

	static create(algorithm: HashAlgorithm): Hasher {
		const kind = hashKind(algorithm);
		if (kind < 0) throw new Error(`createHash: could not start "${algorithm}"`);
		return { _state: newHash(kind) };
	}

	update(data: Bytes): Hasher {
		if (!this._state.finished) updateHash(this._state, bytesOf(data));
		return this;
	}

	digest(): Buffer {
		if (this._state.finished) return new Array<uint8>(0) as Buffer;
		return finishHash(this._state) as Buffer;
	}
}

export class Hmac {
	_state: HmacState;
	_done: boolean;

	static create(algorithm: HashAlgorithm, key: Bytes): Hmac {
		const kind = hashKind(algorithm);
		if (kind < 0) throw new Error(`createHmac: could not start "${algorithm}"`);
		return { _state: newHmac(kind, bytesOf(key)), _done: false };
	}

	update(data: Bytes): Hmac {
		if (!this._done) updateHmac(this._state, bytesOf(data));
		return this;
	}

	digest(): Buffer {
		if (this._done) return new Array<uint8>(0) as Buffer;
		this._done = true;
		return finishHmac(this._state) as Buffer;
	}
}

export function createHash(algorithm: HashAlgorithm): Hasher {
	return Hasher.create(algorithm);
}

export function createHmac(algorithm: HashAlgorithm, key: Bytes): Hmac {
	return Hmac.create(algorithm, key);
}

/** The hashes the portable kernels run today. */
export function getHashes(): HashAlgorithm[] {
	const all: HashAlgorithm[] = [
		"sha256", "sha512", "sha384", "sha224", "sha1", "md5", "ripemd160",
		"sha3-256", "sha3-384", "sha3-512", "sha3-224",
	];
	return all.filter((name) => hashKind(name) >= 0);
}

export function isHashSupported(algorithm: string): boolean {
	return hashKind(algorithm) >= 0;
}

/** The digest of `data` as hex, or base64 when `encoding` says so; "" for an unknown hash. */
export function encodedHash(
	algorithm: string,
	data: string,
	encoding: string,
): string {
	const kind = hashKind(algorithm);
	if (kind < 0) return "";
	const digest = hashOf(kind, data.asBytes().slice(0));
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
