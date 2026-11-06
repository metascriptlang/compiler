import { Buffer } from "std/core/buffer";
import { Bytes } from "std/core/buffer/bytes";
import { bytesOf } from "./bytes";
import { pemDecode, pemEncode } from "./pem";
import { wipeBytes } from "./secret";
import { rsaWipePrivate } from "./rsaKey";
import {
	RsaPublicData, RsaPrivateData,
	rsaPublicFromPkcs1, rsaPublicFromSpki, rsaPublicToSpki,
	rsaPrivateFromPkcs1, rsaPrivateFromPkcs8, rsaPrivateToPkcs1,
	rsaPublicOf, rsaGenerate, rsaSignPkcs1, rsaSignPss,
	rsaVerifyPkcs1, rsaVerifyPss, rsaOaepEncrypt, rsaOaepDecrypt,
} from "./rsa";
import { CryptoError, CryptoErrorKind, cryptoError } from "../errors";

export { CryptoError, CryptoErrorKind } from "../errors";

export type RsaPadding = "pkcs1v15" | "pss";

function privateOfPem(pem: string): RsaPrivateData | null {
	const block = pemDecode(pem);
	if (block == null) return null;
	try {
		if (block.label == "PRIVATE KEY") {
			return rsaPrivateFromPkcs8(block.der);
		}
		if (block.label == "RSA PRIVATE KEY") {
			return rsaPrivateFromPkcs1(block.der);
		}
		return null;
	} finally {
		wipeBytes(block.der);
	}
}

function publicOfPem(pem: string): RsaPublicData | null {
	const block = pemDecode(pem);
	if (block == null) return null;
	if (block.label == "PUBLIC KEY") return rsaPublicFromSpki(block.der);
	if (block.label == "RSA PUBLIC KEY") return rsaPublicFromPkcs1(block.der);
	return null;
}

function validSignHash(hash: string): boolean {
	return hash == "sha256" || hash == "sha384" || hash == "sha512";
}

export class RsaPublicKey {
	_data: RsaPublicData | null;

	static importPemSync(pem: string): Result<RsaPublicKey, CryptoError> {
		const data = publicOfPem(pem);
		if (data == null) {
			return Result.err(cryptoError(
				CryptoErrorKind.InvalidKey,
				"RsaPublicKey.importPem",
				"failed to parse an RSA public key PEM of at least 2048 bits",
			));
		}
		return Result.ok({ _data: data });
	}

	static async importPem(
		pem: string,
	): Promise<Result<RsaPublicKey, CryptoError>> {
		return RsaPublicKey.importPemSync(pem);
	}

	exportPemSync(): Result<string, CryptoError> {
		const data = this._data;
		if (data == null) {
			return Result.err(cryptoError(
				CryptoErrorKind.InvalidKey,
				"RsaPublicKey.exportPem", "failed to export public key",
			));
		}
		return Result.ok(pemEncode("PUBLIC KEY", rsaPublicToSpki(data)));
	}

	async exportPem(): Promise<Result<string, CryptoError>> {
		return this.exportPemSync();
	}

	onDestroy(): void {
		this._data = null;
	}
}

export class RsaPrivateKey {
	_data: RsaPrivateData | null;

	static generateSync(bits: int32): Result<RsaPrivateKey, CryptoError> {
		if (bits != 2048 && bits != 3072 && bits != 4096) {
			return Result.err(cryptoError(
				CryptoErrorKind.InvalidInput,
				"RsaPrivateKey.generate",
				"bits must be 2048, 3072, or 4096",
			));
		}
		try {
			return Result.ok({ _data: rsaGenerate(bits) });
		} catch (_error) {
			return Result.err(cryptoError(
				CryptoErrorKind.KeyGenerationFailed,
				"RsaPrivateKey.generate", "RSA key generation failed",
			));
		}
	}

	static async generate(
		bits: int32,
	): Promise<Result<RsaPrivateKey, CryptoError>> {
		return RsaPrivateKey.generateSync(bits);
	}

	static importPemSync(pem: string): Result<RsaPrivateKey, CryptoError> {
		const data = privateOfPem(pem);
		if (data == null) {
			return Result.err(cryptoError(
				CryptoErrorKind.InvalidKey,
				"RsaPrivateKey.importPem",
				"failed to parse an RSA private key PEM of at least 2048 bits",
			));
		}
		return Result.ok({ _data: data });
	}

	static async importPem(
		pem: string,
	): Promise<Result<RsaPrivateKey, CryptoError>> {
		return RsaPrivateKey.importPemSync(pem);
	}

	exportPemSync(): Result<string, CryptoError> {
		const data = this._data;
		if (data == null) {
			return Result.err(cryptoError(
				CryptoErrorKind.InvalidKey,
				"RsaPrivateKey.exportPem", "failed to export private key",
			));
		}
		const der = rsaPrivateToPkcs1(data);
		try {
			return Result.ok(pemEncode("RSA PRIVATE KEY", der));
		} finally {
			wipeBytes(der);
		}
	}

	async exportPem(): Promise<Result<string, CryptoError>> {
		return this.exportPemSync();
	}

	publicKey(): RsaPublicKey {
		const data = this._data;
		if (data == null) {
			throw new Error(
				"RsaPrivateKey.publicKey: the public half could not be copied",
			);
		}
		return { _data: rsaPublicOf(data) };
	}

	onDestroy(): void {
		const data = this._data;
		if (data != null) {
			rsaWipePrivate(data);
			this._data = null;
		}
	}
}

export function signSync(
	key: RsaPrivateKey,
	data: Bytes,
	hash: string = "sha256",
	padding: RsaPadding = "pkcs1v15",
): Result<Buffer, CryptoError> {
	const privateKey = key._data;
	let signature: uint8[] | null = null;
	if (privateKey != null && validSignHash(hash)) {
		try {
			const message = bytesOf(data);
			signature = padding == "pss"
				? rsaSignPss(privateKey, hash, message)
				: rsaSignPkcs1(privateKey, hash, message);
		} catch (_error) {
			signature = null;
		}
	}
	if (signature == null) {
		return Result.err(cryptoError(
			CryptoErrorKind.SignatureFailed,
			"rsa.sign",
			`signing failed (hash ${hash}, ${padding}; sha1 is refused)`,
		));
	}
	return Result.ok(signature as Buffer);
}

export async function sign(
	key: RsaPrivateKey,
	data: Bytes,
	hash: string = "sha256",
	padding: RsaPadding = "pkcs1v15",
): Promise<Result<Buffer, CryptoError>> {
	return signSync(key, data, hash, padding);
}

export function verifySync(
	key: RsaPublicKey,
	data: Bytes,
	signature: Bytes,
	hash: string = "sha256",
	padding: RsaPadding = "pkcs1v15",
): boolean {
	const publicKey = key._data;
	if (publicKey == null || (!validSignHash(hash) && hash != "sha1")) {
		return false;
	}
	try {
		const message = bytesOf(data);
		const bytes = bytesOf(signature);
		return padding == "pss"
			? rsaVerifyPss(publicKey, hash, message, bytes)
			: rsaVerifyPkcs1(publicKey, hash, message, bytes);
	} catch (_error) {
		return false;
	}
}

export async function verify(
	key: RsaPublicKey,
	data: Bytes,
	signature: Bytes,
	hash: string = "sha256",
	padding: RsaPadding = "pkcs1v15",
): Promise<boolean> {
	return verifySync(key, data, signature, hash, padding);
}

export function encryptSync(
	key: RsaPublicKey,
	data: Bytes,
): Result<Buffer, CryptoError> {
	const publicKey = key._data;
	let encrypted: uint8[] | null = null;
	if (publicKey != null) {
		try {
			encrypted = rsaOaepEncrypt(publicKey, bytesOf(data));
		} catch (_error) {
			encrypted = null;
		}
	}
	if (encrypted == null) {
		return Result.err(cryptoError(
			CryptoErrorKind.EncryptionFailed,
			"rsa.encrypt", "RSA-OAEP encryption failed",
		));
	}
	return Result.ok(encrypted as Buffer);
}

export async function encrypt(
	key: RsaPublicKey,
	data: Bytes,
): Promise<Result<Buffer, CryptoError>> {
	return encryptSync(key, data);
}

export function decryptSync(
	key: RsaPrivateKey,
	data: Bytes,
): Result<Buffer, CryptoError> {
	const privateKey = key._data;
	let decrypted: uint8[] | null = null;
	if (privateKey != null) {
		try {
			decrypted = rsaOaepDecrypt(privateKey, bytesOf(data));
		} catch (_error) {
			decrypted = null;
		}
	}
	if (decrypted == null) {
		return Result.err(cryptoError(
			CryptoErrorKind.DecryptionFailed,
			"rsa.decrypt", "RSA-OAEP decryption failed",
		));
	}
	return Result.ok(decrypted as Buffer);
}

export async function decrypt(
	key: RsaPrivateKey,
	data: Bytes,
): Promise<Result<Buffer, CryptoError>> {
	return decryptSync(key, data);
}
