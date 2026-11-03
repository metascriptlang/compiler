import { Buffer } from "std/core/buffer";
import { CryptoError } from "std/crypto";
import { outputBytes } from "std/crypto/outputBuffer";
import { ChaChaKey, sealSync as chachaSeal, openSync as chachaOpen } from "std/crypto/chacha20";
import { AesKey, sealSync as aesSeal, openSync as aesOpen } from "std/crypto/aes";

@include("src/test/crypto/aeadOracle.h");
@compile("src/test/crypto/aeadOracle.c");

extern function msTestXChachaSealRef(key: Readonly<Span<uint8>>, nonce: Readonly<Span<uint8>>, plainText: Readonly<Span<uint8>>, aad: Readonly<Span<uint8>>, out: Ptr<uint8>): int64;
extern function msTestXChachaOpenRef(key: Readonly<Span<uint8>>, sealed: Readonly<Span<uint8>>, aad: Readonly<Span<uint8>>, out: Ptr<uint8>): int64;
extern function msTestGcmSealRef(key: Readonly<Span<uint8>>, nonce: Readonly<Span<uint8>>, plainText: Readonly<Span<uint8>>, aad: Readonly<Span<uint8>>, out: Ptr<uint8>): int64;
extern function msTestGcmOpenRef(key: Readonly<Span<uint8>>, sealed: Readonly<Span<uint8>>, aad: Readonly<Span<uint8>>, out: Ptr<uint8>): int64;

const AAD_LENGTHS: int32[] = [0, 1, 15, 16, 17, 33];
const LONG_LENGTHS: int32[] = [2047, 2048, 2049, 4095, 4096, 4097, 8191, 16383, 65535, 65536, 65537, 70001];

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

function filled(count: int32, seed: int32): Buffer {
	const buf = Buffer.alloc(count);
	for (let i = 0; i < count; i++) buf.set(i, (i * 31 + seed * 7 + (i >> 3) * 13 + (i >> 9) * 5) & 255);
	return buf;
}

function sameBytes(a: Buffer, b: Buffer): boolean {
	return Buffer.compare(a, b) == 0;
}

function lengths(): int32[] {
	const out: int32[] = [];
	for (let n = 0; n <= 1200; n++) out.push(n);
	for (const n of LONG_LENGTHS) out.push(n);
	return out;
}

test "xchacha20-poly1305 seal opens under the reference and the reference's seal opens here" {
	const raw = filled(32, 1);
	const key = must(ChaChaKey.import(raw));
	for (const n of lengths()) {
		const text = filled(n, n + 7);
		const aad = filled(AAD_LENGTHS[n % AAD_LENGTHS.length], n + 11);
		const sealed = must(chachaSeal(key, text, aad));
		const opened = Buffer.alloc(n);
		assert msTestXChachaOpenRef(raw, sealed, aad, outputBytes(opened)) == 1;
		assert sameBytes(opened, text);
		const theirs = Buffer.alloc(24 + n + 16);
		assert msTestXChachaSealRef(raw, filled(24, n + 13), text, aad, outputBytes(theirs)) == 1;
		assert sameBytes(must(chachaOpen(key, theirs, aad)), text);
	}
}

test "aes-gcm seal opens under the reference and the reference's seal opens here, for 128- and 256-bit keys" {
	for (const keyLength of [16, 32]) {
		const raw = filled(keyLength, keyLength);
		const key = must(AesKey.import(raw));
		for (const n of lengths()) {
			const text = filled(n, n + 3);
			const aad = filled(AAD_LENGTHS[n % AAD_LENGTHS.length], n + 5);
			const sealed = must(aesSeal(key, text, aad));
			const opened = Buffer.alloc(n);
			assert msTestGcmOpenRef(raw, sealed, aad, outputBytes(opened)) == 1;
			assert sameBytes(opened, text);
			const theirs = Buffer.alloc(12 + n + 16);
			assert msTestGcmSealRef(raw, filled(12, n + 9), text, aad, outputBytes(theirs)) == 1;
			assert sameBytes(must(aesOpen(key, theirs, aad)), text);
		}
	}
}
