import { Buffer } from "std/core/buffer";
import { Bytes } from "std/core/buffer/bytes";
import { CryptoError, CryptoErrorKind, cryptoError } from "../errors";
import { bytesOf, wipeIfCopied } from "./bytes";
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

	static import(raw: Bytes): Result<AesKey, CryptoError> {
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
		return this._raw.slice(0) as Buffer;
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

export function sealSync(
	key: AesKey,
	plainTextBytes: Bytes,
	aadBytes: Bytes = "",
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
		return Result.ok(gcmSealWithNonce(
			schedule, nonce, bytesOf(plainTextBytes), bytesOf(aadBytes),
		) as Buffer);
	} catch (_error) {
		return Result.err(cryptoError(
			CryptoErrorKind.EncryptionFailed,
			"seal", "AES-GCM encryption failed",
		));
	}
}

export async function seal(
	key: AesKey,
	plainTextBytes: Bytes,
	aadBytes: Bytes = "",
): Promise<Result<Buffer, CryptoError>> {
	return sealSync(key, plainTextBytes, aadBytes);
}

export function openSync(
	key: AesKey,
	sealedBytes: Bytes,
	aadBytes: Bytes = "",
): Result<Buffer, CryptoError> {
	const schedule = liveSchedule(key, "open");
	const sealed = bytesOf(sealedBytes);
	if (sealed.length < 28) {
		return Result.err(cryptoError(
			CryptoErrorKind.InvalidInput, "open", "sealed data too short",
		));
	}
	const plain = gcmOpen(schedule, sealed, bytesOf(aadBytes));
	if (plain == null) {
		return Result.err(cryptoError(
			CryptoErrorKind.AuthenticationFailed,
			"open", "authentication tag mismatch",
		));
	}
	return Result.ok(plain as Buffer);
}

export async function open(
	key: AesKey,
	sealedBytes: Bytes,
	aadBytes: Bytes = "",
): Promise<Result<Buffer, CryptoError>> {
	return openSync(key, sealedBytes, aadBytes);
}

export function cbcEncryptSync(
	key: AesKey,
	plainTextBytes: Bytes,
	ivBytes: Bytes,
): Result<Buffer, CryptoError> {
	const schedule = liveSchedule(key, "cbcEncrypt");
	const iv = bytesOf(ivBytes);
	if (iv.length != 16) {
		return Result.err(cryptoError(
			CryptoErrorKind.InvalidInput, "cbcEncrypt", "IV must be 16 bytes",
		));
	}
	try {
		return Result.ok(
			encryptCbc(schedule, iv, bytesOf(plainTextBytes)) as Buffer,
		);
	} catch (_error) {
		return Result.err(cryptoError(
			CryptoErrorKind.EncryptionFailed,
			"cbcEncrypt", "AES-CBC encryption failed",
		));
	}
}

export async function cbcEncrypt(
	key: AesKey,
	plainTextBytes: Bytes,
	ivBytes: Bytes,
): Promise<Result<Buffer, CryptoError>> {
	return cbcEncryptSync(key, plainTextBytes, ivBytes);
}

export function cbcDecryptSync(
	key: AesKey,
	cipherTextBytes: Bytes,
	ivBytes: Bytes,
): Result<Buffer, CryptoError> {
	const schedule = liveSchedule(key, "cbcDecrypt");
	const iv = bytesOf(ivBytes);
	if (iv.length != 16) {
		return Result.err(cryptoError(
			CryptoErrorKind.InvalidInput, "cbcDecrypt", "IV must be 16 bytes",
		));
	}
	const plain = decryptCbc(schedule, iv, bytesOf(cipherTextBytes));
	if (plain == null) {
		return Result.err(cryptoError(
			CryptoErrorKind.DecryptionFailed,
			"cbcDecrypt", "AES-CBC decryption failed (bad padding or key)",
		));
	}
	return Result.ok(plain as Buffer);
}

export async function cbcDecrypt(
	key: AesKey,
	cipherTextBytes: Bytes,
	ivBytes: Bytes,
): Promise<Result<Buffer, CryptoError>> {
	return cbcDecryptSync(key, cipherTextBytes, ivBytes);
}
