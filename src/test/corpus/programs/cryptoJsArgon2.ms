// Argon2id gives the same bytes on the C backend (the PHC reference) and on JS (the portable code in
// std/crypto/pure): raw hashes of "password" and "somesalt" for four parameter sets (four lanes, a
// 100-byte output, a 1024-byte output, the minimum memory and output), an encoded hash without the
// version field (version 0x10, whose passes overwrite instead of xor) and with it, all verifying, and the
// encoded-hash strictness the reference decoder has: padded base64, a leading zero, a short salt, trailing
// text and a tampered hash are all false. The expected values were computed independently of both backends.
//
// @stdout: a1 773cbdd591649dfdc8419ffb19e01211
// @stdout: a2 100 d98ff35be4929d949cd4de3dcf10482d8a006a5809bae1c331feae87936a1f4ea0434327ff12c78557fc368fc6c7ac185f8ae722254afc7754cd6c1bf25170301463e34fd1495bd02cf900c3df6aecfda17b00658ff0b59f8726eac34a52d1b62d96ab74
// @stdout: a3 1024 978506ada95b38a90e51750714d76e60 970f6e47feee5c925b260551c9b73095
// @stdout: a4 6b7a947d
// @stdout: raw v13 matches encoded true
// @stdout: v10 verifies true v13 verifies true wrong password false
// @stdout: strict padded false leading zero false short salt false trailing false tampered false
// @exit: 0
// @skip-raiser: std/crypto/argon2 has only a C backend (index.cms over vendor/argon2); there is no argon2.rms

import { CryptoError, toHex } from "std/crypto";
import { argon2HashRaw, argon2HashSync, argon2Verify } from "std/crypto/argon2";

function must<T>(result: Result<T, CryptoError>): T {
	if (!result.ok) throw new Error(`crypto call failed: ${result.error.message}`);
	return result.value;
}

async function raw(timeCost: int32, memoryCost: int32, parallelism: int32, hashLen: int32): Promise<string> {
	return toHex(must(await argon2HashRaw("password", "somesalt", timeCost, memoryCost, parallelism, hashLen)));
}

console.log(`a1 ${await raw(3, 64, 4, 16)}`);
const a2 = await raw(2, 100, 3, 100);
console.log(`a2 ${a2.length / 2} ${a2}`);
const a3 = await raw(1, 256, 1, 1024);
console.log(`a3 ${a3.length / 2} ${a3.substring(0, 32)} ${a3.substring(a3.length - 32)}`);
console.log(`a4 ${await raw(1, 8, 1, 4)}`);

const encoded = must(argon2HashSync("password", "somesalt", 2, 64, 2, 24));
console.log(`raw v13 matches encoded ${encoded == "$argon2id$v=19$m=64,t=2,p=2$c29tZXNhbHQ$NQrDciL0Nsy1wJcvHr079rlYvyBxhBNi"}`);

const v10 = "$argon2id$m=64,t=2,p=2$c29tZXNhbHQ$/qru6ELDx3dN5J8JlnnJkCF2SqUlT4Ga";
console.log(`v10 verifies ${await argon2Verify(v10, "password")} v13 verifies ${await argon2Verify(encoded, "password")} wrong password ${await argon2Verify(v10, "passw0rd")}`);

const hashPart = "/qru6ELDx3dN5J8JlnnJkCF2SqUlT4Ga";
console.log([
	`strict padded ${await argon2Verify("$argon2id$m=64,t=2,p=2$c29tZXNhbHQ=$" + hashPart, "password")}`,
	`leading zero ${await argon2Verify("$argon2id$m=064,t=2,p=2$c29tZXNhbHQ$" + hashPart, "password")}`,
	`short salt ${await argon2Verify("$argon2id$m=64,t=2,p=2$c29tZQ$" + hashPart, "password")}`,
	`trailing ${await argon2Verify(v10 + "$", "password")}`,
	`tampered ${await argon2Verify(v10.substring(0, v10.length - 1) + "b", "password")}`,
].join(" "));
