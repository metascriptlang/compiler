// ECDSA over P-256 and P-384: sign and verify, and a tampered message fails. The first row signs a
// PEM-imported key before any generate ran, so the sign path must bring the crypto library up.
//
// @stdout: imported true false|p256 true false|p384 true false
// @exit: 0
// @skip-js: std/crypto/rsa has only a C backend (index.cms over mbedTLS); there is no rsa.jms
// @skip-raiser: std/crypto/rsa has only a C backend (index.cms over mbedTLS); there is no rsa.rms

import { ecImportPrivate, ecGenerate, ecdsaSign, ecdsaVerify, ecFree } from "std/crypto/rsa";

const pem = [
	"-----BEGIN EC PRIVATE KEY-----",
	"MHcCAQEEIElvWBhY5Rkrp7FGkHv/Nw5SywJRXIbcyLOche64mhaqoAoGCCqGSM49",
	"AwEHoUQDQgAETLgSXoywJW9i0fsa0nUIxpgWeD2WE+1vYwnJzMr/T/yjTbfy7Ug6",
	"R+UQ6z1rV5qnS9pNLZ6uR8FOqorBh0YaXQ==",
	"-----END EC PRIVATE KEY-----",
].join("\n") + "\n";

function row(key: int64, label: string): string {
	const signed = ecdsaSign(key, "message", "sha256");
	if (!signed.ok) throw new Error("ecdsaSign failed");
	const signature = signed.value;
	const good = ecdsaVerify(key, "message", signature, "sha256");
	const tampered = ecdsaVerify(key, "massage", signature, "sha256");
	return `${label} ${good} ${tampered}`;
}

const rows: string[] = [];
const imported = ecImportPrivate(pem);
if (!imported.ok) throw new Error("ecImportPrivate failed");
rows.push(row(imported.value, "imported"));
ecFree(imported.value);
for (const curve of ["p256", "p384"]) {
	const generated = ecGenerate(curve);
	if (!generated.ok) throw new Error("ecGenerate failed");
	rows.push(row(generated.value, curve));
	ecFree(generated.value);
}
console.log(rows.join("|"));
