import { Buffer } from "std/core/buffer";
import { Bytes } from "std/core/buffer/bytes";
import {
	encodeHex, decodeHex, encodeBase64, decodeBase64,
} from "../../core/encoding";
import { bytesOf } from "./bytes";
import { HashState } from "./state";
import {
	hashKind, newHash, updateHash, finishHash, hashOf,
} from "./hash";
import {
	HmacState, newHmac, updateHmac, finishHmac, hmacOf, wipeHmac,
} from "./hmac";
import {
	Ripemd160State,
	newRipemd160, updateRipemd160, finishRipemd160, ripemd160Of,
} from "./ripemd160";
import {
	Sha3State, newSha3, updateSha3, finishSha3, sha3Of,
} from "./sha3";
import { wipeBytes, wipeWords } from "./secret";
import {
	CryptoError, randomFailed, invalidAlgorithm,
	invalidInput, invalidEncoding,
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

export function randomBytesSync(
	size: number,
): Result<Buffer, CryptoError> {
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
		return Result.err(
			invalidInput("random", "min must be a safe integer"),
		);
	}
	if (!isSafeInteger(max)) {
		return Result.err(
			invalidInput("random", "max must be a safe integer"),
		);
	}
	if (!(max > min)) {
		return Result.err(
			invalidInput("random", "max must be greater than min"),
		);
	}
	const range = max - min;
	if (range >= RANGE_LIMIT) {
		return Result.err(
			invalidInput("random", "max - min must be less than 2^48"),
		);
	}
	const drawn = uintLessThan(range as uint64);
	if (drawn == null) {
		return Result.err(
			randomFailed("Random integer generation failed"),
		);
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
	if (b == null) {
		return Result.err(randomFailed("UUID generation failed"));
	}
	b[6] = (b[6] & 0x0f) | 0x40;
	b[8] = (b[8] & 0x3f) | 0x80;
	const hex = b.encodeHex();
	return Result.ok(
		`${hex.slice(0, 8)}-${hex.slice(8, 12)}-` +
		`${hex.slice(12, 16)}-${hex.slice(16, 20)}-` +
		`${hex.slice(20, 32)}`,
	);
}

export async function randomUUID(): Promise<Result<string, CryptoError>> {
	return randomUUIDSync();
}

// ===== Timing-Safe Comparison =====

export function timingSafeEqual(a: Bytes, b: Bytes): boolean {
	const x = bytesOf(a);
	const y = bytesOf(b);
	if (x.length != y.length) return false;
	let acc: uint8 = 0;
	for (let i = 0; i < x.length; i++) acc = acc | (x[i] ^ y[i]);
	const one: uint32 = 1;
	return ((((acc as uint32) - one) >> 8) & one) == one;
}

// ===== Extended algorithm helpers (ripemd160, sha3-*) =====

function sha3BitsOf(algorithm: string): int32 {
	if (algorithm == "sha3-224") return 224;
	if (algorithm == "sha3-256") return 256;
	if (algorithm == "sha3-384") return 384;
	if (algorithm == "sha3-512") return 512;
	return -1;
}

function isExtAlg(algorithm: string): boolean {
	return algorithm == "ripemd160" || sha3BitsOf(algorithm) >= 0;
}

function extOneShot(
	algorithm: string,
	data: Readonly<uint8[]>,
): uint8[] {
	if (algorithm == "ripemd160") return ripemd160Of(data);
	const bits = sha3BitsOf(algorithm);
	if (bits < 0) throw new Error("bad ext algorithm: " + algorithm);
	return sha3Of(bits, data);
}

// ===== Extended HMAC context (Zig16d31: lib/std/crypto/hmac.zig) =====

class ExtHmacCtx {
	_opad: uint8[];
	_inner: Ripemd160State | Sha3State;
}

function newExtHmac(
	algorithm: string,
	key: Readonly<uint8[]>,
): ExtHmacCtx {
	const isRipemd = algorithm == "ripemd160";
	const bits = isRipemd ? 0 : sha3BitsOf(algorithm);
	if (!isRipemd && bits < 0) {
		throw new Error("newExtHmac: bad algorithm " + algorithm);
	}
	const blockSize = isRipemd ? 64 : 200 - (bits >> 2);
	const pad = new Array<uint8>(blockSize);
	if (key.length > blockSize) {
		const kh = extOneShot(algorithm, key);
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
	let inner: Ripemd160State | Sha3State;
	if (isRipemd) {
		const r = newRipemd160();
		updateRipemd160(r, pad);
		inner = r;
	} else {
		const s = newSha3(bits);
		updateSha3(s, pad);
		inner = s;
	}
	wipeBytes(pad);
	return { _opad: opad, _inner: inner };
}

function updateExtHmac(
	ctx: ExtHmacCtx,
	data: Readonly<uint8[]>,
): void {
	const inner = ctx._inner;
	if (inner instanceof Ripemd160State) {
		updateRipemd160(inner, data);
	} else {
		updateSha3(inner, data);
	}
}

function finishExtHmac(ctx: ExtHmacCtx): uint8[] {
	const inner = ctx._inner;
	let result: uint8[];
	if (inner instanceof Ripemd160State) {
		const id = finishRipemd160(inner);
		wipeWords(inner.h);
		const outer = newRipemd160();
		updateRipemd160(outer, ctx._opad);
		updateRipemd160(outer, id);
		result = finishRipemd160(outer);
		wipeWords(outer.h);
		wipeBytes(id);
	} else {
		const id = finishSha3(inner);
		const outer = newSha3(inner.bits);
		updateSha3(outer, ctx._opad);
		updateSha3(outer, id);
		result = finishSha3(outer);
		wipeBytes(id);
	}
	wipeBytes(ctx._opad);
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
			if (typeof data == "string") {
				return Result.ok(
					hashOf(kind, data.asBytes()) as Buffer,
				);
			}
			return Result.ok(hashOf(kind, data) as Buffer);
		} else {
			return Result.ok(hashOf(kind, bytesOf(data)) as Buffer);
		}
	}
	if (!isExtAlg(algorithm)) {
		return Result.err(invalidAlgorithm(algorithm));
	}
	return Result.ok(extOneShot(algorithm, bytesOf(data)) as Buffer);
}

export function hmacSync(
	algorithm: HashAlgorithm,
	key: Bytes,
	data: Bytes,
): Result<Buffer, CryptoError> {
	const kind = hashKind(algorithm);
	if (kind >= 0) {
		when (c) {
			return Result.ok(hmacOf(
				kind,
				typeof key == "string" ? key.asBytes() : key,
				typeof data == "string" ? data.asBytes() : data,
			) as Buffer);
		} else {
			return Result.ok(
				hmacOf(kind, bytesOf(key), bytesOf(data)) as Buffer,
			);
		}
	}
	if (!isExtAlg(algorithm)) {
		return Result.err(invalidAlgorithm(algorithm));
	}
	const ctx = newExtHmac(algorithm, bytesOf(key));
	updateExtHmac(ctx, bytesOf(data));
	return Result.ok(finishExtHmac(ctx) as Buffer);
}

export class Hasher {
	_ctx: HashState | Ripemd160State | Sha3State;

	static create(algorithm: HashAlgorithm): Hasher {
		const kind = hashKind(algorithm);
		if (kind >= 0) return { _ctx: newHash(kind) };
		if (algorithm == "ripemd160") return { _ctx: newRipemd160() };
		const bits = sha3BitsOf(algorithm);
		if (bits < 0) {
			throw new Error(
				`createHash: could not start "${algorithm}"`,
			);
		}
		return { _ctx: newSha3(bits) };
	}

	update(data: Bytes): Hasher {
		const ctx = this._ctx;
		if (ctx instanceof HashState) {
			if (ctx.finished) return this;
			when (c) {
				updateHash(
					ctx,
					typeof data == "string" ? data.asBytes() : data,
				);
			} else {
				updateHash(ctx, bytesOf(data));
			}
		} else if (ctx instanceof Ripemd160State) {
			if (ctx.finished) return this;
			updateRipemd160(ctx, bytesOf(data));
		} else {
			if (ctx.finished) return this;
			updateSha3(ctx, bytesOf(data));
		}
		return this;
	}

	digest(): Buffer {
		const ctx = this._ctx;
		if (ctx instanceof HashState) {
			if (ctx.finished) return new Array<uint8>(0) as Buffer;
			return finishHash(ctx) as Buffer;
		} else if (ctx instanceof Ripemd160State) {
			if (ctx.finished) return new Array<uint8>(0) as Buffer;
			return finishRipemd160(ctx) as Buffer;
		} else {
			if (ctx.finished) return new Array<uint8>(0) as Buffer;
			return finishSha3(ctx) as Buffer;
		}
	}
}

export class Hmac {
	_ctx: HmacState | ExtHmacCtx;
	_done: boolean;

	static create(algorithm: HashAlgorithm, key: Bytes): Hmac {
		const kind = hashKind(algorithm);
		if (kind >= 0) {
			return {
				_ctx: newHmac(kind, bytesOf(key)),
				_done: false,
			};
		}
		if (!isExtAlg(algorithm)) {
			throw new Error(
				`createHmac: could not start "${algorithm}"`,
			);
		}
		return {
			_ctx: newExtHmac(algorithm, bytesOf(key)),
			_done: false,
		};
	}

	update(data: Bytes): Hmac {
		if (!this._done) {
			const ctx = this._ctx;
			if (ctx instanceof HmacState) {
				updateHmac(ctx, bytesOf(data));
			} else {
				updateExtHmac(ctx, bytesOf(data));
			}
		}
		return this;
	}

	digest(): Buffer {
		if (this._done) return new Array<uint8>(0) as Buffer;
		this._done = true;
		const ctx = this._ctx;
		if (ctx instanceof HmacState) {
			const buf = finishHmac(ctx);
			wipeHmac(ctx);
			return buf as Buffer;
		}
		return finishExtHmac(ctx) as Buffer;
	}
}

export function createHash(algorithm: HashAlgorithm): Hasher {
	return Hasher.create(algorithm);
}

export function createHmac(algorithm: HashAlgorithm, key: Bytes): Hmac {
	return Hmac.create(algorithm, key);
}

export function getHashes(): HashAlgorithm[] {
	const all: HashAlgorithm[] = [
		"sha256", "sha512", "sha384", "sha224", "sha1", "md5",
		"ripemd160", "sha3-256", "sha3-384", "sha3-512", "sha3-224",
	];
	return all.filter(
		(name) => hashKind(name) >= 0 || isExtAlg(name),
	);
}

export function isHashSupported(algorithm: string): boolean {
	return hashKind(algorithm) >= 0 || isExtAlg(algorithm);
}

export function encodedHash(
	algorithm: string,
	data: string,
	encoding: string,
): string {
	const kind = hashKind(algorithm);
	if (kind >= 0) {
		const digest = hashOf(kind, data.asBytes().slice(0));
		return encoding == "base64"
			? digest.encodeBase64()
			: digest.encodeHex();
	}
	if (!isExtAlg(algorithm)) return "";
	const digest = extOneShot(algorithm, data.asBytes().slice(0));
	return encoding == "base64"
		? digest.encodeBase64()
		: digest.encodeHex();
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
	if (hex.byteLength == 0) {
		return Result.ok(new Array<uint8>(0) as Buffer);
	}
	const raw = hex.decodeHex();
	if (raw.length == 0) {
		return Result.err(
			invalidEncoding(
				"fromHex",
				"not an even-length hexadecimal string",
			),
		);
	}
	return Result.ok(raw as Buffer);
}

export function toBase64(data: Bytes): string {
	if (typeof data == "string") return data.asBytes().encodeBase64();
	return data.encodeBase64();
}

export function fromBase64(b64: string): Result<Buffer, CryptoError> {
	if (b64.byteLength == 0) {
		return Result.ok(new Array<uint8>(0) as Buffer);
	}
	const raw = b64.decodeBase64();
	if (raw.length == 0) {
		return Result.err(
			invalidEncoding(
				"fromBase64",
				"not canonical padded base64",
			),
		);
	}
	return Result.ok(raw as Buffer);
}
