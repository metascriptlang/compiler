/**
 * X.509 v3 certificates for TLS: parse DER, split a PEM bundle, verify one certificate against its
 * issuer, a chain against a set of trusted roots, and a host name against the certificate.
 * Ported from Zig's std.crypto.Certificate (MIT, see LICENSE.zig-certificate); the CA and key-usage
 * checks on issuers follow RFC 5280 section 6.1.4.
 */

import {
	DerElement, derElementAt, tagNumber, contentSize, derTagBoolean, derTagInteger,
	derTagBitString, derTagOctetString, derTagObjectIdentifier, derTagSequence,
	derTagUtcTime, derTagGeneralizedTime,
} from "./der";
import { ecdsaDerToRaw, ecdsaVerifyRaw } from "../pure/weierstrass";
import { p256 } from "../pure/p256";
import { p384 } from "../pure/p384";
import { RsaPublicData, rsaModulusOf, rsaVerifyPkcs1 } from "../pure/rsa";
import { ed25519Verify } from "../pure/ed25519";
import { bigFromBytes, bitLength } from "../pure/bigint";
import { hashOf } from "../pure/hash";
import { kindSha1, kindSha224, kindSha256, kindSha384, kindSha512 } from "../pure/state";
import { encodeHex } from "../../core/encoding";

export enum X509Error {
	FieldHasInvalidLength,
	FieldHasWrongDataType,
	UnrecognizedObjectId,
	UnsupportedVersion,
	TimeInvalid,
	InvalidBitString,
	IssuerMismatch,
	NotYetValid,
	Expired,
	SignatureAlgorithmUnsupported,
	SignatureAlgorithmMismatch,
	PublicKeyInvalid,
	SignatureInvalidLength,
	SignatureInvalid,
	SignatureUnsupportedBitCount,
	SignatureNamedCurveUnsupported,
	HostMismatch,
	IssuerNotFound,
	IssuerNotCa,
	MissingEndCertificateMarker,
	InvalidPem,
	EmptyChain,
	/** A critical extension this parser does not enforce, such as nameConstraints (RFC 5280 4.2). */
	UnsupportedCriticalExtension,
	DuplicateExtension,
	/** A CA's basicConstraints pathLenConstraint allows fewer intermediates below it than the chain has. */
	PathLengthExceeded,
	/** The leaf's keyUsage lacks digitalSignature or its extendedKeyUsage lacks serverAuth. */
	KeyUsageMismatch,
}

export enum SignatureAlgorithm {
	Sha1WithRsa,
	Sha224WithRsa,
	Sha256WithRsa,
	Sha384WithRsa,
	Sha512WithRsa,
	EcdsaWithSha224,
	EcdsaWithSha256,
	EcdsaWithSha384,
	EcdsaWithSha512,
	Md2WithRsa,
	Md5WithRsa,
	Ed25519,
}

export enum PublicKeyAlgorithm {
	Rsa,
	RsaPss,
	Ec,
	Ed25519,
}

export enum NamedCurve {
	None,
	P256,
	P384,
	P521,
}

/** RFC 5280 KeyUsage bit numbers, as indexes into `X509Certificate.keyUsage`. */
export const keyUsageDigitalSignature: int32 = 0;
export const keyUsageKeyEncipherment: int32 = 2;
export const keyUsageKeyCertSign: int32 = 5;

export interface X509Certificate {
	der: uint8[];
	version: int32;
	serialNumber: uint8[];
	signatureAlgorithm: SignatureAlgorithm;
	/** The DER content of the issuer and subject Names, compared byte for byte. */
	issuer: uint8[];
	subject: uint8[];
	commonName: string;
	/** Seconds since the Unix epoch. */
	notBefore: int64;
	notAfter: int64;
	publicKeyAlgorithm: PublicKeyAlgorithm;
	namedCurve: NamedCurve;
	/** The subjectPublicKey BIT STRING content: PKCS#1 RSAPublicKey, SEC1 point or raw Ed25519 key. */
	publicKey: uint8[];
	/** The signed bytes: the whole TBSCertificate element. */
	message: uint8[];
	signature: uint8[];
	dnsNames: string[];
	/** iPAddress entries: 4 or 16 bytes each. */
	ipAddresses: uint8[][];
	hasBasicConstraints: boolean;
	isCa: boolean;
	/** -1 when basicConstraints carries no pathLenConstraint. */
	pathLength: int32;
	/** Bit `i` set means KeyUsage bit `i` is asserted; -1 when the extension is absent. */
	keyUsage: int32;
	/** The extendedKeyUsage purposes as OID content hex; empty when the extension is absent. */
	extendedKeyUsage: string[];
}

function element(bytes: Readonly<uint8[]>, index: int32, limit: int32): Result<DerElement, X509Error> {
	const found = derElementAt(bytes, index, limit);
	if (found == null) return Result.err(X509Error.FieldHasInvalidLength);
	return Result.ok(found as DerElement);
}

function expectTag(item: DerElement, tag: int32): Result<DerElement, X509Error> {
	if (item.tagNumber() != tag) return Result.err(X509Error.FieldHasWrongDataType);
	return Result.ok(item);
}

function oidHex(bytes: Readonly<uint8[]>, item: DerElement): Result<string, X509Error> {
	if (item.tagNumber() != derTagObjectIdentifier) return Result.err(X509Error.FieldHasWrongDataType);
	return Result.ok(encodeHex(bytes.slice(item.start, item.end)));
}

function signatureAlgorithmOf(oid: string): Result<SignatureAlgorithm, X509Error> {
	if (oid == "2a864886f70d010105") return Result.ok(SignatureAlgorithm.Sha1WithRsa);
	if (oid == "2a864886f70d01010b") return Result.ok(SignatureAlgorithm.Sha256WithRsa);
	if (oid == "2a864886f70d01010c") return Result.ok(SignatureAlgorithm.Sha384WithRsa);
	if (oid == "2a864886f70d01010d") return Result.ok(SignatureAlgorithm.Sha512WithRsa);
	if (oid == "2a864886f70d01010e") return Result.ok(SignatureAlgorithm.Sha224WithRsa);
	if (oid == "2a8648ce3d040301") return Result.ok(SignatureAlgorithm.EcdsaWithSha224);
	if (oid == "2a8648ce3d040302") return Result.ok(SignatureAlgorithm.EcdsaWithSha256);
	if (oid == "2a8648ce3d040303") return Result.ok(SignatureAlgorithm.EcdsaWithSha384);
	if (oid == "2a8648ce3d040304") return Result.ok(SignatureAlgorithm.EcdsaWithSha512);
	if (oid == "2a864886f70d010102") return Result.ok(SignatureAlgorithm.Md2WithRsa);
	if (oid == "2a864886f70d010104") return Result.ok(SignatureAlgorithm.Md5WithRsa);
	if (oid == "2b6570") return Result.ok(SignatureAlgorithm.Ed25519);
	return Result.err(X509Error.UnrecognizedObjectId);
}

function publicKeyAlgorithmOf(oid: string): Result<PublicKeyAlgorithm, X509Error> {
	if (oid == "2a864886f70d010101") return Result.ok(PublicKeyAlgorithm.Rsa);
	if (oid == "2a864886f70d01010a") return Result.ok(PublicKeyAlgorithm.RsaPss);
	if (oid == "2a8648ce3d0201") return Result.ok(PublicKeyAlgorithm.Ec);
	if (oid == "2b6570") return Result.ok(PublicKeyAlgorithm.Ed25519);
	return Result.err(X509Error.UnrecognizedObjectId);
}

function namedCurveOf(oid: string): Result<NamedCurve, X509Error> {
	if (oid == "2b81040022") return Result.ok(NamedCurve.P384);
	if (oid == "2b81040023") return Result.ok(NamedCurve.P521);
	if (oid == "2a8648ce3d030107") return Result.ok(NamedCurve.P256);
	return Result.err(X509Error.UnrecognizedObjectId);
}

const oidCommonName = "550403";
const oidSubjectAltName = "551d11";
const oidBasicConstraints = "551d13";
const oidKeyUsage = "551d0f";
const oidExtendedKeyUsage = "551d25";
const oidSubjectKeyIdentifier = "551d0e";
const oidAuthorityKeyIdentifier = "551d23";
const oidServerAuth = "2b06010505070301";
const oidAnyExtendedKeyUsage = "551d2500";

function parseVersion(bytes: Readonly<uint8[]>, item: DerElement): Result<int32, X509Error> {
	if (item.identifier != 0xa0) return Result.ok(1);
	if (item.contentSize() != 3) return Result.err(X509Error.FieldHasInvalidLength);
	if (bytes[item.start] != 0x02 || bytes[item.start + 1] != 0x01) return Result.err(X509Error.UnsupportedVersion);
	const encoded = bytes[item.start + 2] as int32;
	if (encoded > 2) return Result.err(X509Error.UnsupportedVersion);
	return Result.ok(encoded + 1);
}

function parseBitString(bytes: Readonly<uint8[]>, item: DerElement): Result<uint8[], X509Error> {
	if (item.tagNumber() != derTagBitString) return Result.err(X509Error.FieldHasWrongDataType);
	if (item.contentSize() < 1 || bytes[item.start] != 0) return Result.err(X509Error.InvalidBitString);
	return Result.ok(bytes.slice(item.start + 1, item.end));
}

export function parseTimeDigits(
	bytes: Readonly<uint8[]>,
	at: int32,
	min: int32,
	max: int32,
): Result<int32, X509Error> {
	const high = (bytes[at] as int32) - 0x30;
	const low = (bytes[at + 1] as int32) - 0x30;
	if (high < 0 || high > 9 || low < 0 || low > 9) return Result.err(X509Error.TimeInvalid);
	const value = high * 10 + low;
	if (value < min || value > max) return Result.err(X509Error.TimeInvalid);
	return Result.ok(value);
}

function isLeapYear(year: int32): boolean {
	return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
}

function daysInMonth(year: int32, month: int32): int32 {
	if (month == 2) return isLeapYear(year) ? 29 : 28;
	if (month == 4 || month == 6 || month == 9 || month == 11) return 30;
	return 31;
}

/** Seconds since the epoch of a UTC civil time; years before 1970 count from 1970, as the reference does. */
export function utcSeconds(
	year: int32,
	month: int32,
	day: int32,
	hour: int32,
	minute: int32,
	second: int32,
): int64 {
	let days: int64 = 0;
	for (let y = 1970; y < year; y++) days += isLeapYear(y) ? 366 : 365;
	for (let m = 1; m < month; m++) days += daysInMonth(year, m) as int64;
	days += (day - 1) as int64;
	return days * 86400 + (hour * 3600 + minute * 60 + second) as int64;
}

/** A UTCTime or GeneralizedTime element as seconds since the epoch. */
export function parseTime(bytes: Readonly<uint8[]>, item: DerElement): Result<int64, X509Error> {
	const at = item.start;
	const length = item.contentSize();
	const tag = item.tagNumber();
	if (tag == derTagUtcTime) {
		if (length != 13 || bytes[at + 12] != 0x5a) return Result.err(X509Error.TimeInvalid);
		const shortYear = try parseTimeDigits(bytes, at, 0, 99);
		const month = try parseTimeDigits(bytes, at + 2, 1, 12);
		const day = try parseTimeDigits(bytes, at + 4, 1, 31);
		const hour = try parseTimeDigits(bytes, at + 6, 0, 23);
		const minute = try parseTimeDigits(bytes, at + 8, 0, 59);
		const second = try parseTimeDigits(bytes, at + 10, 0, 59);
		const year = shortYear < 50 ? 2000 + shortYear : 1900 + shortYear;
		return Result.ok(utcSeconds(year, month, day, hour, minute, second));
	}
	if (tag == derTagGeneralizedTime) {
		if (length < 15) return Result.err(X509Error.TimeInvalid);
		const century = try parseTimeDigits(bytes, at, 0, 99);
		const yearInCentury = try parseTimeDigits(bytes, at + 2, 0, 99);
		const month = try parseTimeDigits(bytes, at + 4, 1, 12);
		const day = try parseTimeDigits(bytes, at + 6, 1, 31);
		const hour = try parseTimeDigits(bytes, at + 8, 0, 23);
		const minute = try parseTimeDigits(bytes, at + 10, 0, 59);
		const second = try parseTimeDigits(bytes, at + 12, 0, 59);
		return Result.ok(utcSeconds(century * 100 + yearInCentury, month, day, hour, minute, second));
	}
	return Result.err(X509Error.FieldHasWrongDataType);
}

function commonNameOf(bytes: Readonly<uint8[]>, name: DerElement): Result<string, X509Error> {
	let commonName = "";
	let nameAt = name.start;
	while (nameAt < name.end) {
		const rdn = try element(bytes, nameAt, name.end);
		let rdnAt = rdn.start;
		while (rdnAt < rdn.end) {
			const atav = try element(bytes, rdnAt, rdn.end);
			let atavAt = atav.start;
			while (atavAt < atav.end) {
				const type = try element(bytes, atavAt, atav.end);
				const value = try element(bytes, type.end, atav.end);
				atavAt = value.end;
				const oid = try oidHex(bytes, type);
				if (oid == oidCommonName) commonName = bytes.slice(value.start, value.end).asString();
			}
			rdnAt = atav.end;
		}
		nameAt = rdn.end;
	}
	return Result.ok(commonName);
}

struct Extensions {
	dnsNames: string[];
	ipAddresses: uint8[][];
	hasBasicConstraints: boolean;
	isCa: boolean;
	pathLength: int32;
	keyUsage: int32;
	extendedKeyUsage: string[];
}

function readSubjectAltName(bytes: Readonly<uint8[]>, value: DerElement, ref found: Extensions): Result<void, X509Error> {
	const names = try expectTag(try element(bytes, value.start, value.end), derTagSequence);
	let at = names.start;
	while (at < names.end) {
		const name = try element(bytes, at, names.end);
		at = name.end;
		const kind = name.tagNumber();
		if (kind == 2) found.dnsNames.push(bytes.slice(name.start, name.end).asString());
		else if (kind == 7) found.ipAddresses.push(bytes.slice(name.start, name.end));
	}
	return Result.ok(null);
}

function readBasicConstraints(bytes: Readonly<uint8[]>, value: DerElement, ref found: Extensions): Result<void, X509Error> {
	const sequence = try expectTag(try element(bytes, value.start, value.end), derTagSequence);
	found.hasBasicConstraints = true;
	let at = sequence.start;
	if (at < sequence.end) {
		const first = try element(bytes, at, sequence.end);
		if (first.tagNumber() == derTagBoolean) {
			if (first.contentSize() != 1) return Result.err(X509Error.FieldHasInvalidLength);
			if (bytes[first.start] != 0x00 && bytes[first.start] != 0xff) {
				return Result.err(X509Error.FieldHasWrongDataType);
			}
			found.isCa = bytes[first.start] == 0xff;
			at = first.end;
		}
	}
	if (at < sequence.end) {
		const length = try expectTag(try element(bytes, at, sequence.end), derTagInteger);
		if (length.contentSize() < 1 || length.contentSize() > 3 || (bytes[length.start] & 0x80) != 0) {
			return Result.err(X509Error.FieldHasInvalidLength);
		}
		let pathLength = 0;
		for (let i = length.start; i < length.end; i++) pathLength = pathLength * 256 + (bytes[i] as int32);
		found.pathLength = pathLength;
	}
	return Result.ok(null);
}

function readKeyUsage(bytes: Readonly<uint8[]>, value: DerElement, ref found: Extensions): Result<void, X509Error> {
	const bits = try expectTag(try element(bytes, value.start, value.end), derTagBitString);
	if (bits.contentSize() < 1 || bits.contentSize() > 3) return Result.err(X509Error.InvalidBitString);
	let usage = 0;
	for (let i = bits.start + 1; i < bits.end; i++) {
		const octet = bytes[i] as int32;
		const base = (i - bits.start - 1) * 8;
		for (let bit = 0; bit < 8; bit++) {
			if ((octet & (0x80 >> bit)) != 0) usage |= 1 << (base + bit);
		}
	}
	found.keyUsage = usage;
	return Result.ok(null);
}

function readExtendedKeyUsage(bytes: Readonly<uint8[]>, value: DerElement, ref found: Extensions): Result<void, X509Error> {
	const purposes = try expectTag(try element(bytes, value.start, value.end), derTagSequence);
	let at = purposes.start;
	while (at < purposes.end) {
		const purpose = try element(bytes, at, purposes.end);
		found.extendedKeyUsage.push(try oidHex(bytes, purpose));
		at = purpose.end;
	}
	if (found.extendedKeyUsage.length == 0) return Result.err(X509Error.FieldHasInvalidLength);
	return Result.ok(null);
}

/** The extensions this parser reads or may skip even when critical, as their identifiers carry no constraint to enforce. */
const understoodExtensions: Readonly<string[]> = [
	oidSubjectAltName, oidBasicConstraints, oidKeyUsage, oidExtendedKeyUsage, oidSubjectKeyIdentifier, oidAuthorityKeyIdentifier,
];

/** RFC 5280 4.2: each extension at most once, and an unknown one marked critical refuses the certificate. */
function readExtensions(bytes: Readonly<uint8[]>, wrapper: DerElement, ref found: Extensions): Result<void, X509Error> {
	const extensions = try expectTag(try element(bytes, wrapper.start, wrapper.end), derTagSequence);
	const seen: string[] = [];
	let at = extensions.start;
	while (at < extensions.end) {
		const extension = try element(bytes, at, extensions.end);
		at = extension.end;
		const oidElement = try element(bytes, extension.start, extension.end);
		const oid = try oidHex(bytes, oidElement);
		if (seen.includes(oid)) return Result.err(X509Error.DuplicateExtension);
		seen.push(oid);
		const next = try element(bytes, oidElement.end, extension.end);
		let critical = false;
		let value = next;
		if (next.tagNumber() == derTagBoolean) {
			if (next.contentSize() != 1) return Result.err(X509Error.FieldHasInvalidLength);
			if (bytes[next.start] != 0x00 && bytes[next.start] != 0xff) {
				return Result.err(X509Error.FieldHasWrongDataType);
			}
			critical = bytes[next.start] == 0xff;
			value = try element(bytes, next.end, extension.end);
		}
		if (value.tagNumber() != derTagOctetString) return Result.err(X509Error.FieldHasWrongDataType);
		if (value.end != extension.end) return Result.err(X509Error.FieldHasInvalidLength);
		if (critical && !understoodExtensions.includes(oid)) return Result.err(X509Error.UnsupportedCriticalExtension);
		if (oid == oidSubjectAltName) try readSubjectAltName(bytes, value, found);
		else if (oid == oidBasicConstraints) try readBasicConstraints(bytes, value, found);
		else if (oid == oidKeyUsage) try readKeyUsage(bytes, value, found);
		else if (oid == oidExtendedKeyUsage) try readExtendedKeyUsage(bytes, value, found);
	}
	return Result.ok(null);
}

/** Parse one DER certificate that fills `der` exactly. */
export function parseCertificate(der: Readonly<uint8[]>): Result<X509Certificate, X509Error> {
	const limit = der.length as int32;
	const certificate = try expectTag(try element(der, 0, limit), derTagSequence);
	if (certificate.end != limit) return Result.err(X509Error.FieldHasInvalidLength);
	const tbs = try expectTag(try element(der, certificate.start, certificate.end), derTagSequence);
	const versionElement = try element(der, tbs.start, tbs.end);
	const version = try parseVersion(der, versionElement);
	const serial = versionElement.identifier == 0xa0
		? try element(der, versionElement.end, tbs.end)
		: versionElement;
	if (serial.tagNumber() != derTagInteger) return Result.err(X509Error.FieldHasWrongDataType);
	const tbsSignature = try element(der, serial.end, tbs.end);
	const issuer = try expectTag(try element(der, tbsSignature.end, tbs.end), derTagSequence);
	const validity = try expectTag(try element(der, issuer.end, tbs.end), derTagSequence);
	const notBeforeElement = try element(der, validity.start, validity.end);
	const notBefore = try parseTime(der, notBeforeElement);
	const notAfterElement = try element(der, notBeforeElement.end, validity.end);
	const notAfter = try parseTime(der, notAfterElement);
	const subject = try expectTag(try element(der, validity.end, tbs.end), derTagSequence);

	const publicKeyInfo = try expectTag(try element(der, subject.end, tbs.end), derTagSequence);
	const publicKeyAlgorithmElement = try expectTag(
		try element(der, publicKeyInfo.start, publicKeyInfo.end),
		derTagSequence,
	);
	const algorithmOid = try element(der, publicKeyAlgorithmElement.start, publicKeyAlgorithmElement.end);
	const publicKeyAlgorithm = try publicKeyAlgorithmOf(try oidHex(der, algorithmOid));
	let namedCurve = NamedCurve.None;
	if (publicKeyAlgorithm == PublicKeyAlgorithm.Ec) {
		const parameters = try element(der, algorithmOid.end, publicKeyAlgorithmElement.end);
		namedCurve = try namedCurveOf(try oidHex(der, parameters));
	}
	const publicKeyElement = try element(der, publicKeyAlgorithmElement.end, publicKeyInfo.end);
	const publicKey = try parseBitString(der, publicKeyElement);

	const commonName = try commonNameOf(der, subject);

	const signatureAlgorithmElement = try expectTag(try element(der, tbs.end, certificate.end), derTagSequence);
	const signatureOid = try element(der, signatureAlgorithmElement.start, signatureAlgorithmElement.end);
	const signatureAlgorithm = try signatureAlgorithmOf(try oidHex(der, signatureOid));
	const signatureElement = try element(der, signatureAlgorithmElement.end, certificate.end);
	const signature = try parseBitString(der, signatureElement);
	if (signatureElement.end != certificate.end) return Result.err(X509Error.FieldHasInvalidLength);

	let extensions: Extensions = {
		dnsNames: [],
		ipAddresses: [],
		hasBasicConstraints: false,
		isCa: false,
		pathLength: -1,
		keyUsage: -1,
		extendedKeyUsage: [],
	};
	if (version == 3) {
		let at = publicKeyInfo.end;
		while (at < tbs.end) {
			const optional = try element(der, at, tbs.end);
			at = optional.end;
			if (optional.identifier == 0xa3) try readExtensions(der, optional, extensions);
		}
	}

	return Result.ok({
		der: der.slice(0, limit),
		version,
		serialNumber: der.slice(serial.start, serial.end),
		signatureAlgorithm,
		issuer: der.slice(issuer.start, issuer.end),
		subject: der.slice(subject.start, subject.end),
		commonName,
		notBefore,
		notAfter,
		publicKeyAlgorithm,
		namedCurve,
		publicKey,
		message: der.slice(certificate.start, tbs.end),
		signature,
		dnsNames: extensions.dnsNames,
		ipAddresses: extensions.ipAddresses,
		hasBasicConstraints: extensions.hasBasicConstraints,
		isCa: extensions.isCa,
		pathLength: extensions.pathLength,
		keyUsage: extensions.keyUsage,
		extendedKeyUsage: extensions.extendedKeyUsage,
	});
}

function sameBytes(a: Readonly<uint8[]>, b: Readonly<uint8[]>): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i++) {
		if (a[i] != b[i]) return false;
	}
	return true;
}

function rsaHashName(algorithm: SignatureAlgorithm): string {
	return match (algorithm) {
		SignatureAlgorithm.Sha1WithRsa => "sha1",
		SignatureAlgorithm.Sha256WithRsa => "sha256",
		SignatureAlgorithm.Sha384WithRsa => "sha384",
		SignatureAlgorithm.Sha512WithRsa => "sha512",
		_ => "",
	};
}

function ecdsaHashKind(algorithm: SignatureAlgorithm): int32 {
	return match (algorithm) {
		SignatureAlgorithm.EcdsaWithSha224 => kindSha224,
		SignatureAlgorithm.EcdsaWithSha256 => kindSha256,
		SignatureAlgorithm.EcdsaWithSha384 => kindSha384,
		SignatureAlgorithm.EcdsaWithSha512 => kindSha512,
		_ => kindSha1,
	};
}

function verifyRsa(
	hashName: string,
	message: Readonly<uint8[]>,
	signature: Readonly<uint8[]>,
	issuer: Readonly<X509Certificate>,
): Result<void, X509Error> {
	if (issuer.publicKeyAlgorithm != PublicKeyAlgorithm.Rsa) return Result.err(X509Error.SignatureAlgorithmMismatch);
	const key = issuer.publicKey;
	const sequence = try expectTag(try element(key, 0, key.length as int32), derTagSequence);
	const modulusElement = try expectTag(try element(key, sequence.start, sequence.end), derTagInteger);
	const exponentElement = try expectTag(try element(key, modulusElement.end, sequence.end), derTagInteger);
	let modulusStart = modulusElement.start;
	while (modulusStart < modulusElement.end && key[modulusStart] == 0) modulusStart += 1;
	const modulusLength = modulusElement.end - modulusStart;
	const exponentLength = exponentElement.contentSize();
	if (exponentLength > modulusLength) return Result.err(X509Error.PublicKeyInvalid);
	if (signature.length != modulusLength) return Result.err(X509Error.SignatureInvalidLength);
	if (modulusLength != 128 && modulusLength != 256 && modulusLength != 384 && modulusLength != 512) {
		return Result.err(X509Error.SignatureUnsupportedBitCount);
	}
	const modulus = key.slice(modulusStart, modulusElement.end);
	const n = bigFromBytes(modulus);
	if (bitLength(n) < 512) return Result.err(X509Error.SignatureInvalid);
	if (exponentLength > 4) return Result.err(X509Error.SignatureInvalid);
	let exponentStart = exponentElement.start;
	while (exponentStart + 1 < exponentElement.end && key[exponentStart] == 0) exponentStart += 1;
	const exponent = key.slice(exponentStart, exponentElement.end);
	const e = bigFromBytes(exponent);
	if (e % 2n == 0n || e < 2n || e >= n) return Result.err(X509Error.SignatureInvalid);
	const publicKey: RsaPublicData = { n: modulus, e: exponent, nModulus: rsaModulusOf(modulus) };
	if (!rsaVerifyPkcs1(publicKey, hashName, message, signature)) return Result.err(X509Error.SignatureInvalid);
	return Result.ok(null);
}

function verifyEcdsa(
	kind: int32,
	message: Readonly<uint8[]>,
	signature: Readonly<uint8[]>,
	issuer: Readonly<X509Certificate>,
): Result<void, X509Error> {
	if (issuer.publicKeyAlgorithm != PublicKeyAlgorithm.Ec) return Result.err(X509Error.SignatureAlgorithmMismatch);
	const digest = hashOf(kind, message);
	if (issuer.namedCurve == NamedCurve.P256) {
		const raw = ecdsaDerToRaw(signature, p256.size);
		if (raw == null || !ecdsaVerifyRaw(p256, issuer.publicKey, digest, raw as uint8[])) {
			return Result.err(X509Error.SignatureInvalid);
		}
		return Result.ok(null);
	}
	if (issuer.namedCurve == NamedCurve.P384) {
		const raw = ecdsaDerToRaw(signature, p384.size);
		if (raw == null || !ecdsaVerifyRaw(p384, issuer.publicKey, digest, raw as uint8[])) {
			return Result.err(X509Error.SignatureInvalid);
		}
		return Result.ok(null);
	}
	return Result.err(X509Error.SignatureNamedCurveUnsupported);
}

function verifyEd25519(
	message: Readonly<uint8[]>,
	signature: Readonly<uint8[]>,
	issuer: Readonly<X509Certificate>,
): Result<void, X509Error> {
	if (issuer.publicKeyAlgorithm != PublicKeyAlgorithm.Ed25519) return Result.err(X509Error.SignatureAlgorithmMismatch);
	if (signature.length != 64 || issuer.publicKey.length != 32) return Result.err(X509Error.SignatureInvalid);
	if (!ed25519Verify(issuer.publicKey, signature, message)) return Result.err(X509Error.SignatureInvalid);
	return Result.ok(null);
}

/** The portable RSA code carries no SHA-224 DigestInfo and no MD2/MD5, so these signatures are refused. */
function unsupportedSignatureAlgorithm(): Result<void, X509Error> {
	return Result.err(X509Error.SignatureAlgorithmUnsupported);
}

/** Check that `issuer` names, dates and signed `subject` at `nowSeconds`; it does not check that `issuer` is a CA. */
export function verifyCertificate(
	subject: Readonly<X509Certificate>,
	issuer: Readonly<X509Certificate>,
	nowSeconds: int64,
): Result<void, X509Error> {
	if (!sameBytes(subject.issuer, issuer.subject)) return Result.err(X509Error.IssuerMismatch);
	if (nowSeconds < subject.notBefore) return Result.err(X509Error.NotYetValid);
	if (nowSeconds > subject.notAfter) return Result.err(X509Error.Expired);
	const algorithm = subject.signatureAlgorithm;
	return match (algorithm) {
		SignatureAlgorithm.Sha1WithRsa | SignatureAlgorithm.Sha256WithRsa | SignatureAlgorithm.Sha384WithRsa |
			SignatureAlgorithm.Sha512WithRsa => verifyRsa(rsaHashName(algorithm), subject.message, subject.signature, issuer),
		SignatureAlgorithm.EcdsaWithSha224 | SignatureAlgorithm.EcdsaWithSha256 | SignatureAlgorithm.EcdsaWithSha384 |
			SignatureAlgorithm.EcdsaWithSha512 => verifyEcdsa(ecdsaHashKind(algorithm), subject.message, subject.signature, issuer),
		SignatureAlgorithm.Ed25519 => verifyEd25519(subject.message, subject.signature, issuer),
		SignatureAlgorithm.Sha224WithRsa | SignatureAlgorithm.Md2WithRsa | SignatureAlgorithm.Md5WithRsa =>
			unsupportedSignatureAlgorithm(),
	};
}

function mayIssue(issuer: Readonly<X509Certificate>): boolean {
	if (!issuer.hasBasicConstraints || !issuer.isCa) return false;
	return issuer.keyUsage < 0 || (issuer.keyUsage & (1 << keyUsageKeyCertSign)) != 0;
}

/** `verifyCertificate`, and the issuer must be a CA allowed to sign certificates. */
export function verifyIssuedBy(
	subject: Readonly<X509Certificate>,
	issuer: Readonly<X509Certificate>,
	nowSeconds: int64,
): Result<void, X509Error> {
	try verifyCertificate(subject, issuer, nowSeconds);
	if (!mayIssue(issuer)) return Result.err(X509Error.IssuerNotCa);
	return Result.ok(null);
}

function equalIgnoreCase(a: string, b: string): boolean {
	return a.length == b.length && a.toLowerCase() == b.toLowerCase();
}

/** RFC 6125 section 6.4: exact match ignoring ASCII case, or a `*.` wildcard standing for one whole leftmost label. */
export function hostNameMatches(hostName: string, dnsName: string): boolean {
	if (hostName.length == 0 || dnsName.length == 0) return false;
	if (equalIgnoreCase(dnsName, hostName)) return true;
	if (dnsName.length >= 3 && dnsName.startsWith("*.")) {
		const wildcardSuffix = dnsName.slice(2, dnsName.length);
		if (wildcardSuffix.indexOf("*") >= 0) return false;
		const dot = hostName.indexOf(".");
		if (dot <= 0) return false;
		return equalIgnoreCase(wildcardSuffix, hostName.slice(dot + 1, hostName.length));
	}
	return false;
}

function digitOf(code: int32): int32 {
	return code >= 0x30 && code <= 0x39 ? code - 0x30 : -1;
}

function hexDigitOf(code: int32): int32 {
	if (code >= 0x30 && code <= 0x39) return code - 0x30;
	if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10;
	if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10;
	return -1;
}

/** Dotted-quad IPv4 text as four bytes; leading zeros and out-of-range octets are refused. */
export function parseIp4(text: string): uint8[] | null {
	const out: uint8[] = [0, 0, 0, 0];
	let index = 0;
	let value = 0;
	let digits = 0;
	let zeroPrefix = false;
	for (let i = 0; i < text.length; i++) {
		const code = text.charCodeAt(i) as int32;
		if (code == 0x2e) {
			if (digits == 0 || index == 3) return null;
			out[index] = value as uint8;
			index += 1;
			value = 0;
			digits = 0;
			zeroPrefix = false;
			continue;
		}
		const digit = digitOf(code);
		if (digit < 0) return null;
		if (digit == 0 && digits == 0) zeroPrefix = true;
		else if (zeroPrefix) return null;
		value = value * 10 + digit;
		if (value > 255) return null;
		digits += 1;
	}
	if (index != 3 || digits == 0) return null;
	out[3] = value as uint8;
	return out;
}

/** RFC 4291 section 2.2 IPv6 text, `::` compression and a trailing dotted quad included, as sixteen bytes. */
export function parseIp6(text: string): uint8[] | null {
	const length = text.length as int32;
	if (length < 2) return null;
	const groups: int32[] = [];
	let compressAt = -1;
	let at = 0;
	if (text.startsWith("::")) {
		compressAt = 0;
		at = 2;
	} else if (text.startsWith(":")) {
		return null;
	}
	while (at < length) {
		let end = text.indexOf(":", at) as int32;
		if (end < 0) end = length;
		const piece = text.slice(at, end);
		if (piece.indexOf(".") >= 0) {
			if (end != length) return null;
			const quad = parseIp4(piece);
			if (quad == null) return null;
			const bytes = quad as uint8[];
			groups.push(((bytes[0] as int32) << 8) | (bytes[1] as int32));
			groups.push(((bytes[2] as int32) << 8) | (bytes[3] as int32));
			break;
		}
		if (piece.length == 0 || piece.length > 4) return null;
		let value = 0;
		for (let i = 0; i < piece.length; i++) {
			const digit = hexDigitOf(piece.charCodeAt(i) as int32);
			if (digit < 0) return null;
			value = value * 16 + digit;
		}
		groups.push(value);
		if (end == length) break;
		if (end + 1 < length && text.charCodeAt(end + 1) == 0x3a) {
			if (compressAt >= 0) return null;
			compressAt = groups.length as int32;
			at = end + 2;
		} else {
			at = end + 1;
			if (at == length) return null;
		}
	}
	if (groups.length > 8) return null;
	if (compressAt < 0 && groups.length != 8) return null;
	if (compressAt >= 0 && groups.length > 7) return null;
	const full: int32[] = [];
	for (let i = 0; i < 8; i++) full.push(0);
	const tail = groups.length as int32 - (compressAt < 0 ? groups.length as int32 : compressAt);
	const head = groups.length as int32 - tail;
	for (let i = 0; i < head; i++) full[i] = groups[i];
	for (let i = 0; i < tail; i++) full[8 - tail + i] = groups[head + i];
	const out: uint8[] = [];
	for (const group of full) {
		out.push((group >> 8) as uint8);
		out.push((group & 0xff) as uint8);
	}
	return out;
}

/** RFC 5280 section 4.2.1.6: the host text parses to exactly the SAN's 4 or 16 octets. */
export function ipAddressMatches(hostName: string, address: Readonly<uint8[]>): boolean {
	if (address.length == 4) {
		const parsed = parseIp4(hostName);
		return parsed != null && sameBytes(parsed as uint8[], address);
	}
	if (address.length == 16) {
		const parsed = parseIp6(hostName);
		return parsed != null && sameBytes(parsed as uint8[], address);
	}
	return false;
}

/** With subjectAltName entries, any dNSName or iPAddress entry may match; without them, only the common name. */
export function verifyHostName(certificate: Readonly<X509Certificate>, hostName: string): Result<void, X509Error> {
	if (certificate.dnsNames.length == 0 && certificate.ipAddresses.length == 0) {
		if (hostNameMatches(hostName, certificate.commonName)) return Result.ok(null);
		return Result.err(X509Error.HostMismatch);
	}
	for (const dnsName of certificate.dnsNames) {
		if (hostNameMatches(hostName, dnsName)) return Result.ok(null);
	}
	for (const address of certificate.ipAddresses) {
		if (ipAddressMatches(hostName, address)) return Result.ok(null);
	}
	return Result.err(X509Error.HostMismatch);
}

function stripWhitespace(text: string): string {
	let out = "";
	for (let i = 0; i < text.length; i++) {
		const code = text.charCodeAt(i) as int32;
		if (code != 0x20 && code != 0x09 && code != 0x0d && code != 0x0a) out += text.slice(i, i + 1);
	}
	return out;
}

/** The DER of every `CERTIFICATE` block in `text`, in order. */
export function pemCertificates(text: string): Result<uint8[][], X509Error> {
	const beginMarker = "-----BEGIN CERTIFICATE-----";
	const endMarker = "-----END CERTIFICATE-----";
	const out: uint8[][] = [];
	let from = 0;
	while (true) {
		const begin = text.indexOf(beginMarker, from) as int32;
		if (begin < 0) break;
		const bodyStart = begin + (beginMarker.length as int32);
		const bodyEnd = text.indexOf(endMarker, bodyStart) as int32;
		if (bodyEnd < 0) return Result.err(X509Error.MissingEndCertificateMarker);
		from = bodyEnd + (endMarker.length as int32);
		const der = stripWhitespace(text.slice(bodyStart, bodyEnd)).decodeBase64();
		if (der.length == 0) return Result.err(X509Error.InvalidPem);
		out.push(der);
	}
	return Result.ok(out);
}

/** Trusted roots, looked up by subject Name. */
export class X509Bundle {
	certificates: X509Certificate[] = [];

	/**
	 * Add a certificate unless one with the same subject is present or it expired before `nowSeconds`;
	 * a certificate with an unrecognized algorithm is skipped, any other parse failure is returned.
	 */
	addDer(der: Readonly<uint8[]>, nowSeconds: int64): Result<void, X509Error> {
		const parsed = parseCertificate(der);
		if (!parsed.ok) {
			if (parsed.error == X509Error.UnrecognizedObjectId) return Result.ok(null);
			return Result.err(parsed.error);
		}
		const certificate = parsed.value;
		if (nowSeconds > certificate.notAfter) return Result.ok(null);
		if (this.find(certificate.subject) != null) return Result.ok(null);
		this.certificates.push(certificate);
		return Result.ok(null);
	}

	addPem(text: string, nowSeconds: int64): Result<void, X509Error> {
		const ders = try pemCertificates(text);
		for (const der of ders) try this.addDer(der, nowSeconds);
		return Result.ok(null);
	}

	find(subjectName: Readonly<uint8[]>): X509Certificate | null {
		for (const certificate of this.certificates) {
			if (sameBytes(certificate.subject, subjectName)) return certificate;
		}
		return null;
	}

	/** Verify `subject` against the root that issued it, unexpired at `nowSeconds`; `IssuerNotFound` when no root has its issuer name. */
	verify(subject: Readonly<X509Certificate>, nowSeconds: int64): Result<void, X509Error> {
		const root = this.find(subject.issuer);
		if (root == null) return Result.err(X509Error.IssuerNotFound);
		if (nowSeconds > root.notAfter) return Result.err(X509Error.Expired);
		return verifyIssuedBy(subject, root as X509Certificate, nowSeconds);
	}
}

/** A TLS server's leaf: keyUsage, when present, allows digitalSignature, and extendedKeyUsage, when present, allows serverAuth. */
function verifyServerUsage(leaf: Readonly<X509Certificate>): Result<void, X509Error> {
	if (leaf.keyUsage >= 0 && (leaf.keyUsage & (1 << keyUsageDigitalSignature)) == 0) return Result.err(X509Error.KeyUsageMismatch);
	const purposes = leaf.extendedKeyUsage;
	if (purposes.length > 0 && !purposes.includes(oidServerAuth) && !purposes.includes(oidAnyExtendedKeyUsage)) {
		return Result.err(X509Error.KeyUsageMismatch);
	}
	return Result.ok(null);
}

/** RFC 5280 4.2.1.9: `below` intermediates sit between `ca` and the leaf. */
function verifyPathLength(ca: Readonly<X509Certificate>, below: int32): Result<void, X509Error> {
	if (ca.pathLength >= 0 && below > ca.pathLength) return Result.err(X509Error.PathLengthExceeded);
	return Result.ok(null);
}

/**
 * Verify a chain as a TLS server sends it, leaf first: the leaf matches `hostName` (skipped when null) and may
 * sign for a server, each certificate is issued by the next within its issuer's path length, and the walk stops
 * at the first certificate a root in `roots` issued.
 */
export function verifyChain(
	chain: Readonly<X509Certificate[]>,
	roots: X509Bundle,
	hostName: string | null,
	nowSeconds: int64,
): Result<void, X509Error> {
	if (chain.length == 0) return Result.err(X509Error.EmptyChain);
	if (hostName != null) try verifyHostName(chain[0], hostName as string);
	try verifyServerUsage(chain[0]);
	for (let i = 0; i < chain.length; i++) {
		const subject = chain[i];
		if (i > 0) {
			try verifyIssuedBy(chain[i - 1], subject, nowSeconds);
			try verifyPathLength(subject, i - 1);
		}
		const trusted = roots.verify(subject, nowSeconds);
		if (trusted.ok) return verifyPathLength(roots.find(subject.issuer) as X509Certificate, i);
		if (trusted.error != X509Error.IssuerNotFound) return Result.err(trusted.error);
	}
	return Result.err(X509Error.IssuerNotFound);
}
