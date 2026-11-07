import { Buffer } from "std/core/buffer";
import { ByteInput } from "std/core/buffer/bytes";
import { CryptoError, CryptoErrorKind, cryptoError } from "../errors";
import { bytesOf, wipeIfCopied } from "./bytes";
import { randomOctets } from "./random";
import { wipeBytes } from "./secret";
import {
	ed25519PublicFromSeed, ed25519Sign, ed25519Verify,
} from "./ed25519";

export { CryptoError, CryptoErrorKind } from "../errors";

export class Ed25519PublicKey {
	_raw: uint8[];

	static importSync<D extends ByteInput>(raw: D): Result<Ed25519PublicKey, CryptoError> {
		const bytes = bytesOf(raw);
		if (bytes.length != 32) {
			return Result.err(cryptoError(
				CryptoErrorKind.InvalidKey, "Ed25519PublicKey.import",
				"public key must be 32 bytes",
			));
		}
		return Result.ok({ _raw: bytes.slice(0) });
	}

	static import<D extends ByteInput>(raw: D):
		Promise<Result<Ed25519PublicKey, CryptoError>> {
		return Promise.resolve(Ed25519PublicKey.importSync(raw));
	}

	exportSync(): Result<Buffer, CryptoError> {
		return Result.ok(this._raw.slice(0) as Buffer);
	}

	async export(): Promise<Result<Buffer, CryptoError>> {
		return this.exportSync();
	}

	onDestroy(): void {
		wipeBytes(this._raw);
		this._raw = [];
	}
}

export class Ed25519PrivateKey {
	_seed: uint8[];
	_public: uint8[];

	static fromSeedSync<D extends ByteInput>(seed: D):
		Result<Ed25519PrivateKey, CryptoError> {
		const bytes = bytesOf(seed);
		const publicBytes = ed25519PublicFromSeed(bytes);
		const owned = bytes.slice(0);
		wipeIfCopied(seed, bytes);
		if (publicBytes.length != 32) {
			wipeBytes(owned);
			return Result.err(cryptoError(
				CryptoErrorKind.InvalidKey, "Ed25519PrivateKey.fromSeed",
				"seed must be 32 bytes",
			));
		}
		return Result.ok({ _seed: owned, _public: publicBytes });
	}

	static fromSeed<D extends ByteInput>(seed: D):
		Promise<Result<Ed25519PrivateKey, CryptoError>> {
		return Promise.resolve(Ed25519PrivateKey.fromSeedSync(seed));
	}

	static generateSync(): Result<Ed25519PrivateKey, CryptoError> {
		let seed: uint8[] = [];
		try {
			seed = randomOctets(32);
		} catch (_error) {
			return Result.err(cryptoError(
				CryptoErrorKind.KeyGenerationFailed,
				"Ed25519PrivateKey.generate", "key generation failed",
			));
		}
		try {
			const key = Ed25519PrivateKey.fromSeedSync(seed);
			if (!key.ok) {
				return Result.err(cryptoError(
					CryptoErrorKind.KeyGenerationFailed,
					"Ed25519PrivateKey.generate", "key generation failed",
				));
			}
			return key;
		} finally {
			wipeBytes(seed);
		}
	}

	static async generate(): Promise<Result<Ed25519PrivateKey, CryptoError>> {
		return Ed25519PrivateKey.generateSync();
	}

	exportSeedSync(): Result<Buffer, CryptoError> {
		return Result.ok(this._seed.slice(0) as Buffer);
	}

	async exportSeed(): Promise<Result<Buffer, CryptoError>> {
		return this.exportSeedSync();
	}

	publicKey(): Ed25519PublicKey {
		if (this._public.length != 32) {
			throw new Error("Ed25519PrivateKey.publicKey: out of memory");
		}
		return { _raw: this._public.slice(0) };
	}

	onDestroy(): void {
		wipeBytes(this._seed);
		wipeBytes(this._public);
		this._seed = [];
		this._public = [];
	}
}

export function signSync<D extends ByteInput>(
	key: Ed25519PrivateKey,
	message: D,
): Result<Buffer, CryptoError> {
	const signature = ed25519Sign(key._seed, key._public, bytesOf(message));
	if (signature.length != 64) {
		return Result.err(cryptoError(
			CryptoErrorKind.SignatureFailed, "ed25519.sign", "signing failed",
		));
	}
	return Result.ok(signature as Buffer);
}

export function sign<D extends ByteInput>(
	key: Ed25519PrivateKey,
	message: D,
): Promise<Result<Buffer, CryptoError>> {
	return Promise.resolve(signSync(key, message));
}

export function verifySync<D extends ByteInput, K extends ByteInput>(
	key: Ed25519PublicKey,
	signature: D,
	message: K,
): boolean {
	return ed25519Verify(key._raw, bytesOf(signature), bytesOf(message));
}

export function verify<D extends ByteInput, K extends ByteInput>(
	key: Ed25519PublicKey,
	signature: D,
	message: K,
): Promise<boolean> {
	return Promise.resolve(verifySync(key, signature, message));
}
