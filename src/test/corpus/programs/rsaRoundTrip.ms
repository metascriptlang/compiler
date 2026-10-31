// RSA 2048: generate, sign and verify (a tampered message and a tampered signature fail), OAEP
// encrypt and decrypt, and a PEM export and import that verifies the original signature.
//
// @stdout: sign true tampered false badsig false oaep true pem true
// @exit: 0
// @skip-js: std/crypto/rsa has only a C backend (index.cms over mbedTLS); there is no rsa.jms
// @skip-raiser: std/crypto/rsa has only a C backend (index.cms over mbedTLS); there is no rsa.rms

import { rsaGenerate, rsaSign, rsaVerify, rsaEncrypt, rsaDecrypt, rsaExportPrivate, rsaExportPublic, rsaImportPublic, rsaFree } from "std/crypto/rsa";

const generated = rsaGenerate(2048);
if (!generated.ok) throw new Error("rsaGenerate failed");
const key = generated.value;
const message = "attack at dawn";
const signed = rsaSign(key, message, "sha256");
if (!signed.ok) throw new Error("rsaSign failed");
const signature = signed.value;
const verified = rsaVerify(key, message, signature, "sha256");
const tampered = rsaVerify(key, "attack at dusk", signature, "sha256");
const badSignature = rsaVerify(key, message, "\x00".repeat(256), "sha256");

const sealed = rsaEncrypt(key, "secret payload");
if (!sealed.ok) throw new Error("rsaEncrypt failed");
const opened = rsaDecrypt(key, sealed.value);
const oaep = opened.ok && opened.value.asString() == "secret payload";

const publicPem = rsaExportPublic(key);
const privatePem = rsaExportPrivate(key);
if (!publicPem.ok || !privatePem.ok) throw new Error("export failed");
const imported = rsaImportPublic(publicPem.value);
const pem = imported.ok && rsaVerify(imported.value, message, signature, "sha256");
console.log(`sign ${verified} tampered ${tampered} badsig ${badSignature} oaep ${oaep} pem ${pem}`);
rsaFree(key);
if (imported.ok) rsaFree(imported.value);
