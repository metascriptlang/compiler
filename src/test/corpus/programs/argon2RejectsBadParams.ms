// std/crypto/argon2 returns an error that names the refused parameter instead of aborting the
// process: a negative or tiny hashLen, zero or negative iterations, too little memory (also per
// lane), a lane count out of range and a short salt, through both the encoded and the raw form.
//
// @stdout: hashLen -1 err Output is too short err Output is too short|hashLen 3 err Output is too short err Output is too short|iterations 0 err Time cost is too small err Time cost is too small|iterations -1 err Time cost is too small err Time cost is too small|memory 0 err Memory cost is too small err Memory cost is too small|memory -1 err Memory cost is too small err Memory cost is too small|memory 15 for 2 lanes err Memory cost is too small err Memory cost is too small|lanes 0 err Too few lanes err Too few lanes|lanes -1 err Too few lanes err Too few lanes|salt 7 bytes err Salt is too short err Salt is too short|valid ok ok
// @exit: 0
// @skip-js: std/crypto/argon2 has only a C backend (index.cms over vendor/argon2); there is no argon2.jms
// @skip-raiser: std/crypto/argon2 has only a C backend (index.cms over vendor/argon2); there is no argon2.rms

import { argon2Hash, argon2HashRaw } from "std/crypto/argon2";

async function row(label: string, salt: string, timeCost: int32, memoryCost: int32, parallelism: int32, hashLen: int32): Promise<string> {
	const encoded = await argon2Hash("password", salt, timeCost, memoryCost, parallelism, hashLen);
	const raw = await argon2HashRaw("password", salt, timeCost, memoryCost, parallelism, hashLen);
	return `${label} ${encoded.ok ? "ok" : "err " + encoded.error.message} ${raw.ok ? "ok" : "err " + raw.error.message}`;
}

console.log([
	await row("hashLen -1", "somesalt", 1, 64, 1, -1),
	await row("hashLen 3", "somesalt", 1, 64, 1, 3),
	await row("iterations 0", "somesalt", 0, 64, 1, 16),
	await row("iterations -1", "somesalt", -1, 64, 1, 16),
	await row("memory 0", "somesalt", 1, 0, 1, 16),
	await row("memory -1", "somesalt", 1, -1, 1, 16),
	await row("memory 15 for 2 lanes", "somesalt", 1, 15, 2, 16),
	await row("lanes 0", "somesalt", 1, 64, 0, 16),
	await row("lanes -1", "somesalt", 1, 64, -1, 16),
	await row("salt 7 bytes", "1234567", 1, 64, 1, 16),
	await row("valid", "somesalt", 1, 64, 1, 16),
].join("|"));
