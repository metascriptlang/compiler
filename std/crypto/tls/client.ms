/**
 * A TLS 1.3 client (RFC 8446) over any byte stream: ClientHello with SNI,
 * ALPN, X25519 and P-256 key shares; the server's encrypted flight with
 * its certificate chain handed to a caller-supplied verifier and its
 * CertificateVerify checked with the portable signature kernels; then
 * application data, KeyUpdate and close_notify.
 *
 * `connectTls` also offers TLS 1.2 (RFC 5246) with ECDHE_RSA and
 * ECDHE_ECDSA (RFC 8422) AEAD suites and follows whichever version the
 * server selects. Static-RSA key exchange is not offered.
 */

import { CryptoError, CryptoErrorKind, cryptoError } from "../errors";
import { HashState, kindSha256, kindSha384, kindSha512 } from "../pure/state";
import { newHash, copyHash, updateHash, finishHash, hashOf } from "../pure/hash";
import { x25519 } from "../pure/x25519";
import { p256 } from "../pure/p256";
import { p384 } from "../pure/p384";
import { ownCurve, ecPublicPoint, ecdhShared, ecPublicFromSpki, ecdsaDerToRaw, ecdsaVerifyRaw } from "../pure/weierstrass";
import { ed25519Verify } from "../pure/ed25519";
import { RsaPublicData, rsaModulusOf, rsaVerifyPss, rsaVerifyPkcs1 } from "../pure/rsa";
import { derItem, derChildren, derUnsigned, derSame, tagSequence, tagBitString, tagOid, oidRsaEncryption } from "../pure/asn1";
import {
	CipherSuite, cipherSuiteOf, tls12CipherSuiteOf, tls12SuiteSignsWithEcdsa, tls12FixedIvLength,
	suiteAes128GcmSha256, suiteAes256GcmSha384, suiteChacha20Poly1305Sha256,
	suiteEcdheEcdsaAes128GcmSha256, suiteEcdheEcdsaAes256GcmSha384, suiteEcdheEcdsaChacha20Poly1305Sha256,
	suiteEcdheRsaAes128GcmSha256, suiteEcdheRsaAes256GcmSha384, suiteEcdheRsaChacha20Poly1305Sha256,
} from "./aead";
import { KeySchedule, handshakeSchedule, applicationSchedule, finishedVerifyData, tls12Prf } from "./keySchedule";
import {
	TrafficKeys, Record, RecordBuffer, RecordFailure, trafficKeysOf, tls12TrafficKeysOf, updatedTrafficKeys, plaintextRecords,
	sealRecords, openRecord, newRecordBuffer, recordHeaderLength, maxCiphertextLength, maxPlaintextLength,
	contentChangeCipherSpec, contentAlert, contentHandshake, contentApplicationData,
} from "./record";
import { wipeBytes } from "../pure/secret";

/** The byte stream a connection runs over. */
export abstract class TlsTransport {
	/** Up to `maxBytes` received bytes; empty at the end of the stream or on failure. */
	abstract receive(maxBytes: int32): uint8[];
	/** Sends all of `data`; false when the stream failed. */
	abstract send(data: Readonly<uint8[]>): boolean;
}

/**
 * Decides whether the server's certificate chain (DER, leaf first, as sent)
 * is trusted for `hostname`. Returns the reason when it is not.
 */
export type CertificateVerifier = (chain: uint8[][], hostname: string) => Result<void, string>;

/** Bytes of `Tls13Options.entropy` one handshake reads: client random, session id and the X25519, P-256 and P-384 scalars. */
export const entropyLength: int32 = 176;

export interface Tls13Options {
	/** Sent as SNI and handed to the verifier; empty sends no SNI. */
	hostname: string;
	verifier: CertificateVerifier;
	/** At least `entropyLength` bytes from a cryptographically secure source; read only while building the ClientHello. */
	entropy: uint8[];
	/** ALPN protocols in preference order; empty sends no ALPN extension. */
	alpn: string[];
}

const handshakeHelloRequest: int32 = 0;
const handshakeClientHello: int32 = 1;
const handshakeServerHello: int32 = 2;
const handshakeNewSessionTicket: int32 = 4;
const handshakeEncryptedExtensions: int32 = 8;
const handshakeCertificate: int32 = 11;
const handshakeServerKeyExchange: int32 = 12;
const handshakeCertificateRequest: int32 = 13;
const handshakeServerHelloDone: int32 = 14;
const handshakeCertificateVerify: int32 = 15;
const handshakeClientKeyExchange: int32 = 16;
const handshakeFinished: int32 = 20;
const handshakeKeyUpdate: int32 = 24;
const handshakeMessageHash: int32 = 254;

const extensionServerName: int32 = 0;
const extensionSupportedGroups: int32 = 10;
const extensionEcPointFormats: int32 = 11;
const extensionSignatureAlgorithms: int32 = 13;
const extensionAlpn: int32 = 16;
const extensionSupportedVersions: int32 = 43;
const extensionCookie: int32 = 44;
const extensionPskKeyExchangeModes: int32 = 45;
const extensionKeyShare: int32 = 51;
const extensionRenegotiationInfo: int32 = 0xff01;
const extensionMaxFragmentLength: int32 = 1;
const extensionUseSrtp: int32 = 14;
const extensionHeartbeat: int32 = 15;
const extensionClientCertificateType: int32 = 19;
const extensionServerCertificateType: int32 = 20;
const extensionRecordSizeLimit: int32 = 28;
const extensionPreSharedKey: int32 = 41;
const extensionEarlyData: int32 = 42;

/** RFC 8446 4.2: the extensions each server message may carry; the ClientHello must also have carried them. */
const tls13ServerHelloExtensions: Readonly<int32[]> = [extensionPreSharedKey, extensionKeyShare, extensionSupportedVersions];
const helloRetryRequestExtensions: Readonly<int32[]> = [extensionKeyShare, extensionCookie, extensionSupportedVersions];
const encryptedExtensions: Readonly<int32[]> = [
	extensionServerName, extensionMaxFragmentLength, extensionSupportedGroups, extensionUseSrtp, extensionHeartbeat,
	extensionAlpn, extensionClientCertificateType, extensionServerCertificateType, extensionRecordSizeLimit, extensionEarlyData,
];

/** The largest handshake message accepted; a certificate chain is the biggest a server sends. */
export const maxHandshakeMessageLength: int32 = 1 << 18;

const groupX25519: int32 = 0x001d;
const groupSecp256r1: int32 = 0x0017;
const groupSecp384r1: int32 = 0x0018;

const schemeEcdsaSecp256r1Sha256: int32 = 0x0403;
const schemeEcdsaSecp384r1Sha384: int32 = 0x0503;
const schemeRsaPssRsaeSha256: int32 = 0x0804;
const schemeRsaPssRsaeSha384: int32 = 0x0805;
const schemeRsaPssRsaeSha512: int32 = 0x0806;
const schemeEd25519: int32 = 0x0807;
const schemeRsaPkcs1Sha256: int32 = 0x0401;
const schemeRsaPkcs1Sha384: int32 = 0x0501;
const schemeRsaPkcs1Sha512: int32 = 0x0601;
const schemeEcdsaSha512: int32 = 0x0603;

export const versionTls12: int32 = 0x0303;
export const versionTls13: int32 = 0x0304;
const alertCloseNotify: int32 = 0;

const offeredSuites: Readonly<int32[]> = [suiteChacha20Poly1305Sha256, suiteAes128GcmSha256, suiteAes256GcmSha384];
const offeredTls12Suites: Readonly<int32[]> = [
	suiteEcdheEcdsaAes128GcmSha256,
	suiteEcdheRsaAes128GcmSha256,
	suiteEcdheEcdsaAes256GcmSha384,
	suiteEcdheRsaAes256GcmSha384,
	suiteEcdheEcdsaChacha20Poly1305Sha256,
	suiteEcdheRsaChacha20Poly1305Sha256,
];

/** RFC 8446 4.1.3: the first 7 of the last 8 bytes of ServerHello.random from a TLS 1.3 server that negotiated an older version. */
const downgradeSentinel: Readonly<uint8[]> = [0x44, 0x4f, 0x57, 0x4e, 0x47, 0x52, 0x44];

const helloRetryRequestRandom: Readonly<uint8[]> = [
	0xcf, 0x21, 0xad, 0x74, 0xe5, 0x9a, 0x61, 0x11, 0xbe, 0x1d, 0x8c, 0x02, 0x1e, 0x65, 0xb8, 0x91,
	0xc2, 0xa2, 0x11, 0x16, 0x7a, 0xbb, 0x8c, 0x5e, 0x07, 0x9e, 0x09, 0xe2, 0xc8, 0xa8, 0x33, 0x9c,
];

function tlsError(message: string): CryptoError {
	return cryptoError(CryptoErrorKind.HandshakeFailed, "tls13", message);
}

function connectionError(message: string): CryptoError {
	return cryptoError(CryptoErrorKind.ConnectionFailed, "tls13", message);
}

/** Refuses an extension the server may not send in this message or that `offered` lacks, and one it already sent. */
function checkExtensionType(
	type: int32,
	allowed: Readonly<int32[]> | null,
	offered: Readonly<int32[]>,
	seen: int32[],
	where: string,
): Result<void, CryptoError> {
	if ((allowed != null && !allowed.includes(type)) || !offered.includes(type)) {
		return Result.err(tlsError("TlsUnsupportedExtension: extension " + String(type) + " in " + where));
	}
	if (seen.includes(type)) return Result.err(tlsError("TlsIllegalParameter: duplicate extension " + String(type) + " in " + where));
	seen.push(type);
	return Result.ok(null);
}

// ===== Encoding =====

function putU8(out: uint8[], value: int32): void {
	out.push((value & 255) as uint8);
}

function putU16(out: uint8[], value: int32): void {
	out.push(((value >> 8) & 255) as uint8);
	out.push((value & 255) as uint8);
}

function putU24(out: uint8[], value: int32): void {
	out.push(((value >> 16) & 255) as uint8);
	out.push(((value >> 8) & 255) as uint8);
	out.push((value & 255) as uint8);
}

function putBytes(out: uint8[], data: Readonly<uint8[]>): void {
	for (let i = 0; i < data.length; i++) out.push(data[i]);
}

function putExtension(out: uint8[], type: int32, body: Readonly<uint8[]>): void {
	putU16(out, type);
	putU16(out, body.length as int32);
	putBytes(out, body);
}

/** A handshake message: type, uint24 length, body. */
function handshakeMessage(type: int32, body: Readonly<uint8[]>): uint8[] {
	const out: uint8[] = [];
	putU8(out, type);
	putU24(out, body.length as int32);
	putBytes(out, body);
	return out;
}

// ===== Decoding =====

/** A bounds-checked cursor; a read past `end` sets `bad` and yields zeros. */
class Decoder {
	data: uint8[];
	at: int32;
	end: int32;
	bad: boolean;
}

function decoderOf(data: Readonly<uint8[]>): Decoder {
	return { data: [...data], at: 0, end: data.length as int32, bad: false };
}

function takeU8(this d: Decoder): int32 {
	if (d.at + 1 > d.end) {
		d.bad = true;
		return 0;
	}
	const value = d.data[d.at] as int32;
	d.at += 1;
	return value;
}

function takeU16(this d: Decoder): int32 {
	const high = d.takeU8();
	return (high << 8) | d.takeU8();
}

function takeU24(this d: Decoder): int32 {
	const high = d.takeU16();
	return (high << 8) | d.takeU8();
}

function takeBytes(this d: Decoder, count: int32): uint8[] {
	if (count < 0 || d.at + count > d.end) {
		d.bad = true;
		d.at = d.end;
		return [];
	}
	const out = d.data.slice(d.at, d.at + count);
	d.at += count;
	return out;
}

function done(this d: Decoder): boolean {
	return d.at >= d.end;
}

/** The extension types of the ClientHello `hs` sent last. */
function offeredExtensions(hs: Tls13Handshake): int32[] {
	const d = decoderOf(hs.clientHello);
	d.takeBytes(4 + 2 + 32);
	d.takeBytes(d.takeU8());
	d.takeBytes(d.takeU16());
	d.takeBytes(d.takeU8());
	const extensions = decoderOf(d.takeBytes(d.takeU16()));
	const types: int32[] = [];
	while (!extensions.done()) {
		types.push(extensions.takeU16());
		extensions.takeBytes(extensions.takeU16());
	}
	return types;
}

function sameBytes(a: Readonly<uint8[]>, b: Readonly<uint8[]>): boolean {
	if (a.length != b.length) return false;
	let diff = 0;
	for (let i = 0; i < a.length; i++) diff |= (a[i] ^ b[i]) as int32;
	return diff == 0;
}

// ===== ClientHello =====

enum Stage {
	ServerHello,
	EncryptedExtensions,
	Certificate,
	CertificateVerify,
	ServerKeyExchange,
	ServerHelloDone,
	Finished,
	Done,
}

/** One client handshake in flight. */
export class Tls13Handshake {
	hostname: string;
	alpn: string[];
	clientRandom: uint8[];
	sessionId: uint8[];
	x25519Private: uint8[];
	p256Private: uint8[];
	p384Private: uint8[];
	/** Whether the ClientHello also offers TLS 1.2. */
	offerTls12: boolean;
	/** The groups the ClientHello carries a key share for; a HelloRetryRequest may replace them with one. */
	shareGroups: int32[];
	/** The version the server selected, 0 before its ServerHello. */
	version: int32;
	serverRandom: uint8[];
	/** The ClientHello handshake message (with its 4-byte header) the transcript starts with. */
	clientHello: uint8[];
	stage: Stage;
	retried: boolean;
	transcriptStarted: boolean;
	transcript: HashState;
	suite: CipherSuite;
	schedule: KeySchedule;
	serverKeys: TrafficKeys | null;
	clientKeys: TrafficKeys | null;
	chain: uint8[][];
	certificateRequested: boolean;
	certificateRequestContext: uint8[];
	applicationProtocol: string;
	/** TLS 1.2: the ECDHE pre-master secret and the public key sent in ClientKeyExchange. */
	preMasterSecret: uint8[];
	clientPublic: uint8[];
	masterSecret: uint8[];
	/** TLS 1.2: the server's read keys, installed by its ChangeCipherSpec. */
	pendingServerKeys: TrafficKeys | null;
	expectedServerFinished: uint8[];
}

/** Zeroes the ECDHE scalars once the shared secret is known. */
function forgetKeyShares(hs: Tls13Handshake): void {
	wipeBytes(hs.x25519Private);
	wipeBytes(hs.p256Private);
	wipeBytes(hs.p384Private);
}

function onDestroy(this hs: Tls13Handshake): void {
	forgetKeyShares(hs);
	wipeBytes(hs.preMasterSecret);
	wipeBytes(hs.masterSecret);
}

function clientHelloOf(hs: Tls13Handshake, cookie: Readonly<uint8[]>): uint8[] {
	const body: uint8[] = [];
	putU16(body, 0x0303);
	putBytes(body, hs.clientRandom);
	putU8(body, hs.sessionId.length as int32);
	putBytes(body, hs.sessionId);
	const suites: int32[] = [...offeredSuites];
	if (hs.offerTls12) {
		for (const suite of offeredTls12Suites) suites.push(suite);
	}
	putU16(body, 2 * (suites.length as int32));
	for (const suite of suites) putU16(body, suite);
	putU8(body, 1);
	putU8(body, 0);

	const extensions: uint8[] = [];
	if (hs.hostname.length > 0) {
		const name = hs.hostname.asBytes().slice(0);
		const list: uint8[] = [];
		putU16(list, (name.length as int32) + 3);
		putU8(list, 0);
		putU16(list, name.length as int32);
		putBytes(list, name);
		putExtension(extensions, extensionServerName, list);
	}
	if (hs.offerTls12) {
		putExtension(extensions, extensionSupportedVersions, [4, 0x03, 0x04, 0x03, 0x03]);
		putExtension(extensions, extensionRenegotiationInfo, [0]);
		putExtension(extensions, extensionEcPointFormats, [1, 0]);
	} else {
		putExtension(extensions, extensionSupportedVersions, [2, 0x03, 0x04]);
	}
	const schemes: int32[] = [
		schemeEcdsaSecp256r1Sha256,
		schemeEcdsaSecp384r1Sha384,
		schemeRsaPssRsaeSha256,
		schemeRsaPssRsaeSha384,
		schemeRsaPssRsaeSha512,
		schemeEd25519,
		schemeRsaPkcs1Sha256,
		schemeRsaPkcs1Sha384,
		schemeRsaPkcs1Sha512,
	];
	const schemeList: uint8[] = [];
	putU16(schemeList, 2 * (schemes.length as int32));
	for (const scheme of schemes) putU16(schemeList, scheme);
	putExtension(extensions, extensionSignatureAlgorithms, schemeList);
	const groups: uint8[] = [];
	for (const group of supportedGroups(hs)) putU16(groups, group);
	const groupList: uint8[] = [];
	putU16(groupList, groups.length as int32);
	putBytes(groupList, groups);
	putExtension(extensions, extensionSupportedGroups, groupList);
	putExtension(extensions, extensionPskKeyExchangeModes, [1, 1]);
	const shares: uint8[] = [];
	for (const group of hs.shareGroups) {
		const share = publicKeyOf(hs, group);
		if (share == null) continue;
		putU16(shares, group);
		putU16(shares, share.length as int32);
		putBytes(shares, share);
	}
	const keyShare: uint8[] = [];
	putU16(keyShare, shares.length as int32);
	putBytes(keyShare, shares);
	putExtension(extensions, extensionKeyShare, keyShare);
	if (hs.alpn.length > 0) {
		const protocols: uint8[] = [];
		for (const protocol of hs.alpn) {
			const name = protocol.asBytes().slice(0);
			putU8(protocols, name.length as int32);
			putBytes(protocols, name);
		}
		const alpn: uint8[] = [];
		putU16(alpn, protocols.length as int32);
		putBytes(alpn, protocols);
		putExtension(extensions, extensionAlpn, alpn);
	}
	if (cookie.length > 0) {
		const field: uint8[] = [];
		putU16(field, cookie.length as int32);
		putBytes(field, cookie);
		putExtension(extensions, extensionCookie, field);
	}
	putU16(body, extensions.length as int32);
	putBytes(body, extensions);
	return handshakeMessage(handshakeClientHello, body);
}

function x25519BasePoint(): uint8[] {
	const base = new Array<uint8>(32);
	base[0] = 9;
	return base;
}

/** P-384 only with TLS 1.2 on offer, as the ServerKeyExchange may pick it. */
function supportedGroups(hs: Tls13Handshake): int32[] {
	if (hs.offerTls12) return [groupX25519, groupSecp256r1, groupSecp384r1];
	return [groupX25519, groupSecp256r1];
}

/** This handshake's public key for `group`, or null when the scalar is out of range. */
function publicKeyOf(hs: Tls13Handshake, group: int32): uint8[] | null {
	if (group == groupX25519) return x25519(hs.x25519Private, x25519BasePoint());
	if (group == groupSecp256r1) return ecPublicPoint(p256, hs.p256Private);
	if (group == groupSecp384r1) return ecPublicPoint(p384, hs.p384Private);
	return null;
}

/** A handshake with its ClientHello built from `options.entropy`; `offerTls12` adds TLS 1.2 to it. */
export function newHandshake(options: Tls13Options, offerTls12: boolean = false): Result<Tls13Handshake, CryptoError> {
	const entropy = options.entropy;
	if (entropy.length < entropyLength) return Result.err(tlsError("TlsInsufficientEntropy: options.entropy needs " + String(entropyLength) + " bytes"));
	const hs: Tls13Handshake = {
		hostname: options.hostname,
		alpn: [...options.alpn],
		clientRandom: entropy.slice(0, 32),
		sessionId: entropy.slice(32, 64),
		x25519Private: entropy.slice(64, 96),
		p256Private: entropy.slice(96, 128),
		p384Private: entropy.slice(128, 176),
		offerTls12,
		shareGroups: [groupX25519, groupSecp256r1],
		version: 0,
		serverRandom: [],
		clientHello: [],
		stage: Stage.ServerHello,
		retried: false,
		transcriptStarted: false,
		transcript: newHash(kindSha256),
		suite: { code: 0, hashKind: kindSha256, keyLength: 0 },
		schedule: {
			kind: kindSha256,
			earlySecret: [],
			handshakeSecret: [],
			masterSecret: [],
			clientHandshakeSecret: [],
			serverHandshakeSecret: [],
			clientApplicationSecret: [],
			serverApplicationSecret: [],
		},
		serverKeys: null,
		clientKeys: null,
		chain: [],
		certificateRequested: false,
		certificateRequestContext: [],
		applicationProtocol: "",
		preMasterSecret: [],
		clientPublic: [],
		masterSecret: [],
		pendingServerKeys: null,
		expectedServerFinished: [],
	};
	hs.clientHello = clientHelloOf(hs, []);
	return Result.ok(hs);
}

// ===== Transcript =====

function startTranscript(hs: Tls13Handshake, suite: CipherSuite): void {
	hs.suite = suite;
	hs.transcript = newHash(suite.hashKind);
	hs.transcriptStarted = true;
}

/** Hash of the messages so far, leaving the running hash open. */
function transcriptHash(hs: Tls13Handshake): uint8[] {
	const copy = newHash(hs.suite.hashKind);
	copyHash(hs.transcript, copy);
	return finishHash(copy);
}

// ===== Server messages =====

function sharedSecretOf(hs: Tls13Handshake, group: int32, key: Readonly<uint8[]>): Result<uint8[], CryptoError> {
	if (group == groupX25519) {
		if (key.length != 32) return Result.err(tlsError("TlsIllegalParameter: x25519 key share length"));
		const shared = x25519(hs.x25519Private, key);
		let any = 0;
		for (let i = 0; i < 32; i++) any |= shared[i] as int32;
		if (any == 0) return Result.err(tlsError("TlsDecryptFailure: x25519 low-order key share"));
		return Result.ok(shared);
	}
	if (group == groupSecp256r1) {
		const shared = ecdhShared(p256, hs.p256Private, key);
		if (shared == null) return Result.err(tlsError("TlsDecryptFailure: invalid secp256r1 key share"));
		return Result.ok(shared);
	}
	if (group == groupSecp384r1 && hs.offerTls12) {
		const shared = ecdhShared(p384, hs.p384Private, key);
		if (shared == null) return Result.err(tlsError("TlsDecryptFailure: invalid secp384r1 key share"));
		return Result.ok(shared);
	}
	return Result.err(tlsError("TlsIllegalParameter: key share for a group not offered"));
}

function offered(code: int32): boolean {
	for (const suite of offeredSuites) {
		if (suite == code) return true;
	}
	return false;
}

/** RFC 8446 4.1.4: restarts the transcript with message_hash and answers with a second ClientHello carrying the cookie. */
function onHelloRetryRequest(
	hs: Tls13Handshake,
	d: Decoder,
	wrapped: Readonly<uint8[]>,
	transport: TlsTransport,
): Result<void, CryptoError> {
	if (hs.retried) return Result.err(tlsError("TlsUnexpectedMessage: second HelloRetryRequest"));
	hs.retried = true;
	const sessionEcho = d.takeBytes(d.takeU8());
	const code = d.takeU16();
	d.takeU8();
	const extensions = decoderOf(d.takeBytes(d.takeU16()));
	let version = 0;
	let cookie: uint8[] = [];
	let group = -1;
	const seen: int32[] = [];
	while (!extensions.done()) {
		const type = extensions.takeU16();
		const body = decoderOf(extensions.takeBytes(extensions.takeU16()));
		if (extensions.bad) break;
		try checkExtensionType(type, helloRetryRequestExtensions, [...offeredExtensions(hs), extensionCookie], seen, "HelloRetryRequest");
		if (type == extensionSupportedVersions) version = body.takeU16();
		else if (type == extensionCookie) cookie = body.takeBytes(body.takeU16());
		else if (type == extensionKeyShare) group = body.takeU16();
		if (body.bad) return Result.err(tlsError("TlsDecodeError: HelloRetryRequest extension"));
	}
	if (group != -1) {
		if (hs.shareGroups.includes(group)) return Result.err(tlsError("TlsIllegalParameter: HelloRetryRequest for a group whose share was sent"));
		if (!supportedGroups(hs).includes(group) || publicKeyOf(hs, group) == null) return Result.err(tlsError("TlsIllegalParameter: HelloRetryRequest for a group not offered"));
		hs.shareGroups = [group];
	}
	if (d.bad || extensions.bad) return Result.err(tlsError("TlsDecodeError: HelloRetryRequest"));
	if (version != versionTls13) return Result.err(tlsError("TlsProtocolVersion: HelloRetryRequest is not TLS 1.3"));
	if (!sameBytes(sessionEcho, hs.sessionId)) return Result.err(tlsError("TlsIllegalParameter: session id echo"));
	const suite = cipherSuiteOf(code);
	if (suite == null || !offered(code)) return Result.err(tlsError("TlsIllegalParameter: cipher suite not offered"));
	if (cookie.length == 0 && group == -1) return Result.err(tlsError("TlsIllegalParameter: HelloRetryRequest changes nothing"));
	const firstHash = hashOf(suite.hashKind, hs.clientHello);
	startTranscript(hs, suite);
	const synthetic: uint8[] = [handshakeMessageHash as uint8, 0, 0, firstHash.length as uint8];
	putBytes(synthetic, firstHash);
	updateHash(hs.transcript, synthetic);
	updateHash(hs.transcript, wrapped);
	hs.clientHello = clientHelloOf(hs, cookie);
	updateHash(hs.transcript, hs.clientHello);
	if (!transport.send(plaintextRecords(contentHandshake, hs.clientHello, 0x0303))) return Result.err(connectionError("TlsWriteFailed"));
	return Result.ok(null);
}

function onServerHello(
	hs: Tls13Handshake,
	body: Readonly<uint8[]>,
	wrapped: Readonly<uint8[]>,
	transport: TlsTransport,
): Result<void, CryptoError> {
	const d = decoderOf(body);
	d.takeU16();
	const random = d.takeBytes(32);
	if (sameBytes(random, helloRetryRequestRandom)) return onHelloRetryRequest(hs, d, wrapped, transport);
	const sessionEcho = d.takeBytes(d.takeU8());
	const code = d.takeU16();
	if (d.takeU8() != 0) return Result.err(tlsError("TlsIllegalParameter: compression method"));
	const extensions = decoderOf(d.done() ? [] : d.takeBytes(d.takeU16()));
	let version = 0;
	let group = -1;
	let share: uint8[] = [];
	const types: int32[] = [];
	while (!extensions.done()) {
		const type = extensions.takeU16();
		const ext = decoderOf(extensions.takeBytes(extensions.takeU16()));
		types.push(type);
		if (type == extensionSupportedVersions) {
			version = ext.takeU16();
		} else if (type == extensionKeyShare) {
			group = ext.takeU16();
			share = ext.takeBytes(ext.takeU16());
		}
		const parsed = type == extensionSupportedVersions || type == extensionKeyShare;
		if (ext.bad || (parsed && !ext.done())) return Result.err(tlsError("TlsDecodeError: ServerHello extension"));
	}
	if (d.bad || extensions.bad) return Result.err(tlsError("TlsDecodeError: ServerHello"));
	if (version == 0 && hs.offerTls12 && !hs.retried) return onTls12ServerHello(hs, body, wrapped);
	if (version != versionTls13) return Result.err(tlsError("TlsProtocolVersion: server did not select TLS 1.3"));
	const seen: int32[] = [];
	const offeredTypes = offeredExtensions(hs);
	for (const type of types) try checkExtensionType(type, tls13ServerHelloExtensions, offeredTypes, seen, "ServerHello");
	hs.version = versionTls13;
	if (!sameBytes(sessionEcho, hs.sessionId)) return Result.err(tlsError("TlsIllegalParameter: session id echo"));
	const suite = cipherSuiteOf(code);
	if (suite == null || !offered(code)) return Result.err(tlsError("TlsIllegalParameter: cipher suite not offered"));
	if (hs.transcriptStarted && hs.suite.code != code) return Result.err(tlsError("TlsIllegalParameter: cipher suite changed after HelloRetryRequest"));
	if (group == -1) return Result.err(tlsError("TlsMissingExtension: key_share"));
	const shared = try sharedSecretOf(hs, group, share);
	if (!hs.transcriptStarted) {
		startTranscript(hs, suite);
		updateHash(hs.transcript, hs.clientHello);
	}
	updateHash(hs.transcript, wrapped);
	hs.schedule = handshakeSchedule(suite.hashKind, shared, transcriptHash(hs));
	wipeBytes(shared);
	forgetKeyShares(hs);
	hs.serverKeys = trafficKeysOf(suite, hs.schedule.serverHandshakeSecret);
	hs.clientKeys = trafficKeysOf(suite, hs.schedule.clientHandshakeSecret);
	hs.stage = Stage.EncryptedExtensions;
	return Result.ok(null);
}

/** Records the ALPN protocol the server chose, which must be one offered. */
function onAlpn(hs: Tls13Handshake, ext: Decoder): Result<void, CryptoError> {
	const list = decoderOf(ext.takeBytes(ext.takeU16()));
	const chosen = list.takeBytes(list.takeU8());
	if (list.bad || !list.done() || chosen.length == 0) return Result.err(tlsError("TlsDecodeError: ALPN"));
	let name = "";
	for (const protocol of hs.alpn) {
		if (sameBytes(protocol.asBytes().slice(0), chosen)) name = protocol;
	}
	if (name.length == 0) return Result.err(tlsError("TlsNoApplicationProtocol: server chose an ALPN protocol not offered"));
	hs.applicationProtocol = name;
	return Result.ok(null);
}

function onEncryptedExtensions(hs: Tls13Handshake, body: Readonly<uint8[]>): Result<void, CryptoError> {
	const d = decoderOf(body);
	const extensions = decoderOf(d.takeBytes(d.takeU16()));
	const offeredTypes = offeredExtensions(hs);
	const seen: int32[] = [];
	while (!extensions.done()) {
		const type = extensions.takeU16();
		const ext = decoderOf(extensions.takeBytes(extensions.takeU16()));
		if (extensions.bad) break;
		try checkExtensionType(type, encryptedExtensions, offeredTypes, seen, "EncryptedExtensions");
		if (type == extensionAlpn) try onAlpn(hs, ext);
		if (ext.bad) return Result.err(tlsError("TlsDecodeError: EncryptedExtensions extension"));
	}
	if (d.bad || extensions.bad) return Result.err(tlsError("TlsDecodeError: EncryptedExtensions"));
	hs.stage = Stage.Certificate;
	return Result.ok(null);
}

function onCertificate(
	hs: Tls13Handshake,
	body: Readonly<uint8[]>,
	verifier: CertificateVerifier,
): Result<void, CryptoError> {
	const d = decoderOf(body);
	if (d.takeU8() != 0) return Result.err(tlsError("TlsIllegalParameter: certificate_request_context"));
	const list = decoderOf(d.takeBytes(d.takeU24()));
	const chain: uint8[][] = [];
	while (!list.done()) {
		chain.push(list.takeBytes(list.takeU24()));
		if (list.takeBytes(list.takeU16()).length > 0) return Result.err(tlsError("TlsUnsupportedExtension: CertificateEntry extensions were not requested"));
	}
	if (d.bad || list.bad || !d.done()) return Result.err(tlsError("TlsDecodeError: Certificate"));
	try acceptChain(hs, chain, verifier);
	hs.stage = Stage.CertificateVerify;
	return Result.ok(null);
}

function acceptChain(hs: Tls13Handshake, chain: uint8[][], verifier: CertificateVerifier): Result<void, CryptoError> {
	if (chain.length == 0) return Result.err(tlsError("TlsCertificateRequired: empty server certificate chain"));
	const verdict = verifier(chain, hs.hostname);
	if (!verdict.ok) return Result.err(cryptoError(CryptoErrorKind.CertificateError, "tls13", "TlsCertificateNotVerified: " + verdict.error));
	hs.chain = chain;
	return Result.ok(null);
}

function onCertificateRequest(hs: Tls13Handshake, body: Readonly<uint8[]>): Result<void, CryptoError> {
	const d = decoderOf(body);
	const context = d.takeBytes(d.takeU8());
	d.takeBytes(d.takeU16());
	if (d.bad || !d.done()) return Result.err(tlsError("TlsDecodeError: CertificateRequest"));
	hs.certificateRequested = true;
	hs.certificateRequestContext = context;
	return Result.ok(null);
}

/** RFC 8446 4.4.3: the content a server CertificateVerify signs. */
export function certificateVerifyContent(transcript: Readonly<uint8[]>): uint8[] {
	const out: uint8[] = [];
	for (let i = 0; i < 64; i++) out.push(0x20);
	putBytes(out, "TLS 1.3, server CertificateVerify".asBytes().slice(0));
	out.push(0);
	putBytes(out, transcript);
	return out;
}

/** The SubjectPublicKeyInfo DER of a certificate, or null when it is not a well-formed X.509 v3 shape. */
export function certificateSpki(der: Readonly<uint8[]>): uint8[] | null {
	const root = derItem(der, 0, der.length as int32);
	if (root == null || root.tag != tagSequence) return null;
	const tbs = derItem(der, root.body, root.end);
	if (tbs == null || tbs.tag != tagSequence) return null;
	let at = tbs.body;
	let index = 0;
	while (at < tbs.end) {
		const item = derItem(der, at, tbs.end);
		if (item == null) return null;
		if (index == 0 && item.tag != 0xa0) index = 1;
		if (index == 6) return der.slice(at, item.end);
		index += 1;
		at = item.end;
	}
	return null;
}

const oidEd25519: Readonly<uint8[]> = [0x2b, 0x65, 0x70];

/** The modulus and exponent of an rsaEncryption SPKI with a 1024- to 4096-bit modulus. */
function rsaKeyOfSpki(spki: Readonly<uint8[]>): RsaPublicData | null {
	const root = derItem(spki, 0, spki.length as int32);
	if (root == null || root.tag != tagSequence) return null;
	const parts = derChildren(spki, root);
	if (parts == null || parts.length != 2 || parts[0].tag != tagSequence || parts[1].tag != tagBitString) return null;
	const algorithm = derChildren(spki, parts[0]);
	if (algorithm == null || algorithm.length < 1 || !derSame(spki, algorithm[0], oidRsaEncryption())) return null;
	const bits = parts[1];
	if (bits.end - bits.body < 2 || spki[bits.body] != 0) return null;
	const inner = derItem(spki, bits.body + 1, bits.end);
	if (inner == null || inner.tag != tagSequence) return null;
	const numbers = derChildren(spki, inner);
	if (numbers == null || numbers.length != 2) return null;
	const modulus = derUnsigned(spki, numbers[0]);
	const exponent = derUnsigned(spki, numbers[1]);
	if (modulus == null || exponent == null) return null;
	const size = modulus.length;
	if (size != 128 && size != 256 && size != 384 && size != 512) return null;
	return { n: modulus, e: exponent, nModulus: rsaModulusOf(modulus) };
}

function ed25519KeyOfSpki(spki: Readonly<uint8[]>): uint8[] | null {
	const root = derItem(spki, 0, spki.length as int32);
	if (root == null || root.tag != tagSequence) return null;
	const parts = derChildren(spki, root);
	if (parts == null || parts.length != 2 || parts[0].tag != tagSequence || parts[1].tag != tagBitString) return null;
	const algorithm = derChildren(spki, parts[0]);
	if (algorithm == null || algorithm.length != 1 || algorithm[0].tag != tagOid || !derSame(spki, algorithm[0], oidEd25519)) return null;
	const bits = parts[1];
	if (bits.end - bits.body != 33 || spki[bits.body] != 0) return null;
	return spki.slice(bits.body + 1, bits.end);
}

function ecdsaAcceptable(spki: Readonly<uint8[]>, curveIsP256: boolean, content: Readonly<uint8[]>, signature: Readonly<uint8[]>): boolean {
	const curves = curveIsP256 ? [ownCurve(p256)] : [ownCurve(p384)];
	const key = ecPublicFromSpki(spki, curves);
	if (key == null) return false;
	const size = key.curve.size;
	const raw = ecdsaDerToRaw(signature, size);
	if (raw == null) return false;
	const digest = hashOf(curveIsP256 ? kindSha256 : kindSha384, content);
	return ecdsaVerifyRaw(key.curve, key.point, digest, raw);
}

function rsaPssAcceptable(spki: Readonly<uint8[]>, hash: string, content: Readonly<uint8[]>, signature: Readonly<uint8[]>): boolean {
	const key = rsaKeyOfSpki(spki);
	if (key == null) return false;
	return rsaVerifyPss(key, hash, content, signature);
}

/** Whether `signature` under `scheme` verifies `content` with the leaf certificate's key. RSA must be PSS (RFC 8446 4.4.3). */
export function signatureAcceptable(
	leaf: Readonly<uint8[]>,
	scheme: int32,
	content: Readonly<uint8[]>,
	signature: Readonly<uint8[]>,
): boolean {
	const spki = certificateSpki(leaf);
	if (spki == null) return false;
	if (scheme == schemeEcdsaSecp256r1Sha256) return ecdsaAcceptable(spki, true, content, signature);
	if (scheme == schemeEcdsaSecp384r1Sha384) return ecdsaAcceptable(spki, false, content, signature);
	if (scheme == schemeRsaPssRsaeSha256) return rsaPssAcceptable(spki, "sha256", content, signature);
	if (scheme == schemeRsaPssRsaeSha384) return rsaPssAcceptable(spki, "sha384", content, signature);
	if (scheme == schemeRsaPssRsaeSha512) return rsaPssAcceptable(spki, "sha512", content, signature);
	if (scheme == schemeEd25519) {
		const key = ed25519KeyOfSpki(spki);
		return key != null && ed25519Verify(key, signature, content);
	}
	return false;
}

function onCertificateVerify(hs: Tls13Handshake, body: Readonly<uint8[]>): Result<void, CryptoError> {
	const d = decoderOf(body);
	const scheme = d.takeU16();
	const signature = d.takeBytes(d.takeU16());
	if (d.bad || !d.done()) return Result.err(tlsError("TlsDecodeError: CertificateVerify"));
	const content = certificateVerifyContent(transcriptHash(hs));
	if (!signatureAcceptable(hs.chain[0], scheme, content, signature)) {
		return Result.err(tlsError("TlsDecryptError: CertificateVerify signature does not verify (scheme 0x" + scheme.toString(16) + ")"));
	}
	hs.stage = Stage.Finished;
	return Result.ok(null);
}

/** Checks the server Finished, then sends the client's flight; the transcript must not yet hold the server Finished. */
function onServerFinished(
	hs: Tls13Handshake,
	body: Readonly<uint8[]>,
	wrapped: Readonly<uint8[]>,
	transport: TlsTransport,
): Result<void, CryptoError> {
	const kind = hs.suite.hashKind;
	const expected = finishedVerifyData(kind, hs.schedule.serverHandshakeSecret, transcriptHash(hs));
	if (!sameBytes(expected, body)) return Result.err(tlsError("TlsDecryptError: server Finished does not verify"));
	updateHash(hs.transcript, wrapped);
	applicationSchedule(hs.schedule, transcriptHash(hs));
	const clientKeys = hs.clientKeys;
	if (clientKeys == null) return Result.err(tlsError("TlsUnexpectedMessage: Finished before ServerHello"));
	const flight: uint8[] = [];
	if (hs.sessionId.length > 0) putBytes(flight, [contentChangeCipherSpec as uint8, 0x03, 0x03, 0x00, 0x01, 0x01]);
	if (hs.certificateRequested) {
		const certificate: uint8[] = [];
		putU8(certificate, hs.certificateRequestContext.length as int32);
		putBytes(certificate, hs.certificateRequestContext);
		putU24(certificate, 0);
		const message = handshakeMessage(handshakeCertificate, certificate);
		updateHash(hs.transcript, message);
		putBytes(flight, try sealed(clientKeys, contentHandshake, message));
	}
	const verifyData = finishedVerifyData(kind, hs.schedule.clientHandshakeSecret, transcriptHash(hs));
	const finished = handshakeMessage(handshakeFinished, verifyData);
	updateHash(hs.transcript, finished);
	putBytes(flight, try sealed(clientKeys, contentHandshake, finished));
	if (!transport.send(flight)) return Result.err(connectionError("TlsWriteFailed"));
	hs.stage = Stage.Done;
	return Result.ok(null);
}

function onHandshakeMessage(
	hs: Tls13Handshake,
	type: int32,
	body: Readonly<uint8[]>,
	wrapped: Readonly<uint8[]>,
	transport: TlsTransport,
	verifier: CertificateVerifier,
): Result<void, CryptoError> {
	const stage = hs.stage;
	if (hs.version == versionTls12) return onTls12HandshakeMessage(hs, type, body, wrapped, transport, verifier);
	if (stage == Stage.ServerHello) {
		if (type != handshakeServerHello) return Result.err(tlsError("TlsUnexpectedMessage: expected ServerHello"));
		return onServerHello(hs, body, wrapped, transport);
	}
	if (stage == Stage.Finished && type == handshakeFinished) return onServerFinished(hs, body, wrapped, transport);
	if (stage == Stage.CertificateVerify && type == handshakeCertificateVerify) {
		try onCertificateVerify(hs, body);
		updateHash(hs.transcript, wrapped);
		return Result.ok(null);
	}
	updateHash(hs.transcript, wrapped);
	if (stage == Stage.EncryptedExtensions && type == handshakeEncryptedExtensions) return onEncryptedExtensions(hs, body);
	if (stage == Stage.Certificate && type == handshakeCertificateRequest && !hs.certificateRequested) return onCertificateRequest(hs, body);
	if (stage == Stage.Certificate && type == handshakeCertificate) return onCertificate(hs, body, verifier);
	return Result.err(tlsError("TlsUnexpectedMessage: handshake type " + String(type)));
}

// ===== TLS 1.2 =====

function concatBytes(a: Readonly<uint8[]>, b: Readonly<uint8[]>): uint8[] {
	const out: uint8[] = [...a];
	putBytes(out, b);
	return out;
}

function offeredTls12(code: int32): boolean {
	for (const suite of offeredTls12Suites) {
		if (suite == code) return true;
	}
	return false;
}

/**
 * A TLS 1.2 ServerHello: no supported_versions, a random without the
 * downgrade sentinel, an ECDHE AEAD suite offered. renegotiation_info,
 * when present, must be empty (RFC 5746 3.4); a server without it is
 * accepted, as this client never renegotiates.
 */
function onTls12ServerHello(hs: Tls13Handshake, body: Readonly<uint8[]>, wrapped: Readonly<uint8[]>): Result<void, CryptoError> {
	const d = decoderOf(body);
	const legacyVersion = d.takeU16();
	const random = d.takeBytes(32);
	d.takeBytes(d.takeU8());
	const code = d.takeU16();
	d.takeU8();
	const extensions = decoderOf(d.done() ? [] : d.takeBytes(d.takeU16()));
	const offeredTypes = offeredExtensions(hs);
	const seen: int32[] = [];
	while (!extensions.done()) {
		const type = extensions.takeU16();
		const ext = decoderOf(extensions.takeBytes(extensions.takeU16()));
		if (extensions.bad) break;
		if (type == extensionKeyShare) return Result.err(tlsError("TlsUnsupportedExtension: key_share in a TLS 1.2 ServerHello"));
		try checkExtensionType(type, null, offeredTypes, seen, "TLS 1.2 ServerHello");
		if (type == extensionRenegotiationInfo) {
			if (ext.takeU8() != 0 || !ext.done()) return Result.err(tlsError("TlsHandshakeFailure: renegotiation_info is not empty"));
		} else if (type == extensionAlpn) {
			try onAlpn(hs, ext);
		}
		if (ext.bad) return Result.err(tlsError("TlsDecodeError: ServerHello extension"));
	}
	if (d.bad || extensions.bad) return Result.err(tlsError("TlsDecodeError: ServerHello"));
	if (legacyVersion != versionTls12) return Result.err(tlsError("TlsProtocolVersion: server selected a version before TLS 1.2"));
	if (sameBytes(random.slice(24, 31), downgradeSentinel) && (random[31] as int32) >> 1 == 0) {
		return Result.err(tlsError("TlsIllegalParameter: TLS 1.3 server downgraded to TLS 1.2"));
	}
	const suite = tls12CipherSuiteOf(code);
	if (suite == null || !offeredTls12(code)) return Result.err(tlsError("TlsIllegalParameter: cipher suite not offered"));
	hs.version = versionTls12;
	hs.serverRandom = random;
	startTranscript(hs, suite);
	updateHash(hs.transcript, hs.clientHello);
	updateHash(hs.transcript, wrapped);
	hs.stage = Stage.Certificate;
	return Result.ok(null);
}

function onTls12Certificate(hs: Tls13Handshake, body: Readonly<uint8[]>, verifier: CertificateVerifier): Result<void, CryptoError> {
	const d = decoderOf(body);
	const list = decoderOf(d.takeBytes(d.takeU24()));
	const chain: uint8[][] = [];
	while (!list.done()) chain.push(list.takeBytes(list.takeU24()));
	if (d.bad || list.bad || !d.done()) return Result.err(tlsError("TlsDecodeError: Certificate"));
	try acceptChain(hs, chain, verifier);
	hs.stage = Stage.ServerKeyExchange;
	return Result.ok(null);
}

function ecdsaAnyCurveAcceptable(spki: Readonly<uint8[]>, kind: int32, content: Readonly<uint8[]>, signature: Readonly<uint8[]>): boolean {
	const key = ecPublicFromSpki(spki, [ownCurve(p256), ownCurve(p384)]);
	if (key == null) return false;
	const raw = ecdsaDerToRaw(signature, key.curve.size);
	if (raw == null) return false;
	return ecdsaVerifyRaw(key.curve, key.point, hashOf(kind, content), raw);
}

/** RFC 5246 7.4.1.4.1: in TLS 1.2 an ECDSA scheme names only its hash, and RSA may be PKCS #1 v1.5 or PSS. */
export function tls12SignatureAcceptable(
	leaf: Readonly<uint8[]>,
	scheme: int32,
	content: Readonly<uint8[]>,
	signature: Readonly<uint8[]>,
): boolean {
	const spki = certificateSpki(leaf);
	if (spki == null) return false;
	if (scheme == schemeEcdsaSecp256r1Sha256) return ecdsaAnyCurveAcceptable(spki, kindSha256, content, signature);
	if (scheme == schemeEcdsaSecp384r1Sha384) return ecdsaAnyCurveAcceptable(spki, kindSha384, content, signature);
	if (scheme == schemeEcdsaSha512) return ecdsaAnyCurveAcceptable(spki, kindSha512, content, signature);
	if (scheme == schemeRsaPssRsaeSha256) return rsaPssAcceptable(spki, "sha256", content, signature);
	if (scheme == schemeRsaPssRsaeSha384) return rsaPssAcceptable(spki, "sha384", content, signature);
	if (scheme == schemeRsaPssRsaeSha512) return rsaPssAcceptable(spki, "sha512", content, signature);
	const key = rsaKeyOfSpki(spki);
	if (key == null) return false;
	if (scheme == schemeRsaPkcs1Sha256) return rsaVerifyPkcs1(key, "sha256", content, signature);
	if (scheme == schemeRsaPkcs1Sha384) return rsaVerifyPkcs1(key, "sha384", content, signature);
	if (scheme == schemeRsaPkcs1Sha512) return rsaVerifyPkcs1(key, "sha512", content, signature);
	return false;
}

function schemeIsEcdsa(scheme: int32): boolean {
	return scheme == schemeEcdsaSecp256r1Sha256 || scheme == schemeEcdsaSecp384r1Sha384 || scheme == schemeEcdsaSha512;
}

function schemeIsRsa(scheme: int32): boolean {
	return scheme == schemeRsaPkcs1Sha256 || scheme == schemeRsaPkcs1Sha384 || scheme == schemeRsaPkcs1Sha512 ||
		scheme == schemeRsaPssRsaeSha256 || scheme == schemeRsaPssRsaeSha384 || scheme == schemeRsaPssRsaeSha512;
}

/** RFC 8422 5.4: named-curve ECDHE parameters signed over both randoms with the leaf key of the suite's kind. */
function onServerKeyExchange(hs: Tls13Handshake, body: Readonly<uint8[]>): Result<void, CryptoError> {
	const d = decoderOf(body);
	if (d.takeU8() != 3) return Result.err(tlsError("TlsIllegalParameter: ServerKeyExchange curve type is not named_curve"));
	const group = d.takeU16();
	const point = d.takeBytes(d.takeU8());
	const paramsEnd = d.at;
	const scheme = d.takeU16();
	const signature = d.takeBytes(d.takeU16());
	if (d.bad || !d.done()) return Result.err(tlsError("TlsDecodeError: ServerKeyExchange"));
	const ecdsaSuite = tls12SuiteSignsWithEcdsa(hs.suite.code);
	if (ecdsaSuite ? !schemeIsEcdsa(scheme) : !schemeIsRsa(scheme)) {
		return Result.err(tlsError("TlsIllegalParameter: ServerKeyExchange scheme 0x" + scheme.toString(16) + " does not match the suite"));
	}
	const signed = concatBytes(concatBytes(hs.clientRandom, hs.serverRandom), body.slice(0, paramsEnd));
	if (!tls12SignatureAcceptable(hs.chain[0], scheme, signed, signature)) {
		return Result.err(tlsError("TlsDecryptError: ServerKeyExchange signature does not verify (scheme 0x" + scheme.toString(16) + ")"));
	}
	if (!supportedGroups(hs).includes(group)) return Result.err(tlsError("TlsIllegalParameter: ServerKeyExchange group not offered"));
	const clientPublic = publicKeyOf(hs, group);
	if (clientPublic == null) return Result.err(tlsError("TlsInsufficientEntropy: key exchange scalar out of range"));
	hs.preMasterSecret = try sharedSecretOf(hs, group, point);
	forgetKeyShares(hs);
	hs.clientPublic = clientPublic;
	hs.stage = Stage.ServerHelloDone;
	return Result.ok(null);
}

function onTls12CertificateRequest(hs: Tls13Handshake, body: Readonly<uint8[]>): Result<void, CryptoError> {
	const d = decoderOf(body);
	d.takeBytes(d.takeU8());
	d.takeBytes(d.takeU16());
	d.takeBytes(d.takeU16());
	if (d.bad || !d.done()) return Result.err(tlsError("TlsDecodeError: CertificateRequest"));
	hs.certificateRequested = true;
	return Result.ok(null);
}

/** Keys from the master secret (RFC 5246 6.3); AEAD suites take no MAC keys. */
function installTls12Keys(hs: Tls13Handshake): void {
	const suite = hs.suite;
	const kind = suite.hashKind;
	const seed = concatBytes(hs.clientRandom, hs.serverRandom);
	hs.masterSecret = tls12Prf(kind, hs.preMasterSecret, "master secret", seed, 48);
	const keyLength = suite.keyLength;
	const ivLength = tls12FixedIvLength(suite.code);
	const block = tls12Prf(kind, hs.masterSecret, "key expansion", concatBytes(hs.serverRandom, hs.clientRandom), 2 * keyLength + 2 * ivLength);
	const clientKey = block.slice(0, keyLength);
	const serverKey = block.slice(keyLength, 2 * keyLength);
	const clientIv = block.slice(2 * keyLength, 2 * keyLength + ivLength);
	const serverIv = block.slice(2 * keyLength + ivLength, 2 * keyLength + 2 * ivLength);
	hs.clientKeys = tls12TrafficKeysOf(suite, clientKey, clientIv);
	hs.pendingServerKeys = tls12TrafficKeysOf(suite, serverKey, serverIv);
	wipeBytes(block);
	wipeBytes(clientKey);
	wipeBytes(serverKey);
	wipeBytes(clientIv);
	wipeBytes(serverIv);
	wipeBytes(hs.preMasterSecret);
}

/** Answers ServerHelloDone with [Certificate], ClientKeyExchange, ChangeCipherSpec and the encrypted Finished. */
function onServerHelloDone(hs: Tls13Handshake, body: Readonly<uint8[]>, transport: TlsTransport): Result<void, CryptoError> {
	if (body.length != 0) return Result.err(tlsError("TlsDecodeError: ServerHelloDone"));
	const plain: uint8[] = [];
	if (hs.certificateRequested) {
		const certificate = handshakeMessage(handshakeCertificate, [0, 0, 0]);
		updateHash(hs.transcript, certificate);
		putBytes(plain, certificate);
	}
	const exchange: uint8[] = [];
	putU8(exchange, hs.clientPublic.length as int32);
	putBytes(exchange, hs.clientPublic);
	const keyExchange = handshakeMessage(handshakeClientKeyExchange, exchange);
	updateHash(hs.transcript, keyExchange);
	putBytes(plain, keyExchange);
	installTls12Keys(hs);
	const clientKeys = hs.clientKeys;
	if (clientKeys == null) return Result.err(tlsError("TlsUnexpectedMessage: no client keys"));
	const kind = hs.suite.hashKind;
	const finished = handshakeMessage(handshakeFinished, tls12Prf(kind, hs.masterSecret, "client finished", transcriptHash(hs), 12));
	updateHash(hs.transcript, finished);
	hs.expectedServerFinished = tls12Prf(kind, hs.masterSecret, "server finished", transcriptHash(hs), 12);
	wipeBytes(hs.masterSecret);
	const flight = plaintextRecords(contentHandshake, plain, versionTls12);
	putBytes(flight, [contentChangeCipherSpec as uint8, 0x03, 0x03, 0x00, 0x01, 0x01]);
	putBytes(flight, try sealed(clientKeys, contentHandshake, finished));
	if (!transport.send(flight)) return Result.err(connectionError("TlsWriteFailed"));
	hs.stage = Stage.Finished;
	return Result.ok(null);
}

function onTls12HandshakeMessage(
	hs: Tls13Handshake,
	type: int32,
	body: Readonly<uint8[]>,
	wrapped: Readonly<uint8[]>,
	transport: TlsTransport,
	verifier: CertificateVerifier,
): Result<void, CryptoError> {
	const stage = hs.stage;
	if (stage == Stage.Finished && type == handshakeFinished) {
		if (hs.serverKeys == null) return Result.err(tlsError("TlsUnexpectedMessage: Finished before ChangeCipherSpec"));
		if (!sameBytes(hs.expectedServerFinished, body)) return Result.err(tlsError("TlsDecryptError: server Finished does not verify"));
		hs.stage = Stage.Done;
		return Result.ok(null);
	}
	updateHash(hs.transcript, wrapped);
	if (stage == Stage.Certificate && type == handshakeCertificate) return onTls12Certificate(hs, body, verifier);
	if (stage == Stage.ServerKeyExchange && type == handshakeServerKeyExchange) return onServerKeyExchange(hs, body);
	if (stage == Stage.ServerHelloDone && type == handshakeCertificateRequest && !hs.certificateRequested) return onTls12CertificateRequest(hs, body);
	if (stage == Stage.ServerHelloDone && type == handshakeServerHelloDone) return onServerHelloDone(hs, body, transport);
	return Result.err(tlsError("TlsUnexpectedMessage: TLS 1.2 handshake type " + String(type)));
}

// ===== Records =====

/** The next whole record from `buffer`, receiving more from `transport` as needed. */
function readRecord(transport: TlsTransport, buffer: RecordBuffer): Result<Record, CryptoError> {
	while (true) {
		if (buffer.nextRecordLength() > maxCiphertextLength) return Result.err(connectionError("TlsRecordOverflow"));
		const record = buffer.takeRecord();
		if (record != null) return Result.ok(record);
		const chunk = transport.receive(maxCiphertextLength + recordHeaderLength);
		if (chunk.length == 0) return Result.err(connectionError("TlsConnectionTruncated"));
		buffer.append(chunk);
	}
}

function recordFailureText(failure: RecordFailure): string {
	return match (failure) {
		RecordFailure.BadRecordMac => "TlsBadRecordMac",
		RecordFailure.RecordOverflow => "TlsRecordOverflow",
		RecordFailure.DecodeError => "TlsDecodeError",
		RecordFailure.SequenceExhausted => "TlsSequenceExhausted: no record may follow under these keys",
	};
}

/** `sealRecords` with its failure as the connection's error. */
function sealed(keys: TrafficKeys, contentType: int32, data: Readonly<uint8[]>): Result<uint8[], CryptoError> {
	const records = sealRecords(keys, contentType, data);
	if (!records.ok) return Result.err(connectionError(recordFailureText(records.error)));
	return Result.ok(records.value);
}

/** RFC 8446 6 and RFC 5246 7.2 alert descriptions, code then name. */
const alertNames: Readonly<string[]> = [
	"0", "close_notify", "10", "unexpected_message", "20", "bad_record_mac", "22", "record_overflow",
	"40", "handshake_failure", "42", "bad_certificate", "43", "unsupported_certificate", "44", "certificate_revoked",
	"45", "certificate_expired", "46", "certificate_unknown", "47", "illegal_parameter", "48", "unknown_ca",
	"49", "access_denied", "50", "decode_error", "51", "decrypt_error", "70", "protocol_version",
	"71", "insufficient_security", "80", "internal_error", "86", "inappropriate_fallback", "90", "user_canceled",
	"100", "no_renegotiation", "109", "missing_extension", "110", "unsupported_extension", "112", "unrecognized_name",
	"113", "bad_certificate_status_response", "115", "unknown_psk_identity", "116", "certificate_required",
	"120", "no_application_protocol",
];

function alertName(description: int32): string {
	const code = String(description);
	for (let i = 0; i + 1 < alertNames.length; i += 2) {
		if (alertNames[i] == code) return alertNames[i + 1];
	}
	return "unknown";
}

function alertError(content: Readonly<uint8[]>): CryptoError {
	if (content.length != 2) return connectionError("TlsDecodeError: alert length");
	const description = content[1] as int32;
	return connectionError("TlsAlert: " + alertName(description) + " (level " + String(content[0]) + " description " + String(description) + ")");
}

/** Runs the handshake of `hs` over `transport`: sends its ClientHello, then reads until the server Finished is answered. */
export function completeHandshake(
	hs: Tls13Handshake,
	transport: TlsTransport,
	verifier: CertificateVerifier,
): Result<Tls13Client, CryptoError> {
	if (!transport.send(plaintextRecords(contentHandshake, hs.clientHello, 0x0301))) return Result.err(connectionError("TlsWriteFailed"));
	const buffer = newRecordBuffer();
	let messages: uint8[] = [];
	while (hs.stage != Stage.Done) {
		const record = try readRecord(transport, buffer);
		const serverKeys = hs.serverKeys;
		if (record.contentType == contentChangeCipherSpec) {
			if (record.body.length != 1 || record.body[0] != 1) return Result.err(tlsError("TlsUnexpectedMessage: change_cipher_spec"));
			if (hs.version == versionTls12) {
				if (hs.stage != Stage.Finished || serverKeys != null || messages.length > 0) return Result.err(tlsError("TlsUnexpectedMessage: change_cipher_spec"));
				hs.serverKeys = hs.pendingServerKeys;
			}
			continue;
		}
		if (serverKeys == null && record.body.length > maxPlaintextLength) return Result.err(tlsError("TlsRecordOverflow: plaintext record of " + String(record.body.length) + " bytes"));
		if (serverKeys == null && record.body.length == 0) return Result.err(tlsError("TlsDecodeError: empty plaintext record"));
		if (record.contentType == contentAlert && serverKeys == null) return Result.err(alertError(record.body));
		if (record.contentType == contentHandshake && serverKeys == null) {
			putBytes(messages, record.body);
		} else if (serverKeys != null && (serverKeys.tls12 || record.contentType == contentApplicationData)) {
			const opened = openRecord(serverKeys, record);
			if (!opened.ok) return Result.err(tlsError(recordFailureText(opened.error)));
			const inner = opened.value;
			if (inner.contentType == contentAlert) return Result.err(alertError(inner.content));
			if (inner.contentType != contentHandshake) return Result.err(tlsError("TlsUnexpectedMessage: content type " + String(inner.contentType) + " during handshake"));
			putBytes(messages, inner.content);
		} else if (record.contentType == contentHandshake) {
			return Result.err(tlsError("TlsUnexpectedMessage: plaintext handshake after ServerHello"));
		} else {
			return Result.err(tlsError("TlsUnexpectedMessage: record type " + String(record.contentType)));
		}
		while (messages.length >= 4 && hs.stage != Stage.Done) {
			const length = ((messages[1] as int32) << 16) | ((messages[2] as int32) << 8) | (messages[3] as int32);
			if (length > maxHandshakeMessageLength) return Result.err(tlsError("TlsDecodeError: handshake message of " + String(length) + " bytes"));
			if (messages.length < 4 + length) break;
			const type = messages[0] as int32;
			const wrapped = messages.slice(0, 4 + length);
			const body = messages.slice(4, 4 + length);
			messages = messages.slice(4 + length);
			const keysBefore = hs.serverKeys;
			try onHandshakeMessage(hs, type, body, wrapped, transport, verifier);
			if (keysBefore == null && hs.serverKeys != null && messages.length > 0) {
				return Result.err(tlsError("TlsUnexpectedMessage: handshake data spans the key change"));
			}
		}
	}
	if (messages.length > 0) return Result.err(tlsError("TlsUnexpectedMessage: handshake data after the server Finished"));
	let readKeys = hs.serverKeys;
	let writeKeys = hs.clientKeys;
	if (hs.version == versionTls13) {
		readKeys = trafficKeysOf(hs.suite, hs.schedule.serverApplicationSecret);
		writeKeys = trafficKeysOf(hs.suite, hs.schedule.clientApplicationSecret);
	}
	if (readKeys == null || writeKeys == null) return Result.err(tlsError("TlsUnexpectedMessage: handshake ended without traffic keys"));
	const client: Tls13Client = {
		transport,
		buffer,
		version: hs.version,
		readKeys,
		writeKeys,
		plaintext: [],
		receivedCloseNotify: false,
		sentCloseNotify: false,
		applicationProtocol: hs.applicationProtocol,
		peerCertificates: hs.chain,
		cipherSuite: hs.suite.code,
		helloRetried: hs.retried,
	};
	return Result.ok(client);
}

/** Builds a ClientHello from `options` and runs the handshake over `transport`. */
export function connectTls13(transport: TlsTransport, options: Tls13Options): Result<Tls13Client, CryptoError> {
	const hs = try newHandshake(options);
	return completeHandshake(hs, transport, options.verifier);
}

/** Offers TLS 1.3 and TLS 1.2 in one ClientHello and completes the version the server selects; `version` on the client names it. */
export function connectTls(transport: TlsTransport, options: Tls13Options): Result<Tls13Client, CryptoError> {
	const hs = try newHandshake(options, true);
	return completeHandshake(hs, transport, options.verifier);
}

// ===== Application data =====

/** An established TLS connection: TLS 1.3, or TLS 1.2 when `connectTls` negotiated it. */
export class Tls13Client {
	transport: TlsTransport;
	buffer: RecordBuffer;
	/** `versionTls13` or `versionTls12`. */
	version: int32;
	readKeys: TrafficKeys;
	writeKeys: TrafficKeys;
	/** Decrypted application data not yet returned by `read`. */
	plaintext: uint8[];
	receivedCloseNotify: boolean;
	sentCloseNotify: boolean;
	/** The ALPN protocol the server chose, or empty. */
	applicationProtocol: string;
	/** The server's certificate chain as sent, leaf first. */
	peerCertificates: uint8[][];
	cipherSuite: int32;
	/** True when the server answered the first ClientHello with a HelloRetryRequest. */
	helloRetried: boolean;
}

function sendKeyUpdate(c: Tls13Client, requestPeer: boolean): Result<void, CryptoError> {
	const message = handshakeMessage(handshakeKeyUpdate, [requestPeer ? 1 : 0]);
	if (!c.transport.send(try sealed(c.writeKeys, contentHandshake, message))) return Result.err(connectionError("TlsWriteFailed"));
	c.writeKeys = updatedTrafficKeys(c.writeKeys);
	return Result.ok(null);
}

function onPostHandshake(c: Tls13Client, content: Readonly<uint8[]>): Result<void, CryptoError> {
	let at = 0;
	while (at < content.length) {
		if (at + 4 > content.length) return Result.err(connectionError("TlsBadLength"));
		const type = content[at] as int32;
		const length = ((content[at + 1] as int32) << 16) | ((content[at + 2] as int32) << 8) | (content[at + 3] as int32);
		const next = at + 4 + length;
		if (next > content.length) return Result.err(connectionError("TlsBadLength"));
		if (c.version == versionTls12) {
			if (type != handshakeHelloRequest) return Result.err(connectionError("TlsUnexpectedMessage: post-handshake type " + String(type)));
		} else if (type == handshakeKeyUpdate) {
			if (length != 1) return Result.err(connectionError("TlsDecodeError: KeyUpdate"));
			const request = content[at + 4] as int32;
			if (request > 1) return Result.err(connectionError("TlsIllegalParameter: KeyUpdate request"));
			if (next != content.length) return Result.err(connectionError("TlsUnexpectedMessage: KeyUpdate is not the last message of its record"));
			c.readKeys = updatedTrafficKeys(c.readKeys);
			if (request == 1) try sendKeyUpdate(c, false);
		} else if (type != handshakeNewSessionTicket) {
			return Result.err(connectionError("TlsUnexpectedMessage: post-handshake type " + String(type)));
		}
		at = next;
	}
	return Result.ok(null);
}

/** Reads and handles one record; application data lands in `c.plaintext`. */
function pumpRecord(c: Tls13Client): Result<void, CryptoError> {
	const record = try readRecord(c.transport, c.buffer);
	const allowed = c.version == versionTls12 ? record.contentType != contentChangeCipherSpec : record.contentType == contentApplicationData;
	if (!allowed) return Result.err(connectionError("TlsUnexpectedMessage: record type " + String(record.contentType)));
	const opened = openRecord(c.readKeys, record);
	if (!opened.ok) return Result.err(connectionError(recordFailureText(opened.error)));
	const inner = opened.value;
	if (inner.contentType == contentApplicationData) {
		putBytes(c.plaintext, inner.content);
	} else if (inner.contentType == contentAlert) {
		if (inner.content.length == 2 && inner.content[1] == alertCloseNotify) {
			c.receivedCloseNotify = true;
		} else {
			return Result.err(alertError(inner.content));
		}
	} else if (inner.contentType == contentHandshake) {
		try onPostHandshake(c, inner.content);
	} else {
		return Result.err(connectionError("TlsUnexpectedMessage: content type " + String(inner.contentType)));
	}
	return Result.ok(null);
}

/** Up to `maxBytes` of application data; empty once the server sent close_notify. */
export function read(this c: Tls13Client, maxBytes: int32 = 16384): Result<uint8[], CryptoError> {
	while (c.plaintext.length == 0 && !c.receivedCloseNotify) try pumpRecord(c);
	const take = Math.min(c.plaintext.length, maxBytes) as int32;
	const out = c.plaintext.slice(0, take);
	c.plaintext = c.plaintext.slice(take);
	return Result.ok(out);
}

export function write(this c: Tls13Client, data: Readonly<uint8[]>): Result<void, CryptoError> {
	if (c.sentCloseNotify) return Result.err(connectionError("TLS connection is closed"));
	if (data.length == 0) return Result.ok(null);
	if (!c.transport.send(try sealed(c.writeKeys, contentApplicationData, data))) return Result.err(connectionError("TlsWriteFailed"));
	return Result.ok(null);
}

/** Sends a KeyUpdate and moves to the next write keys; `requestPeer` asks the server to update its keys too. */
export function updateKeys(this c: Tls13Client, requestPeer: boolean): Result<void, CryptoError> {
	if (c.sentCloseNotify) return Result.err(connectionError("TLS connection is closed"));
	if (c.version != versionTls13) return Result.err(connectionError("TlsUnexpectedMessage: KeyUpdate needs TLS 1.3"));
	return sendKeyUpdate(c, requestPeer);
}

/** Sends close_notify; later writes fail. */
export function close(this c: Tls13Client): Result<void, CryptoError> {
	if (c.sentCloseNotify) return Result.ok(null);
	c.sentCloseNotify = true;
	if (!c.transport.send(try sealed(c.writeKeys, contentAlert, [1, alertCloseNotify as uint8]))) return Result.err(connectionError("TlsWriteFailed"));
	return Result.ok(null);
}
