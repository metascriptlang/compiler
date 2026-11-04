/**
 * The std/crypto/tls API (tlsConnect, read, write, close, peerCert) over the
 * MetaScript TLS 1.3 client: a blocking std/net socket, OS random bytes for
 * the handshake, and the server chain checked by x509.ms against the root
 * store. Private until the public index switches to it; it keeps the
 * index's error kinds, messages and timeout behaviour.
 */

import {
	createSocket, connect as connectSocket, send as sendSocket,
	recv as receiveSocket, recvTimedOut, close as closeSocket,
	setTimeout as setSocketTimeout,
} from "std/net";
import { Buffer } from "std/core/buffer";
import { Bytes } from "std/core/buffer/bytes";
import { encodeHex } from "../../core/encoding";
import { CryptoError, CryptoErrorKind, cryptoError } from "../errors";
import {
	TlsTransport, Tls13Client, CertificateVerifier, connectTls13,
	entropyLength, read as clientRead, write as clientWrite,
	close as clientClose,
} from "./client";
import {
	X509Bundle, X509Certificate, X509Error, parseCertificate, verifyChain,
	parseIp4, parseIp6,
} from "./x509";
import { derElementAt } from "./der";
import { RootStore, loadRootStore, defaultRootStore } from "./rootStore";

when (c) {
	@include("runtime/crypto/randomFill.h");
	extern function osRandomFill(
		buffer: Ptr<uint8>,
		length: uint64,
	): int32 from "ms_random_fill";
}

// `operation` of the error tlsConnect returns when the connect or handshake wait ran out.
export const tlsConnectTimeoutOperation = "tlsConnect:timeout";

export const tlsClosedMessage = "TLS connection is closed";

export interface TlsOptions {
	caPath?: string;
	timeoutMs?: int32;
}

class SocketTransport extends TlsTransport {
	fd: int32;
	/** True when the last receive ended because the socket's wait ran out. */
	timedOut: boolean;

	constructor(fd: int32) {
		super();
		this.fd = fd;
		this.timedOut = false;
	}

	receive(maxBytes: int32): uint8[] {
		const chunk: uint8[] = receiveSocket(this.fd, maxBytes);
		this.timedOut = chunk.length == 0 && recvTimedOut();
		return chunk;
	}

	send(data: Readonly<uint8[]>): boolean {
		const bytes: uint8[] = [...data];
		return sendSocket(this.fd, bytes) == bytes.length;
	}
}

// An open TLS connection, blocking. Dropping it closes it; close() earlier is allowed and a second close,
// or a read or write after it, fails with tlsClosedMessage and never reaches the socket again.
export class TlsConnection {
	_client: Tls13Client | null;
	_transport: SocketTransport;
	// After an empty read: "" is a clean close_notify, anything else is why the stream ended.
	lastError: string;
	// True when the last read failed because its wait ran out.
	timedOut: boolean;

	constructor(client: Tls13Client, transport: SocketTransport) {
		this._client = client;
		this._transport = transport;
		this.lastError = "";
		this.timedOut = false;
	}
}

function connectFailed(message: string): CryptoError {
	return cryptoError(CryptoErrorKind.ConnectionFailed, "tlsConnect", message);
}

function connectTimedOut(message: string): CryptoError {
	return cryptoError(CryptoErrorKind.ConnectionFailed, tlsConnectTimeoutOperation, message);
}

function nowSeconds(): int64 {
	return Math.floor(Date.now() / 1000) as int64;
}

function bundleOf(store: RootStore, now: int64): X509Bundle {
	const bundle = new X509Bundle();
	for (const anchor of store.anchors) bundle.addDer(anchor.der, now);
	return bundle;
}

/** The roots of `caPath`, else the default store; parsed per connect, since no cache may cross threads. */
function rootsFor(caPath: string, now: int64): Result<X509Bundle, CryptoError> {
	const store = caPath != "" ? loadRootStore(caPath) : defaultRootStore();
	if (!store.ok) return Result.err(connectFailed(store.error.message));
	return Result.ok(bundleOf(store.value, now));
}

function verifyText(error: X509Error): string {
	return match (error) {
		X509Error.Expired => "The certificate validity has expired",
		X509Error.NotYetValid => "The certificate validity starts in the future",
		X509Error.HostMismatch => "The certificate Common Name (CN) does not match with the expected CN",
		X509Error.IssuerNotFound | X509Error.IssuerMismatch | X509Error.IssuerNotCa |
			X509Error.SignatureInvalid => "The certificate is not correctly signed by the trusted CA",
		_ => error.toString(),
	};
}

function verifyServer(
	chain: uint8[][],
	hostname: string,
	roots: X509Bundle,
	now: int64,
): Result<void, string> {
	const parsed: X509Certificate[] = [];
	for (const der of chain) {
		const certificate = parseCertificate(der);
		if (!certificate.ok) return Result.err(verifyText(certificate.error));
		parsed.push(certificate.value);
	}
	const verdict = verifyChain(parsed, roots, hostname, now);
	if (!verdict.ok) return Result.err(verifyText(verdict.error));
	return Result.ok(null);
}

/** `entropyLength` bytes from the OS CSPRNG, or null when the source failed. */
function handshakeEntropy(): uint8[] | null {
	when (c) {
		const out = new Array<uint8>(entropyLength);
		const span: Span<uint8> = out;
		if (osRandomFill(span as Ptr<uint8>, entropyLength as uint64) != 0) return null;
		return out;
	} else {
		return null;
	}
}

function isIpLiteral(hostname: string): boolean {
	return parseIp4(hostname) != null || parseIp6(hostname) != null;
}

const certificateRejected = "TlsCertificateNotVerified: ";

function handshakeError(error: CryptoError, transport: SocketTransport): CryptoError {
	if (transport.timedOut) return connectTimedOut("TLS handshake timed out");
	const message = error.message;
	if (error.kind == CryptoErrorKind.CertificateError && message.startsWith(certificateRejected)) {
		return connectFailed("certificate verification failed: " + message.slice(certificateRejected.length));
	}
	if (message == "TlsConnectionTruncated") return connectFailed("TLS handshake failed: connection closed by the peer");
	return connectFailed("TLS handshake failed: " + message);
}

export function tlsConnect(hostname: string, port: int32, opts: TlsOptions = {}): Result<TlsConnection, CryptoError> {
	if (hostname.asBytes().length > 255) return Result.err(connectFailed("hostname is longer than 255 bytes"));
	const caPath = opts.caPath ?? "";
	if (caPath.asBytes().length > 511) return Result.err(connectFailed("CA path is longer than 511 bytes"));
	const timeoutMs = opts.timeoutMs ?? 0;
	const now = nowSeconds();
	const roots = try rootsFor(caPath, now);

	const fd = createSocket();
	if (fd < 0) return Result.err(connectFailed(`TCP connect to ${hostname} failed`));
	if (timeoutMs > 0) setSocketTimeout(fd, timeoutMs);
	const started = Date.now();
	if (connectSocket(fd, hostname, port) != 0) {
		closeSocket(fd);
		if (timeoutMs > 0 && Date.now() - started >= timeoutMs) {
			return Result.err(connectTimedOut(`TCP connect to ${hostname} timed out`));
		}
		return Result.err(connectFailed(`TCP connect to ${hostname} failed`));
	}

	const entropy = handshakeEntropy();
	if (entropy == null) {
		closeSocket(fd);
		return Result.err(connectFailed("TLS handshake failed: random byte generation failed"));
	}
	const verifier: CertificateVerifier = (chain: uint8[][], name: string): Result<void, string> =>
		verifyServer(chain, hostname, roots, now);
	const transport = new SocketTransport(fd);
	const connected = connectTls13(transport, {
		hostname: isIpLiteral(hostname) ? "" : hostname,
		verifier,
		entropy: entropy as uint8[],
		alpn: ["http/1.1"],
	});
	if (!connected.ok) {
		closeSocket(fd);
		return Result.err(handshakeError(connected.error, transport));
	}
	return Result.ok(new TlsConnection(connected.value, transport));
}

export function read(this conn: TlsConnection, maxBytes: int32 = 4096): Buffer {
	const client = conn._client;
	conn.timedOut = false;
	if (client == null) {
		conn.lastError = tlsClosedMessage;
		return new Array<uint8>(0) as Buffer;
	}
	conn.lastError = "";
	if (maxBytes <= 0) return new Array<uint8>(0) as Buffer;
	conn._transport.timedOut = false;
	const got = clientRead(client, maxBytes);
	if (got.ok) return got.value as Buffer;
	conn.timedOut = conn._transport.timedOut;
	const message = got.error.message;
	if (conn.timedOut) conn.lastError = "TLS read timed out";
	else if (message == "TlsConnectionTruncated") conn.lastError = "TLS connection closed without close_notify";
	else conn.lastError = "TLS read failed: " + message;
	return new Array<uint8>(0) as Buffer;
}

// Bytes written, 0 for empty data, -1 on failure.
export function write(this conn: TlsConnection, data: Bytes): int32 {
	const client = conn._client;
	conn.timedOut = false;
	if (client == null) {
		conn.lastError = tlsClosedMessage;
		return -1;
	}
	const bytes: uint8[] = typeof data == "string" ? data.asBytes().slice(0) : data;
	if (bytes.length == 0) {
		conn.lastError = "";
		return 0;
	}
	const sent = clientWrite(client, bytes);
	conn.lastError = sent.ok ? "" : "TLS write failed";
	return sent.ok ? bytes.length as int32 : -1;
}

export function close(this conn: TlsConnection): void {
	const client = conn._client;
	if (client == null) return;
	conn._client = null;
	clientClose(client);
	closeSocket(conn._transport.fd);
}

const attributeNames: Readonly<string[]> = [
	"550403", "CN",
	"550406", "C",
	"550407", "L",
	"550408", "ST",
	"55040a", "O",
	"55040b", "OU",
	"2a864886f70d010901", "emailAddress",
	"550405", "serialNumber",
	"550410", "postalAddress",
	"550411", "postalCode",
	"550404", "SN",
	"55042a", "GN",
	"55042b", "initials",
	"55042c", "generationQualifier",
	"55040c", "title",
	"55042e", "dnQualifier",
	"550441", "pseudonym",
	"0992268993f22c640101", "uid",
	"0992268993f22c640119", "DC",
	"55042d", "uniqueIdentifier",
];

function attributeName(oidHex: string): string | null {
	for (let i = 0; i + 1 < attributeNames.length; i += 2) {
		if (attributeNames[i] == oidHex) return attributeNames[i + 1];
	}
	return null;
}

/** An OID's content octets in dotted form, or null when they do not decode. */
function dottedOid(octets: Readonly<uint8[]>): string | null {
	if (octets.length == 0) return null;
	let out = "";
	let arc: int64 = 0;
	let first = true;
	for (let i = 0; i < octets.length; i++) {
		const octet = octets[i] as int64;
		if (arc > 0x00ffffffffffff) return null;
		arc = (arc << 7) | (octet & 0x7f);
		if ((octet & 0x80) != 0) continue;
		if (first) {
			const top: int64 = arc < 40 ? 0 : arc < 80 ? 1 : 2;
			out = `${top}.${arc - top * 40}`;
			first = false;
		} else {
			out += `.${arc}`;
		}
		arc = 0;
	}
	return (octets[octets.length - 1] & 0x80) != 0 ? null : out;
}

const tagUtf8String: int32 = 0x0c;
const tagPrintableString: int32 = 0x13;
const tagIa5String: int32 = 0x16;
const hexDigits = "0123456789ABCDEF";

function hexByte(octet: int32): string {
	return hexDigits.slice(octet >> 4, (octet >> 4) + 1) + hexDigits.slice(octet & 15, (octet & 15) + 1);
}

/** RFC 4514 section 2.4 escaping, bytes outside printable ASCII as `\HH`; null for a NUL byte. */
function escapedValue(octets: Readonly<uint8[]>): string | null {
	let out = "";
	const last = octets.length - 1;
	for (let i = 0; i < octets.length; i++) {
		const octet = octets[i] as int32;
		if (octet == 0) return null;
		const one = String.fromCharCode(octet);
		const special = ",=+<>;\"\\".includes(one) || (i == 0 && (one == "#" || one == " ")) || (i == last && one == " ");
		if (special) out += "\\";
		out += octet < 32 || octet >= 127 ? "\\" + hexByte(octet) : one;
	}
	return out;
}

/**
 * A Name's content as mbedTLS prints it (`CN=host, O=org`): RDNs in encoded order, a multi-valued
 * RDN joined by ` + `, a value that is not UTF8, Printable or IA5 String as `#` and its DER in hex,
 * an attribute without a short name by its dotted OID. Empty when it does not fit 255 bytes.
 */
export function distinguishedNameText(name: Readonly<uint8[]>): string {
	let out = "";
	let at = 0;
	const end = name.length as int32;
	while (at < end) {
		const rdn = derElementAt(name, at, end);
		if (rdn == null) return "";
		let inner = rdn.start;
		let first = true;
		while (inner < rdn.end) {
			const pair = derElementAt(name, inner, rdn.end);
			if (pair == null) return "";
			const type = derElementAt(name, pair.start, pair.end);
			if (type == null) return "";
			const value = derElementAt(name, type.end, pair.end);
			if (value == null) return "";
			if (out.length > 0) out += first ? ", " : " + ";
			const oid = name.slice(type.start, type.end);
			const label = attributeName(encodeHex(oid));
			const tag = value.identifier;
			let hex = tag != tagUtf8String && tag != tagPrintableString && tag != tagIa5String;
			if (label != null) {
				out += label + "=";
			} else {
				const dotted = dottedOid(oid);
				out += dotted != null ? dotted + "=" : "??=";
				if (dotted != null) hex = true;
			}
			if (hex) {
				out += "#";
				for (let i = type.end; i < value.end; i++) out += hexByte(name[i] as int32);
			} else {
				const text = escapedValue(name.slice(value.start, value.end));
				if (text == null) return "";
				out += text;
			}
			first = false;
			inner = pair.end;
		}
		at = rdn.end;
	}
	return out.asBytes().length > 255 ? "" : out;
}

export function peerCert(this conn: TlsConnection): string {
	const client = conn._client;
	if (client == null || client.peerCertificates.length == 0) return "";
	const leaf = parseCertificate(client.peerCertificates[0]);
	if (!leaf.ok) return "";
	return distinguishedNameText(leaf.value.subject);
}

function onDestroy(this conn: TlsConnection): void {
	conn.close();
}

test "a distinguished name prints as RDNs in order with escaped values" {
	// SET{ CN=a,b } SET{ O=x + OU=y }
	const name: uint8[] = [
		0x31, 0x0c, 0x30, 0x0a, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0c, 0x03, 0x61, 0x2c, 0x62,
		0x31, 0x14,
		0x30, 0x08, 0x06, 0x03, 0x55, 0x04, 0x0a, 0x0c, 0x01, 0x78,
		0x30, 0x08, 0x06, 0x03, 0x55, 0x04, 0x0b, 0x0c, 0x01, 0x79,
	];
	assert distinguishedNameText(name) == "CN=a\\,b, O=x + OU=y";
}

test "a distinguished name prints short names, dotted OIDs and hex values like mbedTLS" {
	// SET{ C=US (PrintableString) } SET{ DC=" #x" (IA5String) } SET{ 1.2.3=z } SET{ CN=BMPString "a" }
	const name: uint8[] = [
		0x31, 0x0b, 0x30, 0x09, 0x06, 0x03, 0x55, 0x04, 0x06, 0x13, 0x02, 0x55, 0x53,
		0x31, 0x13, 0x30, 0x11, 0x06, 0x0a, 0x09, 0x92, 0x26, 0x89, 0x93, 0xf2, 0x2c, 0x64, 0x01, 0x19,
		0x16, 0x03, 0x20, 0x23, 0x78,
		0x31, 0x09, 0x30, 0x07, 0x06, 0x02, 0x2a, 0x03, 0x0c, 0x01, 0x7a,
		0x31, 0x0b, 0x30, 0x09, 0x06, 0x03, 0x55, 0x04, 0x03, 0x1e, 0x02, 0x00, 0x61,
	];
	assert distinguishedNameText(name) == "C=US, DC=\\ #x, 1.2.3=#0C017A, CN=#1E020061";
}
