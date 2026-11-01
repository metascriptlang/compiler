// argon2Verify answers true only when the password matches. It reads m, t and p from the encoded
// hash, which an attacker can forge, so it answers false, before the library allocates anything,
// for a hash asking for more than its limits: the default limits are four times the hashing
// defaults (m=262144 KiB, t=12, p=16), and a caller may pass others. A hash that is not argon2id,
// has non-decimal or missing parameters, or overflows the parameter width is false too.
//
// @stdout: within default true
// @stdout: m 1 GiB false
// @stdout: m 4294967295 false
// @stdout: t 13 false
// @stdout: p 17 false
// @stdout: custom limit below m=64 false
// @stdout: custom limit at m=64 true
// @stdout: wrong password false
// @stdout: argon2i false
// @stdout: m too wide false
// @stdout: m not a number false
// @stdout: missing params false
// @exit: 0
// @skip-js: std/crypto/argon2 has only a C backend (index.cms over vendor/argon2); there is no argon2.jms
// @skip-raiser: std/crypto/argon2 has only a C backend (index.cms over vendor/argon2); there is no argon2.rms

import { Argon2Limits, argon2Hash, argon2Verify } from "std/crypto/argon2";

async function show(label: string, encoded: string, password: string = "password", limits: Argon2Limits | null = null): Promise<string> {
	const verified = limits == null ? await argon2Verify(encoded, password) : await argon2Verify(encoded, password, limits);
	return `${label} ${verified}`;
}

const hashed = await argon2Hash("password", "somesalt", 1, 64, 1, 16);
if (!hashed.ok) throw new Error("hash failed");
const encoded = hashed.value;
const params = "m=64,t=1,p=1";

console.log(await show("within default", encoded));
console.log(await show("m 1 GiB", encoded.replace(params, "m=1048576,t=1,p=1")));
console.log(await show("m 4294967295", encoded.replace(params, "m=4294967295,t=1,p=1")));
console.log(await show("t 13", encoded.replace(params, "m=64,t=13,p=1")));
console.log(await show("p 17", encoded.replace(params, "m=64,t=1,p=17")));
console.log(await show("custom limit below m=64", encoded, "password", { memoryCost: 32, timeCost: 12, parallelism: 16 }));
console.log(await show("custom limit at m=64", encoded, "password", { memoryCost: 64, timeCost: 1, parallelism: 1 }));
console.log(await show("wrong password", encoded, "passw0rd"));
console.log(await show("argon2i", encoded.replace("argon2id", "argon2i")));
console.log(await show("m too wide", encoded.replace(params, "m=99999999999,t=1,p=1")));
console.log(await show("m not a number", encoded.replace(params, "m=6x,t=1,p=1")));
console.log(await show("missing params", encoded.replace(params, "m=64,t=1")));
