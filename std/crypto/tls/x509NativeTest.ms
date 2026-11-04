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
	byLeafPem,
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
