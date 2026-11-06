/**
 * ECDSA and ECDH on P-256 and P-384 in MetaScript: the surface of `std/crypto/ec` over the
 * fixed-width curve code of ./pcurve, for the native backend. Private until the public index
 * switches to it. Signatures are DER; the nonce is RFC 6979 deterministic.
 */

import { Buffer } from "std/core/buffer";
import { Bytes } from "std/core/buffer/bytes";
import { bytesOf } from "./bytes";
import { PemBlock, pemEncode } from "./pem";
import {
	Curve, ownCurve, EcPublicData, EcPrivateData, ecPublicFromSpki, ecPublicToSpki,
	ecPrivateFromSec1, ecPrivateFromPkcs8, ecPrivateToSec1, ecdsaDerToRaw, ecdsaRawToDer,
	ecdsaSignRaw, ecdsaVerifyRaw, ecdhShared, ecPointValid, ecPublicPoint, ecDrawScalar,
} from "./weierstrass";
import { hashKind, hashOf } from "./hash";
import { kindSha256, kindSha384, kindSha512 } from "./state";
import { wipeBytes } from "./secret";
import { p256 } from "./p256";
import { p384 } from "./p384";
import { CryptoError, CryptoErrorKind, cryptoError } from "../errors";
export { CryptoError, CryptoErrorKind } from "../errors";

export type EcCurve = "p256" | "p384";

function curves(): Curve[] {
	return [ownCurve(p256), ownCurve(p384)];
}

function curveNamed(curve: EcCurve): Curve {
	return ownCurve(curve == "p384" ? p384 : p256);
}

function curveName(curve: Readonly<Curve>): EcCurve {
	return curve.name == "p384" ? "p384" : "p256";
}

function sameBytes(a: Readonly<uint8[]>, b: Readonly<uint8[]>): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i++) {
		if (a[i] != b[i]) return false;
	}
	return true;
}

/**
 * `pemDecode` of ./pem without its whitespace regex, which C codegen does not lower yet
 * (inbox 2026-10-18-regex-literal-on-c-is-an-internal-error); the RSA lane changes ./pem.
 */
function pemBlockOf(text: string): PemBlock | null {
	const begin = text.indexOf("-----BEGIN ");
	if (begin < 0) return null;
	const labelStart = begin + 11;
	const labelEnd = text.indexOf("-----", labelStart);
	if (labelEnd < 0) return null;
	const label = text.slice(labelStart, labelEnd);
	const bodyStart = labelEnd + 5;
	const bodyEnd = text.indexOf(`-----END ${label}-----`, bodyStart);
	if (bodyEnd < 0) return null;
	const body = text
		.slice(bodyStart, bodyEnd)
		.split("\n")
		.map((line) => line.trim())
		.join("");
	if (body.length == 0) return null;
	const der = body.decodeBase64();
	if (der.length == 0) return null;
	return { label, der: der as Buffer };
}

function publicOfPem(pem: string): EcPublicData | null {
	const block = pemBlockOf(pem);
	if (block == null || block.label != "PUBLIC KEY") return null;
	const data = ecPublicFromSpki(block.der, curves(), true);
	if (data == null || !ecPointValid(data.curve, data.point)) return null;
	return data;
}

/** The scalar and its public point; an embedded point that is not d·G is refused. */
function privateOfPem(pem: string): EcPrivateData | null {
	const block = pemBlockOf(pem);
	if (block == null) return null;
	let data: EcPrivateData | null = null;
	if (block.label == "PRIVATE KEY") {
		data = ecPrivateFromPkcs8(block.der, curves());
	} else if (block.label == "EC PRIVATE KEY") {
		data = ecPrivateFromSec1(block.der, curves());
	}
	wipeBytes(block.der);
	if (data == null) return null;
	const point = ecPublicPoint(data.curve, data.d);
	if (point == null || (data.point.length > 0 && !sameBytes(data.point, point))) {
		wipeBytes(data.d);
		return null;
	}
	return { curve: data.curve, d: data.d, point };
}

export class EcPublicKey {
	_data: EcPublicData;

	static importPemSync(pem: string): Result<EcPublicKey, CryptoError> {
		const data = publicOfPem(pem);
		if (data == null) {
			return Result.err(cryptoError(
				CryptoErrorKind.InvalidKey,
				"EcPublicKey.importPem",
				"failed to parse a P-256 or P-384 public key PEM",
			));
		}
		return Result.ok({ _data: data });
	}

	static async importPem(pem: string): Promise<Result<EcPublicKey, CryptoError>> {
		return EcPublicKey.importPemSync(pem);
	}

	get curve(): EcCurve {
		return curveName(this._data.curve);
	}

	exportPemSync(): Result<string, CryptoError> {
		return Result.ok(pemEncode("PUBLIC KEY", ecPublicToSpki(this._data)));
	}

	async exportPem(): Promise<Result<string, CryptoError>> {
		return this.exportPemSync();
	}
}

export class EcPrivateKey {
	_data: EcPrivateData;

	static generateSync(curve: EcCurve): Result<EcPrivateKey, CryptoError> {
		const chosen = curveNamed(curve);
		const d = ecDrawScalar(chosen);
		const point = d == null ? null : ecPublicPoint(chosen, d);
		if (d == null || point == null) {
			return Result.err(cryptoError(
				CryptoErrorKind.KeyGenerationFailed,
				"EcPrivateKey.generate",
				`EC key generation failed for curve ${curve}`,
			));
		}
		return Result.ok({ _data: { curve: chosen, d, point } });
	}

	static async generate(curve: EcCurve): Promise<Result<EcPrivateKey, CryptoError>> {
		return EcPrivateKey.generateSync(curve);
	}

	static importPemSync(pem: string): Result<EcPrivateKey, CryptoError> {
		const data = privateOfPem(pem);
		if (data == null) {
			return Result.err(cryptoError(
				CryptoErrorKind.InvalidKey,
				"EcPrivateKey.importPem",
				"failed to parse a P-256 or P-384 private key PEM",
			));
		}
		return Result.ok({ _data: data });
	}

	static async importPem(pem: string): Promise<Result<EcPrivateKey, CryptoError>> {
		return EcPrivateKey.importPemSync(pem);
	}

	get curve(): EcCurve {
		return curveName(this._data.curve);
	}

	exportPemSync(): Result<string, CryptoError> {
		const der = ecPrivateToSec1(this._data);
		try {
			return Result.ok(pemEncode("EC PRIVATE KEY", der));
		} finally {
			wipeBytes(der);
		}
	}

	async exportPem(): Promise<Result<string, CryptoError>> {
		return this.exportPemSync();
	}

	publicKey(): EcPublicKey {
		return { _data: { curve: this._data.curve, point: this._data.point } };
	}

	onDestroy(): void {
		wipeBytes(this._data.d);
	}
}

/** The hash kind ECDSA accepts by name, or -1; sha1 verifies but never signs. */
function ecdsaHash(hash: string, signing: boolean): int32 {
	const kind = hashKind(hash);
	if (kind == kindSha256 || kind == kindSha384 || kind == kindSha512) return kind;
	if (hash == "sha1" && !signing) return kind;
	return -1;
}

function signFailed(hash: string): CryptoError {
	return cryptoError(
		CryptoErrorKind.SignatureFailed,
		"ec.ecdsaSign",
		`ECDSA signing failed (hash ${hash}; sha1 is refused)`,
	);
}

function agreementFailed(): CryptoError {
	return cryptoError(
		CryptoErrorKind.KeyDerivationFailed,
		"ec.ecdh",
		"ECDH key agreement failed (are the curves the same?)",
	);
}

// hash is sha256, sha384 or sha512; sha1 signatures are refused.
export function ecdsaSignSync(
	key: EcPrivateKey,
	data: Bytes,
	hash: string = "sha256",
): Result<Buffer, CryptoError> {
	const kind = ecdsaHash(hash, true);
	if (kind < 0) return Result.err(signFailed(hash));
	const digest = hashOf(kind, bytesOf(data));
	const raw = ecdsaSignRaw(key._data.curve, kind, key._data.d, digest);
	if (raw == null) return Result.err(signFailed(hash));
	return Result.ok(ecdsaRawToDer(raw) as Buffer);
}

export async function ecdsaSign(
	key: EcPrivateKey,
	data: Bytes,
	hash: string = "sha256",
): Promise<Result<Buffer, CryptoError>> {
	return ecdsaSignSync(key, data, hash);
}

// False on any failure: a bad signature, a malformed input or an unknown hash.
export function ecdsaVerifySync(
	key: EcPublicKey,
	data: Bytes,
	signature: Bytes,
	hash: string = "sha256",
): boolean {
	const kind = ecdsaHash(hash, false);
	if (kind < 0) return false;
	const curve = key._data.curve;
	const raw = ecdsaDerToRaw(bytesOf(signature), curve.size);
	if (raw == null) return false;
	const digest = hashOf(kind, bytesOf(data));
	return ecdsaVerifyRaw(curve, key._data.point, digest, raw);
}

export async function ecdsaVerify(
	key: EcPublicKey,
	data: Bytes,
	signature: Bytes,
	hash: string = "sha256",
): Promise<boolean> {
	return ecdsaVerifySync(key, data, signature, hash);
}

// The two keys must be on the same curve.
export function ecdhSync(
	privateKey: EcPrivateKey,
	publicKey: EcPublicKey,
): Result<Buffer, CryptoError> {
	const curve = privateKey._data.curve;
	if (publicKey._data.curve.name != curve.name) {
		return Result.err(agreementFailed());
	}
	const shared = ecdhShared(curve, privateKey._data.d, publicKey._data.point);
	if (shared == null) return Result.err(agreementFailed());
	return Result.ok(shared as Buffer);
}

export async function ecdh(
	privateKey: EcPrivateKey,
	publicKey: EcPublicKey,
): Promise<Result<Buffer, CryptoError>> {
	return ecdhSync(privateKey, publicKey);
}
