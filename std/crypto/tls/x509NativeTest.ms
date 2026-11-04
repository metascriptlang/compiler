/**
 * The fixture tree: rootRsa (RSA-2048 CA) issues interP384 (P-384 CA), which issues leafRsa, leafP256
 * and leafP384; rootEd (Ed25519 CA) issues leafEd; otherRoot reuses rootRsa's subject with a P-256 key;
 * leafP256, a non-CA, issues byLeaf.
 */

import {
	X509Certificate, X509Error, X509Bundle, SignatureAlgorithm, PublicKeyAlgorithm, NamedCurve,
	parseCertificate, pemCertificates, parseTime, verifyCertificate, verifyChain, verifyHostName,
	hostNameMatches, ipAddressMatches, parseIp6, keyUsageDigitalSignature, keyUsageKeyCertSign,
} from "./x509";
import { DerElement } from "./der";
import {
	rootRsaPem, otherRootPem, rootEdPem, interP384Pem, leafRsaPem, leafP256Pem, leafP384Pem, leafEdPem,
	byLeafPem, constraintsRootPem, pathZeroPem, subCaPem, deepLeafPem, shallowLeafPem, clientLeafPem, agreeLeafPem,
	criticalLeafPem, namedCaPem, namedLeafPem,
} from "./x509Fixtures";
import { encodeHex } from "../../core/encoding";

const notBefore: int64 = 1735689600;
const notAfter: int64 = 2051222400;
const now: int64 = 1767225600;

function derOf(pem: string): uint8[] {
	const blocks = pemCertificates(pem);
	if (!blocks.ok || blocks.value.length != 1) throw new Error("fixture PEM did not split into one block");
	return blocks.value[0];
}

function certificateOf(pem: string): X509Certificate {
	const parsed = parseCertificate(derOf(pem));
	if (!parsed.ok) throw new Error(`fixture did not parse: ${parsed.error.toString()}`);
	return parsed.value;
}

function trustedRoots(): X509Bundle {
	const roots = new X509Bundle();
	const added = roots.addPem(rootRsaPem + rootEdPem, now);
	if (!added.ok) throw new Error("fixture roots did not load");
	return roots;
}

function chainError(chain: X509Certificate[], roots: X509Bundle, host: string | null, at: int64): string {
	const result = verifyChain(chain, roots, host, at);
	return result.ok ? "ok" : result.error.toString();
}

test "an RSA leaf's fields parse" {
	const leaf = certificateOf(leafRsaPem);
	assert leaf.version == 3;
	assert encodeHex(leaf.serialNumber) == "1001";
	assert leaf.signatureAlgorithm == SignatureAlgorithm.EcdsaWithSha384;
	assert leaf.commonName == "rsa.example.com";
	assert leaf.notBefore == notBefore && leaf.notAfter == notAfter;
	assert leaf.publicKeyAlgorithm == PublicKeyAlgorithm.Rsa && leaf.namedCurve == NamedCurve.None;
	assert encodeHex(leaf.publicKey.slice(0, 4)) == "3082010a";
	assert leaf.dnsNames.length == 2 && leaf.dnsNames[0] == "rsa.example.com" && leaf.dnsNames[1] == "*.wild.example.com";
	assert leaf.ipAddresses.length == 2;
	assert encodeHex(leaf.ipAddresses[0]) == "7f000001";
	assert encodeHex(leaf.ipAddresses[1]) == "00000000000000000000000000000001";
	assert leaf.hasBasicConstraints && !leaf.isCa && leaf.pathLength == -1;
	assert leaf.keyUsage == (1 << keyUsageDigitalSignature);
	assert encodeHex(leaf.issuer) == encodeHex(certificateOf(interP384Pem).subject);
	assert leaf.signature.length > 64;
}

test "EC and Ed25519 keys parse with their curve and raw key" {
	const p256Leaf = certificateOf(leafP256Pem);
	assert p256Leaf.publicKeyAlgorithm == PublicKeyAlgorithm.Ec && p256Leaf.namedCurve == NamedCurve.P256;
	assert p256Leaf.signatureAlgorithm == SignatureAlgorithm.EcdsaWithSha256;
	assert p256Leaf.publicKey.length == 65 && p256Leaf.publicKey[0] == 4;
	const p384Leaf = certificateOf(leafP384Pem);
	assert p384Leaf.namedCurve == NamedCurve.P384 && p384Leaf.publicKey.length == 97;
	assert encodeHex(p384Leaf.publicKey.slice(0, 10)) == "042100c02bf9b4ad7112";
	const edLeaf = certificateOf(leafEdPem);
	assert edLeaf.publicKeyAlgorithm == PublicKeyAlgorithm.Ed25519;
	assert edLeaf.signatureAlgorithm == SignatureAlgorithm.Ed25519 && edLeaf.signature.length == 64;
	assert encodeHex(edLeaf.publicKey) == "ffc550e0d9babf5c83c19f43db69d4a16ff45b9f8664a9b67f5970dceb849cd5";
	assert edLeaf.dnsNames.length == 1 && edLeaf.dnsNames[0] == "ed.example.com";
}

test "a CA certificate carries the CA flag and keyCertSign" {
	const intermediate = certificateOf(interP384Pem);
	assert intermediate.hasBasicConstraints && intermediate.isCa;
	assert (intermediate.keyUsage & (1 << keyUsageKeyCertSign)) != 0;
	assert intermediate.signatureAlgorithm == SignatureAlgorithm.Sha256WithRsa;
	assert intermediate.commonName == "Test Intermediate CA";
	const root = certificateOf(rootRsaPem);
	assert encodeHex(intermediate.issuer) == encodeHex(root.subject);
	assert encodeHex(root.issuer) == encodeHex(root.subject);
}

test "each signature algorithm verifies against its issuer's key" {
	const root = certificateOf(rootRsaPem);
	const intermediate = certificateOf(interP384Pem);
	const edRoot = certificateOf(rootEdPem);
	assert verifyCertificate(root, root, now).ok;
	assert verifyCertificate(intermediate, root, now).ok;
	assert verifyCertificate(certificateOf(leafRsaPem), intermediate, now).ok;
	assert verifyCertificate(certificateOf(leafP256Pem), intermediate, now).ok;
	assert verifyCertificate(certificateOf(leafP384Pem), intermediate, now).ok;
	assert verifyCertificate(edRoot, edRoot, now).ok;
	assert verifyCertificate(certificateOf(leafEdPem), edRoot, now).ok;
}

test "a valid chain verifies to a trusted root with the host checked" {
	const roots = trustedRoots();
	assert roots.certificates.length == 2;
	const intermediate = certificateOf(interP384Pem);
	assert chainError([certificateOf(leafRsaPem), intermediate], roots, "rsa.example.com", now) == "ok";
	assert chainError([certificateOf(leafP256Pem), intermediate], roots, "p256.example.com", now) == "ok";
	assert chainError([certificateOf(leafP384Pem), intermediate], roots, "p384.example.com", now) == "ok";
	assert chainError([certificateOf(leafEdPem)], roots, "ed.example.com", now) == "ok";
	assert chainError([certificateOf(leafRsaPem), intermediate, certificateOf(rootRsaPem)], roots, null, now) == "ok";
}

test "a chain to the wrong root, a missing root or a non-CA issuer fails" {
	const intermediate = certificateOf(interP384Pem);
	const leaf = certificateOf(leafP256Pem);
	const impostor = new X509Bundle();
	assert impostor.addPem(otherRootPem, now).ok;
	assert chainError([leaf, intermediate], impostor, "p256.example.com", now) == X509Error.SignatureAlgorithmMismatch.toString();
	const edOnly = new X509Bundle();
	assert edOnly.addPem(rootEdPem, now).ok;
	assert chainError([leaf, intermediate], edOnly, "p256.example.com", now) == X509Error.IssuerNotFound.toString();
	assert chainError([leaf], trustedRoots(), "p256.example.com", now) == X509Error.IssuerNotFound.toString();
	const byLeaf = certificateOf(byLeafPem);
	assert verifyCertificate(byLeaf, leaf, now).ok;
	assert chainError([byLeaf, leaf, intermediate], trustedRoots(), "byleaf.example.com", now) == X509Error.IssuerNotCa.toString();
	assert chainError([], trustedRoots(), null, now) == X509Error.EmptyChain.toString();
}

test "validity is checked at the given time" {
	const roots = trustedRoots();
	const chain = [certificateOf(leafP384Pem), certificateOf(interP384Pem)];
	assert chainError(chain, roots, "p384.example.com", notAfter) == "ok";
	assert chainError(chain, roots, "p384.example.com", notAfter + 1) == X509Error.Expired.toString();
	assert chainError(chain, roots, "p384.example.com", notBefore - 1) == X509Error.NotYetValid.toString();
}

test "a bundle skips a root that expired before now and a duplicate subject" {
	const expired = new X509Bundle();
	assert expired.addPem(rootRsaPem, notAfter + 1).ok;
	assert expired.certificates.length == 0;
	const duplicate = new X509Bundle();
	assert duplicate.addPem(rootRsaPem + otherRootPem, now).ok;
	assert duplicate.certificates.length == 1;
	assert duplicate.certificates[0].publicKeyAlgorithm == PublicKeyAlgorithm.Rsa;
}

test "a kept bundle refuses a root that expired after it was added" {
	const roots = trustedRoots();
	const chain = [certificateOf(leafP384Pem), certificateOf(interP384Pem)];
	assert chainError(chain, roots, "p384.example.com", now) == "ok";
	for (const root of roots.certificates) root.notAfter = now - 1;
	assert chainError(chain, roots, "p384.example.com", now) == X509Error.Expired.toString();
}

test "a tampered certificate fails its signature" {
	const der = derOf(leafP256Pem);
	const parsed = parseCertificate(der);
	assert parsed.ok;
	assert der[15] == 0x10 && der[16] == 0x02;
	der[16] = 0x03;
	const tampered = parseCertificate(der);
	assert tampered.ok;
	const result = verifyCertificate(tampered.value, certificateOf(interP384Pem), now);
	assert !result.ok && result.error == X509Error.SignatureInvalid;
}

test "host names match exactly or through one leftmost wildcard label" {
	assert hostNameMatches("ziglang.org", "ziglang.org");
	assert hostNameMatches("ziglang.org", "Ziglang.org");
	assert hostNameMatches("ZIGLANG.ORG", "ziglang.org");
	assert hostNameMatches("bar.ziglang.org", "*.ziglang.org");
	assert hostNameMatches("BAR.ziglang.org", "*.Ziglang.ORG");
	assert !hostNameMatches("foo.bar.ziglang.org", "*.ziglang.org");
	assert !hostNameMatches("ziglang.org", "*.ziglang.org");
	assert !hostNameMatches(".ziglang.org", "*.ziglang.org");
	assert !hostNameMatches("ziglang.org", "zig*.org");
	assert !hostNameMatches("ziglang.org", "*lang.org");
	assert !hostNameMatches("ziglang.org", "zi*ng.org");
	assert !hostNameMatches("foo.bar.org", "*.*.org");
	assert !hostNameMatches("foo.bar.org", "foo.*.org");
	assert !hostNameMatches("localhost", "*.local");
	assert !hostNameMatches("localhost", "*.localhost");
	assert !hostNameMatches("", "");
	assert !hostNameMatches("example.com", "");
	assert !hostNameMatches("", "*.example.com");
	assert !hostNameMatches("example.com", "*");
	assert !hostNameMatches("example.com", "*.");
}

test "IP addresses match the SAN's exact octets" {
	assert ipAddressMatches("127.0.0.1", [127, 0, 0, 1]);
	assert ipAddressMatches("0:0:0:0:0:0:0:1", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
	assert ipAddressMatches("::1", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
	assert !ipAddressMatches("1.2.3.4", [5, 6, 7, 8]);
	assert !ipAddressMatches("0:0:0:0:0:0:0:1", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]);
	assert !ipAddressMatches("64:ff9b::192.0.2.10", [192, 0, 2, 10]);
	assert !ipAddressMatches("::ffff:127.0.0.1", [127, 0, 0, 1]);
	assert !ipAddressMatches("127.0.0", [127, 0, 0]);
	assert !ipAddressMatches("127.0.0.1.0", [127, 0, 0, 1, 0]);
	assert !ipAddressMatches("not-an-ip", [127, 0, 0, 1]);
	assert !ipAddressMatches("127.0.0.01", [127, 0, 0, 1]);
	assert !ipAddressMatches("256.0.0.1", [0, 0, 0, 1]);
	assert !ipAddressMatches("", []);
	assert !ipAddressMatches("127.0.0.1", []);
	assert encodeHex(parseIp6("::ffff:127.0.0.1") as uint8[]) == "00000000000000000000ffff7f000001";
	assert encodeHex(parseIp6("2001:db8::8:800:200c:417a") as uint8[]) == "20010db80000000000080800200c417a";
	assert parseIp6("1::2::3") == null && parseIp6(":1::") == null && parseIp6("1:2:3:4:5:6:7:8:9") == null;
	assert parseIp6("1:2:3:4:5:6:7:") == null && parseIp6("12345::") == null;
}

test "a certificate's host check uses its SAN entries" {
	const leaf = certificateOf(leafRsaPem);
	assert verifyHostName(leaf, "rsa.example.com").ok;
	assert verifyHostName(leaf, "RSA.Example.COM").ok;
	assert verifyHostName(leaf, "a.wild.example.com").ok;
	assert verifyHostName(leaf, "127.0.0.1").ok;
	assert verifyHostName(leaf, "::1").ok;
	assert !verifyHostName(leaf, "a.b.wild.example.com").ok;
	assert !verifyHostName(leaf, "wild.example.com").ok;
	assert !verifyHostName(leaf, "127.0.0.2").ok;
	assert !verifyHostName(leaf, "other.example.com").ok;
	const intermediate = certificateOf(interP384Pem);
	assert chainError([leaf, intermediate], trustedRoots(), "other.example.com", now) == X509Error.HostMismatch.toString();
}

test "UTCTime years map per RFC 5280 and malformed times are refused" {
	const at49 = "490101000000Z".asBytes().slice(0);
	const range: DerElement = { identifier: 0x17, start: 0, end: 13 };
	const year2049 = parseTime(at49, range);
	assert year2049.ok && year2049.value == 2493072000;
	const year1999 = parseTime("990101000000Z".asBytes().slice(0), range);
	assert year1999.ok && year1999.value == 915148800;
	const general: DerElement = { identifier: 0x18, start: 0, end: 15 };
	const generalized = parseTime("20350101000000Z".asBytes().slice(0), general);
	assert generalized.ok && generalized.value == notAfter;
	assert !parseTime("991301000000Z".asBytes().slice(0), range).ok;
	assert !parseTime("99010100000aZ".asBytes().slice(0), range).ok;
	assert !parseTime("9901010000000".asBytes().slice(0), range).ok;
}

test "malformed DER is refused" {
	const der = derOf(leafEdPem);
	assert parseCertificate(der).ok;
	assert !parseCertificate([]).ok;
	assert !parseCertificate(der.slice(0, der.length - 1)).ok;
	const trailing = der.slice(0);
	trailing.push(0);
	const trailingResult = parseCertificate(trailing);
	assert !trailingResult.ok && trailingResult.error == X509Error.FieldHasInvalidLength;
	const longer = der.slice(0);
	longer[3] = (longer[3] + 1) as uint8;
	assert !parseCertificate(longer).ok;
	const notSequence = der.slice(0);
	notSequence[0] = 0x31;
	const wrongType = parseCertificate(notSequence);
	assert !wrongType.ok && wrongType.error == X509Error.FieldHasWrongDataType;
	const indefinite = der.slice(0);
	indefinite[1] = 0x80;
	assert !parseCertificate(indefinite).ok;
	for (let cut = 1; cut < der.length; cut += 7) assert !parseCertificate(der.slice(0, cut)).ok;
}

test "PEM text splits into one DER block per certificate" {
	const bundle = pemCertificates("junk\n" + rootRsaPem + "\n" + leafEdPem + interP384Pem);
	assert bundle.ok && bundle.value.length == 3;
	assert parseCertificate(bundle.value[1]).ok;
	const none = pemCertificates("no certificates here");
	assert none.ok && none.value.length == 0;
	const unterminated = pemCertificates("-----BEGIN CERTIFICATE-----\nMIIB\n");
	assert !unterminated.ok && unterminated.error == X509Error.MissingEndCertificateMarker;
	const bad = pemCertificates("-----BEGIN CERTIFICATE-----\n!!!!\n-----END CERTIFICATE-----\n");
	assert !bad.ok && bad.error == X509Error.InvalidPem;
}

/** A DER element: `tag`, the shortest length form, then `content`. */
function tlv(tag: int32, content: Readonly<uint8[]>): uint8[] {
	const out: uint8[] = [tag as uint8];
	const size = content.length as int32;
	if (size >= 256) {
		out.push(0x82);
		out.push((size >> 8) as uint8);
	} else if (size >= 128) {
		out.push(0x81);
	}
	out.push((size & 255) as uint8);
	for (const octet of content) out.push(octet);
	return out;
}

function concat(parts: uint8[][]): uint8[] {
	const out: uint8[] = [];
	for (const part of parts) {
		for (const octet of part) out.push(octet);
	}
	return out;
}

const ed25519Algorithm: uint8[] = tlv(0x30, [0x06, 0x03, 0x2b, 0x65, 0x70]);

/** An Ed25519 v3 certificate shape (not validly signed) carrying `extensions`, each a whole Extension element. */
function craftedCertificate(extensions: uint8[][]): uint8[] {
	const name = tlv(0x30, tlv(0x31, tlv(0x30, concat([[0x06, 0x03, 0x55, 0x04, 0x03], tlv(0x0c, [0x78])]))));
	const validity = tlv(0x30, concat([tlv(0x17, "250101000000Z".asBytes().slice(0)), tlv(0x17, "350101000000Z".asBytes().slice(0))]));
	const key = tlv(0x30, concat([ed25519Algorithm, tlv(0x03, [0, ...new Array<uint8>(32)])]));
	const tbs = tlv(0x30, concat([
		tlv(0xa0, [0x02, 0x01, 0x02]), [0x02, 0x01, 0x01], ed25519Algorithm, name, validity, name, key,
		tlv(0xa3, tlv(0x30, concat(extensions))),
	]));
	return tlv(0x30, concat([tbs, ed25519Algorithm, tlv(0x03, [0, ...new Array<uint8>(64)])]));
}

function extension(oid: uint8[], critical: boolean, value: uint8[]): uint8[] {
	return tlv(0x30, concat([tlv(0x06, oid), critical ? [0x01, 0x01, 0xff] : [], tlv(0x04, value)]));
}

const basicConstraintsOid: uint8[] = [0x55, 0x1d, 0x13];
const caFalse: uint8[] = tlv(0x30, []);

function parseError(der: Readonly<uint8[]>): string {
	const parsed = parseCertificate(der);
	return parsed.ok ? "ok" : parsed.error.toString();
}

test "crafted DER: extensions are read once each and an unknown critical one refuses the certificate" {
	assert parseError(craftedCertificate([extension(basicConstraintsOid, true, caFalse)])) == "ok";
	assert parseError(craftedCertificate([extension([0x2a, 0x03, 0x04], false, [0x05, 0x00])])) == "ok";
	assert parseError(craftedCertificate([extension([0x2a, 0x03, 0x04], true, [0x05, 0x00])])) == X509Error.UnsupportedCriticalExtension.toString();
	const nameConstraints = extension([0x55, 0x1d, 0x1e], true, tlv(0x30, tlv(0xa0, tlv(0x30, tlv(0x82, "example.org".asBytes().slice(0))))));
	assert parseError(craftedCertificate([nameConstraints])) == X509Error.UnsupportedCriticalExtension.toString();
	const twice = extension(basicConstraintsOid, false, caFalse);
	assert parseError(craftedCertificate([twice, twice])) == X509Error.DuplicateExtension.toString();
	const wideBoolean = tlv(0x30, concat([tlv(0x06, basicConstraintsOid), [0x01, 0x02, 0x00, 0xff], tlv(0x04, caFalse)]));
	assert parseError(craftedCertificate([wideBoolean])) == X509Error.FieldHasInvalidLength.toString();
	const trailingInExtension = tlv(0x30, concat([tlv(0x06, basicConstraintsOid), tlv(0x04, caFalse), [0x05, 0x00]]));
	assert parseError(craftedCertificate([trailingInExtension])) == X509Error.FieldHasInvalidLength.toString();
	const emptyPurposes = extension([0x55, 0x1d, 0x25], false, tlv(0x30, []));
	assert parseError(craftedCertificate([emptyPurposes])) == X509Error.FieldHasInvalidLength.toString();
	const pathLengthTooWide = extension(basicConstraintsOid, true, tlv(0x30, concat([[0x01, 0x01, 0xff], tlv(0x02, [1, 0, 0, 0])])));
	assert parseError(craftedCertificate([pathLengthTooWide])) == X509Error.FieldHasInvalidLength.toString();
	const negativePathLength = extension(basicConstraintsOid, true, tlv(0x30, concat([[0x01, 0x01, 0xff], tlv(0x02, [0x80])])));
	assert parseError(craftedCertificate([negativePathLength])) == X509Error.FieldHasInvalidLength.toString();
}

test "crafted DER: non-canonical boolean value is refused at extension critical flag and isCa" {
	const falseBoolean = tlv(0x30, concat([tlv(0x06, basicConstraintsOid), [0x01, 0x01, 0x00], tlv(0x04, caFalse)]));
	assert parseError(craftedCertificate([falseBoolean])) == "ok";
	const trueCritical = tlv(0x30, concat([tlv(0x06, basicConstraintsOid), [0x01, 0x01, 0xff], tlv(0x04, caFalse)]));
	assert parseError(craftedCertificate([trueCritical])) == "ok";
	const nonCanonicalCritical = tlv(0x30, concat([tlv(0x06, basicConstraintsOid), [0x01, 0x01, 0x01], tlv(0x04, caFalse)]));
	assert parseError(craftedCertificate([nonCanonicalCritical])) == X509Error.FieldHasWrongDataType.toString();
	const nonCanonicalIsCa = extension(basicConstraintsOid, true, tlv(0x30, [0x01, 0x01, 0x01]));
	assert parseError(craftedCertificate([nonCanonicalIsCa])) == X509Error.FieldHasWrongDataType.toString();
	const canonicalIsCa = extension(basicConstraintsOid, true, tlv(0x30, [0x01, 0x01, 0xff]));
	const caResult = parseCertificate(craftedCertificate([canonicalIsCa]));
	assert caResult.ok && caResult.value.isCa;
}

test "crafted DER: a non-minimal length, data after the signature and an unknown signature OID are refused" {
	const der = derOf(leafEdPem);
	assert der[1] == 0x81 || der[1] == 0x82;
	const headerLength = der[1] == 0x81 ? 3 : 4;
	const content = der.slice(headerLength);
	const size = content.length as int32;
	const widened: uint8[] = [0x30, 0x83, 0x00, (size >> 8) as uint8, (size & 255) as uint8, ...content];
	assert parseError(widened) == X509Error.FieldHasInvalidLength.toString();
	assert parseError(tlv(0x30, concat([content, [0x05, 0x00]]))) == X509Error.FieldHasInvalidLength.toString();
	assert parseError(tlv(0x30, content)) == "ok";
	const unknownAlgorithm = der.slice(0);
	let last = -1;
	for (let i = 0; i + 4 < unknownAlgorithm.length; i++) {
		if (unknownAlgorithm[i] == 0x06 && unknownAlgorithm[i + 1] == 0x03 && unknownAlgorithm[i + 2] == 0x2b && unknownAlgorithm[i + 3] == 0x65 && unknownAlgorithm[i + 4] == 0x70) last = i;
	}
	assert last > 0;
	unknownAlgorithm[last + 4] = 0x71;
	assert parseError(unknownAlgorithm) == X509Error.UnrecognizedObjectId.toString();
}

function constraintsRoots(): X509Bundle {
	const roots = new X509Bundle();
	if (!roots.addPem(constraintsRootPem, now).ok) throw new Error("constraints root did not load");
	return roots;
}

test "a CA's pathLenConstraint bounds the intermediates below it" {
	const roots = constraintsRoots();
	const pathZero = certificateOf(pathZeroPem);
	assert pathZero.isCa && pathZero.pathLength == 0;
	assert chainError([certificateOf(shallowLeafPem), pathZero], roots, "shallow.example.com", now) == "ok";
	const deep = [certificateOf(deepLeafPem), certificateOf(subCaPem), pathZero];
	assert chainError(deep, roots, "deep.example.com", now) == X509Error.PathLengthExceeded.toString();
}

test "a leaf whose key usage does not allow a TLS server is refused" {
	const roots = constraintsRoots();
	const client = certificateOf(clientLeafPem);
	assert client.extendedKeyUsage.length == 1 && client.extendedKeyUsage[0] == "2b06010505070302";
	assert chainError([client], roots, "client.example.com", now) == X509Error.KeyUsageMismatch.toString();
	assert chainError([certificateOf(agreeLeafPem)], roots, "agree.example.com", now) == X509Error.KeyUsageMismatch.toString();
	assert certificateOf(shallowLeafPem).extendedKeyUsage[0] == "2b06010505070301";
}

test "an unknown critical extension and critical nameConstraints refuse the certificate" {
	assert parseError(derOf(criticalLeafPem)) == X509Error.UnsupportedCriticalExtension.toString();
	assert parseError(derOf(namedCaPem)) == X509Error.UnsupportedCriticalExtension.toString();
	assert parseError(derOf(namedLeafPem)) == "ok";
}
