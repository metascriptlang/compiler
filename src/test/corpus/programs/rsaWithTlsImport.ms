// std/crypto/rsa and std/crypto/tls in one program: both bring in the PSA core, and the program
// must link once and still sign and verify.
//
// @stdout: rsa+tls sign true verify true
// @exit: 0
// @skip-js: std/crypto/rsa has only a C backend (index.cms over mbedTLS); there is no rsa.jms
// @skip-raiser: std/crypto/rsa has only a C backend (index.cms over mbedTLS); there is no rsa.rms

import { RsaPrivateKey, sign, verify } from "std/crypto/rsa";
import { tlsConnect } from "std/crypto/tls";

const generated = await RsaPrivateKey.generate(2048);
if (!generated.ok) throw new Error("RsaPrivateKey.generate failed");
const signed = await sign(generated.value, "both", "sha256");
let verified = false;
if (signed.ok) {
	const checked = await verify(generated.value.publicKey(), "both", signed.value, "sha256");
	verified = checked;
}
const unreachable = signed.ok && !verified;
if (unreachable) tlsConnect("localhost", 1);
console.log(`rsa+tls sign ${signed.ok} verify ${verified}`);
