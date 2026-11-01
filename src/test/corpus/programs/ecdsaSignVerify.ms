// ECDSA over P-256 and P-384: sign and verify, and a tampered message fails. The first row signs a
// PEM-imported key before any generate ran, so the sign path must bring the crypto library up.
//
// @stdout: imported true false|p256 true false|p384 true false
// @exit: 0
// @skip-js: std/crypto/ec has only a C backend (index.cms over mbedTLS); there is no ec.jms
// @skip-raiser: std/crypto/ec has only a C backend (index.cms over mbedTLS); there is no ec.rms

import { EcCurve, EcPrivateKey, ecdsaSign, ecdsaVerify } from "std/crypto/ec";

const pem = [
	"-----BEGIN EC PRIVATE KEY-----",
	"MHcCAQEEIElvWBhY5Rkrp7FGkHv/Nw5SywJRXIbcyLOche64mhaqoAoGCCqGSM49",
	"AwEHoUQDQgAETLgSXoywJW9i0fsa0nUIxpgWeD2WE+1vYwnJzMr/T/yjTbfy7Ug6",
	"R+UQ6z1rV5qnS9pNLZ6uR8FOqorBh0YaXQ==",
	"-----END EC PRIVATE KEY-----",
].join("\n") + "\n";

async function row(key: EcPrivateKey, label: string): Promise<string> {
	const signed = await ecdsaSign(key, "message", "sha256");
	if (!signed.ok) throw new Error("ecdsaSign failed");
	const signature = signed.value;
	const pub = key.publicKey();
	const good = await ecdsaVerify(pub, "message", signature, "sha256");
	const tampered = await ecdsaVerify(pub, "massage", signature, "sha256");
	return `${label} ${good} ${tampered}`;
}

const rows: string[] = [];
const imported = await EcPrivateKey.importPem(pem);
if (!imported.ok) throw new Error("EcPrivateKey.importPem failed");
rows.push(await row(imported.value, "imported"));
const curves: EcCurve[] = ["p256", "p384"];
for (const curve of curves) {
	const generated = await EcPrivateKey.generate(curve);
	if (!generated.ok) throw new Error("EcPrivateKey.generate failed");
	rows.push(await row(generated.value, curve));
}
console.log(rows.join("|"));
