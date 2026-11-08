import { Buffer } from "std/core/buffer";
import { ByteInput } from "std/core/buffer/bytes";
import { CryptoError, CryptoErrorKind, cryptoError } from "../errors";
import { bytesOf, wipeIfCopied } from "./bytes";
import { randomOctets } from "./random";
import { wipeBytes } from "./secret";
import { x25519 } from "./x25519";

export { CryptoError, CryptoErrorKind } from "../errors";

export class X25519PublicKey {
	_raw: uint8[];

	static importSync<D extends ByteInput>(raw: D): Result<X25519PublicKey, CryptoError> {
		const bytes = bytesOf(raw);
		if (bytes.length != 32) {
			return Result.err(cryptoError(
				CryptoErrorKind.InvalidKey, "X25519PublicKey.import",
				"public key must be 32 bytes",
			));
		}
		return Result.ok({ _raw: bytes.slice(0) });
	}

	static import<D extends ByteInput>(raw: D):
		Promise<Result<X25519PublicKey, CryptoError>> {
		return Promise.resolve(X25519PublicKey.importSync(raw));
	}

	exportSync(): Result<Buffer, CryptoError> {
		return Result.ok(Buffer.from(this._raw));
	}

	async export(): Promise<Result<Buffer, CryptoError>> {
		return this.exportSync();
	}

	onDestroy(): void {
		wipeBytes(this._raw);
		this._raw = [];
	}
}

export class X25519PrivateKey {
	_scalar: uint8[];
	_public: uint8[];

	static fromRawSync<D extends ByteInput>(raw: D): Result<X25519PrivateKey, CryptoError> {
		const bytes = bytesOf(raw);
		if (bytes.length != 32) {
			wipeIfCopied(raw, bytes);
			return Result.err(cryptoError(
				CryptoErrorKind.InvalidKey, "X25519PrivateKey.fromRaw",
				"private key must be 32 bytes",
			));
		}
		const base = new Array<uint8>(32);
		base[0] = 9;
		const key: X25519PrivateKey = { _scalar: bytes.slice(0), _public: x25519(bytes, base) };
		wipeIfCopied(raw, bytes);
		return Result.ok(key);
	}

	static fromRaw<D extends ByteInput>(raw: D):
		Promise<Result<X25519PrivateKey, CryptoError>> {
		return Promise.resolve(X25519PrivateKey.fromRawSync(raw));
	}

	static generateSync(): Result<X25519PrivateKey, CryptoError> {
		let raw: uint8[] = [];
		try {
			raw = randomOctets(32);
		} catch (_error) {
			return Result.err(cryptoError(
				CryptoErrorKind.KeyGenerationFailed,
				"X25519PrivateKey.generate", "key generation failed",
			));
		}
		try {
			const key = X25519PrivateKey.fromRawSync(raw);
			if (!key.ok) {
				return Result.err(cryptoError(
					CryptoErrorKind.KeyGenerationFailed,
					"X25519PrivateKey.generate", "key generation failed",
				));
			}
			return key;
		} finally {
			wipeBytes(raw);
		}
	}

	static async generate(): Promise<Result<X25519PrivateKey, CryptoError>> {
		return X25519PrivateKey.generateSync();
	}

	publicKey(): X25519PublicKey {
		if (this._public.length != 32) {
			throw new Error("X25519PrivateKey.publicKey: out of memory");
		}
		return { _raw: this._public.slice(0) };
	}

	onDestroy(): void {
		wipeBytes(this._scalar);
		wipeBytes(this._public);
		this._scalar = [];
		this._public = [];
	}
}

export function sharedSecretSync(
	privateKey: X25519PrivateKey,
	publicKey: X25519PublicKey,
): Result<Buffer, CryptoError> {
	if (privateKey._scalar.length != 32 || publicKey._raw.length != 32) {
		return Result.err(cryptoError(
			CryptoErrorKind.KeyDerivationFailed,
			"x25519.sharedSecret", "key agreement failed",
		));
	}
	const shared = x25519(privateKey._scalar, publicKey._raw);
	let combined: uint32 = 0;
	for (const byte of shared) combined = combined | (byte as uint32);
	if (combined == 0) {
		wipeBytes(shared);
		return Result.err(cryptoError(
			CryptoErrorKind.KeyDerivationFailed,
			"x25519.sharedSecret", "key agreement failed",
		));
	}
	return Result.ok(Buffer.from(shared));
}

export async function sharedSecret(
	privateKey: X25519PrivateKey,
	publicKey: X25519PublicKey,
): Promise<Result<Buffer, CryptoError>> {
	return sharedSecretSync(privateKey, publicKey);
}
