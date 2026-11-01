// ECDSA and ECDH keys made by the native backend (mbedTLS), by WebCrypto on JS and by node:crypto verify, derive and
// decrypt alike on both backends: the constants below were produced by one C run, one JS run on those keys and one
// node:crypto run. A PEM written by the native backend is rewritten byte for byte, a PKCS#8 key imports, signatures
// made elsewhere verify (DER on both backends), the shared secret equals the constant, and a point off the curve, a
// key of another curve and a sha1 signature are refused.
//
// @stdout: p256 pem private true public true peer true verify c true js true node true tampered false
// @stdout: p256 ecdh c true swapped true node true nodeSwapped true cross-curve refused true
// @stdout: p384 pem private true public true peer true verify c true js true node true tampered false
// @stdout: p384 ecdh c true swapped true node true nodeSwapped true cross-curve refused true
// @stdout: off-curve point refused true sha1 sign refused true sha1 verify of sha256 signature false
// @exit: 0
// @skip-raiser: std/crypto/ec has only a C backend and a JS backend; there is no ec.rms

import { Buffer } from "std/core/buffer";
import { CryptoError, EcPrivateKey, EcPublicKey, ecdsaSign, ecdsaVerify, ecdh } from "std/crypto/ec";
import { fromBase64, fromHex, toBase64, toHex } from "std/crypto";

function bytes(hex: string): Buffer {
	const decoded = fromHex(hex);
	if (!decoded.ok) throw new Error("bad hex constant");
	return decoded.value;
}

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error("crypto call failed");
	return result.value;
}

async function row(curve: "p256" | "p384", hash: string, pem: string, publicPem: string, peerPem: string, peerPublicPem: string, cSig: string, jsSig: string, shared: string,
	nodePkcs8: string, nodePublic: string, nodeSig: string, nodePeerPublic: string, nodePeerPkcs8: string, nodeShared: string, otherPublicPem: string): Promise<string[]> {
	const key = must(await EcPrivateKey.importPem(pem));
	const pub = key.publicKey();
	const peer = must(await EcPrivateKey.importPem(peerPem));
	const nodeKey = must(await EcPrivateKey.importPem(nodePkcs8));
	const nodePeer = must(await EcPrivateKey.importPem(nodePeerPkcs8));
	const nodePub = must(await EcPublicKey.importPem(nodePublic));
	const pemRow = `pem private ${must(await key.exportPem()) == pem} public ${must(await pub.exportPem()) == publicPem} peer ${must(await peer.publicKey().exportPem()) == peerPublicPem}`;
	const verifyRow = `verify c ${await ecdsaVerify(pub, "abc", bytes(cSig), hash)} js ${await ecdsaVerify(pub, "abc", bytes(jsSig), hash)} node ${await ecdsaVerify(nodePub, "abc", bytes(nodeSig), hash)} tampered ${await ecdsaVerify(pub, "abd", bytes(cSig), hash)}`;
	const own = must(await ecdh(key, peer.publicKey()));
	const swapped = must(await ecdh(peer, pub));
	const fromNode = must(await ecdh(nodeKey, must(await EcPublicKey.importPem(nodePeerPublic))));
	const nodeSwapped = must(await ecdh(nodePeer, nodePub));
	const other = must(await EcPublicKey.importPem(otherPublicPem));
	const crossCurve = !(await ecdh(key, other)).ok;
	const ecdhRow = `ecdh c ${toHex(own) == shared} swapped ${toHex(swapped) == shared} node ${toHex(fromNode) == nodeShared} nodeSwapped ${toHex(nodeSwapped) == nodeShared} cross-curve refused ${crossCurve}`;
	return [`${curve} ${pemRow} ${verifyRow}`, `${curve} ${ecdhRow}`];
}

const p256Pem = `-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIPUvfNt7ahQHUH2hVEKrf2Tq2bcuD0mmEy4wTlNvwYqIoAoGCCqGSM49
AwEHoUQDQgAEeFp4Yi5eLs4WkDhbfPMXF9d2FWctcJiimx2P0NG8NiddWms3P8Db
qApFwl50i7BDOt18d5gfZ8B04mmc4eF/hQ==
-----END EC PRIVATE KEY-----
`;
const p256PublicPem = `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEeFp4Yi5eLs4WkDhbfPMXF9d2FWct
cJiimx2P0NG8NiddWms3P8DbqApFwl50i7BDOt18d5gfZ8B04mmc4eF/hQ==
-----END PUBLIC KEY-----
`;
const p256Sig = "304502207c99882165224c4f57e397e656c11177ee59d460f5fc8e31033d0c09aea29b7e022100f1aafc794b3c79e775311f1630f9d77c434f2aee3c1fa62e027b11ec9de59636";
const p256PeerPem = `-----BEGIN EC PRIVATE KEY-----
MHcCAQEEICh2zCY8GI3T74LBN/owGjYMZ3LmAQk+PzB4KVMKP0CkoAoGCCqGSM49
AwEHoUQDQgAE7f9RtlARrJF1cmeFlc1klbSEcdzisAIQ1WPhcHSXL5CPjlMUPCb/
PL+KKkgtZnAXBjTpehL4g4J64IvEAPaxuA==
-----END EC PRIVATE KEY-----
`;
const p256PeerPublicPem = `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE7f9RtlARrJF1cmeFlc1klbSEcdzi
sAIQ1WPhcHSXL5CPjlMUPCb/PL+KKkgtZnAXBjTpehL4g4J64IvEAPaxuA==
-----END PUBLIC KEY-----
`;
const p256Shared = "0f1af3457658e7300bc3c86189ccfdad7dca0fdf55a9879539f071baf9d9a953";
const p384Pem = `-----BEGIN EC PRIVATE KEY-----
MIGkAgEBBDAF8q8fi5vWY6S81b9mVujbJy/DJ9qLygaNCm/v8ai6Zzb4wMZQ0YGC
d1ODM4xytJOgBwYFK4EEACKhZANiAAR5rtHaoBDiFmO0fpBUkSG/I9q77Jx+QoVJ
9UT9ZPyIjXFLoMxxLUCHdEWT7BBTKUSIJvsUzEC+f5EGoCs2cluYAZIlzGao9kCu
SX4A0QiS2puk+Abpd2INbw9NpBr5F5w=
-----END EC PRIVATE KEY-----
`;
const p384PublicPem = `-----BEGIN PUBLIC KEY-----
MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEea7R2qAQ4hZjtH6QVJEhvyPau+ycfkKF
SfVE/WT8iI1xS6DMcS1Ah3RFk+wQUylEiCb7FMxAvn+RBqArNnJbmAGSJcxmqPZA
rkl+ANEIktqbpPgG6XdiDW8PTaQa+Rec
-----END PUBLIC KEY-----
`;
const p384Sig = "3066023100d43c48b51c3f38ff55f17a64db233244dd0a0011e8f73c5959621e4eae0fdda895bbaa593f7db7774f1247bccd11a2c0023100ba93b8e48ad6765bdbbce8956b2017c1e9375aa039902afddfde4ef91a71012f6c47b503c6b2245ced099a178c1cdf6b";
const p384PeerPem = `-----BEGIN EC PRIVATE KEY-----
MIGkAgEBBDBscT3OGsfpM+7F7qfD/B+dKFoGZsPR8mUjwBc16HSo83ZE8hzVtgTx
3PCaOJle9rqgBwYFK4EEACKhZANiAATzoJ+N3v2QOVfenzuZnq6UBKHUXQY/4Bjv
Jia1RQ0krLljoeeQVvQGC+jcS2b2QSNqAyA8wybGfmuOVHw2XX3IXaZCWz/RM775
ScAP+ootxLd4cwxRMd/7DlHZcAsVAzY=
-----END EC PRIVATE KEY-----
`;
const p384PeerPublicPem = `-----BEGIN PUBLIC KEY-----
MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAE86Cfjd79kDlX3p87mZ6ulASh1F0GP+AY
7yYmtUUNJKy5Y6HnkFb0Bgvo3Etm9kEjagMgPMMmxn5rjlR8Nl19yF2mQls/0TO+
+UnAD/qKLcS3eHMMUTHf+w5R2XALFQM2
-----END PUBLIC KEY-----
`;
const p384Shared = "734c0f36b365e4276ba2988d2db0193b6ddb9f0ba6bbe4b6faace139a4a95f4faca45892117a50cc54863afe90b189f9";
const jsP256Sig = "3046022100be8b8324f8a1a75668844d827d705c35e0412f217d97ffad39896c561b3193e7022100ce5086c68e683ea6d5640135489c7a6307f48e068853140005df41674826a2de";
const jsP384Sig = "30640230740a71467b56f7b213d4e1ad47b87310eac8cfa48179f3a3d162451d5653086018cd1187c8897465713da7cd018717d20230141642da2c58dae0e7ab94b846ba5b5bddb730759724875839093c15bc1bbe69eb813333742dd48c84b8e494f2189fea";
const nodep256Pkcs8Pem = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgvgyAbWZRCuIhrb8x
SLAvM3Ann50Wqx0QQcNFIU8V8tWhRANCAASQoB5zNb5aBiVPbqe6IWGtDbgAmJnt
UZUi0nFqCj2kG2zlQO7t2TMuQ56CZaSfhyG8IrWVJE1CrLGO6kqIjsd1
-----END PRIVATE KEY-----
`;
const nodep256PublicPem = `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEkKAeczW+WgYlT26nuiFhrQ24AJiZ
7VGVItJxago9pBts5UDu7dkzLkOegmWkn4chvCK1lSRNQqyxjupKiI7HdQ==
-----END PUBLIC KEY-----
`;
const nodep256Sig = "30460221008550255710fae9ddf02d5b415a722b5297e5d53562b13efd8cdf25f79a30cc050221008e583e4f90359ec4bd6a42b7312a92f03af19b41b971d3a4b59a437cecaf051c";
const nodep256PeerPublicPem = `-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEb5MC4IeNVfKyxpJ7W0DGMpPx2i4G
xd0Dv87qvkjGEzPArQ7yCIlWqAuk5N2xXqXlfQ89cJIhEUpx+biXfMUcUQ==
-----END PUBLIC KEY-----
`;
const nodep256Shared = "75cd3c86328e1fe2252b057af5c5f5c58c079de9d123b4f35cdfe064d1748452";
const nodep256PeerPkcs8Pem = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgT5FDEf3G6lBMerfI
ry6z5cKyDmP/8KJ5zHOTdASYieGhRANCAARvkwLgh41V8rLGkntbQMYyk/HaLgbF
3QO/zuq+SMYTM8CtDvIIiVaoC6Tk3bFepeV9Dz1wkiERSnH5uJd8xRxR
-----END PRIVATE KEY-----
`;
const nodep384Pkcs8Pem = `-----BEGIN PRIVATE KEY-----
MIG2AgEAMBAGByqGSM49AgEGBSuBBAAiBIGeMIGbAgEBBDAu9/6YOh0eDQotpUzE
F3dsPpgkply9JqJ4QxmhCrR96rYQxSUF3byxvvPO9qkJjcahZANiAAT6Xz4Vh/DE
5KEEqTznRVmcqIr5lsIXPbVwJC/7JxXIUqewFBng8yuaSOMK7sMwFNMNyxl4PnOG
tCdBPDyk/GXQCiviHLsHB4/IRlUkp5qUMDY0RygdALk7GtMPLbIzDN0=
-----END PRIVATE KEY-----
`;
const nodep384PublicPem = `-----BEGIN PUBLIC KEY-----
MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAE+l8+FYfwxOShBKk850VZnKiK+ZbCFz21
cCQv+ycVyFKnsBQZ4PMrmkjjCu7DMBTTDcsZeD5zhrQnQTw8pPxl0Aor4hy7BweP
yEZVJKealDA2NEcoHQC5OxrTDy2yMwzd
-----END PUBLIC KEY-----
`;
const nodep384Sig = "306502305218eec4ca93eaf6b037cade1b814a4b763299d75e1b30e4472a5e22faf2d18676440b1b2f84d42669310212f5e9f423023100f8a6d829ed946c76782ede6d33038226611aa2f2cf224c02c5f4819ce252e1aeea10b276022f5b9f44edd7dd54eea643";
const nodep384PeerPublicPem = `-----BEGIN PUBLIC KEY-----
MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEazGhmVDkOOYA8LxJ3RJdzfzgqdlYmzWi
rRXgkywQ+GRfJiL5FE3H+/FU21AA2u3rEdt4g8pLUBv3LDT+ZFbijVfvVINXVCcN
SYt3dGtS4WWKJzhiM8VV33EhaB3bH8M4
-----END PUBLIC KEY-----
`;
const nodep384Shared = "7a503f4d13a47cd07133fe0b3ae03c6a596bfff45af33c40ea82a526847424ec0bb40dd41bbd744512685349db5bb3ed";
const nodep384PeerPkcs8Pem = `-----BEGIN PRIVATE KEY-----
MIG2AgEAMBAGByqGSM49AgEGBSuBBAAiBIGeMIGbAgEBBDAVIeAlsZ0TH+znlvOF
X7pdTbWldHlSoine4E02ucZ4JWX81CqTwaEOtKuJU/sgUS6hZANiAARrMaGZUOQ4
5gDwvEndEl3N/OCp2VibNaKtFeCTLBD4ZF8mIvkUTcf78VTbUADa7esR23iDyktQ
G/csNP5kVuKNV+9Ug1dUJw1Ji3d0a1LhZYonOGIzxVXfcSFoHdsfwzg=
-----END PRIVATE KEY-----
`;

const p256Rows = await row("p256", "sha256", p256Pem, p256PublicPem, p256PeerPem, p256PeerPublicPem, p256Sig, jsP256Sig, p256Shared,
	nodep256Pkcs8Pem, nodep256PublicPem, nodep256Sig, nodep256PeerPublicPem, nodep256PeerPkcs8Pem, nodep256Shared, p384PublicPem);
for (const text of p256Rows) console.log(text);
const p384Rows = await row("p384", "sha384", p384Pem, p384PublicPem, p384PeerPem, p384PeerPublicPem, p384Sig, jsP384Sig, p384Shared,
	nodep384Pkcs8Pem, nodep384PublicPem, nodep384Sig, nodep384PeerPublicPem, nodep384PeerPkcs8Pem, nodep384Shared, p256PublicPem);
for (const text of p384Rows) console.log(text);

const body = p256PublicPem.split("\n").filter((text) => text != "" && !text.startsWith("-----")).join("");
const raw = must(fromBase64(body));
raw[raw.length - 1] = (raw[raw.length - 1] ^ 1) as uint8;
const offCurve = await EcPublicKey.importPem(`-----BEGIN PUBLIC KEY-----\n${toBase64(raw)}\n-----END PUBLIC KEY-----\n`);
const key = must(await EcPrivateKey.importPem(p256Pem));
const sha1Sign = await ecdsaSign(key, "abc", "sha1");
const sha1Verify = await ecdsaVerify(key.publicKey(), "abc", bytes(p256Sig), "sha1");
console.log(`off-curve point refused ${!offCurve.ok} sha1 sign refused ${!sha1Sign.ok} sha1 verify of sha256 signature ${sha1Verify}`);
