import { Buffer } from "std/core/buffer";
import { ByteInput } from "std/core/buffer/bytes";
import { CryptoError, CryptoErrorKind, cryptoError } from "../errors";
import { bytesOf, wipeIfCopied } from "./bytes";
import {
	Blake2bState, newBlake2b, updateBlake2b, finishBlake2b, blake2bOf,
} from "./blake2b";

export { CryptoError, CryptoErrorKind } from "../errors";

function badHashSize(hashSize: int32, operation: string): CryptoError | null {
	if (hashSize < 1 || hashSize > 64) {
		return cryptoError(
			CryptoErrorKind.InvalidInput, operation,
			`hashSize must be 1-64, got ${hashSize}`,
		);
	}
	return null;
}

export function blake2bSync<D extends ByteInput>(
	data: D,
	hashSize: int32 = 32,
): Result<Buffer, CryptoError> {
	const bad = badHashSize(hashSize, "blake2b");
	if (bad != null) return Result.err(bad);
	return Result.ok(blake2bOf(hashSize, [], bytesOf(data)) as Buffer);
}

export function blake2bKeyedSync<D extends ByteInput, K extends ByteInput>(
	keyBytes: D,
	data: K,
	hashSize: int32 = 32,
): Result<Buffer, CryptoError> {
	const key = bytesOf(keyBytes);
	if (key.length < 1 || key.length > 64) {
		wipeIfCopied(keyBytes, key);
		return Result.err(cryptoError(
			CryptoErrorKind.InvalidKey, "blake2bKeyed", "key must be 1-64 bytes",
		));
	}
	const bad = badHashSize(hashSize, "blake2bKeyed");
	if (bad != null) {
		wipeIfCopied(keyBytes, key);
		return Result.err(bad);
	}
	const digest = blake2bOf(hashSize, key, bytesOf(data));
	wipeIfCopied(keyBytes, key);
	return Result.ok(digest as Buffer);
}

export function blake2b<D extends ByteInput>(
	data: D,
	hashSize: int32 = 32,
): Promise<Result<Buffer, CryptoError>> {
	return Promise.resolve(blake2bSync(data, hashSize));
}

export function blake2bKeyed<D extends ByteInput, K extends ByteInput>(
	keyBytes: D,
	data: K,
	hashSize: int32 = 32,
): Promise<Result<Buffer, CryptoError>> {
	return Promise.resolve(blake2bKeyedSync(keyBytes, data, hashSize));
}

export class Blake2b {
	_state: Blake2bState;

	update<D extends ByteInput>(data: D): Blake2b {
		if (this._state.finished) {
			throw new Error("Blake2b.update: the hasher already produced its digest");
		}
		const bytes = bytesOf(data);
		updateBlake2b(this._state, bytes, 0, bytes.length as int32);
		return this;
	}

	digest(): Buffer {
		if (this._state.finished) {
			throw new Error("Blake2b.digest: the hasher already produced its digest");
		}
		return finishBlake2b(this._state) as Buffer;
	}

	onDestroy(): void {
		if (!this._state.finished) finishBlake2b(this._state);
	}
}

export function createBlake2b(
	hashSize: int32 = 32,
): Result<Blake2b, CryptoError> {
	const bad = badHashSize(hashSize, "createBlake2b");
	if (bad != null) return Result.err(bad);
	return Result.ok({ _state: newBlake2b(hashSize, []) });
}
