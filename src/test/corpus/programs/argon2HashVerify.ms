// std/crypto/argon2 compiles and round-trips: a hash verifies the right password only, a malformed
// encoded hash is false, and a second parameter set (one lane, other length) behaves the same.
//
// @stdout: m=64,t=2,p=2 right true wrong false malformed false garbage false|m=64,t=1,p=1 right true wrong false malformed false garbage false
// @exit: 0
// @skip-js: std/crypto/argon2 has only a C backend (index.cms over vendor/argon2); there is no argon2.jms
// @skip-raiser: std/crypto/argon2 has only a C backend (index.cms over vendor/argon2); there is no argon2.rms

import { argon2Hash, argon2Verify } from "std/crypto/argon2";

function row(timeCost: int32, memoryCost: int32, parallelism: int32, hashLen: int32): string {
	const hashed = argon2Hash("password", "somesalt", timeCost, memoryCost, parallelism, hashLen);
	if (!hashed.ok) throw new Error(`hash failed: ${hashed.error.message}`);
	const encoded = hashed.value;
	const params = `m=${memoryCost},t=${timeCost},p=${parallelism}`;
	const truncated = encoded.substring(0, encoded.length - 8);
	return `${params} right ${argon2Verify(encoded, "password")} wrong ${argon2Verify(encoded, "passw0rd")} malformed ${argon2Verify(truncated, "password")} garbage ${argon2Verify("not an argon2 hash", "password")}`;
}

console.log([row(2, 64, 2, 24), row(1, 64, 1, 16)].join("|"));
