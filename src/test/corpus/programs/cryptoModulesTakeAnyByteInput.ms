// @stdout: blake2b bddd813c63423972 bddd813c63423972 bddd813c63423972 bddd813c63423972 bddd813c63423972 84771568a8161c0c 84771568a8161c0c bddd813c63423972
// @stdout: argon2 bbaf9979a7520281 bbaf9979a7520281
// @stdout: argon2 verify true true true false
// @stdout: aes cbc 1149130a470884991e040e2339e5c12b 1149130a470884991e040e2339e5c12b 1149130a470884991e040e2339e5c12b 616263
// @stdout: aes gcm 616263 616263 false 616263
// @stdout: chacha 616263 false 616263
// @stdout: ed25519 668d648807b6f992 668d648807b6f992 668d648807b6f992 true true false
// @stdout: x25519 bb50ff9e82a574cf bb50ff9e82a574cf bb50ff9e82a574cf
// @stdout: ecdsa true true false
// @stdout: rsa true true false 616263 616263
// @exit: 0
// @skip-raiser: the raiser carries none of the std/crypto submodules

import { Buffer } from "std/core/buffer";
import { CryptoError, toHex } from "std/crypto";
import { argon2HashRawSync, argon2HashSync, argon2Verify, argon2VerifySync } from "std/crypto/argon2";
import { AesKey, cbcDecryptSync, cbcEncrypt, cbcEncryptSync, open, openSync, seal, sealSync } from "std/crypto/aes";
import * as chacha from "std/crypto/chacha20";
import * as b2 from "std/crypto/blake2b";
import * as ed from "std/crypto/ed25519";
import * as x from "std/crypto/x25519";
import * as ec from "std/crypto/ec";
import * as rsa from "std/crypto/rsa";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(result.error.message);
	return result.value;
}

function head(b: Buffer): string {
	return toHex(b).slice(0, 16);
}

function pattern(n: int32, start: int32): Uint8Array {
	const u = new Uint8Array(n);
	for (let i = 0; i < n; i++) u[i] = ((start + i * 7) % 256) as uint8;
	return u;
}

function viaSpan(s: Readonly<Span<uint8>>): string {
	return head(must(b2.blake2bSync(s)));
}

const abc: uint8[] = [97, 98, 99];
const wide = pattern(5, 0);
wide[1] = 97;
wide[2] = 98;
wide[3] = 99;
const abcView = wide.subarray(1, 4);
const key32 = pattern(32, 3);
const keyVec: uint8[] = [];
for (const b of key32) keyVec.push(b);

console.log("blake2b", head(must(b2.blake2bSync("abc"))), head(must(b2.blake2bSync(abc))), head(must(b2.blake2bSync(abcView))), viaSpan(abcView),
	head(must(await b2.blake2b(abcView))), head(must(b2.blake2bKeyedSync(key32, "abc"))), head(must(b2.blake2bKeyedSync(keyVec, abcView))),
	head(must(b2.createBlake2b()).update("a").update(abcView.subarray(1, 3)).digest()));

const salt = "saltsaltsalt";
console.log("argon2", head(must(argon2HashRawSync("pw", salt, 1, 64, 1))), head(must(argon2HashRawSync(Buffer.fromString("pw", "utf8"), salt.asBytes(), 1, 64, 1))));
const encoded = must(argon2HashSync(abc, salt, 1, 64, 1));
console.log("argon2 verify", argon2VerifySync(encoded, "abc"), argon2VerifySync(encoded, abcView), await argon2Verify(encoded, abc), argon2VerifySync(encoded, "abd"));

const iv = pattern(16, 9);
const aes = must(AesKey.import(key32));
const aesVec = must(AesKey.import(keyVec));
const cbc = must(cbcEncryptSync(aes, "abc", iv));
console.log("aes cbc", toHex(cbc), toHex(must(cbcEncryptSync(aesVec, abcView, iv.subarray(0, 16)))), toHex(must(await cbcEncrypt(aes, abc, iv))),
	toHex(must(cbcDecryptSync(aes, cbc, iv))));
const sealed = must(sealSync(aes, abcView, abc));
console.log("aes gcm", toHex(must(openSync(aesVec, sealed, "abc"))), toHex(must(await open(aes, sealed, abcView))), openSync(aes, sealed).ok,
	toHex(must(openSync(aes, must(await seal(aes, "abc"))))));

const cc = must(chacha.ChaChaKey.import(keyVec));
const ccSealed = must(chacha.sealSync(cc, abc, abcView));
console.log("chacha", toHex(must(chacha.openSync(cc, ccSealed, "abc"))), chacha.openSync(cc, ccSealed).ok, toHex(must(await chacha.open(cc, must(await chacha.seal(cc, abcView)), ""))));

const edKey = must(ed.Ed25519PrivateKey.fromSeedSync(key32));
const edVec = must(await ed.Ed25519PrivateKey.fromSeed(keyVec));
const sig = must(ed.signSync(edKey, "abc"));
const edPublic = must(ed.Ed25519PublicKey.importSync(must(edKey.publicKey().exportSync())));
console.log("ed25519", head(sig), head(must(ed.signSync(edVec, abcView))), head(must(await ed.sign(edKey, abc))),
	ed.verifySync(edPublic, sig, abcView), await ed.verify(edKey.publicKey(), sig, abc), ed.verifySync(edPublic, sig, "abd"));

const xKey = must(x.X25519PrivateKey.fromRawSync(key32));
const xVec = must(await x.X25519PrivateKey.fromRaw(keyVec));
const xPeer = must(x.X25519PublicKey.importSync(must(xVec.publicKey().exportSync())));
console.log("x25519", head(must(xKey.publicKey().exportSync())), head(must(xVec.publicKey().exportSync())), head(must(xPeer.exportSync())));

const ecKey = must(ec.EcPrivateKey.generateSync("p256"));
const ecSig = must(ec.ecdsaSignSync(ecKey, abcView));
console.log("ecdsa", ec.ecdsaVerifySync(ecKey.publicKey(), "abc", ecSig), await ec.ecdsaVerify(ecKey.publicKey(), abc, must(await ec.ecdsaSign(ecKey, "abc"))),
	ec.ecdsaVerifySync(ecKey.publicKey(), "abd", ecSig));

const rsaKey = must(rsa.RsaPrivateKey.generateSync(2048));
const rsaSig = must(rsa.signSync(rsaKey, abc));
const rsaSealed = must(rsa.encryptSync(rsaKey.publicKey(), abcView));
console.log("rsa", rsa.verifySync(rsaKey.publicKey(), "abc", rsaSig), await rsa.verify(rsaKey.publicKey(), abcView, rsaSig), rsa.verifySync(rsaKey.publicKey(), "abd", rsaSig),
	toHex(must(rsa.decryptSync(rsaKey, rsaSealed))), toHex(must(await rsa.decrypt(rsaKey, must(await rsa.encrypt(rsaKey.publicKey(), "abc"))))));
