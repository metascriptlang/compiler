import { msCryptoInit, msCryptoCleanup, msCryptoHashString, msCryptoHashBuffer, msCryptoHmacString, msCryptoHmacBuffer, msCryptoRandomBytes, msCryptoRandomInt, msCryptoRandomUuid, msCryptoTimingSafeEqual, msCryptoHashInitHandle, msCryptoHashUpdateHandle, msCryptoHashFinalHandle, msCryptoHashFinalBufferHandle, msCryptoHashFreeHandle, msCryptoHmacInitHandle, msCryptoHmacUpdateHandle, msCryptoHmacFinalHandle, msCryptoHmacFinalBufferHandle, msCryptoHmacFreeHandle, msCryptoIsHashSupported, msCryptoToHex, msCryptoFromHex, msCryptoToBase64, msCryptoFromBase64, msCryptoPbkdf2, msCryptoHkdf } from "./kernel";

// ===== Types =====

export type HashAlgorithm =
	| "sha256" | "sha512" | "sha384" | "sha224"
	| "sha1" | "md5" | "ripemd160"
	| "sha3-224" | "sha3-256" | "sha3-384" | "sha3-512";

export type HashEncoding = "hex" | "base64";

import { CryptoError, CryptoErrorKind, hashFailed, hmacFailed, randomFailed, keyDerivationFailed } from "./errors";
export { CryptoError, CryptoErrorKind, cryptoError } from "./errors";

// ===== Initialization =====

export function init(): boolean {
	return msCryptoInit();
}

export function cleanup(): void {
	msCryptoCleanup();
}

// ===== Hash Functions =====

export function hash(algorithm: string, data: string, encoding: string = "hex"): Result<string, CryptoError> {
	const result = msCryptoHashString(algorithm, data, encoding);
	if (result == "") {
		return Result.err(hashFailed(algorithm, "Hash computation failed"));
	}
	return Result.ok(result);
}

export function sha256(data: string, encoding: string = "hex"): Result<string, CryptoError> { return hash("sha256", data, encoding); }
export function sha512(data: string, encoding: string = "hex"): Result<string, CryptoError> { return hash("sha512", data, encoding); }
export function sha384(data: string, encoding: string = "hex"): Result<string, CryptoError> { return hash("sha384", data, encoding); }
export function sha1(data: string, encoding: string = "hex"): Result<string, CryptoError> { return hash("sha1", data, encoding); }
export function md5(data: string, encoding: string = "hex"): Result<string, CryptoError> { return hash("md5", data, encoding); }

export function hashBuffer(algorithm: string, data: string): Result<string, CryptoError> {
	const result = msCryptoHashBuffer(algorithm, data);
	if (result == "") {
		return Result.err(hashFailed(algorithm, "Hash computation failed"));
	}
	return Result.ok(result);
}

// ===== HMAC Functions =====

export function hmac(
	algorithm: string,
	key: string,
	data: string,
	encoding: string = "hex"
): Result<string, CryptoError> {
	const result = msCryptoHmacString(algorithm, key, data, encoding);
	if (result == "") {
		return Result.err(hmacFailed(algorithm, "HMAC computation failed"));
	}
	return Result.ok(result);
}

export function hmacBuffer(algorithm: string, key: string, data: string): Result<string, CryptoError> {
	const result = msCryptoHmacBuffer(algorithm, key, data);
	if (result == "") {
		return Result.err(hmacFailed(algorithm, "HMAC computation failed"));
	}
	return Result.ok(result);
}

// ===== Random Functions =====

export function randomBytes(size: number): Result<string, CryptoError> {
	const result = msCryptoRandomBytes(size);
	if (result == "") {
		return Result.err(randomFailed("Random byte generation failed"));
	}
	return Result.ok(result);
}

export function randomInt(min: number, max: number): Result<number, CryptoError> {
	const result = msCryptoRandomInt(min, max);
	if (result == -1) {
		return Result.err(randomFailed("Random integer generation failed"));
	}
	return Result.ok(result);
}

export function randomUUID(): Result<string, CryptoError> {
	const result = msCryptoRandomUuid();
	if (result == "") {
		return Result.err(randomFailed("UUID generation failed"));
	}
	return Result.ok(result);
}

// ===== Timing-Safe Comparison =====

export function timingSafeEqual(a: string, b: string): boolean {
	return msCryptoTimingSafeEqual(a, b);
}

// ===== Streaming Hash =====

export class Hasher {
	_ctx: int64;

	static create(algorithm: string): Hasher {
		const ctx = msCryptoHashInitHandle(algorithm);
		return { _ctx: ctx };
	}

	update(data: string): Hasher {
		if (this._ctx != 0) {
			msCryptoHashUpdateHandle(this._ctx, data);
		}
		return this;
	}

	digest(encoding: string = "hex"): string {
		if (this._ctx == 0) {
			return "";
		}
		const result = msCryptoHashFinalHandle(this._ctx, encoding);
		this._ctx = 0;
		return result;
	}

	digestBuffer(): string {
		if (this._ctx == 0) {
			return "";
		}
		const result = msCryptoHashFinalBufferHandle(this._ctx);
		this._ctx = 0;
		return result;
	}

	onDestroy(): void {
		if (this._ctx != 0) {
			msCryptoHashFreeHandle(this._ctx);
			this._ctx = 0;
		}
	}
}

// ===== Streaming HMAC =====

export class Hmac {
	_ctx: int64;

	static create(algorithm: string, key: string): Hmac {
		const ctx = msCryptoHmacInitHandle(algorithm, key);
		return { _ctx: ctx };
	}

	update(data: string): Hmac {
		if (this._ctx != 0) {
			msCryptoHmacUpdateHandle(this._ctx, data);
		}
		return this;
	}

	digest(encoding: string = "hex"): string {
		if (this._ctx == 0) {
			return "";
		}
		const result = msCryptoHmacFinalHandle(this._ctx, encoding);
		this._ctx = 0;
		return result;
	}

	digestBuffer(): string {
		if (this._ctx == 0) {
			return "";
		}
		const result = msCryptoHmacFinalBufferHandle(this._ctx);
		this._ctx = 0;
		return result;
	}

	onDestroy(): void {
		if (this._ctx != 0) {
			msCryptoHmacFreeHandle(this._ctx);
			this._ctx = 0;
		}
	}
}

// ===== Factory Functions =====

export function createHash(algorithm: string): Hasher {
	return Hasher.create(algorithm);
}

export function createHmac(algorithm: string, key: string): Hmac {
	return Hmac.create(algorithm, key);
}

// ===== Utility =====

export function getHashes(): string[] {
	return ["sha256", "sha512", "sha384", "sha224", "sha1", "md5", "ripemd160",
		"sha3-256", "sha3-384", "sha3-512", "sha3-224"];
}

export function isHashSupported(algorithm: string): boolean {
	return msCryptoIsHashSupported(algorithm);
}

// ===== Encoding =====

export function toHex(data: string): string { return msCryptoToHex(data); }
export function fromHex(hex: string): string { return msCryptoFromHex(hex); }
export function toBase64(data: string): string { return msCryptoToBase64(data); }
export function fromBase64(b64: string): string { return msCryptoFromBase64(b64); }

// ===== Key Derivation =====

export function pbkdf2(password: string, salt: string, iterations: int32, keyLength: int32, digest: string): Result<string, CryptoError> {
	if (digest == "") digest = "sha256";
	const result = msCryptoPbkdf2(password, salt, iterations, keyLength, digest);
	if (result.length == 0) return Result.err(keyDerivationFailed("pbkdf2", "key derivation failed"));
	return Result.ok(result);
}

export function hkdf(algorithm: string, ikm: string, salt: string, info: string, length: int32): Result<string, CryptoError> {
	if (algorithm == "") algorithm = "sha256";
	const result = msCryptoHkdf(algorithm, ikm, salt, info, length);
	if (result.length == 0) return Result.err(keyDerivationFailed("hkdf", "key derivation failed"));
	return Result.ok(result);
}

// ===== Async Versions (spawn to worker thread for heavy operations) =====

export async function pbkdf2Async(password: string, salt: string, iterations: int32, keyLength: int32, digest: string): Promise<Result<string, CryptoError>> {
	return await spawn(() => { return pbkdf2(password, salt, iterations, keyLength, digest); });
}

export async function hashAsync(algorithm: string, data: string, encoding: string): Promise<Result<string, CryptoError>> {
	return await spawn(() => { return hash(algorithm, data, encoding); });
}
