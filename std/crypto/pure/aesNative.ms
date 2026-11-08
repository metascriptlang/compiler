import { Buffer } from "std/core/buffer";
import { ByteInput } from "std/core/buffer/bytes";
import { CryptoError, CryptoErrorKind, cryptoError } from "../errors";
import { bytesOf, wipeIfCopied, outputBuffer } from "./bytes";
import { randomOctets } from "./random";
import { wipeBytes } from "./secret";
import {
	KeySchedule, expandKey, wipeKeySchedule,
	gcmSealWithNonce, gcmOpen,
	cbcEncrypt as encryptCbc, cbcDecrypt as decryptCbc,
} from "./aes";

export { CryptoError, CryptoErrorKind } from "../errors";

export class AesKey {
	_raw: uint8[];
	_schedule: KeySchedule;

	static import<R extends ByteInput>(raw: R): Result<AesKey, CryptoError> {
		const bytes = bytesOf(raw);
		if (bytes.length != 16 && bytes.length != 32) {
			wipeIfCopied(raw, bytes);
			return Result.err(cryptoError(
				CryptoErrorKind.InvalidKey,
				"AesKey.import", "key must be 16 or 32 bytes",
			));
		}
		const owned = bytes.slice(0);
		wipeIfCopied(raw, bytes);
		return Result.ok({ _raw: owned, _schedule: expandKey(owned) });
	}

	static generate(bits: int32 = 256): Result<AesKey, CryptoError> {
		if (bits != 128 && bits != 256) {
			return Result.err(cryptoError(
				CryptoErrorKind.InvalidInput,
				"AesKey.generate", "bits must be 128 or 256",
			));
		}
		let raw: uint8[] = [];
		try {
			raw = randomOctets(bits / 8);
		} catch (_error) {
			return Result.err(cryptoError(
				CryptoErrorKind.RandomFailed,
				"AesKey.generate", "the OS random source failed",
			));
		}
		try {
			return AesKey.import(raw);
		} finally {
			wipeBytes(raw);
		}
	}

	exportRaw(): Buffer {
		liveSchedule(this, "AesKey.exportRaw");
		return Buffer.from(this._raw);
	}

	onDestroy(): void {
		wipeBytes(this._raw);
		wipeKeySchedule(this._schedule);
		this._raw = [];
		this._schedule = [];
	}
}

function liveSchedule(key: AesKey, operation: string): KeySchedule {
	if (key._raw.length == 0) {
		throw new Error(`${operation}: the key was already destroyed`);
	}
	return key._schedule;
}

export function sealSync<P extends ByteInput, A extends ByteInput>(
	key: AesKey,
	plainTextBytes: P,
	aadBytes: A = "",
): Result<Buffer, CryptoError> {
	const schedule = liveSchedule(key, "seal");
	let nonce: uint8[] = [];
	try {
		nonce = randomOctets(12);
	} catch (_error) {
		return Result.err(cryptoError(
			CryptoErrorKind.RandomFailed,
			"seal", "the OS random source failed",
		));
	}
	try {
		return Result.ok(outputBuffer(gcmSealWithNonce(
			schedule, nonce, (typeof plainTextBytes == "string" ? plainTextBytes.asBytes() : plainTextBytes), (typeof aadBytes == "string" ? aadBytes.asBytes() : aadBytes),
		)));
	} catch (_error) {
		return Result.err(cryptoError(
			CryptoErrorKind.EncryptionFailed,
			"seal", "AES-GCM encryption failed",
		));
	}
}

export function seal<P extends ByteInput, A extends ByteInput>(
	key: AesKey,
	plainTextBytes: P,
	aadBytes: A = "",
): Promise<Result<Buffer, CryptoError>> {
	return Promise.resolve(sealSync(key, plainTextBytes, aadBytes));
}

export function openSync<S extends ByteInput, A extends ByteInput>(
	key: AesKey,
	sealedBytes: S,
	aadBytes: A = "",
): Result<Buffer, CryptoError> {
	const schedule = liveSchedule(key, "open");
	const sealed = (typeof sealedBytes == "string" ? sealedBytes.asBytes() : sealedBytes);
	if (sealed.length < 28) {
		return Result.err(cryptoError(
			CryptoErrorKind.InvalidInput, "open", "sealed data too short",
		));
	}
	const plain = gcmOpen(schedule, sealed, (typeof aadBytes == "string" ? aadBytes.asBytes() : aadBytes));
	if (plain == null) {
		return Result.err(cryptoError(
			CryptoErrorKind.AuthenticationFailed,
			"open", "authentication tag mismatch",
		));
	}
	return Result.ok(outputBuffer(plain));
}

export function open<S extends ByteInput, A extends ByteInput>(
	key: AesKey,
	sealedBytes: S,
	aadBytes: A = "",
): Promise<Result<Buffer, CryptoError>> {
	return Promise.resolve(openSync(key, sealedBytes, aadBytes));
}

export function cbcEncryptSync<P extends ByteInput, I extends ByteInput>(
	key: AesKey,
	plainTextBytes: P,
	ivBytes: I,
): Result<Buffer, CryptoError> {
	const schedule = liveSchedule(key, "cbcEncrypt");
	const iv = (typeof ivBytes == "string" ? ivBytes.asBytes() : ivBytes);
	if (iv.length != 16) {
		return Result.err(cryptoError(
			CryptoErrorKind.InvalidInput, "cbcEncrypt", "IV must be 16 bytes",
		));
	}
	try {
		return Result.ok(
			outputBuffer(encryptCbc(schedule, iv, (typeof plainTextBytes == "string" ? plainTextBytes.asBytes() : plainTextBytes))),
		);
	} catch (_error) {
		return Result.err(cryptoError(
			CryptoErrorKind.EncryptionFailed,
			"cbcEncrypt", "AES-CBC encryption failed",
		));
	}
}

export function cbcEncrypt<P extends ByteInput, I extends ByteInput>(
	key: AesKey,
	plainTextBytes: P,
	ivBytes: I,
): Promise<Result<Buffer, CryptoError>> {
	return Promise.resolve(cbcEncryptSync(key, plainTextBytes, ivBytes));
}

export function cbcDecryptSync<C extends ByteInput, I extends ByteInput>(
	key: AesKey,
	cipherTextBytes: C,
	ivBytes: I,
): Result<Buffer, CryptoError> {
	const schedule = liveSchedule(key, "cbcDecrypt");
	const iv = (typeof ivBytes == "string" ? ivBytes.asBytes() : ivBytes);
	if (iv.length != 16) {
		return Result.err(cryptoError(
			CryptoErrorKind.InvalidInput, "cbcDecrypt", "IV must be 16 bytes",
		));
	}
	const plain = decryptCbc(schedule, iv, (typeof cipherTextBytes == "string" ? cipherTextBytes.asBytes() : cipherTextBytes));
	if (plain == null) {
		return Result.err(cryptoError(
			CryptoErrorKind.DecryptionFailed,
			"cbcDecrypt", "AES-CBC decryption failed (bad padding or key)",
		));
	}
	return Result.ok(outputBuffer(plain));
}

export function cbcDecrypt<C extends ByteInput, I extends ByteInput>(
	key: AesKey,
	cipherTextBytes: C,
	ivBytes: I,
): Promise<Result<Buffer, CryptoError>> {
	return Promise.resolve(cbcDecryptSync(key, cipherTextBytes, ivBytes));
}
