import { Buffer } from "std/core/buffer";
import { ByteInput } from "std/core/buffer/bytes";
import {
	HashAlgorithm, createHmac, digestSync, isHashSupported,
} from "./coreNative";
import { bytesOf, wipeIfCopied } from "./bytes";
import { hashKind } from "./hash";
import { pbkdf2Of, hkdfOf } from "./hmac";
import { wipeBytes } from "./secret";
import {
	CryptoError, invalidInput, keyDerivationFailed,
} from "../errors";

function extendedPassword(
	algorithm: HashAlgorithm,
	password: uint8[],
	salt: uint8[],
	iterations: int32,
	length: int32,
): uint8[] {
	const out = new Array<uint8>(length);
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
): uint8[] {
	const extract = createHmac(algorithm, salt);
	extract.update(ikm);
	const prk = extract.digest();
	const out = new Array<uint8>(length);
	const counter = new Array<uint8>(1);
	let previous = new Array<uint8>(0) as Buffer;
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

export function pbkdf2Sync<D extends ByteInput, K extends ByteInput>(
	password: D,
	salt: K,
	iterations: int32,
	keyLength: int32,
	digest: HashAlgorithm,
): Result<Buffer, CryptoError> {
	if (iterations < 1) {
		return Result.err(invalidInput(
			"pbkdf2", "iterations must be at least 1",
		));
	}
	if (keyLength < 1 || keyLength > 1048576) {
		return Result.err(invalidInput(
			"pbkdf2", "keyLength must be between 1 and 1048576",
		));
	}
	if (!isHashSupported(digest)) {
		return Result.err(keyDerivationFailed("pbkdf2", "key derivation failed"));
	}
	const key = bytesOf(password);
	const saltBytes = bytesOf(salt);
	const kind = hashKind(digest);
	try {
		if (kind >= 0) {
			return Result.ok(
				pbkdf2Of(kind, key, saltBytes, iterations, keyLength) as Buffer,
			);
		}
		return Result.ok(extendedPassword(
			digest, key, saltBytes, iterations, keyLength,
		) as Buffer);
	} finally {
		wipeIfCopied(password, key);
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
	if (length < 1) {
		return Result.err(invalidInput("hkdf", "length must be at least 1"));
	}
	const digest = digestSync(algorithm, "");
	const maxLength = digest.ok ? 255 * (digest.value.length as int32) : 0;
	if (length > maxLength) {
		return Result.err(invalidInput(
			"hkdf", `length must be at most ${maxLength} for ${algorithm}`,
		));
	}
	const key = bytesOf(ikm);
	const saltBytes = bytesOf(salt);
	const infoBytes = bytesOf(info);
	const kind = hashKind(algorithm);
	try {
		if (kind >= 0) {
			return Result.ok(
				hkdfOf(kind, key, saltBytes, infoBytes, length) as Buffer,
			);
		}
		return Result.ok(extendedKey(
			algorithm, key, saltBytes, infoBytes, length,
		) as Buffer);
	} finally {
		wipeIfCopied(ikm, key);
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
