/**
 * A TLS 1.3 client (RFC 8446) over any byte stream: ClientHello with SNI,
 * ALPN, X25519 and P-256 key shares; the server's encrypted flight with
 * its certificate chain handed to a caller-supplied verifier and its
 * CertificateVerify checked with the portable signature kernels; then
 * application data, KeyUpdate and close_notify.
 */

import { CryptoError, CryptoErrorKind, cryptoError } from "../errors";
import { HashState, kindSha256, kindSha384 } from "../pure/state";
import { newHash, copyHash, updateHash, finishHash, hashOf } from "../pure/hash";
import { x25519 } from "../pure/x25519";
import { p256 } from "../pure/p256";
import { p384 } from "../pure/p384";
import { ownCurve, ecPublicPoint, ecdhShared, ecPublicFromSpki, ecdsaDerToRaw, ecdsaVerifyRaw } from "../pure/weierstrass";
import { ed25519Verify } from "../pure/ed25519";
import { RsaPublicData, rsaVerifyPss } from "../pure/rsa";
import { derItem, derChildren, derUnsigned, derSame, tagSequence, tagBitString, tagOid, oidRsaEncryption } from "../pure/asn1";
import { bigFromBytes } from "../pure/bigint";
import { CipherSuite, cipherSuiteOf, suiteAes128GcmSha256, suiteAes256GcmSha384, suiteChacha20Poly1305Sha256 } from "./aead";
import { KeySchedule, handshakeSchedule, applicationSchedule, finishedVerifyData } from "./keySchedule";
import {
	TrafficKeys, Record, RecordBuffer, OpenFailure, trafficKeysOf, updatedTrafficKeys, plaintextRecords,
	sealRecords, openRecord, newRecordBuffer, recordHeaderLength, maxCiphertextLength,
	contentChangeCipherSpec, contentAlert, contentHandshake, contentApplicationData,
} from "./record";

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

/** Bytes of `Tls13Options.entropy` one handshake reads: client random, session id and both key-share scalars. */
export const entropyLength: int32 = 128;

export interface Tls13Options {
	/** Sent as SNI and handed to the verifier; empty sends no SNI. */
	hostname: string;
	verifier: CertificateVerifier;
	/** At least `entropyLength` bytes from a cryptographically secure source; read only while building the ClientHello. */
	entropy: uint8[];
	/** ALPN protocols in preference order; empty sends no ALPN extension. */
	alpn: string[];
}

const handshakeClientHello: int32 = 1;
const handshakeServerHello: int32 = 2;
const handshakeNewSessionTicket: int32 = 4;
const handshakeEncryptedExtensions: int32 = 8;
const handshakeCertificate: int32 = 11;
const handshakeCertificateRequest: int32 = 13;
const handshakeCertificateVerify: int32 = 15;
const handshakeFinished: int32 = 20;
const handshakeKeyUpdate: int32 = 24;
const handshakeMessageHash: int32 = 254;

const extensionServerName: int32 = 0;
const extensionSupportedGroups: int32 = 10;
const extensionSignatureAlgorithms: int32 = 13;
const extensionAlpn: int32 = 16;
const extensionSupportedVersions: int32 = 43;
const extensionCookie: int32 = 44;
const extensionPskKeyExchangeModes: int32 = 45;
const extensionKeyShare: int32 = 51;

const groupX25519: int32 = 0x001d;
const groupSecp256r1: int32 = 0x0017;

const schemeEcdsaSecp256r1Sha256: int32 = 0x0403;
const schemeEcdsaSecp384r1Sha384: int32 = 0x0503;
const schemeRsaPssRsaeSha256: int32 = 0x0804;
const schemeRsaPssRsaeSha384: int32 = 0x0805;
const schemeRsaPssRsaeSha512: int32 = 0x0806;
const schemeEd25519: int32 = 0x0807;
const schemeRsaPkcs1Sha256: int32 = 0x0401;
const schemeRsaPkcs1Sha384: int32 = 0x0501;
const schemeRsaPkcs1Sha512: int32 = 0x0601;

const versionTls13: int32 = 0x0304;
const alertCloseNotify: int32 = 0;

const offeredSuites: Readonly<int32[]> = [suiteChacha20Poly1305Sha256, suiteAes128GcmSha256, suiteAes256GcmSha384];

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
}

function clientHelloOf(hs: Tls13Handshake, cookie: Readonly<uint8[]>): uint8[] {
	const body: uint8[] = [];
	putU16(body, 0x0303);
	putBytes(body, hs.clientRandom);
	putU8(body, hs.sessionId.length as int32);
	putBytes(body, hs.sessionId);
	putU16(body, 2 * (offeredSuites.length as int32));
	for (const suite of offeredSuites) putU16(body, suite);
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
	putExtension(extensions, extensionSupportedVersions, [2, 0x03, 0x04]);
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
	putExtension(extensions, extensionSupportedGroups, [0, 4, 0x00, 0x1d, 0x00, 0x17]);
	putExtension(extensions, extensionPskKeyExchangeModes, [1, 1]);
	const shares: uint8[] = [];
	putU16(shares, groupX25519);
	const x25519Public = x25519(hs.x25519Private, x25519BasePoint());
	putU16(shares, x25519Public.length as int32);
	putBytes(shares, x25519Public);
	const p256Public = ecPublicPoint(p256, hs.p256Private);
	if (p256Public != null) {
		putU16(shares, groupSecp256r1);
		putU16(shares, p256Public.length as int32);
		putBytes(shares, p256Public);
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

/** A handshake with its ClientHello built from `options.entropy`. */
export function newHandshake(options: Tls13Options): Result<Tls13Handshake, CryptoError> {
	const entropy = options.entropy;
	if (entropy.length < entropyLength) return Result.err(tlsError("TlsInsufficientEntropy: options.entropy needs " + String(entropyLength) + " bytes"));
	const hs: Tls13Handshake = {
		hostname: options.hostname,
		alpn: [...options.alpn],
		clientRandom: entropy.slice(0, 32),
		sessionId: entropy.slice(32, 64),
		x25519Private: entropy.slice(64, 96),
		p256Private: entropy.slice(96, 128),
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
	while (!extensions.done()) {
		const type = extensions.takeU16();
		const body = decoderOf(extensions.takeBytes(extensions.takeU16()));
		if (type == extensionSupportedVersions) version = body.takeU16();
		else if (type == extensionCookie) cookie = body.takeBytes(body.takeU16());
		else if (type == extensionKeyShare) return Result.err(tlsError("TlsIllegalParameter: HelloRetryRequest for a group whose share was sent"));
		if (body.bad) return Result.err(tlsError("TlsDecodeError: HelloRetryRequest extension"));
	}
	if (d.bad || extensions.bad) return Result.err(tlsError("TlsDecodeError: HelloRetryRequest"));
	if (version != versionTls13) return Result.err(tlsError("TlsProtocolVersion: HelloRetryRequest is not TLS 1.3"));
	if (!sameBytes(sessionEcho, hs.sessionId)) return Result.err(tlsError("TlsIllegalParameter: session id echo"));
	const suite = cipherSuiteOf(code);
	if (suite == null || !offered(code)) return Result.err(tlsError("TlsIllegalParameter: cipher suite not offered"));
	if (cookie.length == 0) return Result.err(tlsError("TlsIllegalParameter: HelloRetryRequest changes nothing"));
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
	const extensions = decoderOf(d.takeBytes(d.takeU16()));
	let version = 0;
	let group = -1;
	let share: uint8[] = [];
	while (!extensions.done()) {
		const type = extensions.takeU16();
		const ext = decoderOf(extensions.takeBytes(extensions.takeU16()));
		if (type == extensionSupportedVersions) {
			if (version != 0) return Result.err(tlsError("TlsIllegalParameter: duplicate supported_versions"));
			version = ext.takeU16();
		} else if (type == extensionKeyShare) {
			if (group != -1) return Result.err(tlsError("TlsIllegalParameter: duplicate key_share"));
			group = ext.takeU16();
			share = ext.takeBytes(ext.takeU16());
		}
		if (ext.bad) return Result.err(tlsError("TlsDecodeError: ServerHello extension"));
	}
	if (d.bad || extensions.bad) return Result.err(tlsError("TlsDecodeError: ServerHello"));
	if (version != versionTls13) return Result.err(tlsError("TlsProtocolVersion: server did not select TLS 1.3"));
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
	hs.serverKeys = trafficKeysOf(suite, hs.schedule.serverHandshakeSecret);
	hs.clientKeys = trafficKeysOf(suite, hs.schedule.clientHandshakeSecret);
	hs.stage = Stage.EncryptedExtensions;
	return Result.ok(null);
}

function onEncryptedExtensions(hs: Tls13Handshake, body: Readonly<uint8[]>): Result<void, CryptoError> {
	const d = decoderOf(body);
	const extensions = decoderOf(d.takeBytes(d.takeU16()));
	while (!extensions.done()) {
		const type = extensions.takeU16();
		const ext = decoderOf(extensions.takeBytes(extensions.takeU16()));
		if (type == extensionAlpn) {
			const list = decoderOf(ext.takeBytes(ext.takeU16()));
			const chosen = list.takeBytes(list.takeU8());
			if (list.bad || !list.done() || chosen.length == 0) return Result.err(tlsError("TlsDecodeError: ALPN"));
			let name = "";
			for (const protocol of hs.alpn) {
				if (sameBytes(protocol.asBytes().slice(0), chosen)) name = protocol;
			}
			if (name.length == 0) return Result.err(tlsError("TlsNoApplicationProtocol: server chose an ALPN protocol not offered"));
			hs.applicationProtocol = name;
		}
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
		list.takeBytes(list.takeU16());
	}
	if (d.bad || list.bad || !d.done()) return Result.err(tlsError("TlsDecodeError: Certificate"));
	if (chain.length == 0) return Result.err(tlsError("TlsCertificateRequired: empty server certificate chain"));
	const verdict = verifier(chain, hs.hostname);
	if (!verdict.ok) return Result.err(cryptoError(CryptoErrorKind.CertificateError, "tls13", "TlsCertificateNotVerified: " + verdict.error));
	hs.chain = chain;
	hs.stage = Stage.CertificateVerify;
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
	return { n: bigFromBytes(modulus), e: bigFromBytes(exponent) };
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
		putBytes(flight, sealRecords(clientKeys, contentHandshake, message));
	}
	const verifyData = finishedVerifyData(kind, hs.schedule.clientHandshakeSecret, transcriptHash(hs));
	const finished = handshakeMessage(handshakeFinished, verifyData);
	updateHash(hs.transcript, finished);
	putBytes(flight, sealRecords(clientKeys, contentHandshake, finished));
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

function openFailureText(failure: OpenFailure): string {
	return match (failure) {
		OpenFailure.BadRecordMac => "TlsBadRecordMac",
		OpenFailure.RecordOverflow => "TlsRecordOverflow",
		OpenFailure.DecodeError => "TlsDecodeError",
	};
}

function alertError(content: Readonly<uint8[]>): CryptoError {
	if (content.length != 2) return connectionError("TlsDecodeError: alert length");
	return connectionError("TlsAlert: level " + String(content[0]) + " description " + String(content[1]));
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
			continue;
		}
		if (record.contentType == contentAlert && serverKeys == null) return Result.err(alertError(record.body));
		if (record.contentType == contentHandshake) {
			if (serverKeys != null) return Result.err(tlsError("TlsUnexpectedMessage: plaintext handshake after ServerHello"));
			putBytes(messages, record.body);
		} else if (record.contentType == contentApplicationData && serverKeys != null) {
			const opened = openRecord(serverKeys, record);
			if (!opened.ok) return Result.err(tlsError(openFailureText(opened.error)));
			const inner = opened.value;
			if (inner.contentType == contentAlert) return Result.err(alertError(inner.content));
			if (inner.contentType != contentHandshake) return Result.err(tlsError("TlsUnexpectedMessage: content type " + String(inner.contentType) + " during handshake"));
			putBytes(messages, inner.content);
		} else {
			return Result.err(tlsError("TlsUnexpectedMessage: record type " + String(record.contentType)));
		}
		while (messages.length >= 4 && hs.stage != Stage.Done) {
			const length = ((messages[1] as int32) << 16) | ((messages[2] as int32) << 8) | (messages[3] as int32);
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
	const client: Tls13Client = {
		transport,
		buffer,
		readKeys: trafficKeysOf(hs.suite, hs.schedule.serverApplicationSecret),
		writeKeys: trafficKeysOf(hs.suite, hs.schedule.clientApplicationSecret),
		plaintext: [],
		receivedCloseNotify: false,
		sentCloseNotify: false,
		applicationProtocol: hs.applicationProtocol,
		peerCertificates: hs.chain,
		cipherSuite: hs.suite.code,
	};
	return Result.ok(client);
}

/** Builds a ClientHello from `options` and runs the handshake over `transport`. */
export function connectTls13(transport: TlsTransport, options: Tls13Options): Result<Tls13Client, CryptoError> {
	const hs = try newHandshake(options);
	return completeHandshake(hs, transport, options.verifier);
}

// ===== Application data =====

/** An established TLS 1.3 connection. */
export class Tls13Client {
	transport: TlsTransport;
	buffer: RecordBuffer;
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
}

function sendKeyUpdate(c: Tls13Client, requestPeer: boolean): Result<void, CryptoError> {
	const message = handshakeMessage(handshakeKeyUpdate, [requestPeer ? 1 : 0]);
	if (!c.transport.send(sealRecords(c.writeKeys, contentHandshake, message))) return Result.err(connectionError("TlsWriteFailed"));
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
		if (type == handshakeKeyUpdate) {
			if (length != 1) return Result.err(connectionError("TlsDecodeError: KeyUpdate"));
			const request = content[at + 4] as int32;
			if (request > 1) return Result.err(connectionError("TlsIllegalParameter: KeyUpdate request"));
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
	if (record.contentType != contentApplicationData) return Result.err(connectionError("TlsUnexpectedMessage: record type " + String(record.contentType)));
	const opened = openRecord(c.readKeys, record);
	if (!opened.ok) return Result.err(connectionError(openFailureText(opened.error)));
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
	if (!c.transport.send(sealRecords(c.writeKeys, contentApplicationData, data))) return Result.err(connectionError("TlsWriteFailed"));
	return Result.ok(null);
}

/** Sends a KeyUpdate and moves to the next write keys; `requestPeer` asks the server to update its keys too. */
export function updateKeys(this c: Tls13Client, requestPeer: boolean): Result<void, CryptoError> {
	if (c.sentCloseNotify) return Result.err(connectionError("TLS connection is closed"));
	return sendKeyUpdate(c, requestPeer);
}

/** Sends close_notify; later writes fail. */
export function close(this c: Tls13Client): Result<void, CryptoError> {
	if (c.sentCloseNotify) return Result.ok(null);
	c.sentCloseNotify = true;
	if (!c.transport.send(sealRecords(c.writeKeys, contentAlert, [1, alertCloseNotify as uint8]))) return Result.err(connectionError("TlsWriteFailed"));
	return Result.ok(null);
}
