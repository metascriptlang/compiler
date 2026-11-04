/**
 * TLS 1.2 client checks on the portable kernels: the PRF against the
 * vendored mbedTLS vectors, the TLS 1.2 AEAD records' seal, open and
 * refusals, the ClientHello that offers both versions, and the ServerHello
 * checks a scripted server can reach without a key exchange.
 */

import { encodeHex, decodeHex } from "../../core/encoding";
import { kindSha256, kindSha384 } from "../pure/state";
import { tls12Prf } from "./keySchedule";
import {
	tls12CipherSuiteOf, tls12FixedIvLength, aeadTagLength,
	suiteEcdheRsaAes128GcmSha256, suiteEcdheEcdsaAes256GcmSha384, suiteEcdheEcdsaChacha20Poly1305Sha256,
} from "./aead";
import {
	TrafficKeys, Record, OpenFailure, tls12TrafficKeysOf, sealRecord, openRecord,
	contentApplicationData, contentHandshake, contentAlert,
} from "./record";
import { TlsTransport, Tls13Handshake, newHandshake, completeHandshake, entropyLength } from "./client";

class ScriptedTransport extends TlsTransport {
	incoming: uint8[];
	sent: uint8[];

	constructor(incoming: uint8[]) {
		super();
		this.incoming = incoming;
		this.sent = [];
	}

	receive(maxBytes: int32): uint8[] {
		const take = Math.min(this.incoming.length, maxBytes) as int32;
		const out = this.incoming.slice(0, take);
		this.incoming = this.incoming.slice(take);
		return out;
	}

	send(data: Readonly<uint8[]>): boolean {
		for (let i = 0; i < data.length; i++) this.sent.push(data[i]);
		return true;
	}
}

function refuseAll(chain: uint8[][], hostname: string): Result<void, string> {
	return Result.err("refused by test");
}

function counting(count: int32): uint8[] {
	const out = new Array<uint8>(count);
	for (let i = 0; i < count; i++) out[i] = i as uint8;
	return out;
}

function handshakeOffering(tls12: boolean): Tls13Handshake {
	const entropy = new Array<uint8>(entropyLength);
	for (let i = 0; i < entropyLength; i++) entropy[i] = (i + 1) as uint8;
	const started = newHandshake({ hostname: "example.com", verifier: refuseAll, entropy, alpn: ["http/1.1"] }, tls12);
	if (!started.ok) throw new Error(started.error.message);
	return started.value;
}

/** A plaintext record holding a ServerHello with `random`, `suite` and the hex `extensions`. */
function serverHelloRecord(hs: Tls13Handshake, random: Readonly<uint8[]>, suite: int32, extensions: string): uint8[] {
	const ext = extensions.decodeHex();
	const body: uint8[] = [0x03, 0x03, ...random, hs.sessionId.length as uint8, ...hs.sessionId];
	body.push(((suite >> 8) & 255) as uint8);
	body.push((suite & 255) as uint8);
	body.push(0);
	body.push(((ext.length >> 8) & 255) as uint8);
	body.push((ext.length & 255) as uint8);
	for (let i = 0; i < ext.length; i++) body.push(ext[i]);
	const message: uint8[] = [2, 0, ((body.length >> 8) & 255) as uint8, (body.length & 255) as uint8, ...body];
	return [22, 3, 3, ((message.length >> 8) & 255) as uint8, (message.length & 255) as uint8, ...message];
}

function sentinelRandom(last: int32): uint8[] {
	const random = counting(32);
	const marker = "444f574e475244".decodeHex();
	for (let i = 0; i < 7; i++) random[24 + i] = marker[i];
	random[31] = last as uint8;
	return random;
}

const emptyRenegotiationInfo = "ff01000100";

// vendor/mbedtls/tests/suites/test_suite_ssl.data, "SSL TLS_PRF MBEDTLS_SSL_TLS_PRF_SHA256" and "_SHA384"
const prfSecret = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
const prfSeed = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";

test "TLS 1.2 PRF matches the mbedTLS SHA-256 and SHA-384 vectors" {
	const secret = prfSecret.decodeHex();
	const seed = prfSeed.decodeHex();
	assert tls12Prf(kindSha256, secret, "test tls_prf label", seed, 16).encodeHex() == "7f9998393198a02c8d731ccc2ef90b2c";
	assert tls12Prf(kindSha384, secret, "test tls_prf label", seed, 16).encodeHex() == "a4206a36eef93f496611c2b7806625c3";
	const long = tls12Prf(kindSha256, secret, "test tls_prf label", seed, 100);
	assert long.length == 100 && long.slice(0, 16).encodeHex() == "7f9998393198a02c8d731ccc2ef90b2c";
}

function tls12Keys(code: int32): TrafficKeys {
	const suite = tls12CipherSuiteOf(code);
	if (suite == null) throw new Error("no suite " + String(code));
	const key = counting(suite.keyLength);
	return tls12TrafficKeysOf(suite, key, counting(tls12FixedIvLength(code)));
}

function recordOf(bytes: Readonly<uint8[]>): Record {
	return { contentType: bytes[0] as int32, header: bytes.slice(0, 5), body: bytes.slice(5) };
}

test "TLS 1.2 records seal and open under GCM with an explicit nonce and under ChaCha20-Poly1305 without one" {
	for (const code of [suiteEcdheRsaAes128GcmSha256, suiteEcdheEcdsaAes256GcmSha384, suiteEcdheEcdsaChacha20Poly1305Sha256]) {
		const writer = tls12Keys(code);
		const reader = tls12Keys(code);
		const explicit = code == suiteEcdheEcdsaChacha20Poly1305Sha256 ? 0 : 8;
		for (let n = 0; n < 3; n++) {
			const type = n == 1 ? contentHandshake : contentApplicationData;
			const sealed = sealRecord(writer, type, counting(n * 10), 0, n * 10);
			assert sealed[0] == type && sealed[1] == 3 && sealed[2] == 3;
			assert sealed.length == 5 + explicit + n * 10 + aeadTagLength;
			if (explicit == 8) assert sealed[12] == n;
			const opened = openRecord(reader, recordOf(sealed));
			assert opened.ok;
			assert opened.value.contentType == type;
			assert opened.value.content.encodeHex() == counting(n * 10).encodeHex();
		}
		assert writer.sequence == 3 && reader.sequence == 3;
	}
}

test "a tampered TLS 1.2 record, type, explicit nonce or sequence number is refused" {
	for (const code of [suiteEcdheRsaAes128GcmSha256, suiteEcdheEcdsaChacha20Poly1305Sha256]) {
		const writer = tls12Keys(code);
		const sealed = sealRecord(writer, contentApplicationData, counting(20), 0, 20);
		const reader = tls12Keys(code);
		const body = [...sealed];
		body[sealed.length - 20] = body[sealed.length - 20] ^ 1;
		const first = openRecord(reader, recordOf(body));
		assert !first.ok && first.error == OpenFailure.BadRecordMac;
		assert reader.sequence == 0;
		const retyped = [...sealed];
		retyped[0] = contentAlert as uint8;
		assert !openRecord(reader, recordOf(retyped)).ok;
		const nonce = [...sealed];
		nonce[6] = nonce[6] ^ 1;
		assert !openRecord(reader, recordOf(nonce)).ok;
		reader.sequence = 1;
		assert !openRecord(reader, recordOf(sealed)).ok;
		reader.sequence = 0;
		assert openRecord(reader, recordOf(sealed)).ok;
		const short = openRecord(reader, recordOf([23, 3, 3, 0, 4, 1, 2, 3, 4]));
		assert !short.ok && short.error == OpenFailure.RecordOverflow;
	}
}

test "the negotiating ClientHello offers TLS 1.3 and 1.2, ECDHE AEAD suites, P-384 and empty renegotiation_info" {
	const hello = handshakeOffering(true).clientHello.encodeHex();
	assert hello.includes("002b00050403040303");
	assert hello.includes("0012130313011302c02bc02fc02cc030cca9cca8");
	assert hello.includes("000a00080006001d00170018");
	assert hello.includes(emptyRenegotiationInfo);
	assert !hello.includes("00180061");
	const only13 = handshakeOffering(false).clientHello.encodeHex();
	assert only13.includes("002b0003020304");
	assert only13.includes("0006130313011302");
	assert !only13.includes(emptyRenegotiationInfo);
}

test "a TLS 1.2 ServerHello carrying the RFC 8446 downgrade sentinel is refused" {
	for (const last of [1, 0]) {
		const hs = handshakeOffering(true);
		const transport = new ScriptedTransport(serverHelloRecord(hs, sentinelRandom(last), suiteEcdheRsaAes128GcmSha256, emptyRenegotiationInfo));
		const done = completeHandshake(hs, transport, refuseAll);
		assert !done.ok;
		assert done.error.message.includes("downgraded");
	}
}

test "a TLS 1.2 ServerHello is followed only when TLS 1.2 was offered and renegotiation_info is empty" {
	const accepted = handshakeOffering(true);
	const plain = serverHelloRecord(accepted, counting(32), suiteEcdheRsaAes128GcmSha256, emptyRenegotiationInfo);
	const followed = completeHandshake(accepted, new ScriptedTransport(plain), refuseAll);
	assert !followed.ok && followed.error.message == "TlsConnectionTruncated";
	assert accepted.version == 0x0303;

	const only13 = handshakeOffering(false);
	const refused = completeHandshake(only13, new ScriptedTransport(serverHelloRecord(only13, counting(32), suiteEcdheRsaAes128GcmSha256, emptyRenegotiationInfo)), refuseAll);
	assert !refused.ok && refused.error.message.includes("TlsProtocolVersion");

	const insecure = handshakeOffering(true);
	const noRenegotiation = completeHandshake(insecure, new ScriptedTransport(serverHelloRecord(insecure, counting(32), suiteEcdheRsaAes128GcmSha256, "")), refuseAll);
	assert !noRenegotiation.ok && noRenegotiation.error.message.includes("secure renegotiation");

	const wrongSuite = handshakeOffering(true);
	const tls13Suite = completeHandshake(wrongSuite, new ScriptedTransport(serverHelloRecord(wrongSuite, counting(32), 0x1301, emptyRenegotiationInfo)), refuseAll);
	assert !tls13Suite.ok && tls13Suite.error.message.includes("cipher suite not offered");
}

test "a HelloRetryRequest for P-384 is answered with a single P-384 key share" {
	const hs = handshakeOffering(true);
	const retryRandom = "cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c".decodeHex();
	const transport = new ScriptedTransport(serverHelloRecord(hs, retryRandom, 0x1301, "002b00020304003300020018"));
	const done = completeHandshake(hs, transport, refuseAll);
	assert !done.ok && done.error.message == "TlsConnectionTruncated";
	assert hs.retried && hs.shareGroups.length == 1 && hs.shareGroups[0] == 0x0018;
	assert hs.clientHello.encodeHex().includes("00330067006500180061");
}
