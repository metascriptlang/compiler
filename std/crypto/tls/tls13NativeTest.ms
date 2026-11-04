/**
 * TLS 1.3 client checks on the portable kernels: the RFC 8448 section 3
 * "Simple 1-RTT Handshake" replayed byte for byte, HKDF-Expand-Label,
 * the RFC 8439 AEAD vector and the record layer's seal, open and refusals.
 */

import { encodeHex, decodeHex } from "../../core/encoding";
import { kindSha256 } from "../pure/state";
import { hkdfLabel, hkdfExpandLabel, deriveSecret, emptyHash } from "./keySchedule";
import {
	suiteAes128GcmSha256, suiteAes256GcmSha384, suiteChacha20Poly1305Sha256, cipherSuiteOf,
	chachaPolySeal, chachaPolyOpen, aeadSeal, aeadTagLength,
} from "./aead";
import {
	TrafficKeys, Record, OpenFailure, trafficKeysOf, sealRecord, openRecord, recordHeader, recordNonce,
	contentApplicationData, contentHandshake,
} from "./record";
import {
	TlsTransport, CertificateVerifier, Tls13Options, Tls13Handshake, newHandshake, completeHandshake, signatureAcceptable, read, write, close,
	entropyLength,
} from "./client";

const clientPrivate = "49af42ba7f7994852d713ef2784bcbcaa7911de26adc5642cb634540e7ea5005";
const clientHello =
	"010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d9912ec18a2ef" +
	"6283024dece7000006130113031302010000910000000b000900000673657276" +
	"6572ff01000100000a00140012001d0017001800190100010101020103010400" +
	"230000003300260024001d002099381de560e4bd43d23d8e435a7dbafeb3c06e" +
	"51c13cae4d5413691e529aaf2c002b0003020304000d0020001e040305030603" +
	"020308040805080604010501060102010402050206020202002d00020101001c" +
	"00024001";
const clientHelloRecord =
	"16030100c4010000c00303cb34ecb1e78163ba1c38c6dacb196a6dffa21a8d99" +
	"12ec18a2ef6283024dece7000006130113031302010000910000000b00090000" +
	"06736572766572ff01000100000a00140012001d001700180019010001010102" +
	"0103010400230000003300260024001d002099381de560e4bd43d23d8e435a7d" +
	"bafeb3c06e51c13cae4d5413691e529aaf2c002b0003020304000d0020001e04" +
	"0305030603020308040805080604010501060102010402050206020202002d00" +
	"020101001c00024001";
const serverHelloRecord =
	"160303005a020000560303a6af06a4121860dc5e6e60249cd34c95930c8ac5cb" +
	"1434dac155772ed3e2692800130100002e00330024001d0020c9828876112095" +
	"fe66762bdbf7c672e156d6cc253b833df1dd69b1b04e751f0f002b00020304";
const serverFlightRecord =
	"17030302a2d1ff334a56f5bff6594a07cc87b580233f500f45e489e7f33af35e" +
	"df7869fcf40aa40aa2b8ea73f848a7ca07612ef9f945cb960b4068905123ea78" +
	"b111b429ba9191cd05d2a389280f526134aadc7fc78c4b729df828b5ecf7b13b" +
	"d9aefb0e57f271585b8ea9bb355c7c79020716cfb9b1183ef3ab20e37d57a6b9" +
	"d7477609aee6e122a4cf51427325250c7d0e509289444c9b3a648f1d71035d2e" +
	"d65b0e3cdd0cbae8bf2d0b227812cbb360987255cc744110c453baa4fcd61092" +
	"8d809810e4b7ed1a8fd991f06aa6248204797e36a6a73b70a2559c09ead68694" +
	"5ba246ab66e5edd8044b4c6de3fcf2a89441ac66272fd8fb330ef8190579b368" +
	"4596c960bd596eea520a56a8d650f563aad27409960dca63d3e688611ea5e22f" +
	"4415cf9538d51a200c27034272968a264ed6540c84838d89f72c24461aad6d26" +
	"f59ecaba9acbbb317b66d902f4f292a36ac1b639c637ce343117b65962224531" +
	"7b49eeda0c6258f100d7d961ffb138647e92ea330faeea6dfa31c7a84dc3bd7e" +
	"1b7a6c7178af36879018e3f252107f243d243dc7339d5684c8b0378bf30244da" +
	"8c87c843f5e56eb4c5e8280a2b48052cf93b16499a66db7cca71e4599426f7d4" +
	"61e66f99882bd89fc50800becca62d6c74116dbd2972fda1fa80f85df881edbe" +
	"5a37668936b335583b599186dc5c6918a396fa48a181d6b6fa4f9d62d513afbb" +
	"992f2b992f67f8afe67f76913fa388cb5630c8ca01e0c65d11c66a1e2ac4c859" +
	"77b7c7a6999bbf10dc35ae69f5515614636c0b9b68c19ed2e31c0b3b66763038" +
	"ebba42f3b38edc0399f3a9f23faa63978c317fc9fa66a73f60f0504de93b5b84" +
	"5e275592c12335ee340bbc4fddd502784016e4b3be7ef04dda49f4b440a30cb5" +
	"d2af939828fd4ae3794e44f94df5a631ede42c1719bfdabf0253fe5175be898e" +
	"750edc53370d2b";
const earlySecret = "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a";
const derivedForHandshake = "6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba";
const handshakeSecret = "1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac";
const clientHandshakeTraffic = "b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21";
const serverHandshakeTraffic = "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38";
const masterSecret = "18df06843d13a08bf2a449844c5f8a478001bc4d4c627984d5a41da8d0402919";
const serverHandshakeKey = "3fce516009c21727d0f2e4e86ee403bc";
const serverHandshakeIv = "5d313eb2671276ee13000b30";
const clientApTraffic = "9e40646ce79a7f9dc05af8889bce6552875afa0b06df0087f792ebb7c17504a5";
const serverApTraffic = "a11af9f05531f856ad47116b45a950328204b4f44bfb6b3a4b4f1f3fcb631643";
const serverApKey = "9f02283b6c9c07efc26bb9f2ac92e356";
const serverApIv = "cf782b88dd83549aadf1e984";
const clientHandshakeKey = "dbfaa693d1762c5b666af5d950258d01";
const clientHandshakeIv = "5bd3c71b836e0b76bb73265f";
const serverFinishedKey = "008d3b66f816ea559f96b537e885c31fc068bf492c652f01f288a1d8cdc19fc8";
const clientFinishedKey = "b80ad01015fb2f0bd65ff7d4da5d6bf83f84821d1f87fdc7d3c75b5a7b42d9c4";
const clientFinishedRecord =
	"170303003575ec4dc238cce60b298044a71e219c56cc77b0517fe9b93c7a4bfc" +
	"44d87f38f80338ac98fc46deb384bd1caeacab6867d726c40546";
const clientApKey = "17422dda596ed5d9acd890e3c63f5051";
const clientApIv = "5b78923dee08579033e523d9";
const ticketRecord =
	"17030300de3a6b8f90414a97d6959c3487680de5134a2b240e6cffac116e95d4" +
	"1d6af8f6b580dcf3d11d63c758db289a015940252f55713e061dc13e078891a3" +
	"8efbcf5753ad8ef170ad3c7353d16d9da773b9ca7f2b9fa1b6c0d4a3d03f75e0" +
	"9c30ba1e62972ac46f75f7b981be63439b2999ce13064615139891d5e4c5b406" +
	"f16e3fc181a77ca475840025db2f0a77f81b5ab05b94c01346755f69232c8651" +
	"9d86cbeeac87aac347d143f9605d64f650db4d023e70e952ca49fe5137121c74" +
	"bc2697687e248746d6df353005f3bce18696129c8153556b3b6c6779b37bf159" +
	"85684f";
const clientDataRecord =
	"1703030043a23f7054b62c94d0affafe8228ba55cbefacea42f914aa66bcab3f" +
	"2b9819a8a5b46b395bd54a9a20441e2b62974e1f5a6292a2977014bd1e3deae6" +
	"3aeebb21694915e4";
const serverDataRecord =
	"17030300432e937e11ef4ac740e538ad36005fc4a46932fc3225d05f82aa1b36" +
	"e30efaf97d90e6dffc602dcb501a59a8fcc49c4bf2e5f0a21c0047c2abf33254" +
	"0dd032e167c2955d";
const clientAlertRecord = "1703030013c9872760655666b74d7ff1153efd6db6d0b0e3";
const serverAlertRecord = "1703030013b58fd67166ebf599d24720cfbe7efa7a8864a9";

const certificateVerify =
	"0f000084080400805a747c5d88fa9bd2e55ab085a61015b7211f824cd484145a" +
	"b3ff52f1fda8477b0b7abc90db78e2d33a5c141a078653fa6bef780c5ea248ee" +
	"aaa785c4f394cab6d30bbe8d4859ee511f602957b15411ac027671459e46445c" +
	"9ea58c181e818e95b8c3fb0bf3278409d3be152a3da5043e063dda65cdf5aea2" +
	"0d53dfacd42f74f3";

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

function joined(parts: string[]): uint8[] {
	const out: uint8[] = [];
	for (const part of parts) {
		const bytes = part.decodeHex();
		for (let i = 0; i < bytes.length; i++) out.push(bytes[i]);
	}
	return out;
}

function counting(count: int32): uint8[] {
	const out = new Array<uint8>(count);
	for (let i = 0; i < count; i++) out[i] = i as uint8;
	return out;
}

/** Test only: the trace's server presents one self-signed certificate for "server". */
function traceVerifier(chain: uint8[][], hostname: string): Result<void, string> {
	if (chain.length != 1 || hostname != "server") return Result.err("unexpected chain or hostname");
	return Result.ok(null);
}

function refuseAll(chain: uint8[][], hostname: string): Result<void, string> {
	return Result.err("refused by test");
}

/** A handshake whose ClientHello, session id and X25519 key are the trace's. */
function traceHandshake(verifier: CertificateVerifier): Tls13Handshake {
	const options: Tls13Options = { hostname: "server", verifier, entropy: new Array<uint8>(entropyLength), alpn: [] };
	const started = newHandshake(options);
	if (!started.ok) throw new Error(started.error.message);
	const hs = started.value;
	hs.clientHello = clientHello.decodeHex();
	hs.sessionId = [];
	hs.x25519Private = clientPrivate.decodeHex();
	return hs;
}

test "RFC 8448 3: HKDF-Expand-Label and Derive-Secret" {
	assert hkdfLabel("key", [], 16).encodeHex() == "001009746c733133206b657900";
	assert hkdfLabel("iv", [], 12).encodeHex() == "000c08746c73313320697600";
	const traffic = serverHandshakeTraffic.decodeHex();
	assert hkdfExpandLabel(kindSha256, traffic, "key", [], 16).encodeHex() == serverHandshakeKey;
	assert hkdfExpandLabel(kindSha256, traffic, "iv", [], 12).encodeHex() == serverHandshakeIv;
	assert hkdfExpandLabel(kindSha256, traffic, "finished", [], 32).encodeHex() == serverFinishedKey;
	assert deriveSecret(kindSha256, earlySecret.decodeHex(), "derived", emptyHash(kindSha256)).encodeHex() == derivedForHandshake;
}

test "RFC 8448 3: the simple 1-RTT handshake replays byte for byte" {
	const hs = traceHandshake(traceVerifier);
	const transport = new ScriptedTransport(joined([serverHelloRecord, serverFlightRecord]));
	const done = completeHandshake(hs, transport, traceVerifier);
	if (!done.ok) console.log(done.error.message);
	assert done.ok;
	const client = done.value;

	assert hs.schedule.earlySecret.encodeHex() == earlySecret;
	assert hs.schedule.handshakeSecret.encodeHex() == handshakeSecret;
	assert hs.schedule.clientHandshakeSecret.encodeHex() == clientHandshakeTraffic;
	assert hs.schedule.serverHandshakeSecret.encodeHex() == serverHandshakeTraffic;
	assert hs.schedule.masterSecret.encodeHex() == masterSecret;
	assert hs.schedule.clientApplicationSecret.encodeHex() == clientApTraffic;
	assert hs.schedule.serverApplicationSecret.encodeHex() == serverApTraffic;
	const serverKeys = hs.serverKeys;
	const clientKeys = hs.clientKeys;
	assert serverKeys != null && clientKeys != null;
	assert serverKeys.key.key.encodeHex() == serverHandshakeKey;
	assert serverKeys.iv.encodeHex() == serverHandshakeIv;
	assert clientKeys.key.key.encodeHex() == clientHandshakeKey;
	assert clientKeys.iv.encodeHex() == clientHandshakeIv;
	assert client.readKeys.key.key.encodeHex() == serverApKey;
	assert client.readKeys.iv.encodeHex() == serverApIv;
	assert client.writeKeys.key.key.encodeHex() == clientApKey;
	assert client.writeKeys.iv.encodeHex() == clientApIv;
	assert client.peerCertificates.length == 1;
	assert transport.sent.encodeHex() == clientHelloRecord + clientFinishedRecord;
	const signature = certificateVerify.decodeHex().slice(8);
	assert !signatureAcceptable(client.peerCertificates[0], 0x0804, counting(10), signature);
	assert !signatureAcceptable(client.peerCertificates[0], 0x0401, counting(10), signature);

	transport.sent = [];
	transport.incoming = joined([ticketRecord, serverDataRecord, serverAlertRecord]);
	assert client.write(counting(50)).ok;
	assert transport.sent.encodeHex() == clientDataRecord;
	const data = try client.read() catch [];
	assert data.encodeHex() == counting(50).encodeHex();
	transport.sent = [];
	assert client.close().ok;
	assert transport.sent.encodeHex() == clientAlertRecord;
	const after = try client.read() catch [1];
	assert after.length == 0 && client.receivedCloseNotify;
	assert !client.write(counting(1)).ok;
}

test "the handshake fails when the verifier refuses the chain" {
	const hs = traceHandshake(refuseAll);
	const transport = new ScriptedTransport(joined([serverHelloRecord, serverFlightRecord]));
	const done = completeHandshake(hs, transport, refuseAll);
	assert !done.ok;
	assert done.error.message.includes("refused by test");
}

test "a flipped byte in the encrypted flight fails the handshake" {
	const hs = traceHandshake(traceVerifier);
	const bytes = joined([serverHelloRecord, serverFlightRecord]);
	bytes[200] = bytes[200] ^ 1;
	const done = completeHandshake(hs, new ScriptedTransport(bytes), traceVerifier);
	assert !done.ok;
	assert done.error.message == "TlsBadRecordMac";
}

test "a truncated server flight fails as truncated" {
	const hs = traceHandshake(traceVerifier);
	const bytes = joined([serverHelloRecord, serverFlightRecord]).slice(0, 300);
	const done = completeHandshake(hs, new ScriptedTransport(bytes), traceVerifier);
	assert !done.ok;
	assert done.error.message == "TlsConnectionTruncated";
}

test "the ClientHello offers TLS 1.3, SNI, ALPN http/1.1 and both key shares" {
	const entropy = new Array<uint8>(entropyLength);
	for (let i = 0; i < entropyLength; i++) entropy[i] = (i + 1) as uint8;
	const started = newHandshake({ hostname: "example.com", verifier: refuseAll, entropy, alpn: ["http/1.1"] });
	assert started.ok;
	const hs = started.value;
	const hello = hs.clientHello.encodeHex();
	assert hello.startsWith("01");
	assert hello.includes("002b0003020304");
	assert hello.includes("6578616d706c652e636f6d");
	assert hello.includes("0010000b000908687474702f312e31");
	assert hello.includes("001d0020");
	assert hello.includes("00170041");
	assert hello.includes("0006130313011302");
	const short = newHandshake({ hostname: "", verifier: refuseAll, entropy: [1, 2, 3], alpn: [] });
	assert !short.ok;
}

test "RFC 8439 2.8.2 ChaCha20-Poly1305 vector, and a flipped tag is refused" {
	const key = "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f".decodeHex();
	const nonce = "070000004041424344454647".decodeHex();
	const aad = "50515253c0c1c2c3c4c5c6c7".decodeHex();
	const plain = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".asBytes().slice(0);
	const sealed = chachaPolySeal(key, nonce, aad, plain);
	const hex = sealed.encodeHex();
	assert hex.startsWith("d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6");
	assert hex.endsWith("61161ae10b594f09e26a7e902ecbd0600691");
	const opened = chachaPolyOpen(key, nonce, aad, sealed);
	assert opened != null && opened.encodeHex() == plain.encodeHex();
	sealed[sealed.length - 1] = sealed[sealed.length - 1] ^ 0x80;
	assert chachaPolyOpen(key, nonce, aad, sealed) == null;
}

function keysFor(code: int32): TrafficKeys {
	const suite = cipherSuiteOf(code);
	if (suite == null) throw new Error("no suite " + String(code));
	const secret = new Array<uint8>(code == suiteAes256GcmSha384 ? 48 : 32);
	secret[0] = 7;
	return trafficKeysOf(suite, secret);
}

function recordOf(bytes: Readonly<uint8[]>): Record {
	return { contentType: bytes[0] as int32, header: bytes.slice(0, 5), body: bytes.slice(5) };
}

test "records seal and open under every suite, with sequence numbers in step" {
	for (const code of [suiteAes128GcmSha256, suiteAes256GcmSha384, suiteChacha20Poly1305Sha256]) {
		const writer = keysFor(code);
		const reader = keysFor(code);
		for (let n = 0; n < 3; n++) {
			const sealed = sealRecord(writer, contentHandshake, counting(n * 10), 0, n * 10);
			assert sealed[0] == 23 && sealed[1] == 3 && sealed[2] == 3;
			assert sealed.length == 5 + n * 10 + 1 + aeadTagLength;
			const opened = openRecord(reader, recordOf(sealed));
			assert opened.ok;
			assert opened.value.contentType == contentHandshake;
			assert opened.value.content.encodeHex() == counting(n * 10).encodeHex();
		}
		assert writer.sequence == 3 && reader.sequence == 3;
	}
}

test "a tampered record, header or sequence number is refused" {
	const writer = keysFor(suiteAes128GcmSha256);
	const sealed = sealRecord(writer, contentApplicationData, counting(20), 0, 20);
	const body = [...sealed];
	body[9] = body[9] ^ 1;
	const reader = keysFor(suiteAes128GcmSha256);
	const first = openRecord(reader, recordOf(body));
	assert !first.ok && first.error == OpenFailure.BadRecordMac;
	assert reader.sequence == 0;
	const header = [...sealed];
	header[2] = 1;
	assert !openRecord(reader, recordOf(header)).ok;
	reader.sequence = 1;
	assert !openRecord(reader, recordOf(sealed)).ok;
	reader.sequence = 0;
	assert openRecord(reader, recordOf(sealed)).ok;
	const short = recordOf([23, 3, 3, 0, 4, 1, 2, 3, 4]);
	const tooShort = openRecord(reader, short);
	assert !tooShort.ok && tooShort.error == OpenFailure.RecordOverflow;
}

test "padding is stripped and an all-zero inner plaintext is refused" {
	const writer = keysFor(suiteChacha20Poly1305Sha256);
	const reader = keysFor(suiteChacha20Poly1305Sha256);
	const inner: uint8[] = [0xaa, 0xbb, contentApplicationData as uint8, 0, 0, 0, 0, 0];
	const header = recordHeader(contentApplicationData, inner.length as int32 + aeadTagLength);
	const padded = [...header];
	const sealed = aeadSeal(writer.key, recordNonce(writer.iv, 0), header, inner);
	for (let i = 0; i < sealed.length; i++) padded.push(sealed[i]);
	const opened = openRecord(reader, recordOf(padded));
	assert opened.ok && opened.value.contentType == contentApplicationData;
	assert opened.value.content.encodeHex() == "aabb";
	const zeros = new Array<uint8>(6);
	const zeroHeader = recordHeader(contentApplicationData, 6 + aeadTagLength);
	const zeroRecord = [...zeroHeader];
	const zeroSealed = aeadSeal(writer.key, recordNonce(writer.iv, 1), zeroHeader, zeros);
	for (let i = 0; i < zeroSealed.length; i++) zeroRecord.push(zeroSealed[i]);
	const refused = openRecord(reader, recordOf(zeroRecord));
	assert !refused.ok && refused.error == OpenFailure.DecodeError;
}

test "the nonce xors the big-endian sequence number into the IV's last 8 bytes" {
	const iv = "5d313eb2671276ee13000b30".decodeHex();
	assert recordNonce(iv, 0).encodeHex() == "5d313eb2671276ee13000b30";
	assert recordNonce(iv, 1).encodeHex() == "5d313eb2671276ee13000b31";
	assert recordNonce(iv, 0x0102030405060708).encodeHex() == "5d313eb2661075ea16060c38";
}
