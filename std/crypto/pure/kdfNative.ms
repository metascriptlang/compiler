import { Buffer } from "std/core/buffer";
import { ByteInput } from "std/core/buffer/bytes";
import {
	HashAlgorithm, createHmac, digestSync, isHashSupported,
} from "./coreNative";
import { wipeBytes } from "./secret";

when (js && nodejs) {
	import { nodeInput, nodePbkdf2, nodeHkdf } from "./nodeCrypto";
}

when (!(js && nodejs)) {
	import { bytesOf, wipeIfCopied } from "./bytes";
	import { hashKind } from "./hash";
	import { pbkdf2Into, hkdfInto } from "./hmac";
}
import {
	CryptoError, invalidInput, keyDerivationFailed,
} from "../errors";

function extendedPassword(
	algorithm: HashAlgorithm,
	password: uint8[],
	salt: uint8[],
	iterations: int32,
	length: int32,
): Buffer {
	const out = new Buffer(length);
	const counter = new Array<uint8>(4);
	let written: int32 = 0;
	let index: int32 = 1;
	while (written < length) {
		counter[0] = ((index >> 24) & 255) as uint8;
		counter[1] = ((index >> 16) & 255) as uint8;
		counter[2] = ((index >> 8) & 255) as uint8;
		counter[3] = (index & 255) as uint8;
		const first = createHmac(algorithm, password);
		first.update(salt);
		first.update(counter);
		let previous = first.digest();
		const count = Math.min(previous.length as int32, length - written);
		for (let i: int32 = 0; i < count; i++) {
			out[written + i] = previous[i];
		}
		for (let round: int32 = 1; round < iterations; round++) {
			const next = createHmac(algorithm, password);
			next.update(previous);
			const digest = next.digest();
			wipeBytes(previous);
			previous = digest;
			for (let i: int32 = 0; i < count; i++) {
				out[written + i] = out[written + i] ^ previous[i];
			}
		}
		wipeBytes(previous);
		written += count;
		index += 1;
	}
	return out;
}

function extendedKey(
	algorithm: HashAlgorithm,
	ikm: uint8[],
	salt: uint8[],
	info: uint8[],
	length: int32,
): Buffer {
	const extract = createHmac(algorithm, salt);
	extract.update(ikm);
	const prk = extract.digest();
	const out = new Buffer(length);
	const counter = new Array<uint8>(1);
	let previous = new Buffer(0);
	let written: int32 = 0;
	let index: int32 = 1;
	while (written < length) {
		const expand = createHmac(algorithm, prk);
		expand.update(previous);
		expand.update(info);
		counter[0] = index as uint8;
		expand.update(counter);
		const digest = expand.digest();
		wipeBytes(previous);
		previous = digest;
		const count = Math.min(previous.length as int32, length - written);
		for (let i: int32 = 0; i < count; i++) {
			out[written + i] = previous[i];
		}
		written += count;
		index += 1;
	}
	wipeBytes(previous);
	wipeBytes(prk);
	return out;
}

/** The error pbkdf2Sync returns before deriving anything, or null when the arguments are valid. */
export function pbkdf2Refusal(iterations: int32, keyLength: int32, digest: HashAlgorithm): CryptoError | null {
	if (iterations < 1) return invalidInput("pbkdf2", "iterations must be at least 1");
	if (keyLength < 1 || keyLength > 1048576) return invalidInput("pbkdf2", "keyLength must be between 1 and 1048576");
	if (!isHashSupported(digest)) return keyDerivationFailed("pbkdf2", "key derivation failed");
	return null;
}

/** The error hkdfSync returns before deriving anything, or null when the arguments are valid. */
export function hkdfRefusal(algorithm: HashAlgorithm, length: int32): CryptoError | null {
	if (length < 1) return invalidInput("hkdf", "length must be at least 1");
	const digest = digestSync(algorithm, "");
	const maxLength = digest.ok ? 255 * (digest.value.length as int32) : 0;
	if (length > maxLength) return invalidInput("hkdf", `length must be at most ${maxLength} for ${algorithm}`);
	return null;
}

export function pbkdf2Sync<D extends ByteInput, K extends ByteInput>(
	password: D,
	salt: K,
	iterations: int32,
	keyLength: int32,
	digest: HashAlgorithm,
): Result<Buffer, CryptoError> {
	const refusal = pbkdf2Refusal(iterations, keyLength, digest);
	if (refusal != null) return Result.err(refusal);
	when (js && nodejs) {
		return Result.ok(nodePbkdf2(nodeInput(password), nodeInput(salt), iterations, keyLength, digest));
	} else {
		const key = bytesOf(password);
		const saltBytes = bytesOf(salt);
		const kind = hashKind(digest);
		try {
			if (kind >= 0) {
				const out = new Buffer(keyLength);
				pbkdf2Into(kind, key, saltBytes, iterations, out);
				return Result.ok(out);
			}
			return Result.ok(extendedPassword(
				digest, key, saltBytes, iterations, keyLength,
			));
		} finally {
			wipeIfCopied(password, key);
		}
	}
}

export function pbkdf2<D extends ByteInput, K extends ByteInput>(
	password: D,
	salt: K,
	iterations: int32,
	keyLength: int32,
	digest: HashAlgorithm,
): Promise<Result<Buffer, CryptoError>> {
	return Promise.resolve(pbkdf2Sync(password, salt, iterations, keyLength, digest));
}

export function hkdfSync<D extends ByteInput, K extends ByteInput, S extends ByteInput>(
	algorithm: HashAlgorithm,
	ikm: D,
	salt: K,
	info: S,
	length: int32,
): Result<Buffer, CryptoError> {
	const refusal = hkdfRefusal(algorithm, length);
	if (refusal != null) return Result.err(refusal);
	when (js && nodejs) {
		return Result.ok(nodeHkdf(algorithm, nodeInput(ikm), nodeInput(salt), nodeInput(info), length));
	} else {
		const key = bytesOf(ikm);
		const saltBytes = bytesOf(salt);
		const infoBytes = bytesOf(info);
		const kind = hashKind(algorithm);
		try {
			if (kind >= 0) {
				const out = new Buffer(length);
				hkdfInto(kind, key, saltBytes, infoBytes, out);
				return Result.ok(out);
			}
			return Result.ok(extendedKey(
				algorithm, key, saltBytes, infoBytes, length,
			));
		} finally {
			wipeIfCopied(ikm, key);
		}
	}
}

export function hkdf<D extends ByteInput, K extends ByteInput, S extends ByteInput>(
	algorithm: HashAlgorithm,
	ikm: D,
	salt: K,
	info: S,
	length: int32,
): Promise<Result<Buffer, CryptoError>> {
	return Promise.resolve(hkdfSync(algorithm, ikm, salt, info, length));
}
