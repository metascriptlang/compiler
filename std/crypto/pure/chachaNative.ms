import { Buffer } from "std/core/buffer";
import { Bytes } from "std/core/buffer/bytes";
import { CryptoError, CryptoErrorKind, cryptoError } from "../errors";
import { bytesOf } from "./bytes";
import { randomOctets, randomInto } from "./random";
import { store32LE } from "./endian";
import { wipeBytes, wipeWords } from "./secret";
import { keyWords, xchachaSealInto, xchachaOpenInto } from "./chacha";

export { CryptoError, CryptoErrorKind } from "../errors";

export class ChaChaKey {
	_words: uint32[];

	static import(raw: Bytes): Result<ChaChaKey, CryptoError> {
		const words = new Array<uint32>(8);
		if (!keyWords(bytesOf(raw), words)) {
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
		const rawBytes = new Array<uint8>(32);
		for (let i: int32 = 0; i < 8; i++) {
			store32LE(rawBytes, i * 4, words[i]);
		}
		return rawBytes as Buffer;
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

export function sealSync(
	key: ChaChaKey,
	plainText: Bytes,
	aad: Bytes = "",
): Result<Buffer, CryptoError> {
	const words = liveWords(key, "seal");
	const plain = bytesOf(plainText);
	const sealed = new Array<uint8>(plain.length + 40);
	let success = false;
	try {
		randomInto(sealed, 24);
		success = xchachaSealInto(words, bytesOf(aad), plain, sealed);
	} catch (_error) {
		success = false;
	}
	if (!success) {
		return Result.err(cryptoError(
			CryptoErrorKind.EncryptionFailed,
			"seal", "XChaCha20-Poly1305 encryption failed",
		));
	}
	return Result.ok(sealed as Buffer);
}

export async function seal(
	key: ChaChaKey,
	plainText: Bytes,
	aad: Bytes = "",
): Promise<Result<Buffer, CryptoError>> {
	return sealSync(key, plainText, aad);
}

export function openSync(
	key: ChaChaKey,
	sealedBytes: Bytes,
	aad: Bytes = "",
): Result<Buffer, CryptoError> {
	const words = liveWords(key, "open");
	const sealed = bytesOf(sealedBytes);
	if (sealed.length < 40) {
		return Result.err(cryptoError(
			CryptoErrorKind.InvalidInput,
			"open", "sealed data too short (need nonce+mac)",
		));
	}
	const plain = new Array<uint8>(sealed.length - 40);
	if (!xchachaOpenInto(words, bytesOf(aad), sealed, plain)) {
		return Result.err(cryptoError(
			CryptoErrorKind.AuthenticationFailed,
			"open", "authentication tag mismatch",
		));
	}
	return Result.ok(plain as Buffer);
}

export async function open(
	key: ChaChaKey,
	sealedBytes: Bytes,
	aad: Bytes = "",
): Promise<Result<Buffer, CryptoError>> {
	return openSync(key, sealedBytes, aad);
}
