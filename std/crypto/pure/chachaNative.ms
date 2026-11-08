import { Buffer } from "std/core/buffer";
import { ByteInput } from "std/core/buffer/bytes";
import { CryptoError, CryptoErrorKind, cryptoError } from "../errors";
import { bytesOf, wipeIfCopied, outputArray, outputBuffer } from "./bytes";
import { randomOctets, randomInto } from "./random";
import { store32LE } from "./endian";
import { wipeBytes, wipeWords } from "./secret";
import { keyWords, xchachaSealInto, xchachaOpenInto } from "./chacha";

export { CryptoError, CryptoErrorKind } from "../errors";

export class ChaChaKey {
	_words: uint32[];

	static import<R extends ByteInput>(raw: R): Result<ChaChaKey, CryptoError> {
		const words = new Array<uint32>(8);
		const bytes = bytesOf(raw);
		const fits = keyWords(bytes, words);
		wipeIfCopied(raw, bytes);
		if (!fits) {
			return Result.err(cryptoError(
				CryptoErrorKind.InvalidKey,
				"ChaChaKey.import", "key must be 32 bytes",
			));
		}
		return Result.ok({ _words: words });
	}

	static generate(): Result<ChaChaKey, CryptoError> {
		let raw: uint8[] = [];
		try {
			raw = randomOctets(32);
		} catch (_error) {
			return Result.err(cryptoError(
				CryptoErrorKind.RandomFailed,
				"ChaChaKey.generate", "the OS random source failed",
			));
		}
		try {
			return ChaChaKey.import(raw);
		} finally {
			wipeBytes(raw);
		}
	}

	exportRaw(): Buffer {
		const words = liveWords(this, "ChaChaKey.exportRaw");
		const rawBytes = new Buffer(32);
		for (let i: int32 = 0; i < 8; i++) {
			store32LE(rawBytes, i * 4, words[i]);
		}
		return rawBytes;
	}

	onDestroy(): void {
		wipeWords(this._words);
		this._words = [];
	}
}

function liveWords(key: ChaChaKey, operation: string): uint32[] {
	if (key._words.length != 8) {
		throw new Error(`${operation}: the key was already destroyed`);
	}
	return key._words;
}

export function sealSync<P extends ByteInput, A extends ByteInput>(
	key: ChaChaKey,
	plainText: P,
	aad: A = "",
): Result<Buffer, CryptoError> {
	const words = liveWords(key, "seal");
	const plain = (typeof plainText == "string" ? plainText.asBytes() : plainText);
	const sealed = outputArray(plain.length + 40);
	let success = false;
	try {
		randomInto(sealed, 24);
		success = xchachaSealInto(words, (typeof aad == "string" ? aad.asBytes() : aad), plain, sealed);
	} catch (_error) {
		success = false;
	}
	if (!success) {
		return Result.err(cryptoError(
			CryptoErrorKind.EncryptionFailed,
			"seal", "XChaCha20-Poly1305 encryption failed",
		));
	}
	return Result.ok(outputBuffer(sealed));
}

export function seal<P extends ByteInput, A extends ByteInput>(
	key: ChaChaKey,
	plainText: P,
	aad: A = "",
): Promise<Result<Buffer, CryptoError>> {
	return Promise.resolve(sealSync(key, plainText, aad));
}

export function openSync<S extends ByteInput, A extends ByteInput>(
	key: ChaChaKey,
	sealedBytes: S,
	aad: A = "",
): Result<Buffer, CryptoError> {
	const words = liveWords(key, "open");
	const sealed = (typeof sealedBytes == "string" ? sealedBytes.asBytes() : sealedBytes);
	if (sealed.length < 40) {
		return Result.err(cryptoError(
			CryptoErrorKind.InvalidInput,
			"open", "sealed data too short (need nonce+mac)",
		));
	}
	const plain = outputArray(sealed.length - 40);
	if (!xchachaOpenInto(words, (typeof aad == "string" ? aad.asBytes() : aad), sealed, plain)) {
		return Result.err(cryptoError(
			CryptoErrorKind.AuthenticationFailed,
			"open", "authentication tag mismatch",
		));
	}
	return Result.ok(outputBuffer(plain));
}

export function open<S extends ByteInput, A extends ByteInput>(
	key: ChaChaKey,
	sealedBytes: S,
	aad: A = "",
): Promise<Result<Buffer, CryptoError>> {
	return Promise.resolve(openSync(key, sealedBytes, aad));
}
