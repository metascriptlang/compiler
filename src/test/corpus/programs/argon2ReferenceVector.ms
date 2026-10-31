// std/crypto/argon2 argument order and output match the vendored library's own CLI (the
// documented `argon2 somesalt -id -t 2 -m 6 -p 2 -l 24` call on "password"), for the encoded
// and the raw form, and for a second parameter set. RFC 9106's vector needs a secret and associated
// data, which the API does not take.
//
// @stdout: encoded $argon2id$v=19$m=64,t=2,p=2$c29tZXNhbHQ$NQrDciL0Nsy1wJcvHr079rlYvyBxhBNi raw 24|encoded $argon2id$v=19$m=64,t=1,p=1$c29tZXNhbHQ$pMlwOs/gn+zdvoB/AGiRNA raw 16
// @exit: 0
// @skip-js: std/crypto/argon2 has only a C backend (index.cms over vendor/argon2); there is no argon2.jms
// @skip-raiser: std/crypto/argon2 has only a C backend (index.cms over vendor/argon2); there is no argon2.rms

import { argon2Hash, argon2HashRaw } from "std/crypto/argon2";

function row(timeCost: int32, memoryCost: int32, parallelism: int32, hashLen: int32): string {
	const encoded = argon2Hash("password", "somesalt", timeCost, memoryCost, parallelism, hashLen);
	const raw = argon2HashRaw("password", "somesalt", timeCost, memoryCost, parallelism, hashLen);
	if (!encoded.ok || !raw.ok) throw new Error("hash failed");
	return `encoded ${encoded.value} raw ${raw.value.length}`;
}

console.log([row(2, 64, 2, 24), row(1, 64, 1, 16)].join("|"));
