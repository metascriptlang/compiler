// RSA 2048: generate, sign and verify (a tampered message and a tampered signature fail), PSS
// sign and verify, OAEP encrypt and decrypt, and a PEM export and import that verifies the original
// signature.
//
// @stdout: sign true tampered false badsig false pss true pssWrongPadding false oaep true pem true
// @exit: 0
// @skip-raiser: std/crypto/rsa has a C and a JS backend and no rsa.rms

import { Buffer } from "std/core/buffer";
import { RsaPrivateKey, RsaPublicKey, sign, verify, encrypt, decrypt } from "std/crypto/rsa";

async function valid(pub: RsaPublicKey, message: string, signature: string | Buffer, padding: "pkcs1v15" | "pss"): Promise<boolean> {
	const checked = await verify(pub, message, signature, "sha256", padding);
	return checked;
}

const generated = await RsaPrivateKey.generate(2048);
if (!generated.ok) throw new Error("RsaPrivateKey.generate failed");
const key = generated.value;
const pub = key.publicKey();
const message = "attack at dawn";
const signed = await sign(key, message, "sha256");
if (!signed.ok) throw new Error("sign failed");
const signature = signed.value;
const verified = await valid(pub, message, signature, "pkcs1v15");
const tampered = await valid(pub, "attack at dusk", signature, "pkcs1v15");
const badSignature = await valid(pub, message, "\x00".repeat(256), "pkcs1v15");

const pssSigned = await sign(key, message, "sha256", "pss");
if (!pssSigned.ok) throw new Error("pss sign failed");
const pss = await valid(pub, message, pssSigned.value, "pss");
const pssWrongPadding = await valid(pub, message, pssSigned.value, "pkcs1v15");

const sealed = await encrypt(pub, "secret payload");
if (!sealed.ok) throw new Error("encrypt failed");
const opened = await decrypt(key, sealed.value);
const oaep = opened.ok && opened.value.asString() == "secret payload";

const publicPem = await pub.exportPem();
const privatePem = await key.exportPem();
if (!publicPem.ok || !privatePem.ok) throw new Error("export failed");
const imported = await RsaPublicKey.importPem(publicPem.value);
const pem = imported.ok && await valid(imported.value, message, signature, "pkcs1v15");
console.log(`sign ${verified} tampered ${tampered} badsig ${badSignature} pss ${pss} pssWrongPadding ${pssWrongPadding} oaep ${oaep} pem ${pem}`);
