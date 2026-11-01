// Every async operation of std/crypto has a Sync twin that returns the same bytes (or boolean) for the same input,
// so code on a spawn worker, which cannot run a promise-returning thunk, can call it.
//
// @stdout: kdf pbkdf2 true hkdf true
// @stdout: aes seal-open true cbc true
// @stdout: chacha seal-open true
// @stdout: argon2 hash true raw true verify true true
// @stdout: ed25519 key true sign true verify true true export true
// @stdout: x25519 key true shared true export true
// @stdout: ecdsa sign-by-sync verified-by-async true sign-by-async verified-by-sync true ecdh true pem true
// @stdout: rsa sign-by-sync verified-by-async true sign-by-async verified-by-sync true pss true oaep true pem true
// @exit: 0
// @skip-raiser: the raiser std/crypto carries only the string-encoded hash family; none of these Buffer APIs

import { Buffer } from "std/core/buffer";
import { CryptoError, hkdf, hkdfSync, pbkdf2, pbkdf2Sync, toHex } from "std/crypto";
import { AesKey, cbcDecrypt, cbcDecryptSync, cbcEncrypt, cbcEncryptSync, open as aesOpen, openSync as aesOpenSync, seal as aesSeal, sealSync as aesSealSync } from "std/crypto/aes";
import { ChaChaKey, open as chachaOpen, openSync as chachaOpenSync, seal as chachaSeal, sealSync as chachaSealSync } from "std/crypto/chacha20";
import { argon2Hash, argon2HashRaw, argon2HashRawSync, argon2HashSync, argon2Verify, argon2VerifySync } from "std/crypto/argon2";
import { Ed25519PrivateKey, Ed25519PublicKey, sign as edSign, signSync as edSignSync, verify as edVerify, verifySync as edVerifySync } from "std/crypto/ed25519";
import { X25519PrivateKey, X25519PublicKey, sharedSecret, sharedSecretSync } from "std/crypto/x25519";
import { EcPrivateKey, EcPublicKey, ecdh, ecdhSync, ecdsaSign, ecdsaSignSync, ecdsaVerify, ecdsaVerifySync } from "std/crypto/ec";
import { RsaPrivateKey, RsaPublicKey, decrypt, decryptSync, encrypt, encryptSync, sign as rsaSign, signSync as rsaSignSync, verify as rsaVerify, verifySync as rsaVerifySync } from "std/crypto/rsa";

function must<T>(r: Result<T, CryptoError>): T {
	if (!r.ok) throw new Error(`unexpected error: ${r.error.message}`);
	return r.value;
}

function hex(r: Result<Buffer, CryptoError>): string {
	if (!r.ok) throw new Error(`unexpected error: ${r.error.message}`);
	return toHex(r.value);
}

function eq(a: Result<Buffer, CryptoError>, b: Result<Buffer, CryptoError>): boolean {
	return hex(a) == hex(b);
}

const seedA = "0123456789abcdef0123456789abcdef";
const seedB = "fedcba9876543210fedcba9876543210";

// kdf
console.log(`kdf pbkdf2 ${eq(await pbkdf2("pw", "salt", 1000, 32, "sha256"), pbkdf2Sync("pw", "salt", 1000, 32, "sha256"))} hkdf ${eq(await hkdf("sha256", "ikm", "salt", "info", 42), hkdfSync("sha256", "ikm", "salt", "info", 42))}`);

// aes: a blob sealed by one form opens in both; cbc with a fixed iv is deterministic
const aesKey = must(AesKey.import(seedA));
const aesBlob = aesSealSync(aesKey, "attack at dawn", "aad");
const aesRound = hex(await aesOpen(aesKey, must(aesBlob), "aad")) == hex(aesOpenSync(aesKey, must(aesBlob), "aad"));
const cbcSync = cbcEncryptSync(aesKey, "attack at dawn", "0123456789abcdef");
const cbcRound = eq(await cbcEncrypt(aesKey, "attack at dawn", "0123456789abcdef"), cbcSync)
	&& eq(await cbcDecrypt(aesKey, must(cbcSync), "0123456789abcdef"), cbcDecryptSync(aesKey, must(cbcSync), "0123456789abcdef"));
const aesAsyncBlob = await aesSeal(aesKey, "x");
console.log(`aes seal-open ${aesRound && aesOpenSync(aesKey, must(aesAsyncBlob)).ok} cbc ${cbcRound}`);

// chacha
const chachaKey = must(ChaChaKey.import(seedA));
const chachaBlob = chachaSealSync(chachaKey, "attack at dawn", "aad");
const chachaAsyncBlob = await chachaSeal(chachaKey, "x");
console.log(`chacha seal-open ${hex(await chachaOpen(chachaKey, must(chachaBlob), "aad")) == hex(chachaOpenSync(chachaKey, must(chachaBlob), "aad")) && chachaOpenSync(chachaKey, must(chachaAsyncBlob)).ok}`);

// argon2, small cost and a fixed salt
const aHash = await argon2Hash("pw", "somesaltsomesalt", 1, 64, 1, 32);
const sHash = argon2HashSync("pw", "somesaltsomesalt", 1, 64, 1, 32);
const hashSame = must(aHash) == must(sHash);
const rawSame = eq(await argon2HashRaw("pw", "somesaltsomesalt", 1, 64, 1, 32), argon2HashRawSync("pw", "somesaltsomesalt", 1, 64, 1, 32));
console.log(`argon2 hash ${hashSame} raw ${rawSame} verify ${await argon2Verify(must(sHash), "pw")} ${argon2VerifySync(must(aHash), "pw")}`);

// ed25519 with a fixed seed
const edAsync = must((await Ed25519PrivateKey.fromSeed(seedA)));
const edSync = must(Ed25519PrivateKey.fromSeedSync(seedA));
const edSigA = await edSign(edAsync, "msg");
const edSigS = edSignSync(edSync, "msg");
const edPub = edSync.publicKey();
const edPubSync = must(Ed25519PublicKey.importSync(must((await edPub.export()))));
console.log(`ed25519 key ${hex(await edAsync.exportSeed()) == hex(edSync.exportSeedSync())} sign ${eq(edSigA, edSigS)} verify ${await edVerify(edPub, must(edSigS), "msg")} ${edVerifySync(edPubSync, must(edSigA), "msg")} export ${eq(await edPub.export(), edPubSync.exportSync())}`);

// x25519 with fixed keys
const xa = must(X25519PrivateKey.fromRawSync(seedA));
const xb = must((await X25519PrivateKey.fromRaw(seedB)));
const xbPub = xb.publicKey();
const xbPubSync = must(X25519PublicKey.importSync(must((await xbPub.export()))));
console.log(`x25519 key ${hex(await xbPub.export()) == hex(xbPubSync.exportSync())} shared ${eq(await sharedSecret(xa, xbPub), sharedSecretSync(xa, xbPubSync))} export ${eq(await xbPub.export(), xbPubSync.exportSync())}`);

// ecdsa and ecdh: each form verifies a signature made by the other
const ecKey = must(EcPrivateKey.generateSync("p256"));
const ecPub = ecKey.publicKey();
const ecSigS = ecdsaSignSync(ecKey, "msg", "sha256");
const ecSigA = await ecdsaSign(ecKey, "msg", "sha256");
const ecPeer = must((await EcPrivateKey.generate("p256")));
const ecPem = must((await ecKey.exportPem())) == must(ecKey.exportPemSync());
const ecPubBack = EcPublicKey.importPemSync(must(ecPub.exportPemSync()));
console.log(`ecdsa sign-by-sync verified-by-async ${await ecdsaVerify(ecPub, "msg", must(ecSigS), "sha256")} sign-by-async verified-by-sync ${ecdsaVerifySync(must(ecPubBack), "msg", must(ecSigA), "sha256")} ecdh ${eq(await ecdh(ecKey, ecPeer.publicKey()), ecdhSync(ecKey, ecPeer.publicKey()))} pem ${ecPem}`);

// rsa
const rsaKey = must(RsaPrivateKey.generateSync(2048));
const rsaPub = rsaKey.publicKey();
const rsaSigS = rsaSignSync(rsaKey, "msg", "sha256");
const rsaSigA = await rsaSign(rsaKey, "msg", "sha256");
const rsaPss = rsaSignSync(rsaKey, "msg", "sha256", "pss");
const oaep = encryptSync(rsaPub, "secret");
const rsaPem = must((await rsaKey.exportPem())) == must(rsaKey.exportPemSync());
const rsaPubBack = RsaPublicKey.importPemSync(must(rsaPub.exportPemSync()));
console.log(`rsa sign-by-sync verified-by-async ${await rsaVerify(rsaPub, "msg", must(rsaSigS), "sha256")} sign-by-async verified-by-sync ${rsaVerifySync(must(rsaPubBack), "msg", must(rsaSigA), "sha256")} pss ${await rsaVerify(rsaPub, "msg", must(rsaPss), "sha256", "pss") && rsaVerifySync(rsaPub, "msg", must(rsaPss), "sha256", "pss")} oaep ${hex(await decrypt(rsaKey, must(oaep))) == hex(decryptSync(rsaKey, must((await encrypt(rsaPub, "secret")))))} pem ${rsaPem}`);
